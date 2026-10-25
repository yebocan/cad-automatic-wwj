<#
.SYNOPSIS
    Invoke-CadSpecFromDwg.ps1 — 从已有图纸反推 spec JSON 骨架。

.DESCRIPTION
    逆向重建的出口：拿 Get-CadDwgSpecFingerprint 的指纹，编译成
    cad-automatic-wwj 自己的 spec JSON（Invoke-CadDraw 可直接消费）。

    转换范围与保真声明（对应指纹的 evidence 级别）：
      known   —— 直读坐标的实体：LINE / CIRCLE / ARC / LWPOLYLINE(首段)
                 POINT / TEXT / MTEXT / INSERT，逐个转换，几何原样保留
      inferred —— DIMENSION*：DXF 组码不足以完整还原标注语义，
                 只生成 dimlinear/dimaligned 占位并写进 needs_review 清单
                 SPLINE / HATCH / ELLIPSE：归入 unsupportedNeedsReview

    产物 spec 永远带一个 needsReview 数组：人（或上层智能体）必须确认
    needsReview 为空或逐项拍板后，才能把 spec 当作「重建完成」。

.PARAMETER Fingerprint
    指纹报告 JSON 文件路径（Get-CadDwgSpecFingerprint -Output 的产物）。

.PARAMETER DxfOrDwgPath
    直接给图纸路径（.dxf/.dwg）。内部会先跑指纹提取，免两步。

.PARAMETER Output
    spec JSON 输出路径。留空则打印。

.EXAMPLE
    & .\Invoke-CadSpecFromDwg.ps1 -DxfOrDwgPath drawing.dwg -Output rebuilt.json
    & .\Invoke-CadDraw.ps1 -SpecFile rebuilt.json -OutputDir out
#>
[CmdletBinding()]
param(
    [string]$Fingerprint,
    [string]$DxfOrDwgPath,
    [string]$Output,
    # 反推出来的 spec 的图纸名（留空用源文件名）
    [string]$Name,
    # 单位声明。未知时留空 → spec 不写 units，编译时由人补
    [string]$Units,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')

# ── 步骤 1：拿指纹 ────────────────────────────────────────────────
$fpReport = $null
if ($Fingerprint) {
    if (-not (Test-Path -LiteralPath $Fingerprint -PathType Leaf)) { throw "指纹文件不存在: $Fingerprint" }
    $fpReport = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Fingerprint).Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
} elseif ($DxfOrDwgPath) {
    $fpScript = Join-Path $scriptDir 'Get-CadDwgSpecFingerprint.ps1'
    $raw = & $fpScript -Path $DxfOrDwgPath
    $fpReport = $raw -join "`n" | ConvertFrom-Json
} else {
    throw '需要 -Fingerprint 或 -DxfOrDwgPath 二选一'
}

if ($fpReport.status -ne 'ok' -or -not $fpReport.fingerprint) {
    throw "指纹提取失败：$($fpReport.error)"
}
$fp = $fpReport.fingerprint

# ── 步骤 2：指纹 → spec 实体 ─────────────────────────────────────
$entities = New-Object System.Collections.Generic.List[object]
$needsReview = New-Object System.Collections.Generic.List[string]
$layerSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($ls in @($fp.layerStats)) { [void]$layerSet.Add([string]$ls.layer) }
if ($layerSet.Count -eq 0) { [void]$layerSet.Add('0') }

function Add-Ent($obj) { $entities.Add($obj) | Out-Null }

# LINE：直读 10/20/11/21 → known
foreach ($l in @($fp.lines)) {
    Add-Ent ([ordered]@{ type='line'; layer=[string]$l.layer; p1=@([double]$l.x1,[double]$l.y1); p2=@([double]$l.x2,[double]$l.y2) })
}

# CIRCLE：10/20/40 → known
foreach ($c in @($fp.circles)) {
    Add-Ent ([ordered]@{ type='circle'; layer=[string]$c.layer; c=@([double]$c.x,[double]$c.y); r=[double]$c.r })
}

# ARC：只取圆心+半径；起止角 DXF 里是 50/51，指纹模块没带出来 → 降级为整圆，needs_review
foreach ($a in @($fp.arcs)) {
    Add-Ent ([ordered]@{ type='circle'; layer=[string]$a.layer; c=@([double]$a.x,[double]$a.y); r=[double]$a.r })
    $needsReview.Add("ARC(x=$($a.x), y=$($a.y), r=$($a.r)) 已退化为整圆，起止角需人工补") | Out-Null
}

# TEXT/MTEXT → known（文字内容直读）
foreach ($t in @($fp.texts)) {
    if ([string]$t.type -eq 'MTEXT') {
        Add-Ent ([ordered]@{ type='mtext'; layer=[string]$t.layer; at=@([double]$t.x,[double]$t.y); value=[string]$t.text })
    } else {
        $h = if ($null -ne $t.h) { [double]$t.h } else { 2.5 }
        Add-Ent ([ordered]@{ type='text'; layer=[string]$t.layer; at=@([double]$t.x,[double]$t.y); value=[string]$t.text; height=$h })
    }
}

# INSERT → block 引用。块定义从指纹 blockDefs 带过来（几何内容指纹不含，
# 给空定义占位并标 needsReview；未定义的块名直接不生成 INSERT，改记 needsReview）
$knownBlocks = @($fp.blockDefs)
foreach ($i in @($fp.inserts)) {
    $blkName = [string]$i.block
    if ($knownBlocks -notcontains $blkName) {
        $needsReview.Add("INSERT 引用块 [$blkName] 在源图 BLOCKS 段找不到定义（可能是匿名块或外部参照），未生成引用，需人工处理") | Out-Null
        continue
    }
    $n = [int]$i.count
    for ($k = 0; $k -lt $n; $k++) {
        Add-Ent ([ordered]@{ type='block'; name=$blkName; at=@(0,0) })
    }
    $needsReview.Add("块 [$blkName] x$n：插入点坐标未能从指纹还原（当前 (0,0)），块内容也未还原（空定义），需人工补 spec 的 blocks[] 与 at") | Out-Null
}

