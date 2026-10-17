<#
    Get-CadImageInfo.ps1 — 图片预检、缩略图、与图纸比对
    ────────────────────────────────────────────────────────────────
    用户丢来一张零件图照片/截图，说「照这个画一张」时用这个。

    四件事：
      -Action info     这张图能不能用（分辨率/空白/反相/对比度）
      -Action ascii    把它缩成字符画 —— 没有视觉能力的模型靠这个"看"图
      -Action ink      墨迹包围盒与留白，用于裁切和坐标换算
      -Action compare  与另一张图逐像素比对，给客观差异比例 + 差异图

    它不做什么：不做 OCR、不做轮廓矢量化、不猜几何。
    图片只是参考，几何终究要写进 spec —— 从位图反推的圆半径差 0.3mm
    在屏幕上完全一样，装到机器上就装不进。

    用法：
      .\Get-CadImageInfo.ps1 -Path part.png
      .\Get-CadImageInfo.ps1 -Path part.png -Action ascii -Columns 100
      .\Get-CadImageInfo.ps1 -Path part.png -Action ink -AsJson
      .\Get-CadImageInfo.ps1 -Path part.png -Action compare -Actual drawn.png -DiffOutput diff.png
      .\Get-CadImageInfo.ps1 -Path part.png -Action convert -KnownWidth 300

    退出码：0 = 可用/一致；3 = 有告警但仍可用/有差异；1 = 不可用/不可比
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [ValidateSet('info', 'ascii', 'ink', 'compare', 'convert')]
    [string]$Action = 'info',

    # ascii
    [int]$Columns = 72,
    [int]$Rows = 0,
    [switch]$Invert,

    # ink / ascii / 可用性
    [int]$Threshold = 200,
    [Nullable[bool]]$DarkIsInk,

    # convert
    [double]$KnownWidth = 0,
    [double]$KnownHeight = 0,
    [double]$Scale = 0,
    [switch]$NoFlipY,

    # compare
    [string]$Actual,
    [int]$Tolerance = 32,
    [switch]$ScaleToReference,
    [string]$DiffOutput,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadImage.ps1')

