#Requires -Version 5.1
<#
.SYNOPSIS
    PDF 矢量路径解析与 DXF 写出（纯 PowerShell，无第三方依赖）。

.DESCRIPTION
    把一份矢量 PDF 里的绘图路径（m/l/c/v/y/re/h 六种构造符 + S/s/f/F/f*/B/B*/b/b*/n 九种
    绘制符）解出来，套上完整的 CTM 变换栈（q/Q 压栈出栈 + cm 矩阵），展平三次贝塞尔，
    最后写成 DXF。

    这不是「PDF 转 CAD」的完整方案，它只做一件事：把矢量线稿搬进 CAD。
    文字（Tj/TJ）、位图（Do + 内联图像）、渐变、裁剪路径都不转换 —— 不在能力范围内的
    内容会在报告里明确列出，绝不假装转换成功。

    为什么不用 Python / PyMuPDF / ezdxf：
      1. 这台机器没有真实 Python（Store 占位存根，exit 9009）。
      2. 纯 PowerShell 足够：FlateDecode 就是 zlib，DeflateStream 跳过 2 字节头即可解；
         PDF 内容流是前缀记号语言，写个词法器就能读。
      3. 零依赖是这个 skill 的底线（对标 keil5-automatic-wwj）。

    坐标系（最容易搞错的地方，务必读）：
      PDF 内容流的坐标原点在左下角、y 轴向上 —— 与 DXF 模型空间一致，**不需要翻转 y**。
      这一点和「用 PyMuPDF 的 get_drawings()」不同：fitz 报告的坐标原点在左上、y 向下，
      所以 pengxiaoan 的 pdf_vector_to_dxf.py 里有 (page_height - p.y) 的翻转。
      本实现直接解析原始内容流，因此没有翻转这一步。如果以后改成基于渲染库的实现，
      必须记得加翻转。

.PARAMETER Path
    PDF 文件路径。

.PARAMETER Output
    输出 DXF 路径。留空则不写文件，只解析。

.PARAMETER Page
    要转换的页码（从 1 开始）。默认 1。

.PARAMETER Scale
    额外缩放系数。PDF 单位是「点」（1/72 英寸），默认 1 表示保持点为单位。
    想让输出以毫米为单位时传 25.4/72 = 0.352778。

.PARAMETER Layer
    线稿所在图层名，默认 PDF_STROKE。

.PARAMETER BezierSegments
    三次贝塞尔展平成折线的段数，默认 8。段数越多越平滑、实体越多。

.PARAMETER IncludeFill
    连填充路径的轮廓也一起导出。默认只导描边路径，因为填充轮廓在 CAD 里往往是
    多余的闭合框，会把图面塞满。

.PARAMETER AsJson
    以 JSON 输出报告。

.EXAMPLE
    .\Convert-CadPdfToDxf.ps1 -Path plan.pdf -Output plan.dxf -AsJson

.EXAMPLE
    # 以毫米为单位、贝塞尔更平滑
    .\Convert-CadPdfToDxf.ps1 -Path plan.pdf -Output plan.dxf -Scale 0.352778 -BezierSegments 16

.NOTES
    本文件是**库**，不是脚本：它没有任何顶层 param 块，只定义函数。
    唯一的入口函数是 Convert-CadPdfToDxf，CLI 包装在 Convert-CadPdfToDxf.ps1。

    为什么必须去掉顶层 param：库里一旦有 [CmdletBinding()] param(...)，
    dot-source 时 PowerShell 会按强制参数规则绑定 —— Mandatory 的 Path 缺省，
    于是整个 . CadPdf.ps1 直接抛「缺少必需参数 Path」，看起来像调用方的错，
    实际是库文件本身的写法问题。这个坑排查了很久，写在这里免得复犯。
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════
#  一、PDF 词法器与内容流解析
# ═══════════════════════════════════════════════════════════════════════════

# PDF 空白字符：NUL, TAB, LF, FF, CR, SPACE
function Test-CadPdfWhitespace {
    param([char]$Ch)
    return ($Ch -eq ' ' -or $Ch -eq "`t" -or $Ch -eq "`n" -or $Ch -eq "`r" -or $Ch -eq "`f" -or [int]$Ch -eq 0)
}

function Test-CadPdfDelimiter {
    param([char]$Ch)
    return ('()<>[]{}/%'.IndexOf($Ch) -ge 0)
}

