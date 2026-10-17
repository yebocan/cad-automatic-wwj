<#
    CadImage.ps1 — 图片预检与视觉比对
    ────────────────────────────────────────────────────────────────
    用途：用户丢来一张零件图纸的照片/截图，要求「照这个画一张」。
    在动手写 spec 之前，得先回答三个问题：

      1. 这张图能不能用？      分辨率够不够、是不是空白页、是不是黑底截图
      2. 图形在图的哪个位置？  墨迹包围盒 → 裁掉大片留白，把像素坐标换成图纸坐标
      3. 画完像不像？          与参考图逐像素比对，给一个客观的差异比例

    ★ 为什么用 System.Drawing 而不是引入 Python/OpenCV ★
      Bitmap + LockBits 在 PowerShell 里够用，且零依赖。
      实测 1600×1200 逐像素遍历（GetPixel）762ms —— 太慢，所以这里
      一律走 LockBits 拿整块字节，同尺寸约 15ms。慢 50 倍不只是体感问题：
      比对要做两次读取 + 逐像素相减，GetPixel 版本会到秒级。

    ★ 这个模块不做的事 ★
      不做 OCR，不做轮廓矢量化，不猜几何类型。图片只是「参考」，
      几何必须由人（或 AI 读着 ASCII 缩略图）写进 spec。
      理由：从位图反推精确几何一定要人工确认，自动猜出来的圆半径
      差 0.3 毫米，图上看起来完全一样，装到机器上就装不进。
#>

Add-Type -AssemblyName System.Drawing

$script:CadImageTempFiles = New-Object System.Collections.Generic.List[string]

# ══════════════════════════════════════════════════════════════════
#  内部：把任意图片读成 24bpp 的字节块
# ══════════════════════════════════════════════════════════════════

function Get-CadImagePixels {
    <#
      返回 @{ width; height; stride; bytes(byte[] BGR 顺序); bitmap }
      调用方负责 $result.bitmap.Dispose()。

      一律转成 Format24bppRgb 再 LockBits：
        · 32bpp 带 alpha 的 PNG 直接读，透明区会被当成黑色，
          判墨迹时把整张图算成"满墨"—— 必须先在白底上合成。
        · 索引色/16 位的图 stride 各不相同，统一到 24bpp 最省事。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "图片不存在: $Path"
    }

    $src = $null
    $flat = $null
    try {
        $src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Path).Path)
    } catch {
        throw "图片无法解码（不是有效的 PNG/JPEG/BMP/GIF/TIFF）: $($_.Exception.Message)"
    }

    try {
        $w = $src.Width
        $h = $src.Height
        if ($w -lt 1 -or $h -lt 1) { throw "图片尺寸异常: ${w}x${h}" }

        # 32bpp 先压到白底，避免透明像素被当成黑色墨迹
        $flat = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($flat)
        try {
            $g.Clear([System.Drawing.Color]::White)
            $g.DrawImage($src, 0, 0, $w, $h)
        } finally {
            $g.Dispose()
        }
    } finally {
        $src.Dispose()
    }

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $flat.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $stride = $data.Stride
        $bytes = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    } finally {
        $flat.UnlockBits($data)
    }

    return [pscustomobject]@{
        width  = $w
        height = $h
        stride = $stride
        bytes  = $bytes
        bitmap = $flat
    }
}

function Get-CadImageLuma {
    <#
      从 24bpp BGR 字节块取某点的亮度（0–255，BT.601 权重）。
      注意字节顺序是 B,G,R —— System.Drawing 的 24bpp 是 BGR 不是 RGB。
      按顺反了，红色会变成蓝色，用亮度判墨迹时影响不大，
      但一旦做彩色比对就会错得离谱。
    #>
    param([byte[]]$Bytes, [int]$Stride, [int]$X, [int]$Y)
    $i = $Y * $Stride + $X * 3
    return [int](0.114 * $Bytes[$i] + 0.587 * $Bytes[$i + 1] + 0.299 * $Bytes[$i + 2])
}

# ══════════════════════════════════════════════════════════════════
#  1. 图片基本信息（能不能解码、多大、什么格式）
# ══════════════════════════════════════════════════════════════════

