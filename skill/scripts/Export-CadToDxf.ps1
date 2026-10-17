<#
    Export-CadToDxf.ps1 — DWG → DXF 转换
    ────────────────────────────────────────────────────────────────
    为什么单独做一个脚本：
      DXF 是本 skill 的「独立证据」通道。DWG 是二进制，只能靠 AutoCAD 自己
      解释；DXF 是 ASCII 组码，脚本可以完全离线重新解析，从而验证「图上到底
      有什么」，而不是相信绘图脚本的自述。所以任何需要核对产物的场合，都先
      转成 DXF。

    实现方式：
      在 accoreconsole 里打开 dwg，跑 (c:SAVEDXF ...)。注意不是 SAVEAS ——
      原 dwg 一个字节都不动，只额外产出一个 dxf。

    用法：
      .\Export-CadToDxf.ps1 -Path drawing.dwg
      .\Export-CadToDxf.ps1 -Path drawing.dwg -Output drawing.dxf
      .\Export-CadToDxf.ps1 -Path drawing.dwg -AsJson
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Output,
    [ValidateSet('2018', '2013', '2010', '2007', '2004', 'R12')]
    [string]$Version = '2018',
    [switch]$AsJson,
    [int]$TimeoutSeconds = 120,
    [string]$AccoreConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')

