<#
    CadRender.ps1 — DXF 预览渲染库（不开 CAD，纯 PowerShell/.NET）
    ══════════════════════════════════════════════════════════════════

    定位：pengxiaoan 的 autocad-image-redraw 有 render_dxf_preview.py
    （ezdxf audit + ezdxf.addons.drawing + PyMuPDF 渲染 PNG/PDF）。
    本机没有可用的 Python，本技能铁律是 accoreconsole + .NET 通道，
    所以这里用纯 PowerShell + System.Drawing 重写同一件事。

    ★ 这是什么，不是什么 ★
      这是「结构预览」，不是「图纸复核」：
        · 读 ASCII DXF 的 ENTITIES 段，把 LINE/LWPOLYLINE/POLYLINE/
          CIRCLE/ARC/ELLIPSE/POINT/SOLID/SPLINE/TEXT/MTEXT/INSERT/
          DIMENSION 画出来；
        · 审计（audit）是自己实现的结构体检：段配对、EOF、编码、
          实体可解析性 —— 不是 ezdxf 的 doc.audit()，结论只对结构负责；
        · HATCH 只画种子点，不画边界；文字用系统字体近似，PDF 里
          非 ASCII 字符替换为 '?'（PDF 基础 14 字体不含中文）；
        · 输出是「看个大概」，不是绘图仪。要精确图纸走 accoreconsole。

    ★ 与 CadPdf.ps1 的分工 ★
      CadPdf.ps1 是「PDF → DXF」（解析别人的 PDF）。
      本模块是「DXF → PNG/PDF」（自己产出预览）。

    ★ 渲染决策（为什么全部采样成折线） ★
      CIRCLE/ARC/ELLIPSE 统一采样成 N 段折线：
        1. INSERT 可以带非等比缩放（41≠42），此时圆会变椭圆，
           DrawEllipse/DrawArc 画不了；采样折线任何仿射变换都扛得住；
        2. PNG 与 PDF 共用同一份折线几何，两边画出来一致；
        3. 每弧 64 段，300dpi 下弦高误差 < 0.05mm，预览无感。
#>

Add-Type -AssemblyName System.Drawing

# ══════════════════════════════════════════════════════════════════
#  一、页幅（横版为基准；portrait 时宽高对调）
# ══════════════════════════════════════════════════════════════════

$script:CadRenderPageMm = @{
    A4 = @(297.0, 210.0)
    A3 = @(420.0, 297.0)
    A2 = @(594.0, 420.0)
    A1 = @(841.0, 594.0)
}

# 每整圆采样段数。64 段在 300dpi A4 上弦高误差远小于 1px。
$script:CadRenderArcSegments = 64

# INSERT 展开深度上限（防递归块互相引用死循环）
$script:CadRenderMaxBlockDepth = 3

# 单文件实体数上限（防异常 DXF 拖爆内存）
$script:CadRenderMaxEntities = 20000

# ══════════════════════════════════════════════════════════════════
#  二、组码桶工具
# ══════════════════════════════════════════════════════════════════

function New-CadRenderBucket {
    # 实体原始组码桶：一个实体的所有组码原样收进来，再按类型提取。
    # plinePts 是老式 POLYLINE 专用的顶点收集器（顶点在后续 VERTEX 实体里）。
    param([string]$Type)
    return [pscustomobject]@{
        type        = $Type
        layer       = $null
        color       = $null
        codes       = New-Object System.Collections.Generic.List[object]   # @{c;v}
        plinePts    = New-Object System.Collections.Generic.List[object]   # VERTEX 顶点 @(x,y)
        plineClosed = $false
    }
}

function Get-CadBucketNum {
    # 取桶里某组码的第一个数值（不存在/不可解析返回 $Default）
    param($Bucket, [int]$Code, $Default = $null)
    foreach ($p in $Bucket.codes) {
        if ($p.c -eq $Code) {
            $d = ConvertTo-CadDouble ([string]$p.v)
            if ($null -ne $d) { return $d }
        }
    }
    return $Default
}

function Get-CadBucketStr {
    param($Bucket, [int]$Code, $Default = '')
    foreach ($p in $Bucket.codes) {
        if ($p.c -eq $Code) { return [string]$p.v }
    }
    return $Default
}

function Get-CadBucketAllNum {
    # 取桶里某组码的所有数值（LWPOLYLINE 的 10/20、SPLINE 控制点）
    param($Bucket, [int]$Code)
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($p in $Bucket.codes) {
        if ($p.c -eq $Code) {
            $d = ConvertTo-CadDouble ([string]$p.v)
            if ($null -ne $d) { $out.Add($d) | Out-Null }
        }
    }
    return $out.ToArray()
}

# ══════════════════════════════════════════════════════════════════
#  三、几何采样
# ══════════════════════════════════════════════════════════════════

function ConvertTo-CadRenderSampledArc {
    # 圆/弧 → 采样折线（世界坐标）。角度为度，CCW，a0→a1。
    param(
        [double]$Cx, [double]$Cy, [double]$R,
        [double]$A0 = 0.0, [double]$A1 = 360.0
    )
    if ($a1 -lt $a0) { $a1 += 360.0 }
    $sweep = $a1 - $a0
    if ($sweep -le 0.001) { $sweep = 360.0 }
    $segs = [Math]::Max(8, [int][Math]::Ceiling($script:CadRenderArcSegments * $sweep / 360.0))
    $pts = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -le $segs; $k++) {
        $a = ($a0 + $sweep * $k / $segs) * [Math]::PI / 180.0
        $pts.Add(@(($Cx + $R * [Math]::Cos($a)), ($Cy + $R * [Math]::Sin($a)))) | Out-Null
    }
    return ,$pts.ToArray()
}

function ConvertTo-CadRenderSampledEllipse {
    # 椭圆参数式：中心(10,20) + 长轴向量(11,21，相对中心) + 比率(40) + 起止参数(41/42)
    param($Bucket)
    $cx = Get-CadBucketNum $Bucket 10; $cy = Get-CadBucketNum $Bucket 20
    $mx = Get-CadBucketNum $Bucket 11; $my = Get-CadBucketNum $Bucket 21
    $ratio = Get-CadBucketNum $Bucket 40 1.0
    $t0 = Get-CadBucketNum $Bucket 41 0.0
    $t1 = Get-CadBucketNum $Bucket 42 ([Math]::PI * 2.0)
    if ($null -eq $cx -or $null -eq $cy -or $null -eq $mx -or $null -eq $my) { return $null }
    $majorLen = [Math]::Sqrt($mx * $mx + $my * $my)
    if ($majorLen -le 1e-9 -or $ratio -le 1e-9) { return $null }
    $ux = $mx / $majorLen; $uy = $my / $majorLen      # 长轴单位向量
    $vx = -$uy * $ratio;  $vy = $ux * $ratio          # 短轴向量 = 垂直 * ratio
    $sweep = $t1 - $t0
    if ($sweep -le 0.001) { $sweep = [Math]::PI * 2.0 }
    $segs = [Math]::Max(8, [int][Math]::Ceiling($script:CadRenderArcSegments * $sweep / ([Math]::PI * 2.0)))
    $pts = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -le $segs; $k++) {
        $t = $t0 + $sweep * $k / $segs
        $pts.Add(@(($cx + $majorLen * ($ux * [Math]::Cos($t) + $vx * [Math]::Sin($t))),
                   ($cy + $majorLen * ($uy * [Math]::Cos($t) + $vy * [Math]::Sin($t))))) | Out-Null
    }
    return ,$pts.ToArray()
}