function Get-CadImageInfo {
    param([Parameter(Mandatory)][string]$Path)

    $out = [ordered]@{
        path        = $null
        valid       = $false
        reason      = $null
        format      = $null
        width       = $null
        height      = $null
        dpiX        = $null
        dpiY        = $null
        pixelFormat = $null
        bytes       = $null
        megapixels  = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $out.reason = '文件不存在'
        return [pscustomobject]$out
    }

    $full = (Resolve-Path -LiteralPath $Path).Path
    $out.path = $full
    $out.bytes = (Get-Item -LiteralPath $full).Length

    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($full)
        $out.format      = ([string]$img.RawFormat).ToUpperInvariant() -replace '^\[', '' -replace '\]$', ''
        # RawFormat 给的是 "Png"/"Jpeg" 这类名字；用扩展名兜底更稳
        $ext = [IO.Path]::GetExtension($full).TrimStart('.').ToUpperInvariant()
        if ($ext) { $out.format = $ext }
        $out.width       = $img.Width
        $out.height      = $img.Height
        $out.dpiX        = [math]::Round($img.HorizontalResolution, 1)
        $out.dpiY        = [math]::Round($img.VerticalResolution, 1)
        $out.pixelFormat = [string]$img.PixelFormat
        $out.megapixels  = [math]::Round(($img.Width * $img.Height) / 1000000.0, 2)
        $out.valid       = $true
    } catch {
        $out.reason = "解码失败: $($_.Exception.Message)"
    } finally {
        if ($img) { $img.Dispose() }
    }

    return [pscustomobject]$out
}

# ══════════════════════════════════════════════════════════════════
#  2. 墨迹统计与包围盒（图形在图里占多大、偏在哪）
# ══════════════════════════════════════════════════════════════════

