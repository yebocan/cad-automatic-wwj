<#
.SYNOPSIS
    Invoke-CadAnchorCompare.ps1 — 锚点配准比对（重建预览 ↔ 源图）。

.DESCRIPTION
    借鉴 autocad-image-redraw 的 compare_redraw 思路（锚点→单应配准→边缘距离统计），
    零 Python 依赖，纯 .NET + PowerShell 实现。

    流程：
      1. 读 anchors JSON：source_points（源图像素坐标）+ cad_points（CAD 预览像素坐标），
         ≥4 对，可带 views 数组做多视图（每视图独立配准 + ROI 合成）。
      2. 每视图解 3x3 单应（归一化 DLT + 高斯消元，Hartley 归一化保数值稳定），
         把 CAD 预览 warp 到源图坐标系，按 ROI 合成。
      3. 两图各提取边缘（Sobel 梯度幅值 + 阈值），算双向边缘距离统计
         （中位数 / P95 / 阈值覆盖率）。距离变换用两遍 chamfer 近似——预检级精度够用。

    证据级别是 inferred：像素配准只能回答「线画得像不像位置对不对」，
    永远证明不了物理尺寸。这个警告写死在输出里。

    与 Invoke-CadVisualCompare 的关系：几何模式（DXF 实体级）走那边，
    本脚本是像素级配准增强，两者互补不替代。

    anchors JSON 格式（单视图）：
      { "source_points": [[x,y],...], "cad_points": [[x,y],...] }
    多视图：
      { "views": [ { "source_points": [...], "cad_points": [...], "source_roi": [l,t,r,b] }, ... ] }

.EXAMPLE
    & .\Invoke-CadAnchorCompare.ps1 -Source plan.jpg -CadPreview preview.png -Anchors anchors.json -OutputDir reports\cmp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$CadPreview,
    [Parameter(Mandatory)][string]$Anchors,
    [string]$OutputDir,
    # 边缘判定阈值（0-255 梯度幅值）
    [int]$EdgeThreshold = 60,
    # 距离覆盖率阈值组（像素）
    [double[]]$Thresholds = @(3, 5, 10),
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')

Add-Type -AssemblyName System.Drawing

$started = Get-Date