# 把内容流拆成记号序列：数字、名字、字符串、数组、字典、操作符。
# 不需要完整的 PDF 语法 —— 内容流里出现的只是这几种东西。
function ConvertTo-CadPdfTokens {
    param([string]$Text)

    $tokens = New-Object System.Collections.Generic.List[object]
    $i = 0
    $n = $Text.Length
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    while ($i -lt $n) {
        $ch = $Text[$i]

        # 空白
        if (Test-CadPdfWhitespace $ch) { $i++; continue }

        # 注释：% 到行尾
        if ($ch -eq '%') {
            while ($i -lt $n -and $Text[$i] -ne "`n" -and $Text[$i] -ne "`r") { $i++ }
            continue
        }

        # 内联图像 BI ... ID <二进制> EI —— 必须整体跳过，否则二进制会被当记号
        if ($ch -eq 'B' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq 'I' -and
            (($i + 2) -ge $n -or (Test-CadPdfWhitespace $Text[$i + 2]))) {
            $idIdx = $Text.IndexOf('ID', $i, [StringComparison]::Ordinal)
            if ($idIdx -lt 0) { break }
            $eiIdx = $Text.IndexOf('EI', $idIdx + 2, [StringComparison]::Ordinal)
            if ($eiIdx -lt 0) { break }
            $i = $eiIdx + 2
            continue
        }

        # 名字 /Name
        if ($ch -eq '/') {
            $j = $i + 1
            while ($j -lt $n -and -not (Test-CadPdfWhitespace $Text[$j]) -and -not (Test-CadPdfDelimiter $Text[$j])) { $j++ }
            $tokens.Add([pscustomobject]@{ kind = 'name'; value = $Text.Substring($i + 1, $j - $i - 1) })
            $i = $j
            continue
        }

        # 字面字符串 (...) —— 只跳过，内容不解析（本工具不转换文字）
        if ($ch -eq '(') {
            $depth = 1
            $j = $i + 1
            while ($j -lt $n -and $depth -gt 0) {
                $c = $Text[$j]
                if ($c -eq '\') { $j += 2; continue }
                if ($c -eq '(') { $depth++ }
                elseif ($c -eq ')') { $depth-- }
                $j++
            }
            $tokens.Add([pscustomobject]@{ kind = 'string'; value = '' })
            $i = $j
            continue
        }

        # 十六进制字符串 <...>
        if ($ch -eq '<' -and ($i + 1) -lt $n -and $Text[$i + 1] -ne '<') {
            $j = $Text.IndexOf('>', $i)
            if ($j -lt 0) { break }
            $tokens.Add([pscustomobject]@{ kind = 'string'; value = '' })
            $i = $j + 1
            continue
        }

        # 字典 << 与数组 [ 都不影响路径解析，直接跳过括号本身
        if ($ch -eq '<' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '<') { $i += 2; continue }
        if ($ch -eq '>' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '>') { $i += 2; continue }
        if ($ch -eq '[' -or $ch -eq ']' -or $ch -eq '{' -or $ch -eq '}') { $i++; continue }

        # 数字（含 PDF 的 +.5 / -.5 / 1. 这类怪写法）
        if (($ch -ge '0' -and $ch -le '9') -or $ch -eq '+' -or $ch -eq '-' -or $ch -eq '.') {
            $j = $i
            while ($j -lt $n -and (($Text[$j] -ge '0' -and $Text[$j] -le '9') -or
                    $Text[$j] -eq '+' -or $Text[$j] -eq '-' -or $Text[$j] -eq '.' -or
                    $Text[$j] -eq 'e' -or $Text[$j] -eq 'E')) { $j++ }
            $raw = $Text.Substring($i, $j - $i)
            $d = 0.0
            if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
                $tokens.Add([pscustomobject]@{ kind = 'num'; value = $d })
            }
            $i = $j
            continue
        }

        # 操作符
        $j = $i
        while ($j -lt $n -and -not (Test-CadPdfWhitespace $Text[$j]) -and -not (Test-CadPdfDelimiter $Text[$j])) { $j++ }
        if ($j -eq $i) { $i++; continue }
        $op = $Text.Substring($i, $j - $i)
        $tokens.Add([pscustomobject]@{ kind = 'op'; value = $op })
        $i = $j
    }

    return $tokens
}

