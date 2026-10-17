<#
.SYNOPSIS
    Get-CadDwgSpecFingerprint.ps1 — 从一张已有图纸（DXF/DWG）提取「实体指纹」，
    输出结构化的 JSON 报告：实体统计、图层分布、块引用、文字与标注清单、几何锚点。

.DESCRIPTION
    这是「逆向重建」流水线的第一步（借鉴 autocad-dwg-redraw 的 prompt-builder 思路，
    用本技能自己的 DXF 解析器实现，零 Python 依赖）：

        已有图纸 ──指纹提取──▶ 结构报告 ──Invoke-CadSpecFromDwg──▶ spec JSON 骨架

    「指纹」的含义：两份图纸若实体数、类型分布、图层集合、文字内容、
    块引用全部一致，大概率是同一张图。它回答的是「这张图长什么样」，
    而不是「这张图对不对」——对错判断仍归 Invoke-CadInspect 的证据分级。

    DWG 输入走 accoreconsole 转 DXF 后解析（与 Invoke-CadInspect 相同通道）。

.PARAMETER Path
    输入图纸（.dxf 或 .dwg）。

.PARAMETER Output
    指纹报告输出路径（JSON）。留空则打印到 stdout。

.PARAMETER MaxEntities
    最多细读多少个实体（默认 2000，防超大图纸拖死解析）。

.PARAMETER AsJson
    以 JSON 打印报告（无 -Output 时的输出形式）。

.EXAMPLE
    & .\Get-CadDwgSpecFingerprint.ps1 -Path drawing.dwg -Output fp.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Output,
    [int]$MaxEntities = 2000,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')

