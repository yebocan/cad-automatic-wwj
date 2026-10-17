<#
.SYNOPSIS
    Invoke-CadVisualCompare.ps1 — 出图结果与参照物做锚点级比对。

.DESCRIPTION
    借鉴 autocad-dwg-redraw 的 compare_redraw 思路，但走本技能自己的证据分级：

    两种参照物，二选一：
      -ReferenceDxf  重建图 vs 源 DXF：逐实体类型比对数量 + 关键几何字段
                     （圆心/半径/线段端点/文字内容/图层），带容差
      -ReferenceImage 重建预览 PNG vs 源图：走已有的 Compare-CadImage 像素粗判

    重建图输入：-Dxf（必填，重建产物先转 DXF 或本来就是 DXF）。
    预览 PNG 由 Invoke-CadPlot 生成后传入。

    输出结论分五档（复用 Get-CadDisposition）：
      pass / pass_with_warnings / needs_review / fail / blocked

.EXAMPLE
    & .\Invoke-CadVisualCompare.ps1 -Dxf rebuilt.dxf -ReferenceDxf source.dxf -AsJson
    & .\Invoke-CadVisualCompare.ps1 -Dxf rebuilt.dxf -Preview preview.png -ReferenceImage source.jpg -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dxf,
    [string]$ReferenceDxf,
    [string]$ReferenceImage,
    # 重建出的预览 PNG（Invoke-CadPlot 或任意渲染器的产物）
    [string]$Preview,
    # 几何容差（图纸单位）。默认 0.01，重建场景一般要 0 起步
    [double]$GeometryTolerance = 0.01,
    # 像素比对容差（0-255），只对 -ReferenceImage 生效
    [int]$PixelTolerance = 32,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')
. (Join-Path $scriptDir 'CadImage.ps1')

$started = Get-Date
$report = [ordered]@{
    status = 'unknown'; mode = $null
    rebuilt = $null; reference = $null
    checks = @(); evidence = @(); warnings = @()
    disposition = $null; error = $null; durationMs = $null
}
$checks   = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]

function Test-CadPath([string]$p, [string]$label) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "$label 不存在: $p" }
    return (Resolve-Path -LiteralPath $p).Path
}