function Get-CadImageInk {
    <#
      统计「墨迹」（比背景暗的像素）。

      -Threshold 是相对亮度的分界，默认 200：白底图纸上线是黑的（<200），
      纸是白的（≈255）。照片有灰阶渐变，200 通常也够用。
      -DarkIsInk 默认 $true。若整张图平均亮度 < 110（AutoCAD 黑底截图、
      蓝图反相），自动按「亮的是墨」处理 —— 否则会把背景算成满墨，
      包围盒直接等于整张图，裁切就失去意义。

      返回 bounds 用像素坐标，原点在左上。要换成图纸坐标请用
      ConvertFrom-CadImagePixel。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Threshold = 200,
        [Nullable[bool]]$DarkIsInk = $null,
        [int]$SampleStep = 1
    )

    $out = [ordered]@{
        path          = $null
        width         = $null
        height        = $null
        threshold     = $Threshold
        darkIsInk     = $null
        sampled       = 0
        inkPixels     = 0
        inkRatio      = 0.0
        meanLuma      = $null
        contrast      = $null
        background    = $null
        bounds        = $null
        emptyBorder   = $null
    }

    if ($SampleStep -lt 1) { $SampleStep = 1 }

    $px = Get-CadImagePixels -Path $Path
    try {
        $w = $px.width
        $h = $px.height
        $out.path   = (Resolve-Path -LiteralPath $Path).Path
        $out.width  = $w
        $out.height = $h

        # 先算平均亮度，决定墨迹方向
        # ★ 亮度一律内联算，不要调 Get-CadImageLuma ★
        #   那个函数是给"偶尔读几个点"用的。逐像素调它会让每像素多一次
        #   PowerShell 函数调用开销：实测 400×260（10 万像素）从 130ms
        #   涨到 2700ms，慢 20 倍。循环内部只做算术加减乘。
        $lumaSum = [double]0
        $lumaSum2 = [double]0
        $n = 0
        for ($y = 0; $y -lt $h; $y += $SampleStep) {
            $row = $y * $px.stride
            for ($x = 0; $x -lt $w; $x += $SampleStep) {
                $i3 = $row + $x * 3
                $l = 0.114 * $px.bytes[$i3] + 0.587 * $px.bytes[$i3 + 1] + 0.299 * $px.bytes[$i3 + 2]
                $lumaSum += $l
                $lumaSum2 += ($l * $l)
                $n++
            }
        }
        $mean = if ($n -gt 0) { $lumaSum / $n } else { 0 }
        $var  = if ($n -gt 0) { [math]::Max(0, ($lumaSum2 / $n) - ($mean * $mean)) } else { 0 }
        $out.meanLuma = [math]::Round($mean, 1)
        $out.contrast = [math]::Round([math]::Sqrt($var), 1)

        $darkInk = if ($null -ne $DarkIsInk) { [bool]$DarkIsInk } else { $mean -ge 110 }
        $out.darkIsInk = $darkInk
        $out.background = if ($darkInk) { 'light' } else { 'dark' }

        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = -1; $maxY = -1
        $ink = 0
        $sampled = 0

        for ($y = 0; $y -lt $h; $y += $SampleStep) {
            $row = $y * $px.stride
            for ($x = 0; $x -lt $w; $x += $SampleStep) {
                $i3 = $row + $x * 3
                $l = 0.114 * $px.bytes[$i3] + 0.587 * $px.bytes[$i3 + 1] + 0.299 * $px.bytes[$i3 + 2]
                $isInk = if ($darkInk) { $l -lt $Threshold } else { $l -gt (255 - $Threshold) }
                $sampled++
                if ($isInk) {
                    $ink++
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }

        $out.sampled   = $sampled
        $out.inkPixels = $ink
        $out.inkRatio  = if ($sampled -gt 0) { [math]::Round($ink / $sampled, 5) } else { 0.0 }

        if ($ink -gt 0) {
            $out.bounds = [pscustomobject]@{
                minX   = $minX
                minY   = $minY
                maxX   = $maxX
                maxY   = $maxY
                width  = ($maxX - $minX + 1)
                height = ($maxY - $minY + 1)
            }
            # 四周留白：判断「图形是不是只挤在角落」「要不要裁」
            $out.emptyBorder = [pscustomobject]@{
                left   = $minX
                top    = $minY
                right  = ($w - 1 - $maxX)
                bottom = ($h - 1 - $maxY)
            }
        }
    } finally {
        if ($px.bitmap) { $px.bitmap.Dispose() }
    }

    return [pscustomobject]$out
}

# ══════════════════════════════════════════════════════════════════
#  3. 可用性判定（这张图能不能用来照抄）
# ══════════════════════════════════════════════════════════════════

function Test-CadImageUsable {
    <#
      给出「能不能拿这张图当参考」的结论。

      默认阈值的来历：
        MinWidth/MinHeight 200  —— 低于 200px，螺栓孔圆在图上不到 3px，
                                   人眼也数不准数量，别说量尺寸
        MinInkRatio 0.002       —— 1000×1000 图上至少 2000 个墨点，
                                   否则基本是空白页或一条扫描黑边
        MaxInkRatio 0.85        —— 超过 85% 是墨，多半是反相没识别对，
                                   或者整张是照片阴影
        MinContrast 12          —— 亮度标准差低于 12 说明几乎单色

      这些不是硬性物理定律，是「值得停下来问用户」的门槛。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinWidth = 200,
        [int]$MinHeight = 200,
        [double]$MinInkRatio = 0.002,
        [double]$MaxInkRatio = 0.85,
        [double]$MinContrast = 12.0,
        [int]$Threshold = 200,
        # 三值：$null = 让实测亮度自己判断（推荐）；$true = 强按白底深线；$false = 强按黑底亮线
        [Nullable[bool]]$DarkIsInk = $null
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $info = Get-CadImageInfo -Path $Path
    $ink = $null

    if (-not $info.valid) {
        return [pscustomobject]@{
            ok     = $false
            path   = $info.path
            issues = @($info.reason)
            info   = $info
            ink    = $null
            advice = '换一张能正常打开的 PNG/JPEG；把图纸另存为图片往往比截图清楚。'
        }
    }

    $ink = Get-CadImageInk -Path $Path -Threshold $Threshold -DarkIsInk $DarkIsInk

    if ($info.width -lt $MinWidth -or $info.height -lt $MinHeight) {
        $issues.Add("分辨率偏低（$($info.width)×$($info.height)，建议至少 ${MinWidth}×${MinHeight}）；细节尺寸无法可靠还原")
    }
    if ($ink.inkRatio -lt $MinInkRatio) {
        $issues.Add("墨迹只占 $([math]::Round($ink.inkRatio * 100, 3))%，接近空白图；确认导出时图形没被裁掉")
    }
    if ($ink.inkRatio -gt $MaxInkRatio) {
        $issues.Add("墨迹占 $([math]::Round($ink.inkRatio * 100, 1))%，整张图几乎全黑；可能是反相截图或阴影过重")
    }
    if ($null -ne $ink.contrast -and $ink.contrast -lt $MinContrast) {
        $issues.Add("对比度低（亮度标准差 $($ink.contrast)）；线条与背景几乎同色，量不出边界")
    }

    $advice = if ($issues.Count -eq 0) {
        '图片可用于照抄。下一步：用 -Ascii 看形状，再用 -KnownWidth 把像素坐标换算成图纸尺寸。'
    } else {
        '先解决上面几条再动手；强行照抄会把图片的模糊当成设计意图。'
    }

    return [pscustomobject]@{
        ok     = ($issues.Count -eq 0)
        path   = $info.path
        issues = $issues.ToArray()
        info   = $info
        ink    = $ink
        advice = $advice
    }
}

# ══════════════════════════════════════════════════════════════════
#  4. ASCII 缩略图（让纯文本模型也能"看"到图）
# ══════════════════════════════════════════════════════════════════

function Get-CadImageAscii {
    <#
      把图缩成字符画。这是给「没有视觉能力的模型」用的：它读不出像素，
      但能读懂下面这种东西 ——

        ....................
        ..########..........
        ..#......#..........
        ..#..OO..#..........
        ..########..........

      每个字符代表一个格子，取格子内墨迹占比映射到 5 级字符
      ' ' '.' ':' '*' '#'。列宽默认 72（终端和聊天窗口都放得下），
      行数按字符长宽比 2:1 自动折半，否则圆会被拉成椭圆。

      -Invert 交换墨/底，黑底截图想让形状"凸"出来时用。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Columns = 72,
        [int]$Rows = 0,
        [int]$Threshold = 200,
        [switch]$Invert,
        [Nullable[bool]]$DarkIsInk = $null
    )

    if ($Columns -lt 8) { $Columns = 8 }
    if ($Columns -gt 400) { $Columns = 400 }

    $px = Get-CadImagePixels -Path $Path
    try {
        $w = $px.width
        $h = $px.height

        # 先判背景方向
        $probeSum = [double]0; $probeN = 0
        for ($y = 0; $y -lt $h; $y += [math]::Max(1, [int]($h / 40))) {
            for ($x = 0; $x -lt $w; $x += [math]::Max(1, [int]($w / 40))) {
                $probeSum += Get-CadImageLuma -Bytes $px.bytes -Stride $px.stride -X $x -Y $y
                $probeN++
            }
        }
        $mean = if ($probeN -gt 0) { $probeSum / $probeN } else { 255 }
        $darkInk = if ($null -ne $DarkIsInk) { [bool]$DarkIsInk } else { $mean -ge 110 }

        $cols = $Columns
        $rows = if ($Rows -gt 0) { $Rows } else {
            $r = [int][math]::Round($cols * ($h / [double]$w) / 2.0)
            [math]::Max(4, [math]::Min(200, $r))
        }

        $cellW = $w / [double]$cols
        $cellH = $h / [double]$rows
        # 反转：让「墨多」显示成空白（黑底截图时形状才凸出来）
        $flipRamp = [bool]$Invert

        $sb = New-Object System.Text.StringBuilder
        for ($r = 0; $r -lt $rows; $r++) {
            $y0 = [int][math]::Floor($r * $cellH)
            $y1 = [int][math]::Ceiling(($r + 1) * $cellH)
            if ($y1 -le $y0) { $y1 = $y0 + 1 }
            if ($y1 -gt $h) { $y1 = $h }

            for ($c = 0; $c -lt $cols; $c++) {
                $x0 = [int][math]::Floor($c * $cellW)
                $x1 = [int][math]::Ceiling(($c + 1) * $cellW)
                if ($x1 -le $x0) { $x1 = $x0 + 1 }
                if ($x1 -gt $w) { $x1 = $w }

                # ★ 纵向逐行扫、横向抽样 ★
                # CAD 图里最多的是一条 1–2px 的横线。若两个方向都抽样，
                # 横线常常整体漏掉（实测一张带外框的图缩出来是空白）。
                # 纵向不跳行，横向按格宽 / 4 抽，代价约 100ms，换形状不漏。
                $inx = 0; $tot = 0
                $sxStep = [math]::Max(1, [int](($x1 - $x0) / 4.0))
                for ($y = $y0; $y -lt $y1; $y++) {
                    $rowBase = $y * $px.stride
                    for ($x = $x0; $x -lt $x1; $x += $sxStep) {
                        $i3 = $rowBase + $x * 3
                        $l = [int](0.114 * $px.bytes[$i3] + 0.587 * $px.bytes[$i3 + 1] + 0.299 * $px.bytes[$i3 + 2])
                        $isInk = if ($darkInk) { $l -lt $Threshold } else { $l -gt (255 - $Threshold) }
                        $tot++
                        if ($isInk) { $inx++ }
                    }
                }

                # ★ 非线性映射，专门照顾线图 ★
                # 线图的格内墨占比天生很低：一条 2px 横线穿过 13px 高的格子
                # 只有 15%，线性映射（ratio*5 取整）会把它判成空格 ——
                # 于是整张图缩出来一片空白，看起来像"没读到图"。
                # 这里以"有墨就该看见"为原则：≥1 个墨点至少给一个点。
                $ratio = if ($tot -gt 0) { $inx / [double]$tot } else { 0 }
                $ch = if ($inx -eq 0) { ' ' }
                      elseif ($ratio -lt 0.02) { '.' }
                      elseif ($ratio -lt 0.10) { ':' }
                      elseif ($ratio -lt 0.30) { '*' }
                      else { '#' }
                if ($flipRamp) {
                    $ch = switch ($ch) { ' ' { '#' } '.' { '*' } ':' { ':' } '*' { '.' } default { ' ' } }
                }
                [void]$sb.Append($ch)
            }
            [void]$sb.Append("`n")
        }

        return [pscustomobject]@{
            path      = (Resolve-Path -LiteralPath $Path).Path
            width     = $w
            height    = $h
            columns   = $cols
            rows      = $rows
            darkIsInk = $darkInk
            ascii     = $sb.ToString()
        }
    } finally {
        if ($px.bitmap) { $px.bitmap.Dispose() }
    }
}