# 矩阵按 PDF 规范是 [a b c d e f]，表示
#   x' = a*x + c*y + e
#   y' = b*x + d*y + f
function New-CadPdfMatrix {
    return @(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
}

function Multiply-CadPdfMatrix {
    param([double[]]$M1, [double[]]$M2)
    # m1 × m2（先 m1 后 m2 的复合）
    return @(
        ($M1[0] * $M2[0] + $M1[1] * $M2[2]),
        ($M1[0] * $M2[1] + $M1[1] * $M2[3]),
        ($M1[2] * $M2[0] + $M1[3] * $M2[2]),
        ($M1[2] * $M2[1] + $M1[3] * $M2[3]),
        ($M1[4] * $M2[0] + $M1[5] * $M2[2] + $M2[4]),
        ($M1[4] * $M2[1] + $M1[5] * $M2[3] + $M2[5])
    )
}

function Convert-CadPdfPoint {
    param([double[]]$M, [double]$X, [double]$Y)
    return @(
        ($M[0] * $X + $M[2] * $Y + $M[4]),
        ($M[1] * $X + $M[3] * $Y + $M[5])
    )
}

# 三次贝塞尔展平。控制点 p0 p1 p2 p3，返回中间采样点（不含 p0）。
function Get-CadPdfBezierPoints {
    param([double[]]$P0, [double[]]$P1, [double[]]$P2, [double[]]$P3, [int]$Segments)
    $out = New-Object System.Collections.Generic.List[object]
    if ($Segments -lt 1) { $Segments = 1 }
    for ($k = 1; $k -le $Segments; $k++) {
        $t = $k / [double]$Segments
        $u = 1.0 - $t
        $a = $u * $u * $u
        $b = 3.0 * $u * $u * $t
        $c = 3.0 * $u * $t * $t
        $d = $t * $t * $t
        $out.Add(@(
                ($a * $P0[0] + $b * $P1[0] + $c * $P2[0] + $d * $P3[0]),
                ($a * $P0[1] + $b * $P1[1] + $c * $P2[1] + $d * $P3[1])
            ))
    }
    return $out.ToArray()
}

# 解析内容流，返回路径列表。每条路径 = { points = [[x,y],...], closed = bool, painted = 'stroke'|'fill'|'stroke+fill'|'clip' }
function ConvertFrom-CadPdfContent {
    param(
        [string]$Text,
        [int]$BezierSegments = 8,
        [double]$Scale = 1.0,
        [double]$MinSegmentLength = 0.01
    )

    $tokens = ConvertTo-CadPdfTokens -Text $Text
    $paths = New-Object System.Collections.Generic.List[object]

    # 图形状态栈
    $ctm = New-CadPdfMatrix
    $stack = New-Object System.Collections.Generic.List[object]
    $stack.Add([pscustomobject]@{ ctm = $ctm; lineWidth = 1.0 })

    # 当前路径
    $cur = $null          # 当前子路径的点列
    $subpaths = New-Object System.Collections.Generic.List[object]
    $curPt = @(0.0, 0.0)
    $startPt = @(0.0, 0.0)
    $hasPath = $false

    $nums = New-Object System.Collections.Generic.List[double]
    $opCounts = @{}

    foreach ($tok in $tokens) {
        if ($tok.kind -eq 'num') { $nums.Add([double]$tok.value); continue }
        if ($tok.kind -ne 'op') { continue }

        $op = [string]$tok.value
        if (-not $opCounts.ContainsKey($op)) { $opCounts[$op] = 0 }
        $opCounts[$op]++

        # ★ 必须 -CaseSensitive ★
        # PowerShell 的 switch 默认不区分大小写，PDF 里 q / Q 是一对意义相反的操作符
        # （保存 / 恢复图形状态）。不加 -CaseSensitive 时，'q' 会同时命中 'q' 和 'Q'
        # 两个分支：先把 CTM 压栈、紧接着又弹出恢复成单位矩阵，于是 cm 设置的
        # 变换被静默清掉 —— 表现是坐标全部原样透传、缩放过小、位置偏移，
        # 但没有任何报错。同理 S/s、f/F、B/b 也全部会互串。
        switch -CaseSensitive ($op) {
            'q' {
                $stack.Add([pscustomobject]@{ ctm = $ctm.Clone(); lineWidth = 1.0 })
            }
            'Q' {
                if ($stack.Count -gt 1) {
                    $stack.RemoveAt($stack.Count - 1)
                    $ctm = [double[]]$stack[$stack.Count - 1].ctm.Clone()
                }
            }
            'cm' {
                if ($nums.Count -ge 6) {
                    $m = @($nums[$nums.Count - 6], $nums[$nums.Count - 5], $nums[$nums.Count - 4],
                        $nums[$nums.Count - 3], $nums[$nums.Count - 2], $nums[$nums.Count - 1])
                    $ctm = Multiply-CadPdfMatrix -M1 $m -M2 $ctm
                }
            }
            'w' { }
            'm' {
                if ($nums.Count -ge 2) {
                    # 之前若有未结束的子路径，先收起来
                    if ($null -ne $cur -and $cur.Count -ge 2) { $subpaths.Add($cur) }
                    $curPt = Convert-CadPdfPoint -M $ctm -X $nums[$nums.Count - 2] -Y $nums[$nums.Count - 1]
                    $startPt = $curPt
                    $cur = New-Object System.Collections.Generic.List[object]
                    $cur.Add($curPt)
                    $hasPath = $true
                }
            }
            'l' {
                if ($nums.Count -ge 2) {
                    $p = Convert-CadPdfPoint -M $ctm -X $nums[$nums.Count - 2] -Y $nums[$nums.Count - 1]
                    if ($null -eq $cur) { $cur = New-Object System.Collections.Generic.List[object]; $cur.Add($curPt) }
                    $cur.Add($p)
                    $curPt = $p
                    $hasPath = $true
                }
            }
            'c' {
                if ($nums.Count -ge 6) {
                    $k = $nums.Count
                    $p1 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 6] -Y $nums[$k - 5]
                    $p2 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 4] -Y $nums[$k - 3]
                    $p3 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 2] -Y $nums[$k - 1]
                    if ($null -eq $cur) { $cur = New-Object System.Collections.Generic.List[object]; $cur.Add($curPt) }
                    foreach ($bp in (Get-CadPdfBezierPoints -P0 $curPt -P1 $p1 -P2 $p2 -P3 $p3 -Segments $BezierSegments)) {
                        $cur.Add($bp)
                    }
                    $curPt = $p3
                    $hasPath = $true
                }
            }
            'v' {
                if ($nums.Count -ge 4) {
                    $k = $nums.Count
                    $p2 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 4] -Y $nums[$k - 3]
                    $p3 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 2] -Y $nums[$k - 1]
                    if ($null -eq $cur) { $cur = New-Object System.Collections.Generic.List[object]; $cur.Add($curPt) }
                    foreach ($bp in (Get-CadPdfBezierPoints -P0 $curPt -P1 $curPt -P2 $p2 -P3 $p3 -Segments $BezierSegments)) {
                        $cur.Add($bp)
                    }
                    $curPt = $p3
                    $hasPath = $true
                }
            }
            'y' {
                if ($nums.Count -ge 4) {
                    $k = $nums.Count
                    $p1 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 4] -Y $nums[$k - 3]
                    $p3 = Convert-CadPdfPoint -M $ctm -X $nums[$k - 2] -Y $nums[$k - 1]
                    if ($null -eq $cur) { $cur = New-Object System.Collections.Generic.List[object]; $cur.Add($curPt) }
                    foreach ($bp in (Get-CadPdfBezierPoints -P0 $curPt -P1 $p1 -P2 $p3 -P3 $p3 -Segments $BezierSegments)) {
                        $cur.Add($bp)
                    }
                    $curPt = $p3
                    $hasPath = $true
                }
            }
            're' {
                if ($nums.Count -ge 4) {
                    $k = $nums.Count
                    $x = $nums[$k - 4]; $y = $nums[$k - 3]
                    $w = $nums[$k - 2]; $h = $nums[$k - 1]
                    if ($null -ne $cur -and $cur.Count -ge 2) { $subpaths.Add($cur) }
                    $rect = New-Object System.Collections.Generic.List[object]
                    $rect.Add((Convert-CadPdfPoint -M $ctm -X $x -Y $y))
                    $rect.Add((Convert-CadPdfPoint -M $ctm -X ($x + $w) -Y $y))
                    $rect.Add((Convert-CadPdfPoint -M $ctm -X ($x + $w) -Y ($y + $h)))
                    $rect.Add((Convert-CadPdfPoint -M $ctm -X $x -Y ($y + $h)))
                    $rect.Add((Convert-CadPdfPoint -M $ctm -X $x -Y $y))
                    $subpaths.Add($rect)
                    $cur = $null
                    $curPt = @($x, $y)
                    $startPt = $curPt
                    $hasPath = $true
                }
            }
            'h' {
                if ($null -ne $cur -and $cur.Count -ge 2) {
                    $cur.Add($startPt)
                    $subpaths.Add($cur)
                    $cur = $null
                }
                $curPt = $startPt
            }
            { $_ -in 'S', 's', 'f', 'F', 'f*', 'B', 'B*', 'b', 'b*', 'n' } {
                if ($null -ne $cur -and $cur.Count -ge 2) { $subpaths.Add($cur) }
                $cur = $null

                $painted = 'stroke'
                if ($op -in 'f', 'F', 'f*') { $painted = 'fill' }
                elseif ($op -in 'B', 'B*', 'b', 'b*') { $painted = 'stroke+fill' }
                elseif ($op -eq 'n') { $painted = 'clip' }

                if ($hasPath) {
                    foreach ($sp in $subpaths) {
                        # 去掉连续重复点（PDF 里 h 之后常跟一个回到起点的 l）
                        $pts = New-Object System.Collections.Generic.List[object]
                        foreach ($pt in $sp) {
                            if ($pts.Count -eq 0) { $pts.Add($pt); continue }
                            $last = $pts[$pts.Count - 1]
                            $dx = [double]$pt[0] - [double]$last[0]
                            $dy = [double]$pt[1] - [double]$last[1]
                            if ([math]::Sqrt($dx * $dx + $dy * $dy) -ge $MinSegmentLength) { $pts.Add($pt) }
                        }
                        if ($pts.Count -ge 2) {
                            $closed = ($pts.Count -ge 3 -and
                                [math]::Abs([double]$pts[0][0] - [double]$pts[$pts.Count - 1][0]) -lt $MinSegmentLength -and
                                [math]::Abs([double]$pts[0][1] - [double]$pts[$pts.Count - 1][1]) -lt $MinSegmentLength)
                            $paths.Add([pscustomobject]@{
                                    points  = $pts.ToArray()
                                    closed  = $closed
                                    painted = $painted
                                })
                        }
                    }
                }
                $subpaths = New-Object System.Collections.Generic.List[object]
                $hasPath = $false
            }
        }

        $nums.Clear()
    }

    # ★ 必须 .ToArray()：PowerShell 7.6.7 里 @() 包 List[object] 会抛
    #   「Argument types do not match」（List[int] / ArrayList / 普通数组都不受影响）。
    #   调用方一律对返回值用 @() 或 .Count，所以这里直接给数组最安全。
    return [pscustomobject]@{
        paths     = $paths.ToArray()
        operators = $opCounts
        tokens    = $tokens.Count
    }
}