function ConvertTo-CadRenderCleanText {
    # MTEXT 格式码粗清理：\P→空格、去掉 \A1;/\H2.5;/\W0.8;/\C1; 等行内格式。
    # 预览不求排版正确，只求别把格式码当字符画出来。
    param([string]$S)
    if (-not $S) { return $S }
    $s = $S -replace '\\P', ' ' -replace '\\~', ' '
    $s = $s -replace '\\[ACHQTWfc]\\[^;]*;', '' -replace '\\[LlOoKkNn]', '' -replace '\\\\', '\'
    return $s
}

# ══════════════════════════════════════════════════════════════════
#  四、桶 → 图元
#  图元种类：
#    line      @{kind;line;layer;x1;y1;x2;y2}
#    polyline  @{kind;polyline;layer;points=@(@(x,y)...);closed=bool}
#    point     @{kind;point;layer;x;y}
#    text      @{kind;text;layer;x;y;s;height;rot}
#    multi     @{kind;multi;prims=@(...)}   （DIMENSION 一变多）
# ══════════════════════════════════════════════════════════════════

function ConvertTo-CadRenderPrimitive {
    param($Bucket)

    $t = ([string]$Bucket.type).Trim().ToUpperInvariant()
    $layer = if ($Bucket.layer) { [string]$Bucket.layer } else { '0' }

    switch ($t) {
        'LINE' {
            $x1 = Get-CadBucketNum $Bucket 10; $y1 = Get-CadBucketNum $Bucket 20
            $x2 = Get-CadBucketNum $Bucket 11; $y2 = Get-CadBucketNum $Bucket 21
            if ($null -eq $x1 -or $null -eq $y1 -or $null -eq $x2 -or $null -eq $y2) { return $null }
            $result = @{ kind = 'line'; layer = $layer; x1 = $x1; y1 = $y1; x2 = $x2; y2 = $y2 }
        }
        'LWPOLYLINE' {
            $xs = Get-CadBucketAllNum $Bucket 10
            $ys = Get-CadBucketAllNum $Bucket 20
            $pts = New-Object System.Collections.Generic.List[object]
            $cnt = [Math]::Min($xs.Count, $ys.Count)
            for ($k = 0; $k -lt $cnt; $k++) { $pts.Add(@($xs[$k], $ys[$k])) | Out-Null }
            $closed = ([int](Get-CadBucketNum $Bucket 70 0)) -band 1 -ne 0
            if ($pts.Count -lt 2) { return $null }
            $result = @{ kind = 'polyline'; layer = $layer; points = $pts.ToArray(); closed = $closed }
        }
        'POLYLINE' {
            $pts = $Bucket.plinePts
            $closed = $Bucket.plineClosed
            if ($pts.Count -lt 2) {
                # 老式 POLYLINE 没有 VERTEX 跟随时，退回自己头上的 10/20（通常无效）
                $xs = Get-CadBucketAllNum $Bucket 10
                $ys = Get-CadBucketAllNum $Bucket 20
                $cnt = [Math]::Min($xs.Count, $ys.Count)
                for ($k = 0; $k -lt $cnt; $k++) { $pts.Add(@($xs[$k], $ys[$k])) | Out-Null }
            }
            if ($pts.Count -lt 2) { return $null }
            $result = @{ kind = 'polyline'; layer = $layer; points = $pts.ToArray(); closed = $closed }
        }
        'CIRCLE' {
            $cx = Get-CadBucketNum $Bucket 10; $cy = Get-CadBucketNum $Bucket 20
            $r = Get-CadBucketNum $Bucket 40
            if ($null -eq $cx -or $null -eq $cy -or $null -eq $r -or $r -le 0) { $result = $null }
            else { $result = @{ kind = 'polyline'; layer = $layer; closed = $true;
                      points = (ConvertTo-CadRenderSampledArc -Cx $cx -Cy $cy -R $r) } }
        }
        'ARC' {
            $cx = Get-CadBucketNum $Bucket 10; $cy = Get-CadBucketNum $Bucket 20
            $r = Get-CadBucketNum $Bucket 40
            $a0 = Get-CadBucketNum $Bucket 50 0.0
            $a1 = Get-CadBucketNum $Bucket 51 360.0
            if ($null -eq $cx -or $null -eq $cy -or $null -eq $r -or $r -le 0) { $result = $null }
            else { $result = @{ kind = 'polyline'; layer = $layer; closed = $false;
                      points = (ConvertTo-CadRenderSampledArc -Cx $cx -Cy $cy -R $r -A0 $a0 -A1 $a1) } }
        }
        'ELLIPSE' {
            $pts = ConvertTo-CadRenderSampledEllipse $Bucket
            if ($null -eq $pts) { $result = $null }
            else { $result = @{ kind = 'polyline'; layer = $layer; closed = $false; points = $pts } }
        }
        'POINT' {
            $x = Get-CadBucketNum $Bucket 10; $y = Get-CadBucketNum $Bucket 20
            if ($null -eq $x -or $null -eq $y) { $result = $null }
            else { $result = @{ kind = 'point'; layer = $layer; x = $x; y = $y } }
        }
        { $_ -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF') } {
            $x = Get-CadBucketNum $Bucket 10; $y = Get-CadBucketNum $Bucket 20
            $h = Get-CadBucketNum $Bucket 40 2.5
            $rot = Get-CadBucketNum $Bucket 50 0.0
            $s = Get-CadBucketStr $Bucket 1 ''
            if ($t -eq 'MTEXT') {
                # MTEXT 的多段文本：3 是续段、1 是末段；拼起来再清格式码
                $chunks = @()
                foreach ($p in $Bucket.codes) {
                    if ($p.c -eq 3) { $chunks += [string]$p.v }
                }
                if ($s) { $chunks += $s }
                $s = ConvertTo-CadRenderCleanText ($chunks -join '')
            }
            if ($null -eq $x -or $null -eq $y) { $result = $null }
            elseif ([string]::IsNullOrWhiteSpace($s)) { $result = $null }
            else {
                if ($h -le 0) { $h = 2.5 }
                $result = @{ kind = 'text'; layer = $layer; x = $x; y = $y; s = $s; height = $h; rot = $rot }
            }
        }
        'SOLID' {
            # DXF 的 SOLID 四角顶点顺序是 1-2-4-3，直接按点序连会打叉。
            # 组码对：角1=10/20，角2=11/21，角3=12/22，角4=13/23。
            $c1 = @((Get-CadBucketNum $Bucket 10), (Get-CadBucketNum $Bucket 20))
            $c2 = @((Get-CadBucketNum $Bucket 11), (Get-CadBucketNum $Bucket 21))
            $c3 = @((Get-CadBucketNum $Bucket 12), (Get-CadBucketNum $Bucket 22))
            $c4 = @((Get-CadBucketNum $Bucket 13), (Get-CadBucketNum $Bucket 23))
            $corners = @()
            foreach ($c in @($c1, $c2, $c4, $c3)) {
                if ($null -ne $c[0] -and $null -ne $c[1]) { $corners += , $c }
            }
            if ($corners.Count -lt 3) { $result = $null }
            else { $result = @{ kind = 'polyline'; layer = $layer; closed = $true; points = $corners } }
        }
        'SPLINE' {
            # 优先拟合点(11/21)，退而控制点(10/20)。折线连控制点不是真实样条，
            # 预览够用且不撒谎——报告里已声明是近似。
            $xs = Get-CadBucketAllNum $Bucket 11
            $ys = Get-CadBucketAllNum $Bucket 21
            if ($xs.Count -lt 2) { $xs = Get-CadBucketAllNum $Bucket 10; $ys = Get-CadBucketAllNum $Bucket 20 }
            $pts = New-Object System.Collections.Generic.List[object]
            $cnt = [Math]::Min($xs.Count, $ys.Count)
            for ($k = 0; $k -lt $cnt; $k++) { $pts.Add(@($xs[$k], $ys[$k])) | Out-Null }
            if ($pts.Count -lt 2) { $result = $null }
            else { $result = @{ kind = 'polyline'; layer = $layer; closed = $false; points = $pts } }
        }
        'DIMENSION' {
            # 简化画法：13/23→14/24 是被测线，11/21 是文字中点。
            # 箭头/界线不画——这是预览，不是标注复刻。
            $prims = New-Object System.Collections.Generic.List[object]
            $x1 = Get-CadBucketNum $Bucket 13; $y1 = Get-CadBucketNum $Bucket 23
            $x2 = Get-CadBucketNum $Bucket 14; $y2 = Get-CadBucketNum $Bucket 24
            if ($null -ne $x1 -and $null -ne $y1 -and $null -ne $x2 -and $null -ne $y2) {
                $prims.Add(@{ kind = 'line'; layer = $layer; x1 = $x1; y1 = $y1; x2 = $x2; y2 = $y2 }) | Out-Null
            }
            $tx = Get-CadBucketNum $Bucket 11; $ty = Get-CadBucketNum $Bucket 21
            $tv = Get-CadBucketStr $Bucket 1 ''
            if ($null -ne $tx -and $null -ne $ty -and -not [string]::IsNullOrWhiteSpace($tv)) {
                $th = Get-CadBucketNum $Bucket 140 2.5
                if ($th -le 0) { $th = 2.5 }
                $prims.Add(@{ kind = 'text'; layer = $layer; x = $tx; y = $ty; s = $tv; height = $th; rot = 0.0 }) | Out-Null
            }
            if ($prims.Count -eq 0) { $result = $null }
            else { $result = @{ kind = 'multi'; layer = $layer; prims = $prims.ToArray() } }
        }
        'HATCH' {
            # HATCH 只画种子点(10/20)，边界不解析（边界路径是另一套组码体系）
            $x = Get-CadBucketNum $Bucket 10; $y = Get-CadBucketNum $Bucket 20
            if ($null -eq $x -or $null -eq $y) { $result = $null }
            else { $result = @{ kind = 'point'; layer = $layer; x = $x; y = $y } }
        }
        default { $result = $null }
    }
    if ($null -ne $result) { return ,$result }
    return $null
}