# ── 数学核心：归一化 DLT 单应求解 ─────────────────────────────
function Find-CadHomography {
    # ★ 为什么不用 [double[][]] 参数类型：PS7 下类型化参数配 foreach 迭代，
    #   $p[0] 会被绑成数组（实测复现），无类型参数 + 索引处显式 [double] 转换才对。
    param($Src, $Dst)
    # 入口固化：把调用方数组拷进本地 jagged 数组。PS7 对外部传入数组的迭代行为
    # 受调用点数组构造方式影响（实测：+= 累积建的数组在跨函数迭代时 $p[0] 解析异常），
    # 拷贝一层后行为完全确定。
    # ★ 数组字面量内 [double]$x[0] 形式会踩解析坑（见 Norm-Pts 注释），必须先赋临时变量
    $srcPts = New-Object 'double[][]' $Src.Count
    for ($i = 0; $i -lt $Src.Count; $i++) {
        $ax = [double]$Src[$i][0]; $ay = [double]$Src[$i][1]
        $srcPts[$i] = [double[]]@($ax, $ay)
    }
    $dstPts = New-Object 'double[][]' $Dst.Count
    for ($i = 0; $i -lt $Dst.Count; $i++) {
        $bx = [double]$Dst[$i][0]; $by = [double]$Dst[$i][1]
        $dstPts[$i] = [double[]]@($bx, $by)
    }
    if ($srcPts.Count -lt 4 -or $srcPts.Count -ne $dstPts.Count) { return $null }

    # ★ 数组字面量 @() 内部元素以 [ 开头（如 [double]$x）会被解析器当成 cast 组合，
    #   产生 Object[] 参与运算的诡异错误（实测复现）。所以本函数内一律先赋临时变量，
    #   数组字面量里只放已算好的纯变量。
    # ★ 函数参数与循环变量不得仅大小写不同（PS 变量大小写不敏感）：
    #   foreach ($p in $P) 中 $p/$P 视为同一变量，迭代时自赋值破坏枚举（实测复现）。
    function Norm-Pts($Pts) {
        $cx = [double]0; $cy = [double]0
        foreach ($pt in $Pts) {
            $px = [double]$pt[0]; $py = [double]$pt[1]
            $cx = $cx + $px; $cy = $cy + $py
        }
        $cnt = $Pts.Count
        $cx = $cx / $cnt; $cy = $cy / $cnt
        $md = [double]0
        foreach ($pt in $Pts) {
            $px = [double]$pt[0]; $py = [double]$pt[1]
            $dx = $px - $cx; $dy = $py - $cy
            $md = $md + [Math]::Sqrt($dx * $dx + $dy * $dy)
        }
        $md = $md / $cnt
        $s = 1.0
        if ($md -gt 1e-9) { $s = [Math]::Sqrt(2.0) / $md }
        $out = New-Object 'double[][]' $cnt
        for ($i = 0; $i -lt $cnt; $i++) {
            $px = [double]$Pts[$i][0]; $py = [double]$Pts[$i][1]
            $vx = ($px - $cx) * $s
            $vy = ($py - $cy) * $s
            $out[$i] = [double[]]@($vx, $vy)
        }
        return @{ pts = $out; cx = $cx; cy = $cy; s = $s }
    }
    function Mul3([double[]]$a, [double[]]$b) {
        $r = New-Object double[] 9
        for ($i = 0; $i -lt 3; $i++) { for ($j = 0; $j -lt 3; $j++) {
            $r[$i*3+$j] = $a[$i*3]*$b[$j] + $a[$i*3+1]*$b[3+$j] + $a[$i*3+2]*$b[6+$j]
        } }
        return $r
    }
    function Inv3([double[]]$m) {
        $a=$m[0];$b=$m[1];$c=$m[2];$d=$m[3];$e=$m[4];$f=$m[5];$g=$m[6];$h2=$m[7];$i2=$m[8]
        $det = $a*($e*$i2-$f*$h2) - $b*($d*$i2-$f*$g) + $c*($d*$h2-$e*$g)
        if ([Math]::Abs($det) -lt 1e-12) { return $null }
        $r0 = (($e*$i2-$f*$h2)/$det); $r1 = (($c*$h2-$b*$i2)/$det); $r2 = (($b*$f-$c*$e)/$det)
        $r3 = (($f*$g-$d*$i2)/$det); $r4 = (($a*$i2-$c*$g)/$det); $r5 = (($c*$d-$a*$f)/$det)
        $r6 = (($d*$h2-$e*$g)/$det); $r7 = (($b*$g-$a*$h2)/$det); $r8 = (($a*$e-$b*$d)/$det)
        return [double[]]@($r0, $r1, $r2, $r3, $r4, $r5, $r6, $r7, $r8)
    }

    $ns = Norm-Pts $srcPts
    $nd = Norm-Pts $dstPts
    $n = $srcPts.Count
    # 化为 2n x 8 非齐次（h33=1）
    $M = New-Object 'double[][]' (2*$n)
    for ($i = 0; $i -lt $n; $i++) {
        $x = [double]$ns.pts[$i][0]; $y = [double]$ns.pts[$i][1]
        $u = [double]$nd.pts[$i][0]; $v = [double]$nd.pts[$i][1]
        $nux = $u * $x; $nuy = $u * $y; $nvx = $v * $x; $nvy = $v * $y
        # A 形式非齐次 DLT 行：[x y 1 0 0 0 -ux -uy | +u]，末列即消元 RHS
        $M[2*$i]   = [double[]]@($x, $y, 1.0, 0.0, 0.0, 0.0, -$nux, -$nuy, $u)
        $M[2*$i+1] = [double[]]@(0.0, 0.0, 0.0, $x, $y, 1.0, -$nvx, -$nvy, $v)
    }
    $rows = 2*$n
    for ($col = 0; $col -lt 8; $col++) {
        $piv = -1; $maxv = 1e-12
        for ($r = $col; $r -lt $rows; $r++) {
            if ([Math]::Abs($M[$r][$col]) -gt $maxv) { $maxv = [Math]::Abs($M[$r][$col]); $piv = $r }
        }
        if ($piv -lt 0) { return $null }
        if ($piv -ne $col) { $t = $M[$col]; $M[$col] = $M[$piv]; $M[$piv] = $t }
        $pv = $M[$col][$col]
        for ($c = 0; $c -lt 9; $c++) { $M[$col][$c] /= $pv }
        for ($r = 0; $r -lt $rows; $r++) {
            if ($r -ne $col -and [Math]::Abs($M[$r][$col]) -gt 1e-15) {
                $f = $M[$r][$col]
                for ($c = 0; $c -lt 9; $c++) { $M[$r][$c] -= $f * $M[$col][$c] }
            }
        }
    }
    $hn = New-Object double[] 9
    for ($c = 0; $c -lt 8; $c++) { $hn[$c] = $M[$c][8] }
    $hn[8] = 1.0
    # H = Td^-1 * Hn * Ts   （数组字面量内不放表达式，全部分步）
    $ss = [double]$ns.s; $scx = [double]$ns.cx; $scy = [double]$ns.cy
    $ds = [double]$nd.s; $dcx = [double]$nd.cx; $dcy = [double]$nd.cy
    $t2 = -$ss * $scx; $t5 = -$ss * $scy
    $Ts = [double[]]@($ss, 0.0, $t2, 0.0, $ss, $t5, 0.0, 0.0, 1.0)
    $id = 1.0 / $ds
    $TdInv = [double[]]@($id, 0.0, $dcx, 0.0, $id, $dcy, 0.0, 0.0, 1.0)
    $H1 = Mul3 $hn $Ts
    $H = Mul3 $TdInv $H1
    return $H
}