# ═══════════════════════════════════════════════════════════════════════════
#  二、PDF 文件层：找流、解压、认页
# ═══════════════════════════════════════════════════════════════════════════

function Expand-CadPdfFlate {
    param([byte[]]$Bytes)
    # zlib 头两字节（0x78 0x9C 之类）不属于 deflate 数据流，DeflateStream 要跳过
    if ($Bytes.Length -le 2) { return [byte[]]@() }
    $offset = 0
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x78) { $offset = 2 }
    try {
        $ms = New-Object System.IO.MemoryStream(,$Bytes)
        $ms.Position = $offset
        $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $out = New-Object System.IO.MemoryStream
        $ds.CopyTo($out)
        $ds.Dispose(); $ms.Dispose()
        return $out.ToArray()
    }
    catch {
        return [byte[]]@()
    }
}

function Expand-CadPdfAsciiHex {
    param([byte[]]$Bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) {
        $c = [char]$b
        if ($c -eq '>') { break }
        if (($c -ge '0' -and $c -le '9') -or ($c -ge 'A' -and $c -le 'F') -or ($c -ge 'a' -and $c -le 'f')) { [void]$sb.Append($c) }
    }
    $hex = $sb.ToString()
    if ($hex.Length % 2 -eq 1) { $hex += '0' }
    $out = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $out.Length; $i++) {
        $out[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }
    return $out
}

