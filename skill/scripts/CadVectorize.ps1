<#
    CadVectorize.ps1 — 把位图（截图/照片/扫描线稿）转成矢量实体
    ══════════════════════════════════════════════════════════════════

    定位：pengxiaoan 的 autocad-dwg-redraw-skill 用 cv2.HoughLinesP +
    cv2.HoughCircles 做「图片 → DXF」。本机没有可用的 Python（Store
    占位存根），所以这里用纯 PowerShell + System.Drawing 重写同一件事。

    ★ 这是什么，不是什么 ★
      这是 visual vectorization（视觉矢量化），不是语义理解：
        · 只认「深色线条在浅背景上」的几何
        · 文字会被当成小墨点丢掉，不会变成 TEXT 实体
        · 齿轮会变成一坨闭合多边形，不会被认成 GEAR
      理由：从位图反推精确几何一定要人工确认。自动猜出来的圆半径
      差 0.3 毫米，屏幕上完全一样，装到机器上就装不进。
      所以本模块的产物是「候选几何」+ 证据分级，最终 spec 仍要人（或
      AI 看着字符画）确认后再画。

    ★ 算法（为什么不用 Hough 变换） ★
      Hough 要做 O(墨点数 × 角度数) 的累加投票，1600×1200 的图在
      PowerShell 里要几十秒。这里改用「连通域 + 主成分拟合」：

        1. 墨迹掩码        比背景暗即墨（自动判断深底/浅底）
        2. 连通域标记      8 邻域 BFS，一条连续的线/一个圆各成一个域
        3. 逐域判定
             a. 径向一致性 + 角度覆盖  → CIRCLE
             b. 细长度（主轴/次轴）     → LINE（PCA 拟合端点）
             c. 其余                    → 闭合凸包 POLYLINE
        4. 像素坐标 → 图纸坐标（翻 Y 轴，否则上下颠倒且不报错）

      三个判据都是「stroke-width 无关」的，线画粗画细结论不变：
        圆  用最大径向偏差 / 平均半径 ≤ 0.15
             （半径 30 的圆：偏差≈线宽/2≈1.5 → 0.05；
              边长 30 的正方形：偏差≈12.4 → 0.41，一眼分开）
        线  用细长度 sqrt(λmax/λmin) ≥ 4
        角度覆盖 ≥ 30/36 个 10° 扇区，防止把圆弧当整圆

    ★ 与 CadImage.ps1 的分工 ★
      CadImage.ps1 回答「这张图能不能用」（Test-CadImageUsable）。
      本模块回答「图里有什么几何」。前者是后者的前置检查，
      两者都读同一套 LockBits 字节块。
#>

Add-Type -AssemblyName System.Drawing

# ══════════════════════════════════════════════════════════════════
#  一、墨迹掩码
# ══════════════════════════════════════════════════════════════════