# ══════════════════════════════════════════════════════════════════
#  5. 像素 ↔ 图纸坐标
# ══════════════════════════════════════════════════════════════════

function ConvertFrom-CadImagePixel {
    <#
      像素坐标 → 图纸坐标。

      参数怎么给：
        -KnownWidth 100   图上最左到最右那条线是 100mm（最常用）
        或者 -Scale 0.25   1px = 0.25mm（图已经带比例尺时）
        -KnownHeight 60   也可以横向给；-KnownWidth 优先
        -Bounds           Get-CadImageInk 的 bounds，把墨迹包围盒当 0..KnownWidth
        -OriginX/-OriginY 图纸原点对应的像素位置，默认就是包围盒左上角

      Y 轴方向要特别注意：像素 y 向下增，图纸 y 向上增。
      这里默认翻转（FlipY = $true），否则画出来的图上下颠倒 ——
      这个错很隐蔽，因为实体数量、图层、尺寸全都对得上。
    #>
    param(
        [Parameter(Mandatory)]$Bounds,
        [double]$KnownWidth = 0,
        [double]$KnownHeight = 0,
        [double]$Scale = 0,
        [double]$OriginX = [double]::NaN,
        [double]$OriginY = [double]::NaN,
        [switch]$NoFlipY
    )

    $bw = [double]$Bounds.width
    $bh = [double]$Bounds.height
    if ($bw -le 0 -or $bh -le 0) {
        throw "bounds 无效（宽 $bw / 高 $bh），先确认图里真的有墨迹"
    }

    $s = 0.0
    $basis = $null
    if ($Scale -gt 0) {
        $s = $Scale
        $basis = "scale=$Scale mm/px"
    } elseif ($KnownWidth -gt 0) {
        $s = $KnownWidth / $bw
        $basis = "KnownWidth=$KnownWidth 跨 $([int]$bw)px"
    } elseif ($KnownHeight -gt 0) {
        $s = $KnownHeight / $bh
        $basis = "KnownHeight=$KnownHeight 跨 $([int]$bh)px"
    } else {
        throw '必须给 -Scale、-KnownWidth 或 -KnownHeight 之一，否则像素没有物理含义'
    }

    $flip = -not $NoFlipY
    $ox = if ([double]::IsNaN($OriginX)) { [double]$Bounds.minX } else { $OriginX }
    # origin 的默认值跟翻转绑在一起：翻转时图纸 y 向上，零点取包围盒**底边**
    # （像素 y 最大处）；不翻转时图纸 y 也跟着像素向下，零点该取**顶边**。
    # 都取 maxY 的话，NoFlipY 模式会把整张图算成负坐标 —— 数值离谱但不报错，
    # 是那种"画出来才发现全在图纸外面"的坑。
    $oy = if ([double]::IsNaN($OriginY)) {
        if ($flip) { [double]$Bounds.maxY } else { [double]$Bounds.minY }
    } else { $OriginY }

    $obj = [pscustomobject]@{
        scale       = [math]::Round($s, 6)
        basis       = $basis
        originPixel = @($ox, $oy)
        flipY       = $flip
        drawWidth   = [math]::Round($bw * $s, 4)
        drawHeight  = [math]::Round($bh * $s, 4)
    }
    # ★ 必须是 ScriptMethod，不能把 scriptblock 存成属性 ★
    #   存属性时 $conv.To(1,2) 报「PSCustomObject 不包含名为 To 的方法」——
    #   PowerShell 的属性不做方法绑定，用户还得写 & $conv.To 1 2。
    #   ScriptMethod 里 $this 能读到同一对象上的 scale / originPixel / flipY。
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name To -Value {
        param([double]$X, [double]$Y)
        $sc = $this.scale
        $dx = ($X - $this.originPixel[0]) * $sc
        $dyPix = ($Y - $this.originPixel[1]) * $sc
        $dy = if ($this.flipY) { -$dyPix } else { $dyPix }
        return @([math]::Round($dx, 4), [math]::Round($dy, 4))
    }
    # 一次换一批，返回 [[x,y],...]。逐个调 To 会慢（每次都要走一遍成员解析）。
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name ToMany -Value {
        param([object[]]$Points)
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($p in $Points) {
            $out.Add($this.To([double]$p[0], [double]$p[1]))
        }
        return $out.ToArray()
    }

    return $obj
}