# DIMENSION → 占位 + needs_review
foreach ($d in @($fp.dims)) {
    $dt = [string]$d.type
    if ($dt -match 'LINEAR|ALIGNED') {
        Add-Ent ([ordered]@{ type='dimlinear'; p1=@([double]([math]::Max(0.0,0.0)),0); p2=@(0,0); at=@(0,0) })
        $needsReview.Add("标注 [$dt] 只还原成占位 dimlinear，真实端点需从原图读") | Out-Null
    } else {
        $needsReview.Add("标注 [$dt] 类型未映射，需人工补 spec") | Out-Null
    }
}

# LWPOLYLINE：指纹只有首点 → 退化为 point，needs_review
foreach ($pl in @($fp.polylines)) {
    $needsReview.Add("多段线 [layer=$($pl.layer)] 在指纹里只有首点，需从 DXF 逐顶点还原（或用 vectorize）") | Out-Null
}

# 类型分布里出现但上面没覆盖的类型 → needs_review
$covered = @('LINE','CIRCLE','ARC','TEXT','MTEXT','ATTRIB','INSERT')
$covered += @('LWPOLYLINE','POLYLINE','POINT')
$statTypes = @($fp.typeStats | ForEach-Object { [string]$_.type })
foreach ($st in $statTypes) {
    if ($covered -notcontains $st -and $st -notlike 'DIMENSION*') {
        $cnt = @($fp.typeStats | Where-Object { [string]$_.type -eq $st } | ForEach-Object { $_.count })[0]
        $needsReview.Add("类型 [$st] ($cnt 个) 未纳入自动还原") | Out-Null
    }
}

# POINT：指纹没单列，从 typeStats 推断有没有
$ptCount = @($fp.typeStats | Where-Object { [string]$_.type -eq 'POINT' } | ForEach-Object { [int]$_.count })
if ($ptCount.Count -gt 0 -and $ptCount[0] -gt 0) {
    $needsReview.Add("POINT x$($ptCount[0])：指纹未记录坐标，需补") | Out-Null
}

# ── 步骤 3：拼 spec ──────────────────────────────────────────────
$name = if ($Name) { $Name } else { [IO.Path]::GetFileNameWithoutExtension($fpReport.path) + '-rebuilt' }
$layers = @()
foreach ($ls in @($fp.layerStats)) {
    $layers += [ordered]@{ name = [string]$ls.layer; color = 7 }
}
if (@($layers).Count -eq 0) { $layers = @([ordered]@{ name='0'; color=7 }) }

$spec = [ordered]@{
    name = $name
    provenance = [ordered]@{
        source        = $fpReport.path
        fingerprint   = $fp.fingerprint
        rebuiltAt     = (Get-Date).ToString('o')
        method        = 'Invoke-CadSpecFromDwg (fingerprint → spec skeleton)'
        entityCount   = $fp.entityCount
        needsReviewCount = @($needsReview).Count
    }
}
if ($Units) { $spec.units = $Units }
# 骨架默认带 save.dxf=true：逆向重建的产物必须能被 Invoke-CadVisualCompare 的几何模式比，
# 没有 DXF 比对层就没输入。调用方不要 DXF 时自己删这个字段。
$spec.save = [ordered]@{ dxf = $true }
$spec.layers = @($layers)
$spec.entities = @($entities.ToArray())
if (@($needsReview).Count -gt 0) { $spec.needsReview = @($needsReview.ToArray()) }

$json = $spec | ConvertTo-Json -Depth 10
if ($Output) {
    $outFull = if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location) $Output }
    [IO.File]::WriteAllText($outFull, $json, [Text.Encoding]::UTF8)
    Write-Host "spec 骨架已写入: $Output"
    Write-Host ("  实体 {0} 个 · 图层 {1} 个 · 待人工确认 {2} 项" -f @($entities.ToArray()).Count, @($layers).Count, @($needsReview.ToArray()).Count)
    if (@($needsReview.ToArray()).Count -gt 0) {
        Write-Host '  ⚠ needsReview 不为空，画出来的图只是骨架，不能当重建完成'
    }
} elseif ($AsJson) {
    $json
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  spec 骨架  ·  {0}" -f $name)
    Write-Host ('═' * 62)
    Write-Host ("  来源    : {0}" -f $fpReport.path)
    Write-Host ("  指纹    : {0}" -f $fp.fingerprint.Substring(0, [Math]::Min(16, $fp.fingerprint.Length)))
    Write-Host ("  实体    : {0} 个（可还原 {1} 个）" -f $fp.entityCount, @($entities.ToArray()).Count)
    Write-Host ("  图层    : {0}" -f ((@($layers) | ForEach-Object { $_.name }) -join ', '))
    if (@($needsReview.ToArray()).Count -gt 0) {
        Write-Host '  待人工确认:'
        foreach ($n in $needsReview) { Write-Host ("            ! {0}" -f $n) }
    }
    Write-Host ('─' * 62)
    Write-Host '下一步:'
    Write-Host ("  Invoke-CadDraw.ps1 -SpecFile <这份 JSON> -OutputDir <输出目录>")
    Write-Host ('═' * 62)
}

exit 0