function Get-CadImageMask {
    <#
      把图片压成一块 bool[] 掩码（true = 墨）。

      返回 @{ width; height; mask(bool[]); inkCount; inkRatio; darkIsInk;
               meanLuma; threshold; bounds }

      ★ 循环内部绝不调 Get-CadImageLuma ★
        那个函数是给「偶尔读几个点」用的。逐像素调它，400×260 会从
        130ms 涨到 2700ms（慢 20 倍）。这里只做加减乘。

      darkIsInk 的判断沿用 CadImage.ps1 的口径：平均亮度 < 110 时
      按「亮的是墨」处理，否则 AutoCAD 黑底截图会被算成满墨。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Threshold = 200,
        [Nullable[bool]]$DarkIsInk = $null,
        [int]$SampleStep = 1
    )

    if ($SampleStep -lt 1) { $SampleStep = 1 }

    $px = Get-CadImagePixels -Path $Path
    try {
        $w = $px.width
        $h = $px.height
        $stride = $px.stride
        $bytes = $px.bytes

        $mask = New-Object bool[] ($w * $h)

        # ── 第一遍：平均亮度（决定墨的方向） ──
        $lumaSum = [double]0
        $n = 0
        for ($y = 0; $y -lt $h; $y += $SampleStep) {
            $row = $y * $stride
            for ($x = 0; $x -lt $w; $x += $SampleStep) {
                $i3 = $row + $x * 3
                $lumaSum += 0.114 * $bytes[$i3] + 0.587 * $bytes[$i3 + 1] + 0.299 * $bytes[$i3 + 2]
                $n++
            }
        }
        $mean = if ($n -gt 0) { $lumaSum / $n } else { 0 }

        $darkInk = if ($null -ne $DarkIsInk) { [bool]$DarkIsInk } else { $mean -ge 110 }
        # darkInk=true（亮图）→ 暗的是墨，只捕 [0, 255-Threshold]
        # darkInk=false（黑底图）→ 亮的是墨，只捕 [Threshold, 255]
        $lo = if ($darkInk) { 0 } else { $Threshold }
        $hi = if ($darkInk) { (255 - $Threshold) } else { 255 }

        # ── 第二遍：掩码 + 包围盒 ──
        $ink = 0
        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = -1; $maxY = -1
        for ($y = 0; $y -lt $h; $y++) {
            $row = $y * $stride
            $dst = $y * $w
            for ($x = 0; $x -lt $w; $x++) {
                $i3 = $row + $x * 3
                $l = 0.114 * $bytes[$i3] + 0.587 * $bytes[$i3 + 1] + 0.299 * $bytes[$i3 + 2]
                if ($l -ge $lo -and $l -le $hi) {
                    $mask[$dst + $x] = $true
                    $ink++
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }

        $bounds = $null
        if ($ink -gt 0) {
            $bounds = [pscustomobject]@{
                minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY
                width = ($maxX - $minX + 1); height = ($maxY - $minY + 1)
            }
        }

        return [pscustomobject]@{
            width      = $w
            height     = $h
            mask       = $mask
            inkCount   = $ink
            inkRatio   = if ($w * $h -gt 0) { [math]::Round($ink / ($w * $h), 5) } else { 0.0 }
            darkIsInk  = $darkInk
            meanLuma   = [math]::Round($mean, 1)
            threshold  = $Threshold
            bounds     = $bounds
        }
    } finally {
        if ($px.bitmap) { $px.bitmap.Dispose() }
    }
}

# ══════════════════════════════════════════════════════════════════
#  二、连通域标记（8 邻域 BFS）
# ══════════════════════════════════════════════════════════════════

function Get-CadMaskBlobs {
    <#
      8 邻域连通域标记。

      为什么用 BFS 而不是「迭代标签传播」：迭代法的最坏情况要跑
      「图形直径」遍全图，细长斜线的直径可能是整张图宽。BFS 用
      预分配的 int[] 队列，O(像素数) 一遍完事，时间可预测。

      每个 blob 自带 width（掩码宽），因为 pixels 存的是「y*w+x」的
      扁平下标，下游拆 x/y 时必须知道 w。少了这个字段，每次都要调用方
      额外传一次宽度，容易忘。

      返回 blob 数组（面积降序），每个 @{ id; area; width; minX; minY;
                              maxX; maxY; cx; cy; pixels(int[]); hull }
      hull 是延迟算的：只有 MinArea 以上的域才算凸包，小墨点（文字笔画、
      噪点）算它纯属浪费。要算的话把 -ComputeHull 打开。
    #>
    param(
        [Parameter(Mandatory)]$Mask,
        [int]$MinArea = 1,
        [int]$MaxPixelsPerBlob = 200000,
        [switch]$ComputeHull
    )

    $w = [int]$Mask.width
    $h = [int]$Mask.height
    $mask = $Mask.mask
    $total = $w * $h

    $labels = New-Object int[] $total
    $queue = New-Object int[] $total
    $blobs = New-Object System.Collections.Generic.List[object]

    $nextId = 0
    for ($seed = 0; $seed -lt $total; $seed++) {
        if (-not $mask[$seed] -or $labels[$seed] -ne 0) { continue }

        $nextId++
        $head = 0
        $tail = 0
        $queue[$tail++] = $seed
        $labels[$seed] = $nextId

        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = -1; $maxY = -1
        $sumX = [long]0; $sumY = [long]0
        $area = 0
        $pix = New-Object System.Collections.Generic.List[int]
        $wm1 = $w - 1
        $hm1 = $h - 1

        while ($head -lt $tail) {
            $p = $queue[$head++]
            $x = $p % $w
            $y = [math]::Floor($p / $w)

            $area++
            $sumX += $x
            $sumY += $y
            if ($pix.Count -lt $MaxPixelsPerBlob) { $pix.Add($p) }
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }

            # 8 邻域：上/下/左/右 + 四个斜向
            if ($y -gt 0) {
                $base = ($y - 1) * $w
                $np = $base + $x
                if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np }
                if ($x -gt 0)  { $np = $base + $x - 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
                if ($x -lt $wm1){ $np = $base + $x + 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
            }
            if ($y -lt $hm1) {
                $base = ($y + 1) * $w
                $np = $base + $x
                if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np }
                if ($x -gt 0)  { $np = $base + $x - 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
                if ($x -lt $wm1){ $np = $base + $x + 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
            }
            if ($x -gt 0)   { $np = $p - 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
            if ($x -lt $wm1){ $np = $p + 1; if ($mask[$np] -and $labels[$np] -eq 0) { $labels[$np] = $nextId; $queue[$tail++] = $np } }
        }

        if ($area -ge $MinArea) {
            $blobs.Add([pscustomobject]@{
                id     = $nextId
                area   = $area
                width  = $w
                minX   = $minX; minY = $minY; maxX = $maxX; maxY = $maxY
                cx     = if ($area -gt 0) { $sumX / $area } else { 0 }
                cy     = if ($area -gt 0) { $sumY / $area } else { 0 }
                pixels = $pix.ToArray()
                hull   = $null
            })
        }
    }

    $arr = $blobs.ToArray()

    # 凸包延后算：大域才算，小墨点算了也用不上
    if ($ComputeHull) {
        foreach ($b in $arr) {
            if ($b.area -lt 3) { continue }
            $h = Get-CadBlobConvexHull -Blob $b
            if ($h.Count -ge 3) {
                Add-Member -InputObject $b -MemberType NoteProperty -Name hull -Value $h -Force
            }
        }
    }

    # ★ PS5.1 单元素数组退化坑：只有一个 blob 时 Sort-Object 会把
    #   数组退化成标量，调用方 $blobs.Count 直接报「找不到属性 Count」
    #   （fixture C 全图一个大连通域就是真实触发场景）。
    #   用一元逗号保住数组形态。 ★
    return ,@($arr | Sort-Object -Property @{Expression = 'area'; Descending = $true})
}

# ══════════════════════════════════════════════════════════════════
#  三、逐域判定：圆 / 线 / 凸包
# ══════════════════════════════════════════════════════════════════

function Get-CadBlobCircleFit {
    <#
      判断一个连通域是不是「整圆」，是则给圆心与半径。

      两个独立判据，都要过：

        A. 径向一致性  最大 |r - r̄| / r̄ ≤ MaxRadialDevRatio
          这是 stroke-width 无关的：圆环的偏差恒等于线宽的一半，
          而等边正方形的偏差是 (√2-1)·R，与线宽无关。
        B. 角度覆盖    36 个 10° 扇区里至少占 MinSectors 个
          防止把 270° 圆弧、C 形、月牙当成整圆 ——
          那种形状强行当圆，端点会凭空多出材料。

      返回 $null 表示不是圆；否则 @{ cx; cy; radius; radialDev; sectors; area }

      阈值默认值不是拍的：0.15 与 30/36 在自造的「圆 vs 方 vs 圆弧」
      三组 fixture 上都能分开，且留了 2 倍余量（实测圆的偏差 ≤0.06、
      正方形 ≥0.40）。要调就一起调，只调一个会让边界形状漏过去。
    #>
    param(
        [Parameter(Mandatory)]$Blob,
        [double]$MaxRadialDevRatio = 0.15,
        [int]$MinSectors = 30,
        [int]$SectorCount = 36
    )

    $pix = $Blob.pixels
    if ($null -eq $pix -or $pix.Count -lt 12) { return $null }

    $w = [int]$Blob.width
    $cx = [double]$Blob.cx
    $cy = [double]$Blob.cy
    $n = $pix.Count

    # ★ 一遍扫完算三件事 ★
    #   平均半径、最大 |r - r̄|、扇区覆盖。
    #   r̄ 要等扫完才知道，所以 maxDev 分两遍：第一遍记 maxR 与 sumR，
    #   第二遍用 meanR 算偏离。看着像做了两倍工作，但两次都是纯算术，
    #   比「先把所有 r 存进 List 再算」省一半内存，且省掉一次 foreach
    #   的元素解引用。实测 5 万像素的圆两遍合计 24ms，可接受。
    $sumR = [double]0
    $sectors = New-Object int[] $SectorCount
    $twoPi = 2 * [math]::PI

    foreach ($p in $pix) {
        $x = $p % $w
        $y = [math]::Floor($p / $w)
        $dx = $x - $cx
        $dy = $y - $cy
        $sumR += [math]::Sqrt($dx * $dx + $dy * $dy)
        # atan2 返回 -π..π，归一到 0..2π 再切成扇区
        $ang = [math]::Atan2($dy, $dx)
        if ($ang -lt 0) { $ang += $twoPi }
        $s = [int][math]::Floor($ang / $twoPi * $SectorCount)
        if ($s -ge $SectorCount) { $s = $SectorCount - 1 }
        if ($s -lt 0) { $s = 0 }
        $sectors[$s]++
    }

    $meanR = $sumR / $n
    if ($meanR -le 0.5) { return $null }   # 半径不到半像素，等于一个墨点

    $covered = 0
    foreach ($s in $sectors) { if ($s -gt 0) { $covered++ } }
    if ($covered -lt $MinSectors) { return $null }

    # 第二遍：真正的最大径向偏离（相对均值，不是相对 0）
    $maxDev = 0.0
    foreach ($p in $pix) {
        $x = $p % $w
        $y = [math]::Floor($p / $w)
        $dx = $x - $cx
        $dy = $y - $cy
        $dev = [math]::Abs([math]::Sqrt($dx * $dx + $dy * $dy) - $meanR)
        if ($dev -gt $maxDev) { $maxDev = $dev }
    }
    $radialDev = $maxDev / $meanR
    if ($radialDev -gt $MaxRadialDevRatio) { return $null }

    return [pscustomobject]@{
        cx        = $cx
        cy        = $cy
        radius    = $meanR
        radialDev = [math]::Round($radialDev, 4)
        sectors   = $covered
        area      = $n
    }
}

function Get-CadBlobLineFit {
    <#
      判断一个连通域是不是「一条线」，是则用主成分方向给出两端点。

      细长度 = sqrt(λmax/λmin)（协方差矩阵的特征值比）。
      默认 4：一条 100px 长、3px 宽的线，λmax/λmin ≈ (100/3)² ≈ 1100，
      细长度 ≈ 33；一个 30px 的圆，λmax/λmin ≈ 1.0，细长度 ≈ 1.0。
      中间隔着一整个数量级，取 4 或取 10 结论一样。

      端点取投影到主轴上的极值（不是 bbox 对角）——
      bbox 对角在线接近竖直/水平时会短一截，画出来两头缺一截。

      返回 $null 表示不是线；否则 @{ x1; y1; x2; y2; length; elongation }
    #>
    param(
        [Parameter(Mandatory)]$Blob,
        [double]$MinElongation = 4.0
    )

    $pix = $Blob.pixels
    if ($null -eq $pix -or $pix.Count -lt 4) { return $null }

    $w = [int]$Blob.width
    $n = $pix.Count

    # 均值
    $mx = 0.0; $my = 0.0
    foreach ($p in $pix) {
        $mx += ($p % $w)
        $my += [math]::Floor($p / $w)
    }
    $mx /= $n; $my /= $n

    # 协方差矩阵（2x2 对称）
    $sxx = 0.0; $syy = 0.0; $sxy = 0.0
    foreach ($p in $pix) {
        $dx = ($p % $w) - $mx
        $dy = [math]::Floor($p / $w) - $my
        $sxx += $dx * $dx
        $syy += $dy * $dy
        $sxy += $dx * $dy
    }
    $sxx /= $n; $syy /= $n; $sxy /= $n

    # 2x2 对称矩阵特征值：λ = (T/2) ± sqrt((T/2)² - D)
    $tr = $sxx + $syy
    $det = $sxx * $syy - $sxy * $sxy
    $disc = $tr * $tr / 4.0 - $det
    if ($disc -lt 0) { $disc = 0 }
    $lmax = $tr / 2.0 + [math]::Sqrt($disc)
    $lmin = $tr / 2.0 - [math]::Sqrt($disc)
    if ($lmin -le 1e-9) { return $null }

    $elong = [math]::Sqrt($lmax / $lmin)
    if ($elong -lt $MinElongation) { return $null }

    # 主轴方向 = 最大特征值的特征向量
    # 当 sxy != 0 时 v = (lmax - syy, sxy)；接近水平/竖直时退化，取另一个公式
    $ux = ($lmax - $syy)
    $uy = $sxy
    $norm = [math]::Sqrt($ux * $ux + $uy * $uy)
    if ($norm -lt 1e-9) {
        $ux = 1.0; $uy = 0.0
    } else {
        $ux /= $norm; $uy /= $norm
    }

    # 投影极值
    $minT = [double]::MaxValue; $maxT = [double]::MinValue
    foreach ($p in $pix) {
        $dx = ($p % $w) - $mx
        $dy = [math]::Floor($p / $w) - $my
        $t = $dx * $ux + $dy * $uy
        if ($t -lt $minT) { $minT = $t }
        if ($t -gt $maxT) { $maxT = $t }
    }

    return [pscustomobject]@{
        x1         = [math]::Round($mx + $ux * $minT, 3)
        y1         = [math]::Round($my + $uy * $minT, 3)
        x2         = [math]::Round($mx + $ux * $maxT, 3)
        y2         = [math]::Round($my + $uy * $maxT, 3)
        length     = [math]::Round($maxT - $minT, 3)
        elongation = [math]::Round($elong, 2)
    }
}

function Get-CadBlobConvexHull {
    <#
      Andrew 单调链凸包，O(n log n)。给「既不是圆也不是线」的域一个
      可用的多边形轮廓（文字、齿轮、填充剖面）。

      为什么是凸包而不是轮廓跟踪：轮廓跟踪要处理孔洞与自交，
      在 PowerShell 里既慢又容易错；凸包只需要排序 + 一遍扫描，
      且对「认不出是什么」的域来说，凸包是诚实的最小外框 ——
      它不会假装自己知道内凹的形状。

      返回 [[x,y],...] 逆时针，不含重复首尾点。少于 3 点返回空数组。
    #>
    param([Parameter(Mandatory)]$Blob)

    $pix = $Blob.pixels
    if ($null -eq $pix -or $pix.Count -lt 3) { return @() }

    $w = [int]$Blob.width
    $pts = New-Object System.Collections.Generic.List[object]
    foreach ($p in $pix) {
        $pts.Add([pscustomobject]@{ x = [double]($p % $w); y = [double][math]::Floor($p / $w) })
    }
    $arr = @($pts.ToArray() | Sort-Object -Property @{Expression = 'x'; Descending = $false}, @{Expression = 'y'; Descending = $false})

    # ★ cross 用 scriptblock + GetNewClosure 会反复做闭包绑定，凸包是
    #   O(n) 次调用，几千个点就是几千次绑定 —— 直接写成一个嵌套函数
    #   （PowerShell 允许函数内定义函数，且能读外层变量）更省。
    function Cross2 {
        param($O, $A, $B)
        return ($A.x - $O.x) * ($B.y - $O.y) - ($A.y - $O.y) * ($B.x - $O.x)
    }

    $lower = New-Object System.Collections.Generic.List[object]
    foreach ($p in $arr) {
        while ($lower.Count -ge 2 -and (Cross2 $lower[$lower.Count - 2] $lower[$lower.Count - 1] $p) -le 0) {
            $lower.RemoveAt($lower.Count - 1)
        }
        $lower.Add($p)
    }

    $upper = New-Object System.Collections.Generic.List[object]
    $rev = @($arr)[($arr.Count - 1)..0]
    if ($rev.Count -gt 0) {
        foreach ($p in $rev) {
            while ($upper.Count -ge 2 -and (Cross2 $upper[$upper.Count - 2] $upper[$upper.Count - 1] $p) -le 0) {
                $upper.RemoveAt($upper.Count - 1)
            }
            $upper.Add($p)
        }
    }

    $hull = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lower.Count - 1; $i++) { $hull.Add(@($lower[$i].x, $lower[$i].y)) }
    for ($i = 0; $i -lt $upper.Count - 1; $i++) { $hull.Add(@($upper[$i].x, $upper[$i].y)) }

    if ($hull.Count -lt 3) { return @() }
    return $hull.ToArray()
}

# ══════════════════════════════════════════════════════════════════
#  三·五、文字区域检测（不依赖 OCR）
# ══════════════════════════════════════════════════════════════════

function Find-CadTextRegions {
    <#
      从连通域里挑出「像文字」的，按行聚成文字块。

      ★ 这一层完全不依赖 OCR ★
        只靠几何特征判断「这块像不像字」，不需要任何引擎。所以即使
        本机没有 OCR 语言包，也能给出「这里有一行字、大概多高、多宽、
        几个字符」—— 足以让 CAD 里建一个 TEXT 占位符并标出来。

      ★ 判据（三条，都是经验值）★
        1. 字高 8–60px：低于 8 是噪点，高于 60 多半是图框或大标题
        2. 字宽 1–60px、宽高比 ≤ 4：中文方块字接近 1:1，字母略窄；
           比例超过 4 的细长块是线，不是字
        3. 填充率 0.08–0.85：字有笔画空隙，实心块（填充区域）不是字

      ★ 为什么要按行聚合 ★
        单个字符 blob 拿去 OCR 几乎必然失败（引擎需要上下文）。而
        「同一基线上的一串字符」才是 OCR 能处理的最小单位。所以先按
        y 中心聚类成行，再按 x 间距切成文字段。

      返回 @{ regions[]; charBlobs[]; warnings[] }
        regions[] 每个 @{ id; x; y; w; h; charCount; estHeight; gap }
    #>
    param(
        [Parameter(Mandatory)]$Blobs,
        [int]$MinCharHeight = 8,
        [int]$MaxCharHeight = 60,
        [int]$MinCharWidth = 1,
        [int]$MaxCharWidth = 60,
        [double]$MaxAspect = 4.0,
        [double]$MinFill = 0.08,
        [double]$MaxFill = 0.85,
        # 行内字间距超过「平均字宽 × 这个倍数」就切成两段
        [double]$RunGapFactor = 2.0,
        # 同一行判定的 y 中心容差（相对字高）
        [double]$RowTolerance = 0.6
    )

    $warnings = New-Object System.Collections.Generic.List[string]

    # ── 1. 挑字符候选 ──
    $chars = New-Object System.Collections.Generic.List[object]
    foreach ($b in @($Blobs)) {
        if ($null -eq $b) { continue }
        # ★ blob.width 是「掩码宽度」，不是连通域宽度 ★
        #   Get-CadMaskBlobs 把 width 定义为掩码宽（因为 pixels 存的是
        #   y*w+x 扁平下标）。连通域的包围盒宽高只能由 min/max 算：
        #   w = maxX-minX+1，h = maxY-minY+1（闭区间像素）。
        #   早先误用 $b.width 当域宽，StrictMode 下读 $b.height 直接抛
        #   PropertyNotFoundStrict —— 这个坑记在这里。
        $bw = [int]$b.maxX - [int]$b.minX + 1
        $bh = [int]$b.maxY - [int]$b.minY + 1
        if ($bw -le 0 -or $bh -le 0) { continue }
        if ($bw -lt $MinCharWidth -or $bw -gt $MaxCharWidth) { continue }
        if ($bh -lt $MinCharHeight -or $bh -gt $MaxCharHeight) { continue }

        $aspect = if ($bh -gt 0) { $bw / [double]$bh } else { 999 }
        if ($aspect -gt $MaxAspect) { continue }

        $fill = if ($bw * $bh -gt 0) { $b.area / [double]($bw * $bh) } else { 0 }
        if ($fill -lt $MinFill -or $fill -gt $MaxFill) { continue }

        $chars.Add([pscustomobject]@{
            blobId = $b.id
            x = [int]$b.minX; y = [int]$b.minY
            w = $bw; h = $bh
            area = [int]$b.area
            fill = [math]::Round($fill, 3)
            cx = [double]$b.minX + $bw / 2.0
            cy = [double]$b.minY + $bh / 2.0
        })
    }

    if ($chars.Count -eq 0) {
        return [pscustomobject]@{
            regions = @(); charBlobs = @(); warnings = $warnings.ToArray()
        }
    }

    # ── 2. 按 y 中心聚成行 ──
    $sorted = @($chars | Sort-Object cy)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $sorted) {
        $placed = $false
        foreach ($row in $rows) {
            $tol = [math]::Max($c.h, $row.refH) * $RowTolerance
            if ([math]::Abs($c.cy - $row.cy) -le $tol) {
                $row.items.Add($c)
                # 行 y 中心与参考字高取累计平均，避免行越聚越偏
                $n = $row.items.Count
                $row.cy = (($row.cy * ($n - 1)) + $c.cy) / $n
                if ($c.h -gt $row.refH) { $row.refH = $c.h }
                $placed = $true
                break
            }
        }
        if (-not $placed) {
            $items = New-Object System.Collections.Generic.List[object]
            $items.Add($c)
            $rows.Add([pscustomobject]@{ cy = $c.cy; refH = $c.h; items = $items })
        }
    }

    # ── 3. 行内按 x 间距切文字段 ──
    #   ★ 这里刻意不用 scriptblock 闭包 ★
    #     上一版把「切段」写成 $flush = {...}.GetNewClosure()，结果闭包
    #     在定义时就把 $run 快照住了，后面往里 Add 的元素闭包看不见，
    #     每段都只切出第一个字符。改成把切段逻辑写成函数、显式传参，
    #     没有隐式状态就没有这个坑。
    $regions = New-Object System.Collections.Generic.List[object]
    $rid = 0

    $emitRun = {
        param($RunItems, $Gap, [ref]$Counter, $Sink)
        if ($RunItems.Count -eq 0) { return }
        $x0 = [int]::MaxValue; $y0 = [int]::MaxValue
        $x1 = -1; $y1 = -1
        $hSum = 0.0
        foreach ($it in $RunItems) {
            if ($it.x -lt $x0) { $x0 = $it.x }
            if ($it.y -lt $y0) { $y0 = $it.y }
            if (($it.x + $it.w) -gt $x1) { $x1 = $it.x + $it.w }
            if (($it.y + $it.h) -gt $y1) { $y1 = $it.y + $it.h }
            $hSum += $it.h
        }
        $Counter.Value++
        $Sink.Add([pscustomobject]@{
            id        = "T$($Counter.Value)"
            x         = $x0
            y         = $y0
            w         = ($x1 - $x0)
            h         = ($y1 - $y0)
            charCount = $RunItems.Count
            estHeight = [math]::Round(($hSum / $RunItems.Count), 1)
            gap       = [math]::Round($Gap, 1)
        }) | Out-Null
    }

    foreach ($row in $rows) {
        $ordered = @($row.items | Sort-Object x)
        if ($ordered.Count -eq 0) { continue }

        $avgW = ($ordered | Measure-Object -Property w -Average).Average
        if ($avgW -le 0) { $avgW = 1 }
        $gapLimit = $avgW * $RunGapFactor

        $run = New-Object System.Collections.Generic.List[object]
        $prevRight = $null
        $runGap = 0.0

        foreach ($c in $ordered) {
            if ($null -ne $prevRight) {
                $gap = $c.x - $prevRight
                if ($gap -gt $gapLimit) {
                    $runGap = $gap
                    & $emitRun $run $runGap ([ref]$rid) $regions
                    $run = New-Object System.Collections.Generic.List[object]
                    $runGap = 0.0
                }
            }
            $run.Add($c)
            $prevRight = $c.x + $c.w
        }
        & $emitRun $run 0 ([ref]$rid) $regions
    }

    # 单字符段多半是噪声或孤立符号，留着会让下游 OCR 白跑一遍
    $kept = @($regions | Where-Object { $_.charCount -ge 2 })
    $dropped = $regions.Count - $kept.Count
    if ($dropped -gt 0) {
        $warnings.Add("丢弃 $dropped 个单字符文字段（孤立的单个笔画多为噪点或符号）")
    }

    return [pscustomobject]@{
        regions   = $kept
        charBlobs = $chars.ToArray()
        warnings  = $warnings.ToArray()
    }
}

# ══════════════════════════════════════════════════════════════════
#  四、整图入口：掩码 → blob → 分类 → 候选几何
# ══════════════════════════════════════════════════════════════════

function Find-CadImageGeometry {
    <#
      从一张图里找出候选几何（圆 / 线 / 多边形）。

      返回 @{ width; height; darkIsInk; inkCount; inkRatio; bounds;
               circles[]; lines[]; polygons[]; blobs; evidence[]; warnings[] }

      ★ 每个几何都带 evidence 字段 ★
        circles/lines 的判定是「多特征一致」的结果，判据本身可复现，
        所以是 known 级；
        polygons 是「认不出是什么，只给最小外框」，所以是 inferred 级 ——
        它可能是齿轮、可能是文字、也可能是个污点。这一级绝不能当成
        可以直接画进 spec 的结论。

      ★ 为什么默认跳过小域 ★
        MinBlobArea 默认 40：一条 200px 长、2px 粗的线是 400 个像素，
        一个 r=4 的细圆环约 2πr·线宽 ≈ 100。低于 40 的基本是文字笔画、
        噪点、JPEG 压缩残留。把它们算进来会产出几十个无意义实体，
        把真正该人看的圆和线埋掉。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Threshold = 200,
        [Nullable[bool]]$DarkIsInk = $null,
        [int]$MinBlobArea = 40,
        [int]$MaxResults = 200,
        [double]$CircleRadialDev = 0.15,
        [int]$CircleMinSectors = 30,
        [double]$LineElongation = 4.0,
        # ── 文字 ──
        # 默认开着：文字区域检测不依赖 OCR，纯几何判断，代价很低。
        # 关掉它才会出现「图里明明有字，输出里一个字都没有」的老问题。
        [switch]$DetectText = $true,
        # OCR 默认关：慢（每段要裁图+放大+识别），而且本机实测在低分辨率
        # 工程图上识别率极低。需要文字内容时显式打开，并接受 inferred 级证据。
        [switch]$Ocr,
        [string]$OcrLanguage = 'zh-Hans-CN',
        [int]$OcrUpscale = 3,
        [int]$MinTextCharHeight = 8,
        [int]$MaxTextCharHeight = 60
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[object]

    $mask = Get-CadImageMask -Path $Path -Threshold $Threshold -DarkIsInk $DarkIsInk

    $circles = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[object]
    $polys = New-Object System.Collections.Generic.List[object]

    if ($mask.inkCount -le 0) {
        $warnings.Add('图里没有墨迹（全白或全黑），换一张或调 -Threshold')
        return [pscustomobject]@{
            width = $mask.width; height = $mask.height
            darkIsInk = $mask.darkIsInk; inkCount = 0; inkRatio = 0.0
            bounds = $null; circles = @(); lines = @(); polygons = @()
            textRegions = @(); textDetection = $null
            blobs = @(); evidence = $evidence.ToArray(); warnings = $warnings.ToArray()
        }
    }

    $blobs = Get-CadMaskBlobs -Mask $mask -MinArea $MinBlobArea
    $skipped = 0

    # ── 文字区域检测 ──
    # ★ 必须在几何分类之前跑 ★
    #   文字笔画也会被当成「线」或「多边形」收进 circles/lines/polygons。
    #   先算出文字区域，后面就能把落在文字区域里的实体剔掉，避免一张
    #   图上几十个字符笔画全变成 IMAGE_LINE 垃圾线。
    $textRegions = @()
    $textDetection = $null
    if ($DetectText) {
        try {
            $td = Find-CadTextRegions -Blobs $blobs `
                -MinCharHeight $MinTextCharHeight -MaxCharHeight $MaxTextCharHeight
            $textRegions = @($td.regions)
            foreach ($w in $td.warnings) { $warnings.Add($w) }

            $textDetection = [ordered]@{
                available   = $true
                regions     = $textRegions.Count
                charBlobs   = @($td.charBlobs).Count
                ocr         = $false
                ocrLanguage = $null
                ocrOk       = 0
                ocrFailed   = 0
            }

            # ── 可选：OCR 出文字内容 ──
            if ($Ocr -and $textRegions.Count -gt 0) {
                if (-not (Get-Command Invoke-CadOcrRegions -ErrorAction SilentlyContinue)) {
                    . (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'CadOcr.ps1')
                }
                $ocrOut = Invoke-CadOcrRegions -ImagePath $Path -Regions $textRegions `
                    -Language $OcrLanguage -Upscale $OcrUpscale

                $textDetection.ocr = [bool]$ocrOut.available
                $textDetection.ocrLanguage = $ocrOut.language
                if (-not $ocrOut.available) {
                    $warnings.Add("OCR 不可用，只给了文字区域没有文字内容：$($ocrOut.error)")
                } else {
                    $byId = @{}
                    foreach ($r in @($ocrOut.results)) { $byId[[string]$r.id] = $r }
                    foreach ($tr in $textRegions) {
                        $hit = $byId[[string]$tr.id]
                        if ($null -ne $hit -and $hit.ok) {
                            $tr | Add-Member -NotePropertyName text -NotePropertyValue ([string]$hit.text) -Force
                            if ($hit.text) { $textDetection.ocrOk++ } else { $textDetection.ocrFailed++ }
                        } else {
                            $tr | Add-Member -NotePropertyName text -NotePropertyValue '' -Force
                            $textDetection.ocrFailed++
                        }
                    }
                    if ($textDetection.ocrOk -eq 0) {
                        $warnings.Add("OCR 跑通了但一个字都没认出来（$($textRegions.Count) 个文字段全部失败）。低分辨率扫描图常见；文字区域坐标仍然可用，内容请人工填。")
                    } elseif ($textDetection.ocrOk -lt $textRegions.Count) {
                        $warnings.Add("OCR 只认出 $($textDetection.ocrOk)/$($textRegions.Count) 个文字段，其余为空。OCR 结果一律 inferred 级，必须人工核对。")
                    }
                }
            }
        } catch {
            $warnings.Add("文字区域检测失败（不影响几何）：$($_.Exception.Message)")
            $textDetection = [ordered]@{ available = $false; regions = 0; charBlobs = 0; ocr = $false; error = $_.Exception.Message }
        }
    }

    # 文字区域覆盖判定：实体中心落在某个文字区域内就视为文字笔画
    $inTextRegion = {
        param($Cx, $Cy)
        foreach ($tr in $textRegions) {
            if ($Cx -ge $tr.x -and $Cx -le ($tr.x + $tr.w) -and
                $Cy -ge $tr.y -and $Cy -le ($tr.y + $tr.h)) { return $true }
        }
        return $false
    }
    $textStrokes = 0

    foreach ($b in $blobs) {
        if (($circles.Count + $lines.Count + $polys.Count) -ge $MaxResults) {
            $skipped++
            continue
        }

        # ★ 落在文字区域里的连通域是笔画，不是几何 ★
        #   不剔掉的话，一行「三相电动机」会变成十几个 IMAGE_LINE，
        #   把真正的线埋掉，还会让人以为图里有大量短线段。
        if ($textRegions.Count -gt 0) {
            $bcx = ([int]$b.minX + [int]$b.maxX) / 2.0
            $bcy = ([int]$b.minY + [int]$b.maxY) / 2.0
            if (& $inTextRegion $bcx $bcy) {
                $textStrokes++
                continue
            }
        }

        $c = Get-CadBlobCircleFit -Blob $b -MaxRadialDevRatio $CircleRadialDev -MinSectors $CircleMinSectors
        if ($null -ne $c) {
            $circles.Add([pscustomobject]@{
                kind       = 'circle'
                cx         = [math]::Round($c.cx, 3)
                cy         = [math]::Round($c.cy, 3)
                r          = [math]::Round($c.radius, 3)
                pixelArea  = $b.area
                radialDev  = $c.radialDev
                sectors    = $c.sectors
                evidence   = (New-CadEvidence -Kind 'image-circle' -Level 'known' `
                                -Message "圆心 ($($c.cx),$($c.cy)) 半径 $([math]::Round($c.radius,2))px，径向偏差 $($c.radialDev)，覆盖 $($c.sectors)/36 扇区" `
                                -Value $c.radius -Source "$Path blob#$($b.id)")
            })
            continue
        }

        $l = Get-CadBlobLineFit -Blob $b -MinElongation $LineElongation
        if ($null -ne $l) {
            $lines.Add([pscustomobject]@{
                kind       = 'line'
                x1         = $l.x1; y1 = $l.y1; x2 = $l.x2; y2 = $l.y2
                length     = $l.length
                elongation = $l.elongation
                pixelArea  = $b.area
                evidence   = (New-CadEvidence -Kind 'image-line' -Level 'known' `
                                -Message "线 ($($l.x1),$($l.y1))→($($l.x2),$($l.y2))，长 $($l.length)px，细长度 $($l.elongation)" `
                                -Value $l.length -Source "$Path blob#$($b.id)")
            })
            continue
        }

        # ★ 凸包可能是空的 ★
        #   Get-CadBlobConvexHull 内部 return @()，而 PowerShell 的管道
        #   语义会把这个空数组压成 $null 返回给调用方。StrictMode Latest
        #   下 $null.Count 直接抛 PropertyNotFoundStrict —— 不是「返回 0」
        #   而是整张图解析崩掉。所以必须先判空再取 Count。
        $hull = @(Get-CadBlobConvexHull -Blob $b)
        if ($hull.Count -ge 3) {
            $polys.Add([pscustomobject]@{
                kind      = 'polygon'
                points    = $hull
                pixelArea = $b.area
                evidence  = (New-CadEvidence -Kind 'image-polygon' -Level 'inferred' `
                               -Message "未识别的连通域 #$($b.id)，面积 $($b.area)px，给出 $($hull.Count) 点凸包当最小外框；可能是齿轮/文字/污点，**不能直接当几何用**" `
                               -Value $b.area -Source "$Path blob#$($b.id)" -Supports $false)
            })
        }
    }

    $evidence.Add((New-CadEvidence -Kind 'image-ink' -Level 'known' `
        -Message "掩码：$($mask.width)x$($mask.height)，墨 $($mask.inkCount)px（$([math]::Round($mask.inkRatio * 100, 2))%），$(if ($mask.darkIsInk) {'黑底亮线'} else {'白底深线'})" `
        -Value $mask.inkCount -Source $Path))

    $evidence.Add((New-CadEvidence -Kind 'image-geometry' -Level 'known' `
        -Message "分类结果：圆 $($circles.Count) / 线 $($lines.Count) / 未识别 $($polys.Count)（共 $($blobs.Count) 个连通域 ≥$MinBlobArea px）" `
        -Value ($circles.Count + $lines.Count) -Source $Path))

    if ($null -ne $textDetection -and $textDetection.available) {
        $evidence.Add((New-CadEvidence -Kind 'image-text-region' -Level 'known' `
            -Message "文字区域 $($textRegions.Count) 段（$($textDetection.charBlobs) 个字符笔画），剔除落在其中的 $textStrokes 个连通域；文字内容 $(if ($textDetection.ocr) { "OCR 认出 $($textDetection.ocrOk)/$($textRegions.Count)" } else { '未做 OCR（只给位置）' })" `
            -Value $textRegions.Count -Source $Path))
    }

    if ($skipped -gt 0) {
        $warnings.Add("达到上限 $MaxResults，还有 $skipped 个连通域未处理；图可能太碎（噪点多）或该先裁掉空白边")
    }
    if ($polys.Count -gt $circles.Count + $lines.Count -and $polys.Count -gt 3) {
        $warnings.Add("未识别域（$($polys.Count)）多于已识别几何 —— 这份图多半不是干净线稿，或文字/剖面线太多；先看图再写 spec")
    }
    if ($textStrokes -gt 0) {
        $warnings.Add("有 $textStrokes 个连通域被判定为文字笔画并从几何里剔除；它们的位置在 textRegions 里，内容需要人工填或开 -Ocr")
    }

    return [pscustomobject]@{
        width         = $mask.width
        height        = $mask.height
        darkIsInk     = $mask.darkIsInk
        inkCount      = $mask.inkCount
        inkRatio      = $mask.inkRatio
        bounds        = $mask.bounds
        circles       = $circles.ToArray()
        lines         = $lines.ToArray()
        polygons      = $polys.ToArray()
        textRegions   = @($textRegions)
        textDetection = $textDetection
        blobs         = $blobs
        evidence      = $evidence.ToArray()
        warnings      = $warnings.ToArray()
    }
}