# ══════════════════════════════════════════════════════════════════
#  6. 视觉比对（画完的图与参考图差多少）
# ══════════════════════════════════════════════════════════════════

function Compare-CadImage {
    <#
      逐像素比对两张图。

      -Tolerance 是单通道容差（0–255，默认 32）：|A-B| > 容差才算"这一像素不同"。
      给 0 会把抗锯齿和 JPEG 噪声全算成差异；给 32 大致相当于
      "人眼扫过去看不出区别"。要严格的几何比对就别用这个模块，
      去比 DXF 的坐标（那是精确的），这里只做"像不像"的粗判。

      两张图尺寸不同时，默认把实际图缩放到参考图尺寸再比
      （-ScaleToReference $false 则直接判不可比）。
    #>
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$Actual,
        [int]$Tolerance = 32,
        [switch]$ScaleToReference,
        [int]$IgnoreBorder = 0
    )

    $out = [ordered]@{
        comparable    = $false
        reason        = $null
        reference     = $null
        actual        = $null
        width         = $null
        height        = $null
        tolerance     = $Tolerance
        diffPixels    = $null
        totalPixels   = $null
        diffRatio     = $null
        inkReference  = $null
        inkActual     = $null
        inkDiffRatio  = $null
        centroidShift = $null
        identical     = $false
        diffBounds    = $null
        verdict       = $null
    }

    $ra = Get-CadImageInfo -Path $Reference
    $ac = Get-CadImageInfo -Path $Actual
    if (-not $ra.valid) { $out.reason = "参考图不可用: $($ra.reason)"; return [pscustomobject]$out }
    if (-not $ac.valid) { $out.reason = "实际图不可用: $($ac.reason)"; return [pscustomobject]$out }
    $out.reference = $ra.path
    $out.actual = $ac.path

    # 尺寸不同 → 缩放实际图到参考图尺寸
    $targetPath = $ac.path
    $scaledTemp = $null
    if ($ra.width -ne $ac.width -or $ra.height -ne $ac.height) {
        if (-not $ScaleToReference) {
            $out.reason = "尺寸不同（参考 $($ra.width)x$($ra.height) / 实际 $($ac.width)x$($ac.height)），加 -ScaleToReference 可先缩放再比"
            return [pscustomobject]$out
        }
        $scaledTemp = Join-Path $env:TEMP ("cadimg_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
        $img = [System.Drawing.Image]::FromFile($ac.path)
        try {
            $bmp = New-Object System.Drawing.Bitmap($ra.width, $ra.height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.Clear([System.Drawing.Color]::White)
                $g.DrawImage($img, 0, 0, $ra.width, $ra.height)
            } finally { $g.Dispose() }
            $bmp.Save($scaledTemp, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        } finally {
            $img.Dispose()
        }
        $targetPath = $scaledTemp
    }

    $pxA = $null
    $pxB = $null
    try {
        $pxA = Get-CadImagePixels -Path $ra.path
        $pxB = Get-CadImagePixels -Path $targetPath

        $w = [math]::Min($pxA.width, $pxB.width)
        $h = [math]::Min($pxA.height, $pxB.height)
        $out.width = $w
        $out.height = $h

        $diff = 0
        $total = 0
        $inkA = 0      # 参考图的墨迹数
        $inkB = 0      # 实际图的墨迹数
        $inkDiff = 0   # 只有一边是墨的那部分（对称差）
        $sumXa = [double]0; $sumYa = [double]0
        $sumXb = [double]0; $sumYb = [double]0
        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = -1; $maxY = -1

        $yb0 = [math]::Max($IgnoreBorder, 0)
        $yb1 = $h - $yb0
        $xb0 = $yb0
        $xb1 = $w - $xb0
        if ($xb1 -le $xb0 -or $yb1 -le $yb0) {
            $out.reason = ' -IgnoreBorder 太大，没有可比的像素'
            return [pscustomobject]$out
        }

        for ($y = $yb0; $y -lt $yb1; $y++) {
            $rowA = $y * $pxA.stride
            $rowB = $y * $pxB.stride
            for ($x = $xb0; $x -lt $xb1; $x++) {
                $ia = $rowA + $x * 3
                $ib = $rowB + $x * 3
                $total++

                $la = 0.114 * $pxA.bytes[$ia] + 0.587 * $pxA.bytes[$ia + 1] + 0.299 * $pxA.bytes[$ia + 2]
                $lb = 0.114 * $pxB.bytes[$ib] + 0.587 * $pxB.bytes[$ib + 1] + 0.299 * $pxB.bytes[$ib + 2]
                $isInkA = $la -lt 200
                $isInkB = $lb -lt 200
                if ($isInkA) { $inkA++; $sumXa += $x; $sumYa += $y }
                if ($isInkB) { $inkB++; $sumXb += $x; $sumYb += $y }
                if ($isInkA -ne $isInkB) { $inkDiff++ }

                # 三通道任一超容差就算不同
                if ([math]::Abs([int]$pxA.bytes[$ia]     - [int]$pxB.bytes[$ib])     -gt $Tolerance -or
                    [math]::Abs([int]$pxA.bytes[$ia + 1] - [int]$pxB.bytes[$ib + 1]) -gt $Tolerance -or
                    [math]::Abs([int]$pxA.bytes[$ia + 2] - [int]$pxB.bytes[$ib + 2]) -gt $Tolerance) {
                    $diff++
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }

        $out.comparable  = $true
        $out.diffPixels  = $diff
        $out.totalPixels = $total
        $out.diffRatio   = if ($total -gt 0) { [math]::Round($diff / $total, 5) } else { 0.0 }
        $out.identical   = ($diff -eq 0)
        $out.inkReference = $inkA
        $out.inkActual    = $inkB
        # ★ 光看 diffRatio 分不出严重程度 ★
        #   白底线图墨迹只占 3%，于是「整个图形被换掉」和「平移 20px」
        #   的 diffRatio 都是 4% 出头（实测 4.55% vs 4.25%）。
        #   按墨迹并集归一化才有判别力：换掉形状≈全部墨迹都变了，
        #   平移则只有边缘一圈变化。
        # ★ 分母必须是 inkA + inkB，不是并集 ★
        #   inkDiff 是对称差。用 Jaccard 并集 (a+b+d)/2 做分母时，
        #   两张完全不相交的图会算出 2.0 —— 越界的数字没人看得懂。
        #   除以 a+b 天然落在 [0,1]：0 = 墨迹完全重合，1 = 一点不重合。
        #   第一版写成 a+b-d（= 2×交集），交集为 0 时直接除爆成 52.6。
        $inkBase = $inkA + $inkB
        $out.inkDiffRatio = if ($inkBase -gt 0) { [math]::Round($inkDiff / [double]$inkBase, 4) } else { 0.0 }

        # ★ 平移与「图形真的不同」要分开 ★
        #   整张图平移 20px 时，几乎每个墨点都换了位置，对称差接近满值，
        #   inkDiffRatio 逼近 1.0 —— 但平移是可救的（挪 origin 重画），
        #   形状变了才是真问题。两个信号一起用才分得开：
        #     ① 墨迹总量几乎不变（平移不增不减，换形状通常会变）
        #     ② 墨迹质心明显偏移
        #   实测：平移 20px → 墨量 3397/3397（比 1.00）+ 偏移 20px；
        #         换成一个椭圆 → 墨量 3397/4734（比 0.72）+ 偏移 11.8px。
        $nA = if ($inkA -gt 0) { $inkA } else { 1 }
        $nB = if ($inkB -gt 0) { $inkB } else { 1 }
        $cxA = $sumXa / $nA; $cyA = $sumYa / $nA
        $cxB = $sumXb / $nB; $cyB = $sumYb / $nB
        $shiftPx = [math]::Sqrt([math]::Pow($cxB - $cxA, 2) + [math]::Pow($cyB - $cyA, 2))
        $inkRatio = if ([math]::Max($inkA, $inkB) -gt 0) {
            [math]::Min($inkA, $inkB) / [double][math]::Max($inkA, $inkB)
        } else { 1.0 }
        $out.centroidShift = [pscustomobject]@{
            dx         = [math]::Round($cxB - $cxA, 2)
            dy         = [math]::Round($cyB - $cyA, 2)
            distance   = [math]::Round($shiftPx, 2)
            inkRatio   = [math]::Round($inkRatio, 4)
            looksLikeTranslation = ($shiftPx -gt 6 -and $inkRatio -gt 0.92)
        }

        if ($diff -gt 0) {
            $out.diffBounds = [pscustomobject]@{
                minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY
                width = ($maxX - $minX + 1); height = ($maxY - $minY + 1)
            }
        }

        $r = $out.inkDiffRatio
        # 判断顺序很重要：先说「像是整体平移」，再说「形状不同」。
        # 否则用户只会看到「差异很大」，白去改几何。
        $out.verdict = if ($diff -eq 0) { '完全一致' }
            elseif ($r -lt 0.05) { '基本一致（墨迹差异 <5%，多为抗锯齿/线宽）' }
            elseif ($out.centroidShift.looksLikeTranslation) {
                "疑似整体平移（墨迹差异 $([math]::Round($r * 100, 1))%，质心偏移 $([math]::Round($shiftPx, 1))px，墨量一致）；先用 ConvertFrom-CadImagePixel 对齐原点再比"
            }
            elseif ($r -lt 0.20) { '有局部差异（墨迹差异 5%–20%），多半是少量实体不同' }
            elseif ($r -lt 0.60) { '差异明显（墨迹差异 20%–60%），图形大体对应但有多处不同' }
            else { '差异很大（墨迹差异 >60%），不是同一张图' }
    } finally {
        if ($pxA -and $pxA.bitmap) { $pxA.bitmap.Dispose() }
        if ($pxB -and $pxB.bitmap) { $pxB.bitmap.Dispose() }
        if ($scaledTemp -and (Test-Path -LiteralPath $scaledTemp)) {
            Remove-Item -LiteralPath $scaledTemp -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]$out
}

# ══════════════════════════════════════════════════════════════════
#  7. 差异图（把不同的地方标红，方便人眼复核）
# ══════════════════════════════════════════════════════════════════

function New-CadImageDiff {
    <#
      生成一张差异可视化 PNG：参考图做底，差异像素标红。
      给的是"哪儿不一样"，不是"差多少"——数字看 Compare-CadImage。
    #>
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Output,
        [int]$Tolerance = 32
    )

    $ra = Get-CadImageInfo -Path $Reference
    $ac = Get-CadImageInfo -Path $Actual
    if (-not $ra.valid -or -not $ac.valid) { throw '两张图都要能正常读取' }
    if ($ra.width -ne $ac.width -or $ra.height -ne $ac.height) {
        throw "尺寸必须一致才能出差异图（$($ra.width)x$($ra.height) vs $($ac.width)x$($ac.height)）；先用 Compare-CadImage -ScaleToReference 看比例"
    }

    $pxA = $null
    $pxB = $null
    $outBmp = $null
    try {
        $pxA = Get-CadImagePixels -Path $ra.path
        $pxB = Get-CadImagePixels -Path $ac.path

        $outBmp = New-Object System.Drawing.Bitmap($pxA.width, $pxA.height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $pxA.width, $pxA.height)
        $data = $outBmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $stride = $data.Stride
            $buf = New-Object byte[] ($stride * $pxA.height)
            $diffCount = 0
            for ($y = 0; $y -lt $pxA.height; $y++) {
                $rowA = $y * $pxA.stride
                $rowB = $y * $pxB.stride
                $rowO = $y * $stride
                for ($x = 0; $x -lt $pxA.width; $x++) {
                    $ia = $rowA + $x * 3
                    $ib = $rowB + $x * 3
                    $io = $rowO + $x * 3
                    $d = [math]::Max(
                        [math]::Abs([int]$pxA.bytes[$ia] - [int]$pxB.bytes[$ib]),
                        [math]::Max(
                            [math]::Abs([int]$pxA.bytes[$ia+1] - [int]$pxB.bytes[$ib+1]),
                            [math]::Abs([int]$pxA.bytes[$ia+2] - [int]$pxB.bytes[$ib+2])))
                    if ($d -gt $Tolerance) {
                        # BGR：纯红 = B0 G0 R255
                        $buf[$io] = 40; $buf[$io+1] = 40; $buf[$io+2] = 235
                        $diffCount++
                    } else {
                        # 底图去饱和压暗，红色才跳得出来
                        $bl = [int](([int]$pxA.bytes[$ia] + [int]$pxA.bytes[$ia+1] + [int]$pxA.bytes[$ia+2]) / 3)
                        $soft = [int](235 - ($bl * 0.25))
                        $buf[$io] = $soft; $buf[$io+1] = $soft; $buf[$io+2] = $soft
                    }
                }
            }
            [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $data.Scan0, $buf.Length)
        } finally {
            $outBmp.UnlockBits($data)
        }

        $outFull = [IO.Path]::GetFullPath($Output)
        $dir = Split-Path -Parent $outFull
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $outBmp.Save($outFull, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($pxA -and $pxA.bitmap) { $pxA.bitmap.Dispose() }
        if ($pxB -and $pxB.bitmap) { $pxB.bitmap.Dispose() }
        if ($outBmp) { $outBmp.Dispose() }
    }

    return [pscustomobject]@{
        output = [IO.Path]::GetFullPath($Output)
        bytes  = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($Output))).Length
    }
}