# 把整个 PDF 按字节扫一遍，找出所有 "stream ... endstream" 段及其紧邻的字典文本。
# 不解析 xref、不解析对象树 —— 够用，且不会被压缩对象流骗到。
function Get-CadPdfStreams {
    param([byte[]]$Bytes, [int]$MaxStreams = 4096)

    $latin = [System.Text.Encoding]::GetEncoding(28591)   # ISO-8859-1，逐字节一一对应
    $text = $latin.GetString($Bytes)
    $streams = New-Object System.Collections.Generic.List[object]
    $pos = 0
    $idx = 0
    $len = $text.Length

    while ($pos -lt $len -and $streams.Count -lt $MaxStreams) {
        $s = $text.IndexOf('stream', $pos, [StringComparison]::Ordinal)
        if ($s -lt 0) { break }

        # "endstream" 里也含 "stream"，要排除
        if ($s -ge 3 -and $text.Substring($s - 3, 3) -eq 'end') { $pos = $s + 6; continue }

        # 数据起点：stream 后必须跟 CRLF 或 LF
        $dataStart = $s + 6
        if ($dataStart -lt $len -and $text[$dataStart] -eq "`r") { $dataStart++ }
        if ($dataStart -lt $len -and $text[$dataStart] -eq "`n") { $dataStart++ }

        $e = $text.IndexOf('endstream', $dataStart, [StringComparison]::Ordinal)
        if ($e -lt 0) { break }

        # 字典：往前找 200 字节看有没有 Filter
        $dictStart = [math]::Max(0, $s - 1200)
        $dictText = $text.Substring($dictStart, $s - $dictStart)

        $dataLen = $e - $dataStart
        if ($dataLen -gt 0) {
            $raw = New-Object byte[] $dataLen
            [Array]::Copy($Bytes, $dataStart, $raw, 0, $dataLen)

            $filter = ''
            $fm = [regex]::Match($dictText, '/Filter\s*(?:\[\s*)?/(\w+)')
            if ($fm.Success) { $filter = $fm.Groups[1].Value }

            $expanded = $null
            switch ($filter) {
                'FlateDecode' { $expanded = Expand-CadPdfFlate -Bytes $raw }
                'ASCIIHexDecode' { $expanded = Expand-CadPdfAsciiHex -Bytes $raw }
                'ASCII85Decode' { $expanded = $null }
                'LZWDecode' { $expanded = $null }
                '' { $expanded = $raw }
                default { $expanded = $null }
            }

            $streams.Add([pscustomobject]@{
                    index      = $idx
                    offset     = $dataStart
                    length     = $dataLen
                    filter     = $filter
                    data       = $expanded
                    expandedLt = $(if ($null -ne $expanded) { $expanded.Length } else { 0 })
                })
            $idx++
        }

        $pos = $e + 9
    }

    return $streams
}