function Expand-CadRenderInsert {
    <#
      INSERT 展开：把块定义里的图元按 插入点/缩放/旋转 变换后复制出来。
      非等比缩放下圆会变椭圆 —— 这正是「全部采样成折线」的原因：
      折线只存点，任何仿射变换都精确。
    #>
    param(
        [object[]]$Prims,
        [double]$Ix, [double]$Iy,
        [double]$Sx, [double]$Sy,
        [double]$RotDeg
    )
    $out = New-Object System.Collections.Generic.List[object]
    $th = $RotDeg * [Math]::PI / 180.0
    $cos = [Math]::Cos($th); $sin = [Math]::Sin($th)

    foreach ($p in $Prims) {
        if ($null -eq $p) { continue }
        if ($p.kind -eq 'multi') {
            foreach ($sub in (Expand-CadRenderInsert -Prims $p.prims -Ix $Ix -Iy $Iy -Sx $Sx -Sy $Sy -RotDeg $RotDeg)) {
                $out.Add($sub) | Out-Null
            }
            continue
        }
        if ($p.kind -eq 'line') {
            $q1x = $Ix + ($p.x1 * $Sx) * $cos - ($p.y1 * $Sy) * $sin
            $q1y = $Iy + ($p.x1 * $Sx) * $sin + ($p.y1 * $Sy) * $cos
            $q2x = $Ix + ($p.x2 * $Sx) * $cos - ($p.y2 * $Sy) * $sin
            $q2y = $Iy + ($p.x2 * $Sx) * $sin + ($p.y2 * $Sy) * $cos
            $out.Add(@{ kind = 'line'; layer = $p.layer; x1 = $q1x; y1 = $q1y; x2 = $q2x; y2 = $q2y }) | Out-Null
        } elseif ($p.kind -eq 'polyline') {
            $pts = New-Object System.Collections.Generic.List[object]
            foreach ($pt in $p.points) {
                $pts.Add(@($Ix + ($pt[0] * $Sx) * $cos - ($pt[1] * $Sy) * $sin,
                           $Iy + ($pt[0] * $Sx) * $sin + ($pt[1] * $Sy) * $cos)) | Out-Null
            }
            $out.Add(@{ kind = 'polyline'; layer = $p.layer; closed = $p.closed; points = $pts.ToArray() }) | Out-Null
        } elseif ($p.kind -eq 'point') {
            $qx = $Ix + ($p.x * $Sx) * $cos - ($p.y * $Sy) * $sin
            $qy = $Iy + ($p.x * $Sx) * $sin + ($p.y * $Sy) * $cos
            $out.Add(@{ kind = 'point'; layer = $p.layer; x = $qx; y = $qy }) | Out-Null
        } elseif ($p.kind -eq 'text') {
            $qx = $Ix + ($p.x * $Sx) * $cos - ($p.y * $Sy) * $sin
            $qy = $Iy + ($p.x * $Sx) * $sin + ($p.y * $Sy) * $cos
            $hh = $p.height * [Math]::Sqrt([Math]::Abs($Sx * $Sy))
            if ($hh -le 0) { $hh = $p.height }
            $out.Add(@{ kind = 'text'; layer = $p.layer; x = $qx; y = $qy; s = $p.s;
                        height = $hh; rot = ($p.rot + $RotDeg) }) | Out-Null
        }
    }
    return ,$out.ToArray()
}

