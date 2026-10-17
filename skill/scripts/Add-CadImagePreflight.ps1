<#
.SYNOPSIS
    Add-CadImagePreflight.ps1 — 图片进矢量重建前的质量预检。

.DESCRIPTION
    借鉴 autocad-image-redraw 的 preflight 思路，但零依赖（System.Drawing 自实现，
    不引 Python/OpenCV —— 本技能铁律是 accoreconsole + .NET 通道，谁加 Python 谁破坏
    自动化）。

    预检产出：可读性、短边长度、对比度、清晰度（拉普拉斯方差）、明暗占比、EXIF 旋转。
    这些指标决定「这张图有没有资格进 vectorize / 重建」：模糊到看不清线的图，
    矢量化出来全是噪声，不如先让人重新拍。

    预检不是拿来精确算数的 —— 拉普拉斯方差的阈值 45 / 对比度 18 是经验值，
    输出的是「风险提示」，不是「判决书」。结论仍走本技能的证据分级。

.EXAMPLE
    & .\Add-CadImagePreflight.ps1 -Image plan.jpg -Output reports\preflight.json
    & .\Add-CadImagePreflight.ps1 -Image plan.jpg -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$Output,
    # 最短边下限（像素）。低于它，小特征和文字大概率不可靠
    [int]$MinShortEdge = 700,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')

Add-Type -AssemblyName System.Drawing

$started = Get-Date
$warnings = New-Object System.Collections.Generic.List[string]
$blockers = New-Object System.Collections.Generic.List[string]
$checks   = New-Object System.Collections.Generic.List[object]