# 判断一段解压后的字节像不像内容流：含绘图操作符才认。
function Test-CadPdfContentStream {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 16) { return $false }
    # 内容流是纯 ASCII 操作符 + 数字，二进制流里会有大量非文本字节
    $sample = [math]::Min($Bytes.Length, 8192)
    $binary = 0
    for ($i = 0; $i -lt $sample; $i++) {
        $b = $Bytes[$i]
        if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32) -or $b -gt 126) { $binary++ }
    }
    if (($binary / [double]$sample) -gt 0.10) { return $false }

    $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes, 0, $sample)
    # 至少要出现一次路径绘制符
    return ($txt -match '(?m)(^|\s)(m|l|c|re|S|f)\s')
}

function Get-CadPdfInfo {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "PDF 文件不存在: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 100) { throw "文件太小，不像 PDF: $Path" }

    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [math]::Min(16, $bytes.Length))
    $version = ''
    $vm = [regex]::Match($head, '%PDF-(\d+\.\d+)')
    if ($vm.Success) { $version = $vm.Groups[1].Value }

    $latin = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin.GetString($bytes)

    $pageCount = 0
    $pm = [regex]::Matches($text, '/Type\s*/Page[^s]')
    $pageCount = $pm.Count

    $mediaBox = @()
    $mb = [regex]::Match($text, '/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]')
    if ($mb.Success) {
        $mediaBox = @([double]$mb.Groups[1].Value, [double]$mb.Groups[2].Value,
            [double]$mb.Groups[3].Value, [double]$mb.Groups[4].Value)
    }

    $streams = @(Get-CadPdfStreams -Bytes $bytes)
    $filters = @{}
    foreach ($st in $streams) {
        $k = if ($st.filter) { $st.filter } else { '(none)' }
        if (-not $filters.ContainsKey($k)) { $filters[$k] = 0 }
        $filters[$k]++
    }

    # ★ $streams / $contentStreams 必须是数组 ★
    # 一个流都没有的 PDF（纯文本假 PDF、扫描件的索引页）会让
    # Get-CadPdfStreams 返回 $null，而 $null.Count 会抛
    # 「在此对象上找不到属性 Count」—— 报错位置指向本函数的 return，
    # 完全看不出是上面 $streams 为空。两个都先 @(...) 包一层，
    # 下游的 streamCount / contentStreams 才能安心用 .Count。
    $contentStreams = @()
    foreach ($st in $streams) {
        if ($null -ne $st.data -and (Test-CadPdfContentStream -Bytes $st.data)) { $contentStreams += $st }
    }

    return [pscustomobject]@{
        path            = (Resolve-Path -LiteralPath $Path).Path
        bytes           = $bytes.Length
        version         = $version
        pageCount       = $pageCount
        mediaBox        = $mediaBox
        streamCount     = $streams.Count
        contentStreams  = $contentStreams
        filters         = $filters
        hasText         = ($text -match '(?m)(^|\s)(Tj|TJ|Tf)\s')
        hasImage        = ($text -match '/Subtype\s*/Image')
        hasXObject      = ($text -match '(?m)(^|\s)Do\s')
        hasShading      = ($text -match '(?m)(^|\s)sh\s')
    }
}

# ═══════════════════════════════════════════════════════════════════════════
#  三、DXF 写出（R12 格式，LINE + POLYLINE，兼容一切 CAD）
# ═══════════════════════════════════════════════════════════════════════════

function Format-CadDxfNum {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return '0.0' }
    return $Value.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-CadDxfText {
    param([System.Text.StringBuilder]$Sb, [int]$Code, [string]$Value)
    [void]$Sb.Append($Code).Append("`r`n").Append($Value).Append("`r`n")
}