# ── 复用 Invoke-CadInspect 的 DWG→DXF 通道（独立实现以避免跨脚本 dot-source 参数污染）──
function Convert-CadDwgToDxfLocal {
    param([string]$DwgPath, [int]$TimeoutSeconds, [string]$AccoreConsole)

    Initialize-CadState | Out-Null
    $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    $accore = $accoreInfo.path

    $work = Join-Path $script:CadStateDir ("fp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $coreSrc = Join-Path $scriptDir 'cadcore.lsp'
    $coreWork = Join-Path $work 'cadcore.lsp'
    Write-CadLsp -Path $coreWork -Body ([IO.File]::ReadAllText($coreSrc, [Text.Encoding]::UTF8)) | Out-Null

    $dxfOut = Join-Path $work 'fingerprint.dxf'
    $lsp = Join-Path $work 'fp.lsp'
    Write-CadLsp -Path $lsp -Body @"
(setvar "SECURELOAD" 0)
(load "$(ConvertTo-CadPath $coreWork)")
(c:SETUP)
(c:SAVEDXF "$(ConvertTo-CadPath $dxfOut)" "2018" "16")
(princ "\n@@DONE@@")
(princ)
"@ | Out-Null

    $scr = Join-Path $work 'fp.scr'
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
    return [pscustomobject]@{ dxf = $dxfOut; work = $work }
}

# ── 指纹提取主逻辑 ────────────────────────────────────────────────
function Get-CadFingerprintFromDxf {
    param([Parameter(Mandatory)][string]$DxfPath, [int]$MaxEntities)

    $doc = Read-CadDxfPairs -Path $DxfPath
    $pairs = $doc.pairs
    $encoding = $doc.encoding

    $inEntities = $false
    $inBlocks = $false
    $cur = $null
    $ents = New-Object System.Collections.Generic.List[object]

    function New-Ent {
        [pscustomobject]@{
            type = $null; layer = $null; handle = $null; blockRef = $null
            x = $null; y = $null; x2 = $null; y2 = $null
            r = $null; h = $null; w = $null; rot = $null
            text = $null; style = $null; color = $null
        }
    }

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]

        if ($p.code -eq 0 -and $p.value -eq 'SECTION') {
            $name = ''
            if ($i + 1 -lt $pairs.Count -and $pairs[$i+1].code -eq 2) { $name = $pairs[$i+1].value }
            if ($name -eq 'ENTITIES') { $inEntities = $true; $inBlocks = $false }
            elseif ($name -eq 'BLOCKS') { $inBlocks = $true; $inEntities = $false }
            else { $inEntities = $false; $inBlocks = $false }
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'ENDSEC') { $inEntities = $false; $inBlocks = $false; continue }

        # BLOCKS 段只收集块定义名（0=BLOCK 后紧跟的 2）
        if ($inBlocks -and $p.code -eq 0 -and $p.value -eq 'BLOCK') {
            # 跳过匿名块 (*D, *T, *U...) 由后续统计
            if ($i + 1 -lt $pairs.Count -and $pairs[$i+1].code -eq 2) {
                $blkName = $pairs[$i+1].value
                if (-not $blkName.StartsWith('*')) {
                    $ents.Add([pscustomobject]@{
                        type = '__BLOCKDEF__'; layer = $null; handle = $null; blockRef = $blkName
                        x = $null; y = $null; x2 = $null; y2 = $null
                        r = $null; h = $null; w = $null; rot = $null
                        text = $null; style = $null; color = $null
                    }) | Out-Null
                }
            }
            continue
        }

        if ($inEntities -and $p.code -eq 0) {
            if ($cur) {
                $ents.Add($cur) | Out-Null
                if ($ents.Count -ge $MaxEntities) { break }
            }
            $cur = New-Ent
            $cur.type = $p.value
            continue
        }
        if (-not $inEntities -or -not $cur) { continue }

        switch ($p.code) {
            8  { if (-not $cur.layer)  { $cur.layer = $p.value } }
            5  { if (-not $cur.handle) { $cur.handle = $p.value } }
            2  { if ($cur.type -eq 'INSERT' -and -not $cur.blockRef) { $cur.blockRef = $p.value } }
            10 { if ($null -eq $cur.x)  { $cur.x = ConvertTo-CadDouble $p.value } }
            20 { if ($null -eq $cur.y)  { $cur.y = ConvertTo-CadDouble $p.value } }
            11 { if ($null -eq $cur.x2) { $cur.x2 = ConvertTo-CadDouble $p.value } }
            21 { if ($null -eq $cur.y2) { $cur.y2 = ConvertTo-CadDouble $p.value } }
            40 { if ($null -eq $cur.r -and $cur.type -in @('CIRCLE','ARC')) { $cur.r = ConvertTo-CadDouble $p.value }
                 elseif ($null -eq $cur.h) { $cur.h = ConvertTo-CadDouble $p.value } }
            41 { if ($null -eq $cur.w) { $cur.w = ConvertTo-CadDouble $p.value } }
            50 { if ($null -eq $cur.rot) { $cur.rot = ConvertTo-CadDouble $p.value } }
            1  { if ($null -eq $cur.text -and $cur.type -in @('TEXT','MTEXT','ATTRIB')) { $cur.text = $p.value } }
            7  { if (-not $cur.style) { $cur.style = $p.value } }
            62 { if ($null -eq $cur.color) { $cur.color = ConvertTo-CadDouble $p.value } }
        }
    }
    if ($cur -and $ents.Count -lt $MaxEntities) { $ents.Add($cur) | Out-Null }

    # ── 统计聚合 ─────────────────────────────────────────────
    $realEnts = @($ents | Where-Object { $_.type -ne '__BLOCKDEF__' })
    $blockDefs = @($ents | Where-Object { $_.type -eq '__BLOCKDEF__' })

    $typeStats = @($realEnts | Group-Object type | Sort-Object Count -Descending |
        ForEach-Object { [ordered]@{ type = $_.Name; count = $_.Count } })

    $layerStats = @($realEnts | Where-Object { $_.layer } | Group-Object layer | Sort-Object Count -Descending |
        ForEach-Object { [ordered]@{ layer = $_.Name; count = $_.Count } })

    $inserts = @($realEnts | Where-Object { $_.type -eq 'INSERT' } |
        Group-Object blockRef | Sort-Object Count -Descending |
        ForEach-Object { [ordered]@{ block = $_.Name; count = $_.Count } })

    $texts = @($realEnts | Where-Object { $_.type -in @('TEXT','MTEXT') -and $_.text } |
        Select-Object -First 200 | ForEach-Object { [ordered]@{
            type = $_.type; layer = $_.layer; x = $_.x; y = $_.y
            h = $_.h; rot = $_.rot; text = $_.text } })

    $dims = @($realEnts | Where-Object { $_.type -like 'DIMENSION*' } |
        Select-Object -First 100 | ForEach-Object { [ordered]@{
            type = $_.type; layer = $_.layer; x = $_.x; y = $_.y; x2 = $_.x2; y2 = $_.y2 } })

    $circles = @($realEnts | Where-Object { $_.type -eq 'CIRCLE' -and $null -ne $_.r } |
        ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; r = $_.r; layer = $_.layer } })

    $lines = @($realEnts | Where-Object { $_.type -eq 'LINE' -and $null -ne $_.x2 } |
        ForEach-Object { [ordered]@{ x1 = $_.x; y1 = $_.y; x2 = $_.x2; y2 = $_.y2; layer = $_.layer } })

    $arcs = @($realEnts | Where-Object { $_.type -eq 'ARC' -and $null -ne $_.r } |
        ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; r = $_.r; layer = $_.layer } })

    $polylines = @($realEnts | Where-Object { $_.type -in @('LWPOLYLINE','POLYLINE') } |
        Select-Object -First 200 | ForEach-Object { [ordered]@{ layer = $_.layer; x = $_.x; y = $_.y } })

    $textStyles = @()
    try {
        $ts = @($realEnts | Where-Object { $_.style } | Group-Object style | Sort-Object Count -Descending)
        $textStyles = @($ts | ForEach-Object { [ordered]@{ style = $_.Name; count = $_.Count } })
    } catch { }

    # 指纹哈希：类型分布 + 图层集合 + 文字内容 → SHA-256
    $fpParts = @(
        (($typeStats | ForEach-Object { "$($_.type):$($_.count)" }) -join ','),
        (($layerStats | ForEach-Object { $_.layer }) -join ','),
        (($texts | ForEach-Object { $_.text }) -join '|')
    ) -join ';'
    $fpHash = ''
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($fpParts)
            $fpHash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } catch { $fpHash = $null }

    return [pscustomobject]@{
        encoding    = $encoding
        entityCount = $realEnts.Count
        truncated   = ($ents.Count -ge $MaxEntities)
        typeStats   = $typeStats
        layerStats  = $layerStats
        blockDefs   = @($blockDefs | ForEach-Object { $_.blockRef })
        inserts     = $inserts
        textStyles  = $textStyles
        texts       = $texts
        dims        = $dims
        circles     = $circles
        lines       = $lines
        arcs        = $arcs
        polylines   = $polylines
        fingerprint = $fpHash
    }
}