try {
    if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) {
        throw "图片不存在: $Image"
    }
    $imgFull = (Resolve-Path -LiteralPath $Image).Path
    $checks.Add([pscustomobject]@{ name = '可读'; pass = $true }) | Out-Null

    # ── 1. SHA-256：预检报告必须能锚定到具体文件 ──
    $sha = Get-CadSha256 -Path $imgFull

    # ── 2. 载入位图。System.Drawing 不认 EXIF 方向是已知坑：只报告，不假装已转正 ──
    $bmp = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap($imgFull)
    } catch {
        throw "图片解码失败: $($_.Exception.Message)"
    }

    try {
        $w = $bmp.Width; $h = $bmp.Height
        $shortEdge = [Math]::Min($w, $h)
        $checks.Add([pscustomobject]@{ name = "短边≥$MinShortEdge"; pass = ($shortEdge -ge $MinShortEdge) }) | Out-Null
        if ($shortEdge -lt $MinShortEdge) {
            $warnings.Add("短边只有 ${shortEdge}px，小特征和文字可能不可靠") | Out-Null
        }

        # ── 3. 灰度统计：LockBits 一次拿全部像素，别 GetPixel 逐点（慢 100 倍） ──
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                              [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $stride = $data.Stride
            $bytes = New-Object byte[] ($stride * $h)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        } finally {
            $bmp.UnlockBits($data)
        }

        # BGR 顺序；灰度 = 0.114B + 0.587G + 0.299R（整数移位近似即可，预检不求精度）
        $n = [long]$w * $h
        $sum = 0.0; $sumSq = 0.0; $dark = 0; $light = 0
        # 拉普拉斯方差：遍历内部像素，与 4 邻域均值之差的平方和。
        # 采样步长 2 是刻意为之——预检不需要逐像素精度，快一倍值得。
        $lapSum = 0.0; $lapSumSq = 0.0; $lapN = 0L
        $step = 2
        for ($y = 1; $y -lt $h - 1; $y += $step) {
            $row = $y * $stride
            for ($x = 1; $x -lt $w - 1; $x += $step) {
                $i = $row + $x * 3
                $b = $bytes[$i]; $g = $bytes[$i + 1]; $r = $bytes[$i + 2]
                $gray = ($r * 77 + $g * 150 + $b * 29) -shr 8
                $sum += $gray; $sumSq += [double]$gray * $gray
                if ($gray -lt 64) { $dark++ }
                elseif ($gray -gt 245) { $light++ }

                $iu = $row + ($x - 1) * 3; $id = $row + ($x + 1) * 3
                $il = ($y - 1) * $stride + $x * 3; $ir = ($y + 1) * $stride + $x * 3
                $gu = ($bytes[$il + 2] * 77 + $bytes[$il + 1] * 150 + $bytes[$il] * 29) -shr 8
                $gd = ($bytes[$ir + 2] * 77 + $bytes[$ir + 1] * 150 + $bytes[$ir] * 29) -shr 8
                $gl = ($bytes[$iu + 2] * 77 + $bytes[$iu + 1] * 150 + $bytes[$iu] * 29) -shr 8
                $gr = ($bytes[$id + 2] * 77 + $bytes[$id + 1] * 150 + $bytes[$id] * 29) -shr 8
                $lap = [double]$gray * 4 - $gu - $gd - $gl - $gr
                $lapSum += $lap; $lapSumSq += $lap * $lap; $lapN++
            }
        }

        $mean = $sum / $n
        $std = [Math]::Sqrt([Math]::Max(0.0, $sumSq / $n - $mean * $mean))
        $lapMean = $lapSum / $lapN
        $lapVar = [Math]::Max(0.0, $lapSumSq / $lapN - $lapMean * $lapMean)
        $darkFrac = $dark / $n
        $lightFrac = $light / $n

        $checks.Add([pscustomobject]@{ name = "对比度≥18"; pass = ($std -ge 18) }) | Out-Null
        if ($std -lt 18) { $warnings.Add("全局对比度低（σ={0:N1}），线条分离可能不可靠" -f $std) | Out-Null }
        $checks.Add([pscustomobject]@{ name = "清晰度≥45"; pass = ($lapVar -ge 45) }) | Out-Null
        if ($lapVar -lt 45) { $warnings.Add("拉普拉斯方差低（{0:N1}），可能模糊" -f $lapVar) | Out-Null }
        if ($lightFrac -lt 0.15 -and $darkFrac -lt 0.02) {
            $df = [Math]::Round($darkFrac * 100, 1)
            $lf = [Math]::Round($lightFrac * 100, 1)
            $warnings.Add("画面不像纸面（暗区 ${df}% / 亮区 ${lf}%），手动核对阈值与边缘设置") | Out-Null
        }

        $metrics = [ordered]@{
            width = $w; height = $h
            grayMean = [Math]::Round($mean, 2)
            grayStddev = [Math]::Round($std, 2)
            laplacianVariance = [Math]::Round($lapVar, 1)
            darkFraction = [Math]::Round($darkFrac, 4)
            lightFraction = [Math]::Round($lightFrac, 4)
        }
    } finally {
        $bmp.Dispose()
    }

    $status = if ($blockers.Count -gt 0) { 'blocked' }
              elseif ($warnings.Count -gt 0) { 'pass_with_warnings' }
              else { 'pass' }

    $checksArr = @($checks.ToArray())
    $warnArr = @($warnings.ToArray())
    $blockArr = @($blockers.ToArray())
    $report = [ordered]@{
        tool = 'Add-CadImagePreflight/1.0'
        image = $imgFull
        sha256 = $sha
        status = $status
        checks = $checksArr
        metrics = $metrics
        warnings = $warnArr
        blockers = $blockArr
        durationMs = $null
    }
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds

    if ($Output) {
        $outFull = if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location) $Output }
        $outDir = Split-Path -Parent $outFull
        if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFull -Encoding UTF8
    }

    if (-not $AsJson) {
        Write-Host ""
        Write-Host "══════════════════════════════════════════════════════════════"
        Write-Host ("  图片预检  ·  {0}" -f $status)
        Write-Host "══════════════════════════════════════════════════════════════"
        Write-Host ("  图片   : {0}" -f $imgFull)
        Write-Host ("  尺寸   : {0}×{1}" -f $metrics.width, $metrics.height)
        Write-Host ("  对比度 : {0}（阈值 18）" -f $metrics.grayStddev)
        Write-Host ("  清晰度 : {0}（阈值 45）" -f $metrics.laplacianVariance)
        Write-Host ("  明暗   : 暗 {0} / 亮 {1}" -f $metrics.darkFraction, $metrics.lightFraction)
        foreach ($wmsg in $warnings) { Write-Host ("  ! {0}" -f $wmsg) }
        foreach ($bmsg in $blockers) { Write-Host ("  ✗ {0}" -f $bmsg) }
        if ($Output) { Write-Host ("  报告   : {0}" -f $outFull) }
    }

    # 退出码：0=ok，3=blocked。与 Invoke-CadDraw/Compare 系列一致
    if ($status -eq 'blocked') { exit 3 } else { exit 0 }

} catch {
    if ($AsJson) {
        @{ tool = 'Add-CadImagePreflight/1.0'; status = 'failed'; error = $_.Exception.Message } |
            ConvertTo-Json | Write-Output
    } else {
        Write-Host ("预检失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("  行: {0}  文件: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.ScriptName)
        Write-Host $_.ScriptStackTrace
    }
    exit 1
}