function ConvertFrom-CadWarp {
    # 用单应 H 把 cadGray 双线性重采样到 (w,h)，白底填充
    param([byte[]]$CadGray, [int]$CadW, [int]$CadH, [double[]]$H, [int]$W, [int]$Ht)
    $out = New-Object byte[] ([long]$W * $Ht)
    # 填白
    for ($i = 0; $i -lt $out.Length; $i++) { $out[$i] = 255 }
    for ($y = 0; $y -lt $Ht; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $den = $H[6]*$x + $H[7]*$y + $H[8]
            if ([Math]::Abs($den) -lt 1e-12) { continue }
            $sx = ($H[0]*$x + $H[1]*$y + $H[2]) / $den
            $sy = ($H[3]*$x + $H[4]*$y + $H[5]) / $den
            if ($sx -lt 0 -or $sy -lt 0 -or $sx -ge $CadW - 1 -or $sy -ge $CadH - 1) { continue }
            $x0 = [int][Math]::Floor($sx); $y0 = [int][Math]::Floor($sy)
            $fx = $sx - $x0; $fy = $sy - $y0
            $i00 = $y0 * $CadW + $x0
            $p = (1-$fx)*(1-$fy)*$CadGray[$i00] + $fx*(1-$fy)*$CadGray[$i00+1] + (1-$fx)*$fy*$CadGray[$i00+$CadW] + $fx*$fy*$CadGray[$i00+$CadW+1]
            $out[$y * $W + $x] = [byte][Math]::Round($p)
        }
    }
    return $out
}