$report = [ordered]@{
    status     = 'unknown'
    source     = $null
    output     = $null
    # 目标版本是调用方关心的信息（同一个 dwg 导出 R12 与导出 2018，
    # 文件大小和实体保真度差很多），必须出现在报告里。
    version    = $Version
    bytes      = 0
    valid      = $false
    entityCount = $null
    # 文件里实际的 $ACADVER（AC1009/AC1032…）。请求的 version 是意图，
    # 这个才是事实；两者不一致说明 DXFOUT 没吃下 _V 选项，必须能看出来。
    actualVersion = $null
    versionMatch  = $null
    warnings   = @()
    error      = $null
    durationMs = $null
}
$warnings = New-Object System.Collections.Generic.List[string]
$started = Get-Date
$tempDir = $null

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "源文件不存在: $Path"
    }
    $src = (Resolve-Path -LiteralPath $Path).Path
    $report.source = $src

    if ([IO.Path]::GetExtension($src).ToLowerInvariant() -ne '.dwg') {
        throw "只接受 .dwg 输入。如果是 DXF，直接读就行，不需要转换。"
    }

    if (-not $Output) {
        $Output = [IO.Path]::ChangeExtension($src, '.dxf')
    } elseif (-not [IO.Path]::IsPathRooted($Output)) {
        $Output = Join-Path (Split-Path -Parent $src) $Output
    }
    $outFull = [IO.Path]::GetFullPath($Output)
    $outDir = Split-Path -Parent $outFull
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    $report.output = $outFull

    Initialize-CadState | Out-Null
    $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    $accore = $accoreInfo.path

    $tempDir = Join-Path $script:CadStateDir ("dxf-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    # cadcore.lsp 必须转 GBK 副本，不能直接 load skill 目录里的 UTF-8 原件
    $coreWork = Join-Path $tempDir 'cadcore.lsp'
    Write-CadLsp -Path $coreWork -Body ([IO.File]::ReadAllText((Join-Path $scriptDir 'cadcore.lsp'), [Text.Encoding]::UTF8)) | Out-Null

    # DXF 版本控制：DXFOUT 的「第二个参数」是小数精度，不是版本。
    # 版本藏在精度提示的 _V 选项里，所以版本名原样传给 c:SAVEDXF 的第二个参数，
    # 精度固定给 16（最高精度，对 R12 也无害）。实测对应 AC1009/AC1015/AC1018/AC1021/AC1024/AC1027/AC1032。
    $verName = switch -Regex ($Version) {
        '^(?i)r12$|^(?i)14$|^(?i)r14$'  { 'R12' }
        '^(?i)2000$' { '2000' }
        '^(?i)2004$' { '2004' }
        '^(?i)2007$' { '2007' }
        '^(?i)2010$' { '2010' }
        '^(?i)2013$' { '2013' }
        '^(?i)2018$' { '2018' }
        default      { '2018' }
    }

    $lsp = Join-Path $tempDir 'export.lsp'
    Write-CadLsp -Path $lsp -Body @"
(setvar "SECURELOAD" 0)
(load "$(ConvertTo-CadPath $coreWork)")
(c:SETUP)
(c:SAVEDXF "$(ConvertTo-CadPath $outFull)" "$verName" "16")
(princ "\n@@DONE@@")
(princ)
"@ | Out-Null

    $scr = Join-Path $tempDir 'export.scr'
    Write-CadScr -Path $scr -Lines @(
        '(setvar "SECURELOAD" 0)',
        '(setvar "FILEDIA" 0)',
        '(setvar "CMDDIA" 0)',
        '(setvar "CMDECHO" 0)',
        '(setvar "EXPERT" 5)',
        "(load `"$(ConvertTo-CadPath $lsp)`")",
        '_.QUIT', '_N', '_N'
    ) | Out-Null

    $run = Invoke-CadCoreConsole -AccoreConsole $accore -Script $scr `
        -InputDwg $src -WorkingDirectory $tempDir -TimeoutSeconds $TimeoutSeconds -ReadOnly

    if ($run.lispError) { $warnings.Add("LISP 报错: $($run.lispErrorLines -join ' | ')") }
    if ($run.timedOut) { $warnings.Add("执行超时（${TimeoutSeconds}s）") }

    $exists = Test-Path -LiteralPath $outFull -PathType Leaf
    if (-not $exists) {
        throw "转换失败，未生成 DXF（exit=$($run.exitCode) $($run.exitName)）。日志: $($run.stdoutFile)"
    }

    $report.bytes = (Get-Item -LiteralPath $outFull).Length
    $check = Test-CadDxfFile -Path $outFull
    $report.valid = [bool]$check.valid
    $report.entityCount = $check.entityCount
    if (-not $check.valid) { $warnings.Add("生成的 DXF 结构校验未通过: $($check.reason)") }

    # 版本真相在文件头，不在命令行回显。请求 R12 却拿到 AC1032，
    # 说明 _V 选项没被吃下（例如版本名写错后 AutoCAD 静默回落默认版本），
    # 这种「看起来成功但版本没切」的情况必须由报告暴露，而不是让调用方自己 diff。
    $report.actualVersion = $check.version
    $expectedPair = @{
        'R12' = 'AC1009'; '2000' = 'AC1015'; '2004' = 'AC1018'; '2007' = 'AC1021'
        '2010' = 'AC1024'; '2013' = 'AC1027'; '2018' = 'AC1032'
    }
    $want = if ($expectedPair.ContainsKey($verName)) { $expectedPair[$verName] } else { $null }
    $report.versionMatch = if ($want -and $report.actualVersion) { $report.actualVersion -eq $want } else { $null }
    if ($report.versionMatch -eq $false) {
        $warnings.Add("版本未按请求生效：请求 $verName（$want），实际 $($report.actualVersion)")
    }

    $report.status = if (-not $check.valid) {
        'invalid'
    } elseif ($report.versionMatch -eq $false) {
        'partial'
    } else {
        'ok'
    }
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
    $report | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  DWG → DXF  ·  {0}" -f $report.status)
    Write-Host ('═' * 62)
    Write-Host ("  源文件  : {0}" -f $report.source)
    Write-Host ("  输出    : {0}  ({1:N0} 字节)" -f $report.output, $report.bytes)
    if ($null -ne $report.entityCount) { Write-Host ("  实体    : {0} 个" -f $report.entityCount) }
    if ($report.warnings -and @($report.warnings).Count -gt 0) {
        foreach ($w in $report.warnings) { Write-Host ("  ! {0}" -f $w) }
    }
    if ($report.error) { Write-Host ("  错误    : {0}" -f $report.error) }
    Write-Host ('═' * 62)
}

if ($report.status -eq 'ok') { exit 0 } else { exit 1 }