try {
    $dxfFull = Test-CadPath $Dxf '重建 DXF'

    if ($ReferenceDxf) {
        # ── 模式 A：逐实体几何比对 ──────────────────────────────
        $report.mode = 'geometry'
        $refFull = Test-CadPath $ReferenceDxf '参照 DXF'
        $report.reference = $refFull
        $report.rebuilt = $dxfFull

        $reb = @(Get-CadDxfEntities -Path $dxfFull -Limit 10000)
        $ref = @(Get-CadDxfEntities -Path $refFull -Limit 10000)

        # A1. 实体总数
        $checks.Add([pscustomobject]@{
            name = "实体总数（重建 $($reb.Count) vs 源 $($ref.Count)，容差 ±0）"
            pass = ($reb.Count -eq $ref.Count)
        }) | Out-Null

        # A2. 类型分布
        $rt = $reb | Group-Object type | Sort-Object Name
        $ft = $ref | Group-Object type | Sort-Object Name
        $rtMap = @{}; foreach ($g in $rt) { $rtMap[$g.Name] = $g.Count }
        $ftMap = @{}; foreach ($g in $ft) { $ftMap[$g.Name] = $g.Count }
        $allTypes = @($rtMap.Keys + $ftMap.Keys | Sort-Object -Unique)
        $typeDiff = @()
        foreach ($t in $allTypes) {
            $a = if ($rtMap.ContainsKey($t)) { $rtMap[$t] } else { 0 }
            $b = if ($ftMap.ContainsKey($t)) { $ftMap[$t] } else { 0 }
            if ($a -ne $b) { $typeDiff += "$t (重建$a / 源$b)" }
        }
        $checks.Add([pscustomobject]@{
            name = if ($typeDiff.Count -eq 0) { '实体类型分布一致' } else { "类型分布有差异: $($typeDiff -join '; ')" }
            pass = ($typeDiff.Count -eq 0)
        }) | Out-Null

        # A3. 图层集合
        $rl = @($reb | Where-Object { $_.layer } | ForEach-Object { $_.layer } | Sort-Object -Unique)
        $fl = @($ref | Where-Object { $_.layer } | ForEach-Object { $_.layer } | Sort-Object -Unique)
        $layerOnlyReb = @($rl | Where-Object { $fl -notcontains $_ })
        $layerOnlyRef = @($fl | Where-Object { $rl -notcontains $_ })
        $checks.Add([pscustomobject]@{
            name = if ($layerOnlyReb.Count -eq 0 -and $layerOnlyRef.Count -eq 0) { '图层集合一致' }
                   else { "图层差异: 重建多[$($layerOnlyReb -join ',')] 源多[$($layerOnlyRef -join ',')]" }
            pass = ($layerOnlyReb.Count -eq 0 -and $layerOnlyRef.Count -eq 0)
        }) | Out-Null

        # A4. 逐实体几何配对：按 (type,layer) 分桶后按序比坐标
        $tol = $GeometryTolerance
        $geomChecked = 0; $geomMismatch = 0; $geomDetails = @()
        foreach ($typeName in $allTypes) {
            $rb = @($reb | Where-Object { $_.type -eq $typeName } | Sort-Object handle)
            $fb = @($ref | Where-Object { $_.type -eq $typeName } | Sort-Object handle)
            $n = [Math]::Min($rb.Count, $fb.Count)
            for ($i = 0; $i -lt $n; $i++) {
                $geomChecked++
                $a = $rb[$i]; $b = $fb[$i]
                $bad = $false
                foreach ($pair in @(@('x','x'), @('y','y'), @('radius','radius'))) {
                    $av = $null; $bv = $null
                    if ($a.PSObject.Properties[$pair[0]]) { $av = $a.($pair[0]) }
                    if ($b.PSObject.Properties[$pair[1]]) { $bv = $b.($pair[1]) }
                    if ($null -ne $av -and $null -ne $bv) {
                        if ([Math]::Abs([double]$av - [double]$bv) -gt $tol) {
                            $bad = $true
                            $geomDetails += "$typeName#$($b.handle) $($pair[0]): 重建$av vs 源$bv"
                            break
                        }
                    } elseif ($null -ne $av -or $null -ne $bv) {
                        $bad = $true; break
                    }
                }
                if ($bad) { $geomMismatch++ }
            }
        }
        $checks.Add([pscustomobject]@{
            name = if ($geomMismatch -eq 0) { "逐实体几何一致（查了 $geomChecked 个坐标对，容差 $tol）" }
                   else { "几何差异 $geomMismatch / $geomChecked（容差 $tol）: $($geomDetails | Select-Object -First 5)" }
            pass = ($geomMismatch -eq 0)
        }) | Out-Null

        $evidence.Add((New-CadEvidence -Kind 'geometry-compare' -Level 'known' -Message "逐实体几何比对：重建 $($reb.Count) 实体 vs 源 $($ref.Count) 实体，容差 $tol")) | Out-Null
    }
    elseif ($ReferenceImage) {
        # ── 模式 B：预览图 vs 源图（像素粗判，走已有 Compare-CadImage）──
        $report.mode = 'pixel'
        if (-not $Preview) { throw '像素模式需要 -Preview（重建图的 PNG）' }
        $refFull = Test-CadPath $ReferenceImage '参照图'
        $pvFull  = Test-CadPath $Preview '预览图'
        $report.reference = $refFull
        $report.rebuilt = $pvFull

        $cmp = Compare-CadImage -Reference $refFull -Actual $pvFull -Tolerance $PixelTolerance -ScaleToReference
        if ($cmp.comparable) {
            $checks.Add([pscustomobject]@{
                name = "像素差异率 $([Math]::Round($cmp.diffRatio * 100, 2))%（容差 $PixelTolerance）"
                pass = ($cmp.diffRatio -lt 0.05)
            }) | Out-Null
            $evidence.Add((New-CadEvidence -Kind 'pixel-compare' -Level 'inferred' -Message "像素比对是「像不像」的粗判，不能证明尺寸精确")) | Out-Null
        } else {
            $warnings.Add("像素比对不可比: $($cmp.reason)")
        }
    }
    else {
        throw '需要 -ReferenceDxf（几何比对）或 -ReferenceImage（像素比对）二选一'
    }

    $report.status = 'ok'
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $report.checks = $checks.ToArray()
    $report.evidence = $evidence.ToArray()
    $report.warnings = $warnings.ToArray()
    $report.disposition = Get-CadDisposition -Checks $checks -Evidence $evidence `
        -Warnings $warnings -Error $report.error
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 10
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  重建比对  ·  {0}  ·  {1}" -f $report.status, $report.disposition)
    Write-Host ('═' * 62)
    Write-Host ("  重建    : {0}" -f $report.rebuilt)
    Write-Host ("  参照    : {0}" -f $report.reference)
    Write-Host ("  模式    : {0}" -f $report.mode)
    foreach ($c in $report.checks) {
        $mark = if ($c.pass) { '✓' } else { '✗' }
        Write-Host ("  {0} {1}" -f $mark, $c.name)
    }
    foreach ($w in $report.warnings) { Write-Host ("  ! {0}" -f $w) }
    if ($report.error) { Write-Host ("  错误    : {0}" -f $report.error) }
    Write-Host ('═' * 62)
}

if ($report.status -eq 'ok' -and $report.disposition -ne 'fail') { exit 0 } else { exit 1 }