function Get-CadEdgeMask {
    # Sobel 幅值 + 阈值 → byte mask（0/1）
    param([byte[]]$Gray, [int]$W, [int]$Ht, [int]$Thresh)
    $mask = New-Object byte[] ([long]$W * $Ht)
    for ($y = 1; $y -lt $Ht - 1; $y++) {
        for ($x = 1; $x -lt $W - 1; $x++) {
            $i = $y * $W + $x
            $gx = -$Gray[$i-$W-1] - 2*$Gray[$i-1] - $Gray[$i+$W-1] + $Gray[$i-$W+1] + 2*$Gray[$i+1] + $Gray[$i+$W+1]
            $gy = -$Gray[$i-$W-1] - 2*$Gray[$i-$W] - $Gray[$i-$W+1] + $Gray[$i+$W-1] + 2*$Gray[$i+$W] + $Gray[$i+$W+1]
            $mag = [Math]::Sqrt([double]$gx*$gx + [double]$gy*$gy)
            if ($mag -ge $Thresh) { $mask[$i] = 1 }
        }
    }
    return $mask
}

function Get-CadChamferDistance {
    # 两遍 chamfer 距离变换（3-4 chamfer），返回到 mask=1 集合的距离图（float 近似 int*0.5 存 ushort）
    param([byte[]]$Mask, [int]$W, [int]$Ht)
    $INF = 60000
    $d = New-Object uint16[] ([long]$W * $Ht)
    for ($i = 0; $i -lt $d.Length; $i++) { $d[$i] = if ($Mask[$i] -eq 1) { 0 } else { $INF } }
    # 前向：左、上、左上、右上
    for ($y = 0; $y -lt $Ht; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $i = $y * $W + $x
            if ($d[$i] -eq 0) { continue }
            $v = $d[$i]
            if ($x -gt 0)      { $t = $d[$i-1] + 3;   if ($t -lt $v) { $v = $t } }
            if ($y -gt 0)      { $t = $d[$i-$W] + 3;  if ($t -lt $v) { $v = $t } }
            if ($x -gt 0 -and $y -gt 0)   { $t = $d[$i-$W-1] + 4; if ($t -lt $v) { $v = $t } }
            if ($x -lt $W-1 -and $y -gt 0) { $t = $d[$i-$W+1] + 4; if ($t -lt $v) { $v = $t } }
            $d[$i] = $v
        }
    }
    # 反向
    for ($y = $Ht-1; $y -ge 0; $y--) {
        for ($x = $W-1; $x -ge 0; $x--) {
            $i = $y * $W + $x
            if ($d[$i] -eq 0) { continue }
            $v = $d[$i]
            if ($x -lt $W-1)   { $t = $d[$i+1] + 3;   if ($t -lt $v) { $v = $t } }
            if ($y -lt $Ht-1)  { $t = $d[$i+$W] + 3;  if ($t -lt $v) { $v = $t } }
            if ($x -lt $W-1 -and $y -lt $Ht-1) { $t = $d[$i+$W+1] + 4; if ($t -lt $v) { $v = $t } }
            if ($x -gt 0 -and $y -lt $Ht-1)    { $t = $d[$i+$W-1] + 4; if ($t -lt $v) { $v = $t } }
            $d[$i] = $v
        }
    }
    return $d
}

function Get-CadGray {
    param([string]$Path)
    $bmp = New-Object System.Drawing.Bitmap((Resolve-Path -LiteralPath $Path).Path)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                              [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $bytes = New-Object byte[] ($data.Stride * $h)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        } finally { $bmp.UnlockBits($data) }
        $gray = New-Object byte[] ([long]$w * $h)
        for ($y = 0; $y -lt $h; $y++) {
            $row = $y * $data.Stride
            $gi = $y * $w
            for ($x = 0; $x -lt $w; $x++) {
                $i = $row + $x * 3
                $gray[$gi + $x] = [byte](($bytes[$i+2] * 77 + $bytes[$i+1] * 150 + $bytes[$i] * 29) -shr 8)
            }
        }
        return @{ gray = $gray; w = $w; h = $h }
    } finally { $bmp.Dispose() }
}

function Test-CadPath0([string]$p, [string]$label) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "$label 不存在: $p" }
    return (Resolve-Path -LiteralPath $p).Path
}