# 写一份最小但结构完整的 R12 DXF。AutoCAD / QCAD / LibreCAD / ezdxf 都能直接打开。
function Write-CadDxfFile {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][object[]]$Paths,
        [string]$Layer = 'PDF_STROKE',
        [double]$Scale = 1.0,
        [switch]$AsPolyline
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    # 统一缩放并算范围
    $minX = [double]::MaxValue; $minY = [double]::MaxValue
    $maxX = [double]::MinValue; $maxY = [double]::MinValue
    $scaled = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Paths) {
        $pts = New-Object System.Collections.Generic.List[object]
        foreach ($pt in $p.points) {
            $x = [double]$pt[0] * $Scale
            $y = [double]$pt[1] * $Scale
            $pts.Add(@($x, $y))
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
        if ($pts.Count -ge 2) {
            $scaled.Add([pscustomobject]@{ points = $pts; closed = [bool]$p.closed })
        }
    }
    if ($scaled.Count -eq 0) { $minX = 0; $minY = 0; $maxX = 0; $maxY = 0 }
    $scaledArr = $scaled.ToArray()

    $sb = New-Object System.Text.StringBuilder

    # ── HEADER ──
    New-CadDxfText $sb 0 'SECTION'
    New-CadDxfText $sb 2 'HEADER'
    New-CadDxfText $sb 9 '$ACADVER'
    New-CadDxfText $sb 1 'AC1009'
    New-CadDxfText $sb 9 '$INSUNITS'
    New-CadDxfText $sb 70 '0'
    New-CadDxfText $sb 9 '$EXTMIN'
    New-CadDxfText $sb 10 (Format-CadDxfNum $minX)
    New-CadDxfText $sb 20 (Format-CadDxfNum $minY)
    New-CadDxfText $sb 30 '0.0'
    New-CadDxfText $sb 9 '$EXTMAX'
    New-CadDxfText $sb 10 (Format-CadDxfNum $maxX)
    New-CadDxfText $sb 20 (Format-CadDxfNum $maxY)
    New-CadDxfText $sb 30 '0.0'
    New-CadDxfText $sb 0 'ENDSEC'

    # ── TABLES ──
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
    New-CadDxfText $sb 70 '2'
    New-CadDxfText $sb 0 'LAYER'
    New-CadDxfText $sb 2 '0'
    New-CadDxfText $sb 70 '0'
    New-CadDxfText $sb 62 '7'
    New-CadDxfText $sb 6 'CONTINUOUS'
    New-CadDxfText $sb 0 'LAYER'
    New-CadDxfText $sb 2 $Layer
    New-CadDxfText $sb 70 '0'
    New-CadDxfText $sb 62 '7'
    New-CadDxfText $sb 6 'CONTINUOUS'
    New-CadDxfText $sb 0 'ENDTAB'

    New-CadDxfText $sb 0 'ENDSEC'

    # ── ENTITIES ──
    New-CadDxfText $sb 0 'SECTION'
    New-CadDxfText $sb 2 'ENTITIES'

    foreach ($p in $scaled) {
        $pts = $p.points
        $isLine = ($pts.Count -eq 2)

        if ($isLine -and -not $AsPolyline) {
            New-CadDxfText $sb 0 'LINE'
            New-CadDxfText $sb 8 $Layer
            New-CadDxfText $sb 10 (Format-CadDxfNum $pts[0][0])
            New-CadDxfText $sb 20 (Format-CadDxfNum $pts[0][1])
            New-CadDxfText $sb 30 '0.0'
            New-CadDxfText $sb 11 (Format-CadDxfNum $pts[1][0])
            New-CadDxfText $sb 21 (Format-CadDxfNum $pts[1][1])
            New-CadDxfText $sb 31 '0.0'
        }
        else {
            # R12 老式 POLYLINE：66=1 表示后跟 VERTEX 序列，70 的 bit0 = 闭合
            $flags = if ($p.closed) { 1 } else { 0 }
            New-CadDxfText $sb 0 'POLYLINE'
            New-CadDxfText $sb 8 $Layer
            New-CadDxfText $sb 66 '1'
            New-CadDxfText $sb 70 $flags
            New-CadDxfText $sb 10 '0.0'
            New-CadDxfText $sb 20 '0.0'
            New-CadDxfText $sb 30 '0.0'
            foreach ($pt in $pts) {
                New-CadDxfText $sb 0 'VERTEX'
                New-CadDxfText $sb 8 $Layer
                New-CadDxfText $sb 10 (Format-CadDxfNum $pt[0])
                New-CadDxfText $sb 20 (Format-CadDxfNum $pt[1])
                New-CadDxfText $sb 30 '0.0'
            }
            New-CadDxfText $sb 0 'SEQEND'
            New-CadDxfText $sb 8 $Layer
        }
    }

    New-CadDxfText $sb 0 'ENDSEC'
    New-CadDxfText $sb 0 'EOF'

    $text = $sb.ToString()
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Output
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Output, $text, $enc)

    return [pscustomobject]@{
        output   = $Output
        bytes    = (Get-Item -LiteralPath $Output).Length
        entities = $scaled.Count
        extents  = [pscustomobject]@{ minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
#  四、总入口
# ═══════════════════════════════════════════════════════════════════════════

function Convert-CadPdfToDxf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Output,
        [int]$Page = 1,
        [double]$Scale = 1.0,
        [string]$Layer = 'PDF_STROKE',
        [int]$BezierSegments = 8,
        [switch]$IncludeFill
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $warnings = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[object]

    $info = Get-CadPdfInfo -Path $Path
    if (-not $info.version) { throw "不是有效的 PDF（找不到 %PDF- 头）: $Path" }

    $evidence.Add((New-CadEvidence -Kind 'pdf-version' -Level 'known' `
                -Message "PDF 版本 $($info.version)，$($info.pageCount) 页，$($info.streamCount) 个流" `
                -Value $info.version -Source $info.path))

    if ($Page -lt 1 -or ($info.pageCount -gt 0 -and $Page -gt $info.pageCount)) {
        throw "页码 $Page 超出范围（该 PDF 有 $($info.pageCount) 页）"
    }

    # 多页 PDF 的内容流顺序一般与页序一致；本工具按「第 N 个内容流」取第 N 页。
    # 这是启发式，不是 PDF 规范保证 —— 报告里如实说明。
    $target = $null
    if ($info.contentStreams.Count -ge $Page) {
        $target = $info.contentStreams[$Page - 1]
    }
    elseif ($info.contentStreams.Count -ge 1) {
        $target = $info.contentStreams[0]
        if ($info.contentStreams.Count -gt 1) {
            $warnings.Add("要求第 $Page 页，但只识别到 $($info.contentStreams.Count) 个内容流；已改用第 1 个")
        }
    }

    if ($null -eq $target) {
        throw "PDF 里没找到可解析的矢量内容流。这份 PDF 可能是扫描件（纯位图），需要先 OCR/矢量化，本工具不处理。"
    }

    if ($info.contentStreams.Count -gt 1) {
        $warnings.Add("检测到 $($info.contentStreams.Count) 个候选内容流，按出现顺序取第 $Page 个；多页 PDF 的页流顺序是启发式判断，不保证与页号严格对应")
    }

    $contentText = [System.Text.Encoding]::GetEncoding(28591).GetString($target.data)
    $parsed = ConvertFrom-CadPdfContent -Text $contentText -BezierSegments $BezierSegments -Scale $Scale

    $allPaths = @($parsed.paths)
    if ($allPaths.Count -eq 1 -and $null -eq $allPaths[0]) { $allPaths = @() }
    $strokePaths = @($allPaths | Where-Object { $_.painted -eq 'stroke' -or $_.painted -eq 'stroke+fill' })
    $fillPaths = @($allPaths | Where-Object { $_.painted -eq 'fill' })

    $usePaths = if ($IncludeFill) { $allPaths } else { $strokePaths }

    if (-not $IncludeFill -and $fillPaths.Count -gt 0) {
        $warnings.Add("跳过 $($fillPaths.Count) 条纯填充路径（加 -IncludeFill 可一并导出）")
    }

    $unsupported = New-Object System.Collections.Generic.List[string]
    if ($info.hasText) { $unsupported.Add('文字（Tj/TJ）') }
    if ($info.hasImage) { $unsupported.Add('嵌入位图（/Image XObject）') }
    if ($info.hasXObject) { $unsupported.Add('XObject 引用（Do）') }
    if ($info.hasShading) { $unsupported.Add('渐变着色（sh）') }
    if ($parsed.operators.ContainsKey('W') -or $parsed.operators.ContainsKey('W*')) { $unsupported.Add('裁剪路径（W/W*）') }

    if ($unsupported.Count -gt 0) {
        $warnings.Add("以下内容未转换（不在矢量线稿范围内）：" + ($unsupported -join '、'))
    }

    if ($usePaths.Count -eq 0) {
        $warnings.Add('这个内容流里没有可导出的路径；可能是空白页、纯文字页，或路径全在 XObject 里')
    }

    $evidence.Add((New-CadEvidence -Kind 'pdf-paths' -Level 'scaled' `
                -Message "解出 $($allPaths.Count) 条路径（描边 $($strokePaths.Count) / 填充 $($fillPaths.Count)），导出 $($usePaths.Count) 条" `
                -Value $usePaths.Count -Source $info.path))

    $result = [ordered]@{
        status          = 'ok'
        source          = $info.path
        output          = $null
        page            = $Page
        pageCount       = $info.pageCount
        pdfVersion      = $info.version
        streamCount     = $info.streamCount
        streamFilter    = $target.filter
        streamBytes     = $target.length
        expandedBytes   = $target.expandedLt
        tokens          = $parsed.tokens
        pathCount       = $allPaths.Count
        strokePaths     = $strokePaths.Count
        fillPaths       = $fillPaths.Count
        exportedPaths   = $usePaths.Count
        entities        = 0
        scale           = $Scale
        bezierSegments  = $BezierSegments
        layer           = $Layer
        mediaBox        = $info.mediaBox
        extents         = $null
        bytes           = 0
        unsupported     = $unsupported.ToArray()
        evidence        = $evidence.ToArray()
        warnings        = $warnings.ToArray()
        error           = $null
        durationMs      = 0
    }

    if ($Output) {
        $dxf = Write-CadDxfFile -Output $Output -Paths $usePaths -Layer $Layer -Scale $Scale
        $result.output = $dxf.output
        $result.entities = $dxf.entities
        $result.extents = $dxf.extents
        $result.bytes = $dxf.bytes
        $evidence.Add((New-CadEvidence -Kind 'dxf-written' -Level 'known' `
                    -Message "写出 DXF：$($dxf.entities) 个实体 / $([math]::Round($dxf.bytes / 1KB, 1)) KB" `
                    -Value $dxf.bytes -Source $dxf.output))
    }
    else {
        $result.status = 'parsed'
        $warnings.Add('没有指定 -Output，只解析未写文件')
    }

    if ($usePaths.Count -eq 0) { $result.status = 'empty' }

    $sw.Stop()
    $result.durationMs = [int]$sw.ElapsedMilliseconds
    $result.evidence = $evidence.ToArray()
    $result.warnings = $warnings.ToArray()
    return [pscustomobject]$result
}
