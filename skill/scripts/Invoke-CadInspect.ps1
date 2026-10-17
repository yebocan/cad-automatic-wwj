<#
    Invoke-CadInspect.ps1 — 读一张已有图纸，输出结构报告
    ────────────────────────────────────────────────────────────────
    两种模式：
      · DXF（推荐）：完全离线自解析组码，不需要启动 AutoCAD，快且可复现。
      · DWG：必须经 accoreconsole 转一手 —— 打开 dwg → DXFOUT → 再按 DXF 解析。
              会产生临时文件，且需要 accoreconsole 可用。

    为什么默认走 DXF：
      这是「独立证据」。绘图脚本自己说画了 12 个实体不算证据，
      从产物文件里重新读出来的才算。所以校验一律基于 DXF 重解析。

    用法：
      .\Invoke-CadInspect.ps1 -Path drawing.dxf
      .\Invoke-CadInspect.ps1 -Path drawing.dwg
      .\Invoke-CadInspect.ps1 -Path drawing.dwg -AsJson
      .\Invoke-CadInspect.ps1 -Path drawing.dxf -Entities -Limit 100
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Entities,
    [int]$Limit = 200,
    [switch]$AsJson,
    [int]$TimeoutSeconds = 120,
    [string]$AccoreConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')

function Convert-CadDwgToDxf {
    <#
      DWG → DXF：在 accoreconsole 里打开 dwg，跑 DXFOUT。
      注意不能直接对输入 dwg 做 SAVEAS，只导出 DXF 不动原文件。
    #>
    param([string]$DwgPath, [int]$TimeoutSeconds)

    Initialize-CadState | Out-Null
    $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    $accore = $accoreInfo.path

    $work = Join-Path $script:CadStateDir ("inspect-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $coreSrc = Join-Path $scriptDir 'cadcore.lsp'
    $coreWork = Join-Path $work 'cadcore.lsp'
    Write-CadLsp -Path $coreWork -Body ([IO.File]::ReadAllText($coreSrc, [Text.Encoding]::UTF8)) | Out-Null

    $dxfOut = Join-Path $work 'inspect.dxf'
    $lsp = Join-Path $work 'inspect.lsp'
    Write-CadLsp -Path $lsp -Body @"
(setvar "SECURELOAD" 0)
(load "$(ConvertTo-CadPath $coreWork)")
(c:SETUP)
(c:SAVEDXF "$(ConvertTo-CadPath $dxfOut)" "2018" "16")
(princ "\n@@DONE@@")
(princ)
"@ | Out-Null

    $scr = Join-Path $work 'inspect.scr'
    # ★ 末尾的 _N 不能省 ★
    #   只写 _.QUIT 时，accoreconsole 还会问「是否保存对 xxx 的修改？」，
    #   没有应答就悬在那里，只能等超时（实测 122 秒才返回）。
    #   多给几个 _N 兜底：万一前面某步多问了别的，也能被吃掉。
    Write-CadScr -Path $scr -Lines @(
        '(setvar "SECURELOAD" 0)',
        '(setvar "FILEDIA" 0)',
        '(setvar "CMDDIA" 0)',
        '(setvar "CMDECHO" 0)',
        '(setvar "EXPERT" 5)',
        "(load `"$(ConvertTo-CadPath $lsp)`")",
        '_.QUIT',
        '_N', '_N', '_N'
    ) | Out-Null

    $run = Invoke-CadCoreConsole -AccoreConsole $accore -Script $scr `
        -InputDwg $DwgPath -WorkingDirectory $work -TimeoutSeconds $TimeoutSeconds -ReadOnly

    if (-not (Test-Path -LiteralPath $dxfOut -PathType Leaf)) {
        throw "DWG 转 DXF 失败（exit=$($run.exitCode) $($run.exitName)）。日志: $($run.stdoutFile)"
    }
    return [pscustomobject]@{ dxf = $dxfOut; work = $work; run = $run }
}

$report = [ordered]@{
    status      = 'unknown'
    path        = $null
    format      = $null
    valid       = $false
    entityCount = $null
    entityTypes = @()
    layers      = @()
    extents     = $null
    blockCount  = $null
    sections    = @()
    version     = $null
    entities    = @()
    warnings    = @()
    error       = $null
    durationMs  = $null
}
$warnings = New-Object System.Collections.Generic.List[string]
$started = Get-Date
$tempDir = $null

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "文件不存在: $Path"
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $report.path = $full
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()

    $dxfPath = $null
    switch ($ext) {
        '.dxf' {
            $report.format = 'dxf'
            $dxfPath = $full
        }
        '.dwg' {
            $report.format = 'dwg'
            $conv = Convert-CadDwgToDxf -DwgPath $full -TimeoutSeconds $TimeoutSeconds
            $dxfPath = $conv.dxf
            $tempDir = $conv.work
            if ($conv.run.lispError) {
                $warnings.Add("转换期 LISP 报错: $($conv.run.lispErrorLines -join ' | ')")
            }
        }
        default { throw "不支持的扩展名 '$ext'，只接受 .dxf 或 .dwg" }
    }

    $info = Get-CadDrawingInfo -Path $dxfPath
    $report.valid       = [bool]$info.dxfValid
    $report.entityCount = $info.entityCount
    $report.entityTypes = $info.entityTypes
    $report.layers      = $info.layers
    $report.extents     = $info.extents
    $report.blockCount  = $info.blockCount
    $report.sections    = $info.sections
    $report.version     = $info.version

    if (-not $info.dxfValid) { $warnings.Add("DXF 校验未通过: $($info.reason)") }
    if ($info.malformedLines -gt 0) { $warnings.Add("DXF 有 $($info.malformedLines) 行不是合法的组码/值对") }

    if ($Entities) {
        $report.entities = Get-CadDxfEntities -Path $dxfPath -Limit $Limit
    }

    $report.status = if ($info.dxfValid) { 'ok' } else { 'invalid' }
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $report.warnings = $warnings.ToArray()
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 8
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  图纸体检  ·  {0}" -f $report.status)
    Write-Host ('═' * 62)
    Write-Host ("  文件    : {0}" -f $report.path)
    Write-Host ("  格式    : {0}" -f $report.format)
    if ($report.version) { Write-Host ("  DXF 版本: {0}" -f $report.version) }
    if ($null -ne $report.entityCount) { Write-Host ("  实体    : {0} 个" -f $report.entityCount) }
    if ($report.entityTypes) {
        Write-Host '  类型分布:'
        foreach ($t in $report.entityTypes) { Write-Host ("            {0,-14} {1}" -f $t.type, $t.count) }
    }
    if ($report.layers) { Write-Host ("  图层    : {0}" -f ($report.layers -join ', ')) }
    if ($null -ne $report.blockCount) { Write-Host ("  块定义  : {0}" -f $report.blockCount) }
    if ($report.extents) {
        $e = $report.extents
        Write-Host ("  范围    : X [{0:N3}, {1:N3}]  Y [{2:N3}, {3:N3}]" -f $e.minX, $e.maxX, $e.minY, $e.maxY)
        Write-Host ("  尺寸    : {0:N3} × {1:N3}" -f $e.width, $e.height)
    }
    if ($report.sections) { Write-Host ("  DXF 段  : {0}" -f ($report.sections -join ', ')) }
    if ($report.entities -and @($report.entities).Count -gt 0) {
        Write-Host '  实体明细:'
        foreach ($en in $report.entities) {
            Write-Host ("            {0,-12} layer={1,-12} handle={2}" -f $en.type, $en.layer, $en.handle)
        }
    }
    if ($report.warnings -and @($report.warnings).Count -gt 0) {
        Write-Host '  警告    :'
        foreach ($w in $report.warnings) { Write-Host ("            ! {0}" -f $w) }
    }
    if ($report.error) { Write-Host ("  错误    : {0}" -f $report.error) }
    Write-Host ('═' * 62)
}

if ($report.status -eq 'ok') { exit 0 } else { exit 1 }