function ConvertTo-CadRenderPrimList {
    <#
      桶数组 → 图元数组（INSERT 在此递归展开）。
      $Blocks: @{ 块名 → 桶数组 }；$Depth 防递归。
    #>
    param(
        [object[]]$Buckets,
        [hashtable]$Blocks,
        [System.Collections.Generic.List[string]]$Fixes,
        [int]$Depth
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($b in $Buckets) {
        if ($null -eq $b) { continue }
        $t = ([string]$b.type).Trim().ToUpperInvariant()
        if ($t -eq 'INSERT') {
            $bname = Get-CadBucketStr $b 2 ''
            if ($Depth -ge $script:CadRenderMaxBlockDepth) {
                $Fixes.Add("块引用嵌套超过 $($script:CadRenderMaxBlockDepth) 层，'${bname}' 不再展开") | Out-Null
                continue
            }
            if (-not $bname) { continue }
            if ($Blocks.ContainsKey($bname) -and @($Blocks[$bname]).Count -gt 0) {
                $ix = Get-CadBucketNum $b 10 0.0; $iy = Get-CadBucketNum $b 20 0.0
                $sx = Get-CadBucketNum $b 41 1.0; $sy = Get-CadBucketNum $b 42 1.0
                $rot = Get-CadBucketNum $b 50 0.0
                if ($null -eq $sx -or $sx -eq 0) { $sx = 1.0 }
                if ($null -eq $sy -or $sy -eq 0) { $sy = 1.0 }
                $subPrims = ConvertTo-CadRenderPrimList -Buckets @($Blocks[$bname]) -Blocks $Blocks -Fixes $Fixes -Depth ($Depth + 1)
                foreach ($tp in (Expand-CadRenderInsert -Prims $subPrims -Ix $ix -Iy $iy -Sx $sx -Sy $sy -RotDeg $rot)) {
                    $out.Add($tp) | Out-Null
                }
            } else {
                $Fixes.Add("INSERT 引用未定义块 '${bname}'，已跳过") | Out-Null
            }
            continue
        }
        $pr = ConvertTo-CadRenderPrimitive $b
        if ($null -eq $pr) { continue }
        if ($pr.kind -eq 'multi') {
            foreach ($one in $pr.prims) { $out.Add($one) | Out-Null }
        } else {
            $out.Add($pr) | Out-Null
        }
    }
    return ,$out.ToArray()
}

function Get-CadRenderExtents {
    <#
      图元数组 → 世界坐标范围 @{minX;minY;maxX;maxY}。
      文字的范围用插入点 + 估宽（height*0.62*字符数），旋转忽略——预览够用。
      没有任何图元返回 $null。
    #>
    param([object[]]$Prims)
    $minX = [double]::MaxValue; $minY = [double]::MaxValue
    $maxX = [double]::MinValue; $maxY = [double]::MinValue

    foreach ($p in $Prims) {
        if ($null -eq $p) { continue }
        if ($p.kind -eq 'line') {
            $minX = [Math]::Min($minX, [Math]::Min($p.x1, $p.x2)); $maxX = [Math]::Max($maxX, [Math]::Max($p.x1, $p.x2))
            $minY = [Math]::Min($minY, [Math]::Min($p.y1, $p.y2)); $maxY = [Math]::Max($maxY, [Math]::Max($p.y1, $p.y2))
        } elseif ($p.kind -eq 'polyline') {
            foreach ($pt in $p.points) {
                if ($null -eq $pt -or $pt.Count -lt 2) { continue }
                $minX = [Math]::Min($minX, $pt[0]); $maxX = [Math]::Max($maxX, $pt[0])
                $minY = [Math]::Min($minY, $pt[1]); $maxY = [Math]::Max($maxY, $pt[1])
            }
        } elseif ($p.kind -eq 'point') {
            $minX = [Math]::Min($minX, $p.x); $maxX = [Math]::Max($maxX, $p.x)
            $minY = [Math]::Min($minY, $p.y); $maxY = [Math]::Max($maxY, $p.y)
        } elseif ($p.kind -eq 'text') {
            $w = $p.height * 0.62 * [Math]::Max(1, $p.s.Length)
            $minX = [Math]::Min($minX, $p.x); $maxX = [Math]::Max($maxX, $p.x + $w)
            $minY = [Math]::Min($minY, $p.y); $maxY = [Math]::Max($maxY, $p.y + $p.height)
        }
    }
    if ($minX -eq [double]::MaxValue) { return $null }
    return @{ minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY }
}

# ══════════════════════════════════════════════════════════════════
#  五、DXF → 渲染模型（解析 + 审计）
# ══════════════════════════════════════════════════════════════════

function Get-CadDxfRenderData {
    <#
      解析 ASCII DXF 成渲染模型（含自实现审计）。

      返回 @{
        valid; reason               # 结构是否可渲染
        version                     # $ACADVER（如 AC1032）
        entities                    # 展开后的图元数组
        blocks                      # @{块名 → 图元数组}
        layerCounts                 # @{图层名 → 实体数}
        entityCounts                # @{类型名 → 实体数}（含 INSERT/HATCH 等未展开类）
        extents                     # 图元实际范围（渲染布局用它）
        headerExtents               # HEADER $EXTMIN/$EXTMAX（对照用）
        auditErrors; auditFixes; warnings
        entityTotal; blockTotal; encoding
      }
    #>
    param([Parameter(Mandatory)][string]$Path)

    $auditErrors = New-Object System.Collections.Generic.List[string]
    $auditFixes  = New-Object System.Collections.Generic.List[string]
    $warnings    = New-Object System.Collections.Generic.List[string]

    try {
        $doc = Read-CadDxfPairs -Path $Path
    } catch {
        $auditErrors.Add($_.Exception.Message) | Out-Null
        return [pscustomobject][ordered]@{
            valid = $false; reason = $_.Exception.Message; version = $null
            entities = @(); blocks = @{}; layerCounts = @{}; entityCounts = @{}
            extents = $null; headerExtents = $null
            auditErrors = $auditErrors.ToArray(); auditFixes = $auditFixes.ToArray()
            warnings = $warnings.ToArray(); entityTotal = 0; blockTotal = 0; encoding = $null
        }
    }
    $pairs = $doc.pairs

    if ($doc.malformedLines.Count -gt 0) {
        $auditFixes.Add("有 $($doc.malformedLines.Count) 行组码不是整数（行号: $($doc.malformedLines -join ',')），已跳过") | Out-Null
    }

    # ── 第一遍：结构扫描 + 桶收集 ──
    $version = $null
    $extMinX = $null; $extMinY = $null; $extMaxX = $null; $extMaxY = $null
    $hdrVar = $null
    $entityCounts = @{}
    $layerCounts = @{}
    $blocks = @{}                       # 块名 → 桶 List
    $secNames = New-Object System.Collections.Generic.List[string]
    $entityBuckets = New-Object System.Collections.Generic.List[object]
    $curBlockName = $null
    $curBlockBuckets = $null
    $curBucket = $null                  # 当前桶（ENTITIES 或 BLOCKS 共用变量 $entityBuckets/$curBlockBuckets 的写入目标）
    $isInEntities = $false
    $isInBlocks = $false
    $inTableLayer = $false
    $secOpen = 0
    $eof = $false
    $entityTotal = 0
    $blockTotal = 0
    $lastPolylineBucket = $null

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]

        if ($p.code -eq 0 -and $p.value -eq 'SECTION') {
            $sec = ''
            if ($i + 1 -lt $pairs.Count -and $pairs[$i + 1].code -eq 2) { $sec = [string]$pairs[$i + 1].value }
            $secNames.Add($sec) | Out-Null
            $secOpen++
            $isInEntities = ($sec -eq 'ENTITIES')
            $isInBlocks = ($sec -eq 'BLOCKS')
            $curBucket = $null
            $lastPolylineBucket = $null
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'ENDSEC') {
            $secOpen--
            $isInEntities = $false; $isInBlocks = $false; $inTableLayer = $false
            $curBucket = $null; $curBlockName = $null; $curBlockBuckets = $null
            $lastPolylineBucket = $null
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'EOF') { $eof = $true; break }

        # ── HEADER：$ACADVER / $EXTMIN / $EXTMAX ──
        if (-not $isInEntities -and -not $isInBlocks -and $secNames.Count -gt 0 -and $secNames[$secNames.Count - 1] -eq 'HEADER') {
            if ($p.code -eq 9) {
                $hdrVar = [string]$p.value
                if ($hdrVar -eq '$ACADVER' -and $i + 1 -lt $pairs.Count -and $pairs[$i + 1].code -eq 1) {
                    $version = [string]$pairs[$i + 1].value
                }
            } elseif ($hdrVar -eq '$EXTMIN' -and $p.code -eq 10 -and $null -eq $extMinX) {
                $extMinX = ConvertTo-CadDouble ([string]$p.value)
            } elseif ($hdrVar -eq '$EXTMIN' -and $p.code -eq 20 -and $null -ne $extMinX -and $null -eq $extMinY) {
                $extMinY = ConvertTo-CadDouble ([string]$p.value)
            } elseif ($hdrVar -eq '$EXTMAX' -and $p.code -eq 10 -and $null -eq $extMaxX) {
                $extMaxX = ConvertTo-CadDouble ([string]$p.value)
            } elseif ($hdrVar -eq '$EXTMAX' -and $p.code -eq 20 -and $null -ne $extMaxX -and $null -eq $extMaxY) {
                $extMaxY = ConvertTo-CadDouble ([string]$p.value)
            }
            continue
        }

        # ── TABLES：LAYER 声明（用于对照实体引用的图层是否存在） ──
        if ($secNames.Count -gt 0 -and $secNames[$secNames.Count - 1] -eq 'TABLES') {
            if ($p.code -eq 0 -and $p.value -eq 'LAYER') { $inTableLayer = $true; continue }
            if ($p.code -eq 0) { $inTableLayer = $false; continue }
            if ($inTableLayer -and $p.code -eq 2 -and $null -ne $p.value -and $p.value) {
                if (-not $layerCounts.ContainsKey([string]$p.value)) { $layerCounts[[string]$p.value] = 0 }
            }
            continue
        }

        # ── BLOCKS 段 ──
        if ($isInBlocks) {
            if ($p.code -eq 0) {
                if ($p.value -eq 'BLOCK') {
                    $curBlockName = $null
                    $curBlockBuckets = New-Object System.Collections.Generic.List[object]
                    $curBucket = $null
                    continue
                }
                if ($p.value -eq 'ENDBLK') {
                    if ($curBlockName) {
                        if ($blocks.ContainsKey($curBlockName)) {
                            $auditFixes.Add("块 '$curBlockName' 重复定义，后一个覆盖前一个") | Out-Null
                        } else {
                            $blockTotal++
                        }
                        $blocks[$curBlockName] = $curBlockBuckets.ToArray()
                    }
                    $curBlockName = $null; $curBlockBuckets = $null; $curBucket = $null
                    continue
                }
                # 块内实体开新桶
                $t = [string]$p.value
                if ($t -and $t -notin @('BLOCK', 'ENDBLK')) {
                    $curBucket = New-CadRenderBucket $t
                    if ($t -eq 'POLYLINE') { $lastPolylineBucket = $curBucket }
                    if ($null -ne $curBlockBuckets) { $curBlockBuckets.Add($curBucket) | Out-Null }
                }
                continue
            }
            if ($null -ne $curBlockName -and $null -eq $curBucket -and $p.code -eq 2) {
                # 块头自己的 2 组码 = 块名
                $curBlockName = [string]$p.value
                continue
            }
            if ($null -ne $curBucket) {
                if ($p.code -eq 8) { $curBucket.layer = [string]$p.value }
                elseif ($p.code -eq 62) { $curBucket.color = [string]$p.value }
                $curBucket.codes.Add(@{ c = $p.code; v = $p.value }) | Out-Null
            }
            continue
        }

        # ── ENTITIES 段 ──
        if ($isInEntities) {
            if ($p.code -eq 0) {
                $t = [string]$p.value
                if ($t -eq 'SEQEND') { $lastPolylineBucket = $null; continue }
                if ($t -eq 'VERTEX') {
                    # 顶点并进前一个 POLYLINE 桶；悬空 VERTEX 忽略
                    if ($null -ne $lastPolylineBucket) {
                        $vx = $null; $vy = $null
                        $j = $i + 1
                        while ($j -lt $pairs.Count -and $pairs[$j].code -ne 0) {
                            if ($pairs[$j].code -eq 10 -and $null -eq $vx) { $vx = ConvertTo-CadDouble ([string]$pairs[$j].value) }
                            if ($pairs[$j].code -eq 20 -and $null -eq $vy) { $vy = ConvertTo-CadDouble ([string]$pairs[$j].value) }
                            $j++
                        }
                        if ($null -ne $vx -and $null -ne $vy) {
                            $lastPolylineBucket.plinePts.Add(@($vx, $vy)) | Out-Null
                        }
                        $i = $j - 1
                    }
                    continue
                }
                if (-not $t) { continue }
                if ($entityTotal -ge $script:CadRenderMaxEntities) {
                    $auditErrors.Add("实体数超过上限 $($script:CadRenderMaxEntities)，解析中止") | Out-Null
                    break
                }
                $curBucket = New-CadRenderBucket $t
                if ($t -eq 'POLYLINE') { $lastPolylineBucket = $curBucket }
                $entityBuckets.Add($curBucket) | Out-Null
                $entityTotal++
                if ($entityCounts.ContainsKey($t)) { $entityCounts[$t]++ } else { $entityCounts[$t] = 1 }
                continue
            }
            if ($null -ne $curBucket) {
                if ($p.code -eq 8) { $curBucket.layer = [string]$p.value }
                elseif ($p.code -eq 62) { $curBucket.color = [string]$p.value }
                elseif ($curBucket.type -eq 'POLYLINE' -and $p.code -eq 70) {
                    $f = ConvertTo-CadDouble ([string]$p.value)
                    if ($null -ne $f) { $curBucket.plineClosed = ([int]$f -band 1) -ne 0 }
                }
                $curBucket.codes.Add(@{ c = $p.code; v = $p.value }) | Out-Null
            }
            continue
        }
    }

    # ── 审计：结构事实 ──
    if (-not $eof) { $auditErrors.Add('缺少 EOF 记录（文件被截断）') | Out-Null }
    if ($secOpen -ne 0) { $auditErrors.Add("SECTION/ENDSEC 不配对，差值 $secOpen") | Out-Null }
    if (-not ($secNames -contains 'ENTITIES')) { $auditErrors.Add('缺少 ENTITIES 段') | Out-Null }

    # ── 第二遍：桶 → 图元（INSERT 展开） ──
    $prims = ConvertTo-CadRenderPrimList -Buckets $entityBuckets.ToArray() -Blocks $blocks -Fixes $auditFixes -Depth 0

    # ── 图层计数：实体实际落在哪些图层 ──
    # layerCounts 在第一遍已预置 TABLES 声明的图层（值 0），
    # 这里累加实际有图元的图层；实体缺图层按 '0' 计。
    foreach ($pr in $prims) {
        $ly = if ($pr.layer) { [string]$pr.layer } else { '0' }
        if ($layerCounts.ContainsKey($ly)) { $layerCounts[$ly]++ } else { $layerCounts[$ly] = 1 }
    }

    $extents = Get-CadRenderExtents $prims
    if ($null -eq $extents -and $entityTotal -gt 0) {
        $warnings.Add("有 $entityTotal 个实体但没有可画几何（全是文字空串/坏坐标），预览为空") | Out-Null
    }

    $headerExtents = $null
    if ($null -ne $extMinX -and $null -ne $extMinY -and $null -ne $extMaxX -and $null -ne $extMaxY) {
        $headerExtents = @{ minX = $extMinX; minY = $extMinY; maxX = $extMaxX; maxY = $extMaxY }
    }

    $valid = ($auditErrors.Count -eq 0)
    $reason = if ($valid) { 'ok' } else { ($auditErrors -join '；') }

    return [pscustomobject][ordered]@{
        valid         = $valid
        reason        = $reason
        version       = $version
        entities      = $prims
        blocks        = $blocks
        layerCounts   = $layerCounts
        entityCounts  = $entityCounts
        extents       = $extents
        headerExtents = $headerExtents
        auditErrors   = $auditErrors.ToArray()
        auditFixes    = $auditFixes.ToArray()
        warnings      = $warnings.ToArray()
        entityTotal   = $entityTotal
        blockTotal    = $blockTotal
        encoding      = $doc.encoding
    }
}