$result = [ordered]@{
    action     = $Action
    status     = 'unknown'
    path       = $null
    exitCode   = 0
    info       = $null
    usable     = $null
    ink        = $null
    ascii      = $null
    convert    = $null
    compare    = $null
    diffImage  = $null
    warnings   = @()
    error      = $null
    durationMs = $null
}
$warnings = New-Object System.Collections.Generic.List[string]
$started = Get-Date

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "文件不存在: $Path"
    }
    $result.path = (Resolve-Path -LiteralPath $Path).Path

    switch ($Action) {
        'info' {
            $u = Test-CadImageUsable -Path $Path -Threshold $Threshold -DarkIsInk $DarkIsInk
            $result.info = $u.info
            $result.usable = [pscustomobject]@{
                ok     = $u.ok
                issues = $u.issues
                advice = $u.advice
            }
            $result.ink = $u.ink
            foreach ($i in $u.issues) { $warnings.Add($i) }
            $result.status = if ($u.ok) { 'usable' } else { 'unusable' }
        }

        'ink' {
            $k = Get-CadImageInk -Path $Path -Threshold $Threshold -DarkIsInk $DarkIsInk
            $result.ink = $k
            if ($null -eq $k.bounds) {
                $warnings.Add('图里没有找到任何墨迹；空白图无法照抄')
                $result.status = 'unusable'
            } else {
                $result.status = 'ok'
            }
        }

        'ascii' {
            $a = Get-CadImageAscii -Path $Path -Columns $Columns -Rows $Rows `
                -Threshold $Threshold -Invert:$Invert -DarkIsInk $DarkIsInk
            $result.ascii = $a
            $result.status = 'ok'
        }

        'convert' {
            if ($Scale -le 0 -and $KnownWidth -le 0 -and $KnownHeight -le 0) {
                throw 'convert 需要 -Scale、-KnownWidth 或 -KnownHeight 之一'
            }
            $k = Get-CadImageInk -Path $Path -Threshold $Threshold -DarkIsInk $DarkIsInk
            if ($null -eq $k.bounds) { throw '图里没有墨迹，无法换算坐标' }
            $result.ink = $k
            $c = ConvertFrom-CadImagePixel -Bounds $k.bounds -KnownWidth $KnownWidth `
                -KnownHeight $KnownHeight -Scale $Scale -NoFlipY:$NoFlipY
            # ScriptMethod 不能直接 JSON 序列化，摊平成纯数据
            $result.convert = [pscustomobject]@{
                scale       = $c.scale
                basis       = $c.basis
                originPixel = $c.originPixel
                flipY       = $c.flipY
                drawWidth   = $c.drawWidth
                drawHeight  = $c.drawHeight
                inkBounds   = $k.bounds
                # 给调用方算好的四个角，省得它自己再推
                corners     = [pscustomobject]@{
                    bottomLeft  = $c.To($k.bounds.minX, $k.bounds.maxY)
                    bottomRight = $c.To($k.bounds.maxX, $k.bounds.maxY)
                    topRight    = $c.To($k.bounds.maxX, $k.bounds.minY)
                    topLeft     = $c.To($k.bounds.minX, $k.bounds.minY)
                }
            }
            $result.status = 'ok'
        }

        'compare' {
            if (-not $Actual) { throw 'compare 需要 -Actual 指定要比较的另一张图' }
            if (-not (Test-Path -LiteralPath $Actual -PathType Leaf)) {
                throw "要比较的图不存在: $Actual"
            }
            $c = Compare-CadImage -Reference $Path -Actual $Actual -Tolerance $Tolerance `
                -ScaleToReference:$ScaleToReference
            $result.compare = $c
            if (-not $c.comparable) {
                $warnings.Add($c.reason)
                $result.status = 'incomparable'
            } else {
                $result.status = if ($c.identical) { 'identical' } else { 'different' }
                # 判定语已经单独打印了，别再往 warnings 里抄一遍——
                # 同一条信息出现两次，人会以为是两个独立问题。
            }
            if ($DiffOutput -and $c.comparable) {
                try {
                    $di = New-CadImageDiff -Reference $Path -Actual $Actual -Output $DiffOutput -Tolerance $Tolerance
                    $result.diffImage = $di
                } catch {
                    $warnings.Add("差异图生成失败（不影响比对结果）：$($_.Exception.Message)")
                }
            }
        }
    }
} catch {
    $result.status = 'error'
    $result.error = $_.Exception.Message
} finally {
    $result.warnings = $warnings.ToArray()
    $result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds

    switch ($result.status) {
        'usable'   { $result.exitCode = 0 }
        'identical'{ $result.exitCode = 0 }
        'ok'       { $result.exitCode = 0 }
        'different'{ $result.exitCode = 3 }
        { $_ -in @('unusable', 'incomparable', 'error') } { $result.exitCode = 1 }
        default    { $result.exitCode = 1 }
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  图片分析  ·  {0}  ·  {1}" -f $Action, $result.status)
    Write-Host ('═' * 62)
    Write-Host ("  文件    : {0}" -f $result.path)

    if ($result.info) {
        $i = $result.info
        Write-Host ("  尺寸    : {0} × {1} px  ({2} MPx)" -f $i.width, $i.height, $i.megapixels)
        Write-Host ("  格式    : {0}   DPI {1} / {2}" -f $i.format, $i.dpiX, $i.dpiY)
        Write-Host ("  文件大小: {0:N0} 字节" -f $i.bytes)
    }
    if ($result.ink -and $result.ink.bounds) {
        $k = $result.ink
        Write-Host ("  墨迹    : {0} 点，占 {1}%" -f $k.inkPixels, [math]::Round($k.inkRatio * 100, 2))
        Write-Host ("  背景    : {0}（平均亮度 {1}，对比度 {2}）" -f $k.background, $k.meanLuma, $k.contrast)
        Write-Host ("  包围盒  : X [{0}, {1}]  Y [{2}, {3}]  = {4} × {5} px" -f `
            $k.bounds.minX, $k.bounds.maxX, $k.bounds.minY, $k.bounds.maxY, $k.bounds.width, $k.bounds.height)
        Write-Host ("  四周留白: 左 {0}  上 {1}  右 {2}  下 {3}" -f `
            $k.emptyBorder.left, $k.emptyBorder.top, $k.emptyBorder.right, $k.emptyBorder.bottom)
    }
    if ($result.usable) {
        Write-Host ("  可用性  : {0}" -f $(if ($result.usable.ok) { '✓ 可以照抄' } else { '✗ 不建议直接照抄' }))
        foreach ($it in $result.usable.issues) { Write-Host ("            ! {0}" -f $it) }
        Write-Host ("  建议    : {0}" -f $result.usable.advice)
    }
    if ($result.convert) {
        $c = $result.convert
        Write-Host ("  换算    : {0}  ({1})" -f $c.scale, $c.basis)
        Write-Host ("  图纸尺寸: {0} × {1}" -f $c.drawWidth, $c.drawHeight)
        Write-Host ("  Y 翻转  : {0}" -f $c.flipY)
        Write-Host ("  四角坐标: 左下 ({0})  右上 ({1})" -f `
            ($c.corners.bottomLeft -join ', '), ($c.corners.topRight -join ', '))
    }
    if ($result.ascii) {
        Write-Host ''
        Write-Host ("  {0} × {1} 缩略图（深底={2}）：" -f $result.ascii.columns, $result.ascii.rows, $result.ascii.darkIsInk)
        Write-Host ''
        Write-Host $result.ascii.ascii
    }
    if ($result.compare) {
        $c = $result.compare
        if ($c.comparable) {
            Write-Host ("  差异    : {0} / {1} 像素（{2}%）" -f `
                $c.diffPixels, $c.totalPixels, [math]::Round($c.diffRatio * 100, 2))
            Write-Host ("  墨迹差异: {0}%   质心偏移 {1} px   墨量比 {2}" -f `
                [math]::Round($c.inkDiffRatio * 100, 1), $c.centroidShift.distance, $c.centroidShift.inkRatio)
            Write-Host ("  判定    : {0}" -f $c.verdict)
            if ($c.diffBounds) {
                Write-Host ("  差异范围: {0} × {1} px" -f $c.diffBounds.width, $c.diffBounds.height)
            }
        } else {
            Write-Host ("  不可比  : {0}" -f $c.reason)
        }
    }
    if ($result.diffImage) {
        Write-Host ("  差异图  : {0}（{1:N0} 字节，差异处标红）" -f $result.diffImage.output, $result.diffImage.bytes)
    }
    if ($result.warnings.Count -gt 0) {
        Write-Host '  提示    :'
        foreach ($w in $result.warnings) { Write-Host ("            ! {0}" -f $w) }
    }
    if ($result.error) { Write-Host ("  错误    : {0}" -f $result.error) }
    Write-Host ("  耗时    : {0} ms" -f $result.durationMs)
    Write-Host ('═' * 62)
}

exit $result.exitCode