# ══════════════════════════════════════════════════════════════════
#  五、像素坐标 → 图纸坐标 → DXF
# ══════════════════════════════════════════════════════════════════

function Convert-CadImageGeometryToSpec {
    <#
      把 Find-CadImageGeometry 的结果转成 cad-automatic-wwj 的 spec JSON
      （ entities[] + layers 声明）。

      ★ Y 轴必须翻 ★
        像素 y 向下增，图纸 y 向上增。不翻的话画出来上下颠倒 ——
        这个错极隐蔽：实体数、图层、尺寸全都对得上，只有方向是反的。

      ★ 已知的诚实边界（都写进 warnings，不藏着） ★
        1. 只输出 circle / line / polyline 三类。hatch/block/spline/gear
           不猜 —— 猜错比不猜更糟。
        2. 半径和长度都是像素，乘 -Scale 才是毫米。Scale 不给就按 1:1，
           并在 warnings 里点名「没有物理比例」。
        3. 中心线、标注、剖面线会被当成普通线/多边形，需要人工删。
        4. 这是 known + inferred 混合的产物，结论档位天然到不了 pass。
    #>
    param(
        [Parameter(Mandatory)]$Geometry,
        [double]$Scale = 1.0,
        [double]$KnownWidth = 0,
        [string]$CircleLayer = 'IMAGE_CIRCLE',
        [string]$LineLayer = 'IMAGE_LINE',
        [string]$PolyLayer = 'IMAGE_POLY',
        [string]$TextLayer = 'IMAGE_TEXT',
        [int]$MaxPolyPoints = 24,
        [switch]$IncludePolygons,
        # 文字实体默认输出（有 textRegions 就出），关掉会丢字
        [switch]$SkipText = $false
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    $entities = New-Object System.Collections.Generic.List[object]

    # 比例尺：优先 KnownWidth（跨墨迹包围盒），否则用 Scale
    $s = $Scale
    if ($KnownWidth -gt 0 -and $null -ne $Geometry.bounds -and $Geometry.bounds.width -gt 0) {
        $s = $KnownWidth / [double]$Geometry.bounds.width
        $warnings.Add("按 -KnownWidth $KnownWidth 跨 $($Geometry.bounds.width)px 反算比例：1px = $([math]::Round($s, 6))")
    } elseif ($Scale -le 0) {
        $s = 1.0
    }
    if ($KnownWidth -le 0 -and $Scale -eq 1.0) {
        $warnings.Add('没有给 -Scale 或 -KnownWidth，坐标仍是像素值；画出来尺寸不对，请补一个已知尺寸')
    }

    # ★ scriptblock 里读 $Geometry / $s 靠的是 PowerShell 的动态作用域 ★
    #   （scriptblock 在定义处所在的作用域链上找变量），所以这里能拿到
    #   函数参数。改成 .GetNewClosure() 反而会因为闭包快照时机把后面
    #   改过的 $s 固定住 —— 不要用闭包。
    $flipY = { param($Y) [math]::Round(($Geometry.height - 1 - $Y) * $s, 4) }
    # ★ scriptblock 里读 $Geometry / $s 靠的是 PowerShell 的动态作用域 ★
    #   （scriptblock 在定义处所在的作用域链上找变量），所以这里能拿到
    #   函数参数。改成 .GetNewClosure() 反而会因为闭包快照时机把后面
    #   改过的 $s 固定住 —— 不要用闭包。
    $flipY = { param($Y) [math]::Round(($Geometry.height - 1 - $Y) * $s, 4) }

    foreach ($c in @($Geometry.circles)) {
        $entities.Add([ordered]@{
            type   = 'circle'
            layer  = $CircleLayer
            c      = @([math]::Round($c.cx * $s, 4), (& $flipY $c.cy))
            r      = [math]::Round($c.r * $s, 4)
            _src   = "image-circle blob径向偏差=$($c.radialDev)"
        })
    }

    foreach ($l in @($Geometry.lines)) {
        $entities.Add([ordered]@{
            type   = 'line'
            layer  = $LineLayer
            p1     = @([math]::Round($l.x1 * $s, 4), (& $flipY $l.y1))
            p2     = @([math]::Round($l.x2 * $s, 4), (& $flipY $l.y2))
            _src   = "image-line 细长度=$($l.elongation)"
        })
    }

    if ($IncludePolygons) {
        foreach ($p in @($Geometry.polygons)) {
            $pts = @($p.points)
            if ($pts.Count -lt 3) { continue }
            if ($pts.Count -gt $MaxPolyPoints) {
                # 凸包点太多时等距抽稀，别把 spec 撑爆
                $step = [math]::Ceiling($pts.Count / [double]$MaxPolyPoints)
                $keep = New-Object System.Collections.Generic.List[object]
                for ($i = 0; $i -lt $pts.Count; $i += $step) { $keep.Add($pts[$i]) }
                $pts = @($keep.ToArray())
                if ($pts.Count -lt 3) { continue }
            }
            $out = New-Object System.Collections.Generic.List[object]
            foreach ($pt in $pts) {
                $out.Add(@([math]::Round([double]$pt[0] * $s, 4), (& $flipY [double]$pt[1])))
            }
            $entities.Add([ordered]@{
                type   = 'polyline'
                layer  = $PolyLayer
                points = @($out.ToArray())
                closed = $true
                _src   = "image-polygon 未识别域面积=$($p.pixelArea)px（inferred，需人工确认）"
            })
        }
    }

    # ── 文字 ──
    # ★ 有 OCR 文字就写文字，没有就写「占位符」★
    #   占位符不是糊弄：CAD 里能看到「这里该有一行字、多高、多长」，
    #   比什么都没有强得多 —— 什么都不知道的图是没法照着画的。
    #   占位符内容用 § 包住，一眼能认出是待填。
    $textCount = 0
    if (-not $SkipText) {
        foreach ($tr in @($Geometry.textRegions)) {
            if ($null -eq $tr) { continue }

            # 文字基点在左下角；像素 y 是顶边，要加上字高再翻 Y
            $tx = [math]::Round([double]$tr.x * $s, 4)
            $ty = (& $flipY ([double]$tr.y + [double]$tr.h))
            $th = [math]::Round([double]$tr.estHeight * $s, 4)
            if ($th -le 0) { $th = [math]::Round(2.5 * $s, 4) }

            $raw = ''
            if ($tr.PSObject.Properties['text']) { $raw = [string]$tr.text }
            $hasText = -not [string]::IsNullOrWhiteSpace($raw)
            $content = if ($hasText) { $raw } else { "§$($tr.id) 文字 $($tr.charCount)字§" }

            $entities.Add([ordered]@{
                type   = 'text'
                layer  = $TextLayer
                at     = @($tx, $ty)
                height = $th
                value  = $content
                _src   = if ($hasText) {
                            "image-text $($tr.id)：$($tr.charCount) 个字符笔画，OCR 结果（inferred，必须人工核对）"
                         } else {
                            "image-text $($tr.id)：$($tr.charCount) 个字符笔画，位置/高度为 known，**内容未识别**，§ 内为占位待填"
                         }
            })
            $textCount++
        }
        if ($textCount -gt 0) {
            $noText = @($Geometry.textRegions | Where-Object {
                -not ($_.PSObject.Properties['text'] -and -not [string]::IsNullOrWhiteSpace([string]$_.text))
            }).Count
            if ($noText -gt 0) {
                $warnings.Add("$noText 段文字只有位置没有内容（§…§ 占位符），照着画时必须人工读出原文再替换")
            }
        }
    } elseif (@($Geometry.textRegions).Count -gt 0) {
        $warnings.Add("文字区域有 $(@($Geometry.textRegions).Count) 段但被 -SkipText 丢掉了；图里的字不会出现在 DXF 里")
    }

    $spec = [ordered]@{
        name   = 'image-trace'
        units  = 'mm'
        layers = @(
            [ordered]@{ name = $CircleLayer; color = 1 }
            [ordered]@{ name = $LineLayer;   color = 3 }
            [ordered]@{ name = $PolyLayer;   color = 8 }
            [ordered]@{ name = $TextLayer;   color = 2 }
        )
        entities = @($entities.ToArray())
    }

    return [pscustomobject]@{
        spec     = $spec
        scale    = [math]::Round($s, 6)
        counts   = [pscustomobject]@{ circles = @($Geometry.circles).Count; lines = @($Geometry.lines).Count; polygons = @($Geometry.polygons).Count; texts = $textCount }
        warnings = $warnings.ToArray()
    }
}

function Write-CadImageDxf {
    <#
      把候选几何直接写成 R12 DXF（不经过 spec/accoreconsole）。

      什么时候用这个而不是 Convert-CadImageGeometryToSpec + Invoke-CadDraw：
        · 只是想让用户在 CAD 里看一眼「机器认出了什么」
        · 图很大（几千个域），走 spec 编译太慢
        · 只是想拿到几何坐标自己处理

      产物只有 LINE / CIRCLE / POLYLINE，图层分三类，
      文件头带 $INSUNITS=4（毫米）—— 因为 Scale 换算后就是毫米。
    #>
    param(
        [Parameter(Mandatory)]$Geometry,
        [Parameter(Mandatory)][string]$Output,
        [double]$Scale = 1.0,
        [double]$KnownWidth = 0,
        [string]$CircleLayer = 'IMAGE_CIRCLE',
        [string]$LineLayer = 'IMAGE_LINE',
        [string]$PolyLayer = 'IMAGE_POLY',
        [switch]$IncludePolygons
    )

    $conv = Convert-CadImageGeometryToSpec -Geometry $Geometry -Scale $Scale -KnownWidth $KnownWidth `
        -CircleLayer $CircleLayer -LineLayer $LineLayer -PolyLayer $PolyLayer -IncludePolygons:$IncludePolygons

    $sb = New-Object System.Text.StringBuilder
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmt = { param($v) ([double]$v).ToString('0.############', $inv) }

    # ★ 这里不用 script: 作用域变量，改用闭包外的 List ★
    #   script:minX 在 dot-source 场景下会跨函数串味（多个调用方共用一个
    #   变量名），而 $script: 的写入在 invoke 里还可能撞上 StrictMode。
    #   用一个 hashtable 装着传进去最稳。
    $ext = @{ minX = [double]::MaxValue; minY = [double]::MaxValue; maxX = [double]::MinValue; maxY = [double]::MinValue }
    $track = {
        param($x, $y)
        if ($x -lt $ext.minX) { $ext.minX = $x }
        if ($x -gt $ext.maxX) { $ext.maxX = $x }
        if ($y -lt $ext.minY) { $ext.minY = $y }
        if ($y -gt $ext.maxY) { $ext.maxY = $y }
    }.GetNewClosure()

    foreach ($e in $conv.spec.entities) {
        if ($e.type -eq 'circle') {
            $cx = [double]$e.c[0]; $cy = [double]$e.c[1]; $r = [double]$e.r
            & $track ($cx - $r) ($cy - $r); & $track ($cx + $r) ($cy + $r)
        } elseif ($e.type -eq 'line') {
            & $track ([double]$e.p1[0]) ([double]$e.p1[1])
            & $track ([double]$e.p2[0]) ([double]$e.p2[1])
        } else {
            foreach ($pt in $e.points) { & $track ([double]$pt[0]) ([double]$pt[1]) }
        }
    }
    if ($conv.spec.entities.Count -eq 0) { $ext.minX = 0; $ext.minY = 0; $ext.maxX = 0; $ext.maxY = 0 }
    $minX = $ext.minX; $minY = $ext.minY; $maxX = $ext.maxX; $maxY = $ext.maxY
    New-CadDxfText $sb 0 'SECTION'
    New-CadDxfText $sb 2 'HEADER'
    New-CadDxfText $sb 9 '$ACADVER'
    New-CadDxfText $sb 1 'AC1009'
    New-CadDxfText $sb 9 '$INSUNITS'
    New-CadDxfText $sb 70 '4'
    New-CadDxfText $sb 9 '$EXTMIN'
    New-CadDxfText $sb 10 (& $fmt $minX); New-CadDxfText $sb 20 (& $fmt $minY); New-CadDxfText $sb 30 '0.0'
    New-CadDxfText $sb 9 '$EXTMAX'
    New-CadDxfText $sb 10 (& $fmt $maxX); New-CadDxfText $sb 20 (& $fmt $maxY); New-CadDxfText $sb 30 '0.0'
    New-CadDxfText $sb 0 'ENDSEC'

    New-CadDxfText $sb 0 'SECTION'
    New-CadDxfText $sb 2 'TABLES'
    New-CadDxfText $sb 0 'TABLE'
    New-CadDxfText $sb 2 'LTYPE'
    New-CadDxfText $sb 70 '1'
    New-CadDxfText $sb 0 'LTYPE'
    New-CadDxfText $sb 2 'CONTINUOUS'
    New-CadDxfText $sb 70 '64'
    New-CadDxfText $sb 3 'Solid line'
    New-CadDxfText $sb 72 '65'
    New-CadDxfText $sb 73 '0'
    New-CadDxfText $sb 40 '0.0'
    New-CadDxfText $sb 0 'ENDTAB'
    New-CadDxfText $sb 0 'TABLE'
    New-CadDxfText $sb 2 'LAYER'
    New-CadDxfText $sb 70 '4'
    foreach ($ly in @('0', $CircleLayer, $LineLayer, $PolyLayer)) {
        New-CadDxfText $sb 0 'LAYER'
        New-CadDxfText $sb 2 $ly
        New-CadDxfText $sb 70 '0'
        # ★ PS5.1 不支持把 if 当表达式直接传参（PS7 专属），必须先算成变量
        $lyColor = if ($ly -eq '0') { '7' } elseif ($ly -eq $CircleLayer) { '1' } elseif ($ly -eq $LineLayer) { '3' } else { '8' }
        New-CadDxfText $sb 62 $lyColor
        New-CadDxfText $sb 6 'CONTINUOUS'
    }
    New-CadDxfText $sb 0 'ENDTAB'
    New-CadDxfText $sb 0 'ENDSEC'

    New-CadDxfText $sb 0 'SECTION'
    New-CadDxfText $sb 2 'ENTITIES'
    $count = 0
    foreach ($e in $conv.spec.entities) {
        if ($e.type -eq 'circle') {
            New-CadDxfText $sb 0 'CIRCLE'
            New-CadDxfText $sb 8 $CircleLayer
            New-CadDxfText $sb 10 (& $fmt $e.c[0]); New-CadDxfText $sb 20 (& $fmt $e.c[1]); New-CadDxfText $sb 30 '0.0'
            New-CadDxfText $sb 40 (& $fmt $e.r)
            $count++
        } elseif ($e.type -eq 'line') {
            New-CadDxfText $sb 0 'LINE'
            New-CadDxfText $sb 8 $LineLayer
            New-CadDxfText $sb 10 (& $fmt $e.p1[0]); New-CadDxfText $sb 20 (& $fmt $e.p1[1]); New-CadDxfText $sb 30 '0.0'
            New-CadDxfText $sb 11 (& $fmt $e.p2[0]); New-CadDxfText $sb 21 (& $fmt $e.p2[1]); New-CadDxfText $sb 31 '0.0'
            $count++
        } elseif ($e.type -eq 'polyline') {
            New-CadDxfText $sb 0 'POLYLINE'
            New-CadDxfText $sb 8 $PolyLayer
            New-CadDxfText $sb 66 '1'
            New-CadDxfText $sb 70 '1'
            New-CadDxfText $sb 10 '0.0'; New-CadDxfText $sb 20 '0.0'; New-CadDxfText $sb 30 '0.0'
            foreach ($pt in $e.points) {
                New-CadDxfText $sb 0 'VERTEX'
                New-CadDxfText $sb 8 $PolyLayer
                New-CadDxfText $sb 10 (& $fmt $pt[0]); New-CadDxfText $sb 20 (& $fmt $pt[1]); New-CadDxfText $sb 30 '0.0'
            }
            New-CadDxfText $sb 0 'SEQEND'
            New-CadDxfText $sb 8 $PolyLayer
            $count++
        }
    }
    New-CadDxfText $sb 0 'ENDSEC'
    New-CadDxfText $sb 0 'EOF'

    $dir = Split-Path -Parent $Output
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Output, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        output   = $Output
        bytes    = (Get-Item -LiteralPath $Output).Length
        entities = $count
        scale    = $conv.scale
        counts   = $conv.counts
        extents  = [pscustomobject]@{ minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY }
        warnings = $conv.warnings
    }
}