# ══════════════════════════════════════════════════════════════════
#  六、布局
# ══════════════════════════════════════════════════════════════════

function Get-CadRenderLayout {
    <#
      extents → 页面布局。返回 @{ scale; offX; offY; pageW; pageH; contentW; contentH }，
      单位 mm。scale 把世界坐标变成页面 mm，offX/offY 是绘图区左下角在页面上的位置。
      零尺寸范围（单点/水平线）用 1mm 兜底，避免除零。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Extents,
        [Parameter(Mandatory)][double[]]$PageMm,
        [double]$MarginMm = 10.0
    )
    $contentW = $PageMm[0] - 2.0 * $MarginMm
    $contentH = $PageMm[1] - 2.0 * $MarginMm
    if ($contentW -le 1) { $contentW = 1 }
    if ($contentH -le 1) { $contentH = 1 }

    $drawW = $Extents.maxX - $Extents.minX
    $drawH = $Extents.maxY - $Extents.minY
    if ($drawW -le 0.0) { $drawW = 1.0 }
    if ($drawH -le 0.0) { $drawH = 1.0 }

    $scale = [Math]::Min($contentW / $drawW, $contentH / $drawH)
    $offX = $MarginMm + ($contentW - $drawW * $scale) / 2.0
    $offY = $MarginMm + ($contentH - $drawH * $scale) / 2.0

    return @{
        scale = $scale; offX = $offX; offY = $offY
        pageW = $PageMm[0]; pageH = $PageMm[1]
        contentW = $contentW; contentH = $contentH
        drawW = $drawW; drawH = $drawH
    }
}