# ── 主流程 ────────────────────────────────────────────────────────
$started = Get-Date
$tempDir = $null
$report = [ordered]@{
    status = 'unknown'; path = $null; format = $null
    fingerprint = $null; warnings = @(); error = $null; durationMs = $null
}
$warnings = New-Object System.Collections.Generic.List[string]

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件不存在: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $report.path = $full
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()

    switch ($ext) {
        '.dxf' { $report.format = 'dxf'; $dxfPath = $full }
        '.dwg' {
            $report.format = 'dwg'
            $conv = Convert-CadDwgToDxfLocal -DwgPath $full -TimeoutSeconds 180
            $dxfPath = $conv.dxf
            $tempDir = $conv.work
        }
        default { throw "不支持的扩展名 '$ext'，只接受 .dxf 或 .dwg" }
    }

    $fp = Get-CadFingerprintFromDxf -DxfPath $dxfPath -MaxEntities $MaxEntities
    $report.fingerprint = $fp
    if ($fp.truncated) { $warnings.Add("实体数超过 -MaxEntities $MaxEntities，指纹只覆盖前 $MaxEntities 个实体") }

    $report.status = 'ok'
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

$json = $report | ConvertTo-Json -Depth 10
if ($Output) {
    $outFull = if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location) $Output }
    [IO.File]::WriteAllText($outFull, $json, [Text.Encoding]::UTF8)
    Write-Host "指纹报告已写入: $Output"
    if ($report.status -eq 'ok') {
        Write-Host ("  实体 {0} 个 · 图层 {1} 个 · 块 {2} 个 · 指纹 {3}" -f `
            $report.fingerprint.entityCount, @($report.fingerprint.layerStats).Count, `
            @($report.fingerprint.blockDefs).Count, $report.fingerprint.fingerprint.Substring(0, [Math]::Min(16, $report.fingerprint.fingerprint.Length)))
    }
} else {
    $json
}

if ($report.status -eq 'ok') { exit 0 } else { exit 1 }