try {
    $srcFull = Test-CadPath0 $Source '源图'
    $cadFull = Test-CadPath0 $CadPreview 'CAD 预览'

    $anchorsRaw = Get-Content -LiteralPath $Anchors -Raw -Encoding UTF8 | ConvertFrom-Json

    # 归一化视图列表：单视图 → 一个假视图
    $views = @()
    if ($null -ne $anchorsRaw.PSObject.Properties['views'] -and $anchorsRaw.views) {
        foreach ($v in $anchorsRaw.views) { $views += $v }
    } else {
        $views += $anchorsRaw
    }
    if ($views.Count -eq 0) { throw 'anchors JSON 里没有视图（既没有 views 也没有顶层点对）' }

    $src = Get-CadGray -Path $srcFull
    $cad = Get-CadGray -Path $cadFull

    $W = $src.w; $Ht = $src.h
    $composite = New-Object byte[] ([long]$W * $Ht)
    for ($i = 0; $i -lt $composite.Length; $i++) { $composite[$i] = 255 }
    $coverage = New-Object byte[] ([long]$W * $Ht)
    $totalInlier = 0

    $viewIdx = 0
    foreach ($view in $views) {
        $viewIdx++
        $sp = @(); $cp = @()
        foreach ($pt in $view.source_points) {
            $qx = [double]$pt[0]; $qy = [double]$pt[1]
            $sp += ,[double[]]@($qx, $qy)
        }
        foreach ($pt in $view.cad_points) {
            $rx = [double]$pt[0]; $ry = [double]$pt[1]
            $cp += ,[double[]]@($rx, $ry)
        }
        if ($sp.Count -lt 4) { throw "视图 #$viewIdx source_points 少于 4 对" }
        if ($sp.Count -ne $cp.Count) { throw "视图 #$viewIdx source_points 与 cad_points 数量不等" }

        $H = Find-CadHomography -Src $cp -Dst $sp
        if ($null -eq $H) { throw "视图 #$viewIdx 单应求解失败（点共线或退化）" }

        # 残差内点计数：所有点映射误差 ≤ 4px 记 inlier
        $inlier = 0
        for ($i = 0; $i -lt $sp.Count; $i++) {
            $den = $H[6]*$cp[$i][0] + $H[7]*$cp[$i][1] + $H[8]
            if ([Math]::Abs($den) -lt 1e-12) { continue }
            $mx = ($H[0]*$cp[$i][0] + $H[1]*$cp[$i][1] + $H[2]) / $den
            $my = ($H[3]*$cp[$i][0] + $H[4]*$cp[$i][1] + $H[5]) / $den
            $err = [Math]::Sqrt(($mx-$sp[$i][0])*($mx-$sp[$i][0]) + ($my-$sp[$i][1])*($my-$sp[$i][1]))
            if ($err -le 4.0) { $inlier++ }
        }
        $totalInlier += $inlier

        # warp + ROI 合成。warp 按「src 像素→cad 采样」工作，需要 H 的逆（src→cad）；
        # 我们解出的 H 是 cad→src，先求逆（齐次尺度归一）。
        $Hden = [double]$H[8]
        $Hnorm = New-Object double[] 9
        for ($k = 0; $k -lt 9; $k++) { $Hnorm[$k] = [double]$H[$k] / $Hden }
        # 顶层 3x3 求逆（Inv3 是 Find-CadHomography 的嵌套函数，此处不可见）
        $a1 = $Hnorm[0]; $b1 = $Hnorm[1]; $c1 = $Hnorm[2]
        $d1 = $Hnorm[3]; $e1 = $Hnorm[4]; $f1 = $Hnorm[5]
        $g1 = $Hnorm[6]; $h1 = $Hnorm[7]; $i1 = $Hnorm[8]
        $detH = $a1*($e1*$i1 - $f1*$h1) - $b1*($d1*$i1 - $f1*$g1) + $c1*($d1*$h1 - $e1*$g1)
        $Hinv = $null
        if ([Math]::Abs($detH) -gt 1e-12) {
            $v0 = ($e1*$i1 - $f1*$h1) / $detH
            $v1 = ($c1*$h1 - $b1*$i1) / $detH
            $v2 = ($b1*$f1 - $c1*$e1) / $detH
            $v3 = ($f1*$g1 - $d1*$i1) / $detH
            $v4 = ($a1*$i1 - $c1*$g1) / $detH
            $v5 = ($c1*$d1 - $a1*$f1) / $detH
            $v6 = ($d1*$h1 - $e1*$g1) / $detH
            $v7 = ($b1*$g1 - $a1*$h1) / $detH
            $v8 = ($a1*$e1 - $b1*$d1) / $detH
            $Hinv = [double[]]@($v0, $v1, $v2, $v3, $v4, $v5, $v6, $v7, $v8)
        }
        if ($null -eq $Hinv) { throw "视图 #$viewIdx 单应不可逆" }
        $warped = ConvertFrom-CadWarp -CadGray $cad.gray -CadW $cad.w -CadH $cad.h -H $Hinv -W $W -Ht $Ht
        $roi = @(0, 0, $W, $Ht)
        $hasRoi = $null -ne $view.PSObject.Properties['source_roi'] -and $null -ne $view.source_roi
        if ($hasRoi) {
            $r0 = [int]$view.source_roi[0]; $r1 = [int]$view.source_roi[1]
            $r2 = [int]$view.source_roi[2]; $r3 = [int]$view.source_roi[3]
            $roi = @($r0, $r1, $r2, $r3)
        }
        $l = [Math]::Max(0, $roi[0]); $t = [Math]::Max(0, $roi[1])
        $r = [Math]::Min($W, $roi[2]); $b = [Math]::Min($Ht, $roi[3])
        if ($r -le $l -or $b -le $t) { throw "视图 #$viewIdx source_roi 裁剪后为空" }
        for ($y = $t; $y -lt $b; $y++) {
            for ($x = $l; $x -lt $r; $x++) {
                $i = $y * $W + $x
                $composite[$i] = $warped[$i]
                $coverage[$i] = 1
            }
        }
    }

    # 未覆盖区填白（保持白底语义）
    for ($i = 0; $i -lt $composite.Length; $i++) {
        if ($coverage[$i] -eq 0) { $composite[$i] = 255 }
    }

    # ── 边缘与距离统计 ──
    $srcEdges = Get-CadEdgeMask -Gray $src.gray -W $W -Ht $Ht -Thresh $EdgeThreshold
    $cadEdges = Get-CadEdgeMask -Gray $composite -W $W -Ht $Ht -Thresh $EdgeThreshold
    $distToSrc = Get-CadChamferDistance -Mask $srcEdges -W $W -Ht $Ht   # 每点到源边缘的距离（chamfer 单位 3=1px）
    $distToCad = Get-CadChamferDistance -Mask $cadEdges -W $W -Ht $Ht

    $cadDists = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $cadEdges.Length; $i++) { if ($cadEdges[$i] -eq 1) { $cadDists.Add($distToSrc[$i] / 3.0) } }
    $srcDists = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $srcEdges.Length; $i++) { if ($srcEdges[$i] -eq 1) { $srcDists.Add($distToCad[$i] / 3.0) } }

    function Get-Percentile([System.Collections.Generic.List[double]]$vals, [double]$p) {
        if ($vals.Count -eq 0) { return $null }
        $s = $vals.ToArray(); [Array]::Sort($s)
        $idx = [Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($p / 100.0 * $s.Count) - 1))
        return $s[$idx]
    }
    function Get-Mean([System.Collections.Generic.List[double]]$vals) {
        if ($vals.Count -eq 0) { return 0.0 }
        $sum = 0.0; foreach ($v in $vals) { $sum += $v }
        return $sum / $vals.Count
    }

    $covCad = @{}; $covSrc = @{}
    foreach ($th in $Thresholds) {
        $c = 0; foreach ($v in $cadDists) { if ($v -le $th) { $c++ } }
        $covCad["$th"] = if ($cadDists.Count) { [Math]::Round($c / $cadDists.Count, 4) } else { 0.0 }
        $c2 = 0; foreach ($v in $srcDists) { if ($v -le $th) { $c2++ } }
        $covSrc["$th"] = if ($srcDists.Count) { [Math]::Round($c2 / $srcDists.Count, 4) } else { 0.0 }
    }

    $metrics = [ordered]@{
        tool = 'Invoke-CadAnchorCompare/1.0'
        metricScope = 'visual_registration_only'
        viewCount = $views.Count
        homographyInliers = $totalInlier
        sourceEdgePixels = $srcDists.Count
        cadEdgePixels = $cadDists.Count
        cadToSourceMedianPx = (Get-Percentile $cadDists 50)
        cadToSourceP95Px = (Get-Percentile $cadDists 95)
        sourceToCadMedianPx = (Get-Percentile $srcDists 50)
        sourceToCadP95Px = (Get-Percentile $srcDists 95)
        cadEdgeWithinThreshold = $covCad
        sourceEdgeCoverage = $covSrc
        warning = '像素配准只评估「线画得像不像」，永远不能证明物理尺寸。尺寸证据必须来自 DXF 实体级比对。'
        durationMs = $null
    }
    $metrics.durationMs = [int]((Get-Date) - $started).TotalMilliseconds

    # 落盘 registered-cad.png
    if ($OutputDir) {
        if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
        $outBmp = New-Object System.Drawing.Bitmap($W, $Ht)
        $rect2 = New-Object System.Drawing.Rectangle(0, 0, $W, $Ht)
        $d2 = $outBmp.LockBits($rect2, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                               [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $buf = New-Object byte[] ($d2.Stride * $Ht)
            for ($y = 0; $y -lt $Ht; $y++) {
                for ($x = 0; $x -lt $W; $x++) {
                    $g2 = $composite[$y * $W + $x]
                    $i2 = $y * $d2.Stride + $x * 3
                    $buf[$i2] = $g2; $buf[$i2+1] = $g2; $buf[$i2+2] = $g2
                }
            }
            [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $d2.Scan0, $buf.Length)
        } finally { $outBmp.UnlockBits($d2) }
        $regPath = Join-Path $OutputDir 'registered-cad.png'
        $outBmp.Save($regPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $outBmp.Dispose()
        $metrics.registeredCad = $regPath
        $metrics | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'metrics.json') -Encoding UTF8
    }

    if (-not $AsJson) {
        Write-Host ""
        Write-Host "══════════════════════════════════════════════════════════════"
        Write-Host ("  锚点配准比对  ·  {0} 个视图  ·  内点 {1}" -f $views.Count, $totalInlier)
        Write-Host "══════════════════════════════════════════════════════════════"
        Write-Host ("  源图     : {0} ({1}×{2})" -f $srcFull, $W, $Ht)
        Write-Host ("  CAD 预览 : {0}" -f $cadFull)
        Write-Host ("  CAD→源   : 中位 {0}px / P95 {1}px" -f $metrics.cadToSourceMedianPx, $metrics.cadToSourceP95Px)
        Write-Host ("  源→CAD   : 中位 {0}px / P95 {1}px" -f $metrics.sourceToCadMedianPx, $metrics.sourceToCadP95Px)
        foreach ($k in $covCad.Keys) { Write-Host ("  CAD 边缘 ≤{0}px 覆盖: {1}   源边缘覆盖: {2}" -f $k, $covCad[$k], $covSrc[$k]) }
        Write-Host ("  ⚠ {0}" -f $metrics.warning)
        if ($metrics.registeredCad) { Write-Host ("  配准图   : {0}" -f $metrics.registeredCad) }
    }

    exit 0

} catch {
    if ($AsJson) {
        @{ tool = 'Invoke-CadAnchorCompare/1.0'; status = 'failed'; error = $_.Exception.Message } | ConvertTo-Json | Write-Output
    } else {
        Write-Host ("配准比对失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("  行: {0}" -f $_.InvocationInfo.ScriptLineNumber)
        Write-Host $_.ScriptStackTrace
    }
    exit 1
}