# ══════════════════════════════════════════════════════════════════
#  七、PNG 渲染（System.Drawing）
# ══════════════════════════════════════════════════════════════════

function Write-CadPreviewPng {
    param(
        [Parameter(Mandatory)][object[]]$Prims,
        [Parameter(Mandatory)][hashtable]$Extents,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][double[]]$PageMm,
        [int]$Dpi = 300,
        [double]$MarginMm = 10.0
    )
    $mmToPx = $Dpi / 25.4
    $pxW = [int][Math]::Round($PageMm[0] * $mmToPx)
    $pxH = [int][Math]::Round($PageMm[1] * $mmToPx)
    if ($pxW -lt 1) { $pxW = 1 }
    if ($pxH -lt 1) { $pxH = 1 }

    $lay = Get-CadRenderLayout -Extents $Extents -PageMm $PageMm -MarginMm $MarginMm
    $sc = $lay.scale
    $minX = $Extents.minX; $minY = $Extents.minY

    # 世界 → 像素（PNG 的 Y 向下，要翻；页面原点在左上）
    $toPxX = { param($x) (($lay.offX + ($x - $minX) * $sc) * $mmToPx) }
    $toPxY = { param($y) (($lay.pageH - ($lay.offY + ($y - $minY) * $sc)) * $mmToPx) }

    $bmp = New-Object System.Drawing.Bitmap($pxW, $pxH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::White)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        # 页面框（浅灰）+ 绘图区框（更浅），让边距可见
        $penFrame = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(190, 190, 190), 1.0)
        $penMargin = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(225, 225, 225), 1.0)
        $g.DrawRectangle($penFrame, 0, 0, $pxW - 1, $pxH - 1)
        $g.DrawRectangle($penMargin,
            [float]($MarginMm * $mmToPx), [float]($MarginMm * $mmToPx),
            [float](($lay.contentW) * $mmToPx), [float](($lay.contentH) * $mmToPx))

        $ink = [System.Drawing.Color]::FromArgb(35, 35, 35)
        $penW = [Math]::Max(1.0, 0.25 * $sc * $mmToPx)   # 名义线宽 0.25mm，随缩放，最细 1px
        $pen = New-Object System.Drawing.Pen($ink, [float]$penW)
        $penLine = New-Object System.Drawing.Pen($ink, [float]$penW)
        $penPoint = New-Object System.Drawing.Pen($ink, [float][Math]::Max(2.0, $penW))
        $brush = New-Object System.Drawing.SolidBrush($ink)

        $fontFamily = $null
        try { $fontFamily = New-Object System.Drawing.FontFamily('Microsoft YaHei UI') } catch { $fontFamily = $null }
        if ($null -eq $fontFamily) {
            try { $fontFamily = New-Object System.Drawing.FontFamily('Microsoft YaHei') } catch { $fontFamily = [System.Drawing.FontFamily]::GenericSansSerif }
        }

        foreach ($pr in $Prims) {
            if ($null -eq $pr) { continue }
            if ($pr.kind -eq 'line') {
                $g.DrawLine($penLine,
                    [float](& $toPxX $pr.x1), [float](& $toPxY $pr.y1),
                    [float](& $toPxX $pr.x2), [float](& $toPxY $pr.y2))
            } elseif ($pr.kind -eq 'polyline') {
                $pts = $pr.points
                if ($null -eq $pts -or $pts.Count -lt 2) { continue }
                $px = New-Object System.Collections.Generic.List[System.Drawing.PointF]
                foreach ($pt in $pts) {
                    if ($null -eq $pt -or $pt.Count -lt 2) { continue }
                    $px.Add([System.Drawing.PointF]::new([float](& $toPxX $pt[0]), [float](& $toPxY $pt[1]))) | Out-Null
                }
                if ($px.Count -lt 2) { continue }
                if ($pr.closed) {
                    $px.Add($px[0]) | Out-Null     # 闭合：首尾相接
                }
                $g.DrawLines($penLine, $px.ToArray())
            } elseif ($pr.kind -eq 'point') {
                $cx = & $toPxX $pr.x; $cy = & $toPxY $pr.y
                $half = [Math]::Max(1.5, $penW)
                $g.DrawLine($penPoint, [float]($cx - $half), [float]($cy - $half), [float]($cx + $half), [float]($cy + $half))
                $g.DrawLine($penPoint, [float]($cx - $half), [float]($cy + $half), [float]($cx + $half), [float]($cy - $half))
            } elseif ($pr.kind -eq 'text') {
                $sizePx = [Math]::Max(6.0, $pr.height * $sc * $mmToPx)
                if ($sizePx -gt 400) { $sizePx = 400 }
                try {
                    $font = New-Object System.Drawing.Font($fontFamily, [float]$sizePx,
                        [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
                    try {
                        $st = $g.Save()
                        $g.TranslateTransform([float](& $toPxX $pr.x), [float](& $toPxY $pr.y))
                        $g.RotateTransform([float](- $pr.rot))    # 屏幕 Y 翻转后 CCW 变 CW，取负
                        $g.DrawString($pr.s, $font, $brush, [float]0, [float](- $sizePx))
                        $g.Restore($st)
                    } finally {
                        if ($font) { $font.Dispose() }
                    }
                } catch {
                    # 字体渲染失败不致命：画一条基线示意
                    $g.DrawLine($penLine,
                        [float](& $toPxX $pr.x), [float](& $toPxY $pr.y),
                        [float](& $toPxX ($pr.x + $pr.height * 0.62 * [Math]::Max(1, $pr.s.Length))), [float](& $toPxY $pr.y))
                }
            }
        }

        # 保存前确保目录存在
        $outDir = Split-Path -Parent $Output
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $bmp.Save($Output, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($g) { $g.Dispose() }
        if ($bmp) { $bmp.Dispose() }
    }
    return $Output
}

# ══════════════════════════════════════════════════════════════════
#  八、PDF 渲染（最小 PDF 写出器，矢量）
# ══════════════════════════════════════════════════════════════════

function ConvertTo-CadPdfTextLiteral {
    # PDF 字符串字面量：转义特殊字符；基础 14 字体不含中文 → 非 Latin-1 变 '?'
    param([string]$S)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $S.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '(' -or $ch -eq ')' -or $ch -eq '\') {
            [void]$sb.Append('\'); [void]$sb.Append($ch)
        } elseif ($code -ge 32 -and $code -le 126) {
            [void]$sb.Append($ch)
        } elseif ($code -ge 160 -and $code -le 255) {
            [void]$sb.Append($ch)    # WinAnsi 与 Latin-1 在 0xA0-0xFF 基本一致
        } else {
            [void]$sb.Append('?')
        }
    }
    return $sb.ToString()
}

function Write-CadPreviewPdf {
    <#
      手写最小 PDF 1.4：Catalog / Pages / Page / Contents / Helvetica。
      页面尺寸 = 页幅 mm × 72/25.4（点）。坐标 Y 向上，与 DXF 同向，无需翻转。
      xref 偏移按字节数精确计算（Latin-1 编码 1 字符 = 1 字节）。
    #>
    param(
        [Parameter(Mandatory)][object[]]$Prims,
        [Parameter(Mandatory)][hashtable]$Extents,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][double[]]$PageMm,
        [double]$MarginMm = 10.0,
        [string]$Title = 'CAD preview'
    )
    $mmToPt = 72.0 / 25.4
    $pageWPt = $PageMm[0] * $mmToPt
    $pageHPt = $PageMm[1] * $mmToPt

    $lay = Get-CadRenderLayout -Extents $Extents -PageMm $PageMm -MarginMm $MarginMm
    $sc = $lay.scale
    $minX = $Extents.minX; $minY = $Extents.minY

    # 世界 → PDF 点（PDF 原点左下、Y 向上）
    $toPtX = { param($x) (($lay.offX + ($x - $minX) * $sc) * $mmToPt) }
    $toPtY = { param($y) (($lay.offY + ($y - $minY) * $sc) * $mmToPt) }

    $fmt = [System.Globalization.CultureInfo]::InvariantCulture
    $cs = New-Object System.Text.StringBuilder
    [void]$cs.Append("q`n")
    $lw = [Math]::Max(0.2, 0.25 * $sc * $mmToPt)
    [void]$cs.Append(($lw.ToString('0.###', $fmt) + " w 0.14 0.14 0.14 RG 0 G`n"))

    $textWarnCount = 0
    foreach ($pr in $Prims) {
        if ($null -eq $pr) { continue }
        if ($pr.kind -eq 'line') {
            [void]$cs.Append(("{0} {1} m {2} {3} l S`n" -f (& $toPtX $pr.x1).ToString('0.###', $fmt),
                (& $toPtY $pr.y1).ToString('0.###', $fmt), (& $toPtX $pr.x2).ToString('0.###', $fmt),
                (& $toPtY $pr.y2).ToString('0.###', $fmt)))
        } elseif ($pr.kind -eq 'polyline') {
            $pts = $pr.points
            if ($null -eq $pts -or $pts.Count -lt 2) { continue }
            $sb = New-Object System.Text.StringBuilder
            $first = $true
            foreach ($pt in $pts) {
                if ($null -eq $pt -or $pt.Count -lt 2) { continue }
                if ($first) {
                    [void]$sb.Append(("{0} {1} m " -f (& $toPtX $pt[0]).ToString('0.###', $fmt), (& $toPtY $pt[1]).ToString('0.###', $fmt)))
                    $first = $false
                } else {
                    [void]$sb.Append(("{0} {1} l " -f (& $toPtX $pt[0]).ToString('0.###', $fmt), (& $toPtY $pt[1]).ToString('0.###', $fmt)))
                }
            }
            if ($first) { continue }
            if ($pr.closed) {
                [void]$sb.Append('h ')
            }
            [void]$sb.Append("S`n")
            [void]$cs.Append($sb.ToString())
        } elseif ($pr.kind -eq 'point') {
            $cx = (& $toPtX $pr.x).ToString('0.###', $fmt)
            $cy = (& $toPtY $pr.y).ToString('0.###', $fmt)
            [void]$cs.Append("0.8 w 0 G`n")
            [void]$cs.Append(("0.6 0.6 0 RG {0} {1} m {2} {3} l S {0} {1} m {4} {5} l S`n" -f $cx, $cy,
                ((& $toPtX $pr.x) + 1.0).ToString('0.###', $fmt), ((& $toPtY $pr.y) + 1.0).ToString('0.###', $fmt),
                ((& $toPtX $pr.x) - 1.0).ToString('0.###', $fmt), ((& $toPtY $pr.y) - 1.0).ToString('0.###', $fmt)))
            [void]$cs.Append(($lw.ToString('0.###', $fmt) + " w 0.14 0.14 0.14 RG`n"))
        } elseif ($pr.kind -eq 'text') {
            $hPt = $pr.height * $sc * $mmToPt
            if ($hPt -le 0.5) { continue }
            if ($hPt -gt 200) { $hPt = 200 }
            $tx = ConvertTo-CadPdfTextLiteral $pr.s
            if ($tx -ne $pr.s) { $textWarnCount++ }
            [void]$cs.Append(("BT /F1 {0} Tf {1} {2} Td ({3}) Tj ET`n" -f $hPt.ToString('0.##', $fmt),
                (& $toPtX $pr.x).ToString('0.###', $fmt), (& $toPtY $pr.y).ToString('0.###', $fmt), $tx))
        }
    }
    [void]$cs.Append("Q`n")
    $contentStr = $cs.ToString()

    # ── 组装 PDF 字节 ──
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $pdf = New-Object System.Text.StringBuilder
    $offsets = @{}
    [void]$pdf.Append("%PDF-1.4`n")

    $offsets[1] = $pdf.Length
    [void]$pdf.Append("1 0 obj`n<</Type/Catalog/Pages 2 0 R>>`nendobj`n")

    $offsets[2] = $pdf.Length
    [void]$pdf.Append("2 0 obj`n<</Type/Pages/Kids[3 0 R]/Count 1>>`nendobj`n")

    $offsets[3] = $pdf.Length
    $pw = $pageWPt.ToString('0.##', $fmt); $ph = $pageHPt.ToString('0.##', $fmt)
    [void]$pdf.Append("3 0 obj`n<</Type/Page/Parent 2 0 R/MediaBox[0 0 $pw $ph]/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>`nendobj`n")

    $offsets[4] = $pdf.Length
    $contentBytes = $latin1.GetBytes($contentStr)
    [void]$pdf.Append("4 0 obj`n<</Length $($contentBytes.Length)>>`nstream`n")
    [void]$pdf.Append($contentStr)
    [void]$pdf.Append("`nendstream`nendobj`n")

    $offsets[5] = $pdf.Length
    [void]$pdf.Append("5 0 obj`n<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>`nendobj`n")

    $xrefPos = $pdf.Length
    [void]$pdf.Append("xref`n0 6`n")
    [void]$pdf.Append("0000000000 65535 f `n")
    for ($objNum = 1; $objNum -le 5; $objNum++) {
        [void]$pdf.Append(('{0:d10} 00000 n ' -f $offsets[$objNum]) + "`n")
    }
    $titleEsc = ConvertTo-CadPdfTextLiteral $Title
    [void]$pdf.Append("trailer`n<</Size 6/Root 1 0 R/Info<</Title($titleEsc)/Producer(CadRender.ps1)>>>>`n")
    [void]$pdf.Append("startxref`n$xrefPos`n%%EOF`n")

    # 保存前确保目录存在
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Output, $latin1.GetBytes($pdf.ToString()))

    return @{ path = $Output; textReplaced = $textWarnCount }
}

# ══════════════════════════════════════════════════════════════════
#  九、总入口：渲染预览（供 CLI 调用）
# ══════════════════════════════════════════════════════════════════

function Invoke-CadDxfPreviewRender {
    <#
      DXF → 审计 + 计数 + 固定页幅 PNG/PDF。
      报告字段对齐 render_dxf_preview.py：tool/status/dxf/sha256/
      audit_errors/audit_fixes/entity_counts/layer_counts/page_mm/dpi/
      extents/artifacts/warnings/durationMs。
      status: blocked（结构错误，无法渲染）/ pass_with_warnings / pass
    #>
    param(
        [Parameter(Mandatory)][string]$Dxf,
        [string]$OutputDir,
        [ValidateSet('A4', 'A3', 'A2', 'A1')][string]$Page = 'A4',
        [ValidateSet('landscape', 'portrait')][string]$Orientation = 'landscape',
        [double]$MarginMm = 10.0,
        [int]$Dpi = 300,
        [switch]$NoPng,
        [switch]$NoPdf
    )
    $started = Get-Date
    $warnings = New-Object System.Collections.Generic.List[string]
    $artifacts = New-Object System.Collections.Generic.List[object]

    $dxfFull = $null
    if (-not (Test-Path -LiteralPath $Dxf -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            tool = 'Invoke-CadRenderPreview/1.0'; status = 'blocked'
            dxf = $Dxf; sha256 = $null
            audit_errors = @("DXF 文件不存在: $Dxf"); audit_fixes = @()
            entity_counts = @{}; layer_counts = @{}
            page_mm = @(); dpi = $Dpi; extents = $null
            artifacts = @(); warnings = @()
            durationMs = 0; exitCode = 3
        }
    }
    $dxfFull = (Resolve-Path -LiteralPath $Dxf).Path

    try {
        $sha = Get-CadSha256 -Path $dxfFull
    } catch {
        $sha = $null
    }

    $data = Get-CadDxfRenderData -Path $dxfFull

    foreach ($w in $data.warnings) { $warnings.Add($w) | Out-Null }

    # 审计错误 → blocked
    if (-not $data.valid) {
        return [pscustomobject][ordered]@{
            tool = 'Invoke-CadRenderPreview/1.0'; status = 'blocked'
            dxf = $dxfFull; sha256 = $sha
            audit_errors = $data.auditErrors; audit_fixes = $data.auditFixes
            entity_counts = $data.entityCounts; layer_counts = $data.layerCounts
            page_mm = @(); dpi = $Dpi; extents = $null
            artifacts = $artifacts.ToArray(); warnings = $warnings.ToArray()
            version = $data.version; encoding = $data.encoding
            durationMs = [int]((Get-Date) - $started).TotalMilliseconds; exitCode = 3
        }
    }

    # 页幅
    $base = $script:CadRenderPageMm[$Page]
    if ($Orientation -eq 'portrait') {
        $pageMm = @($base[1], $base[0])
    } else {
        $pageMm = @($base[0], $base[1])
    }

    # 输出目录与文件名
    $dxfName = [IO.Path]::GetFileNameWithoutExtension($dxfFull)
    if (-not $OutputDir) {
        $OutputDir = Join-Path (Split-Path -Parent $dxfFull) 'cad-preview'
    }
    if (-not [IO.Path]::IsPathRooted($OutputDir)) {
        $OutputDir = Join-Path (Split-Path -Parent $dxfFull) $OutputDir
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $pngPath = Join-Path $OutputDir ($dxfName + '-preview.png')
    $pdfPath = Join-Path $OutputDir ($dxfName + '-preview.pdf')

    $extents = $data.extents
    if ($null -eq $extents) {
        return [pscustomobject][ordered]@{
            tool = 'Invoke-CadRenderPreview/1.0'; status = 'blocked'
            dxf = $dxfFull; sha256 = $sha
            audit_errors = @('没有可渲染的几何（ENTITIES 段为空或全部不可解析）'); audit_fixes = $data.auditFixes
            entity_counts = $data.entityCounts; layer_counts = $data.layerCounts
            page_mm = $pageMm; dpi = $Dpi; extents = $null
            artifacts = $artifacts.ToArray(); warnings = $warnings.ToArray()
            version = $data.version; encoding = $data.encoding
            durationMs = [int]((Get-Date) - $started).TotalMilliseconds; exitCode = 3
        }
    }

    # ── 渲染 ──
    try {
        if (-not $NoPng) {
            Write-CadPreviewPng -Prims $data.entities -Extents $extents -Output $pngPath `
                -PageMm $pageMm -Dpi $Dpi -MarginMm $MarginMm | Out-Null
            $pngItem = [ordered]@{
                kind = 'png'; path = $pngPath
                bytes = (Get-Item -LiteralPath $pngPath).Length
                sha256 = (Get-CadSha256 -Path $pngPath)
            }
            $artifacts.Add([pscustomobject]$pngItem) | Out-Null
        }
        $pdfTextReplaced = 0
        if (-not $NoPdf) {
            $pdfRes = Write-CadPreviewPdf -Prims $data.entities -Extents $extents -Output $pdfPath `
                -PageMm $pageMm -MarginMm $MarginMm -Title $dxfName
            $pdfTextReplaced = $pdfRes.textReplaced
            $pdfItem = [ordered]@{
                kind = 'pdf'; path = $pdfPath
                bytes = (Get-Item -LiteralPath $pdfPath).Length
                sha256 = (Get-CadSha256 -Path $pdfPath)
            }
            $artifacts.Add([pscustomobject]$pdfItem) | Out-Null
        }
        if ($pdfTextReplaced -gt 0) {
            $warnings.Add("PDF 预览里 $pdfTextReplaced 处文字含中文/非 Latin-1 字符，已替换为 '?'（基础 14 字体不含中文；PNG 预览不受影响）") | Out-Null
        }
    } catch {
        return [pscustomobject][ordered]@{
            tool = 'Invoke-CadRenderPreview/1.0'; status = 'blocked'
            dxf = $dxfFull; sha256 = $sha
            audit_errors = @("渲染失败: $($_.Exception.Message)"); audit_fixes = $data.auditFixes
            entity_counts = $data.entityCounts; layer_counts = $data.layerCounts
            page_mm = $pageMm; dpi = $Dpi; extents = $extents
            artifacts = $artifacts.ToArray(); warnings = $warnings.ToArray()
            version = $data.version; encoding = $data.encoding
            durationMs = [int]((Get-Date) - $started).TotalMilliseconds; exitCode = 3
        }
    }

    # ── status 分档 ──
    $status = 'pass'
    if ($data.auditFixes.Count -gt 0 -or $warnings.Count -gt 0) { $status = 'pass_with_warnings' }

    return [pscustomobject][ordered]@{
        tool = 'Invoke-CadRenderPreview/1.0'; status = $status
        dxf = $dxfFull; sha256 = $sha
        audit_errors = @(); audit_fixes = $data.auditFixes
        entity_counts = $data.entityCounts; layer_counts = $data.layerCounts
        page_mm = $pageMm; dpi = $Dpi; extents = $extents
        artifacts = $artifacts.ToArray(); warnings = $warnings.ToArray()
        version = $data.version; encoding = $data.encoding
        entityTotal = $data.entityTotal; blockTotal = $data.blockTotal
        durationMs = [int]((Get-Date) - $started).TotalMilliseconds; exitCode = 0
    }
}