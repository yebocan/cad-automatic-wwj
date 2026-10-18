<#
    CadCompiler.ps1 — 把 JSON 图纸描述编译成 LISP 代码
    ────────────────────────────────────────────────────────────────
    这是本 skill 的核心：AI 只需要产出 JSON，编译器负责生成可靠的 LISP。

    为什么不让 AI 直接写 LISP：
      · LISP 里一个括号错，整个脚本静默失败，accoreconsole 只报 "语法错误"
      · 命令行顺序（先点后尺寸、先 _C 后半径）很容易记错
      · JSON 可以被 schema 校验，LISP 不能

    JSON 结构（全部字段见 references/spec.md）：
      {
        "name": "demo",
        "units": "mm",
        "layers": [ {"name":"GEO","color":3,"ltype":"CONTINUOUS"} ],
        "blocks": [ {"name":"BOLT","base":[0,0],"entities":[...]} ],
        "entities": [ {"type":"line","layer":"GEO","p1":[0,0],"p2":[100,0]} ],
        "save": {"dwg":"out.dwg","dxf":true,"pdf":null,"version":"2018"}
      }
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════
#  安全字段访问
# ══════════════════════════════════════════════════════════════════
#  JSON 里可选字段经常整个不存在。StrictMode 下直接点号访问会抛
#  「找不到属性」——那不是用户想看到的错误，所以统一走这里。

function Get-CadField {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }

    # ★ 必须同时支持哈希表与 PSCustomObject ★
    #   两种来源都会进来：ConvertFrom-Json 给 PSCustomObject，
    #   而调用方（含测试、含手写 spec）经常直接传 [ordered]@{} 哈希表。
    #   $hash.PSObject.Properties['name'] 对哈希表恒为 $null —— 只写这一条
    #   会让所有哈希表输入被当成「字段不存在」，然后静默用默认值或 throw
    #   「需要 xx」，排查时会怀疑到 JSON 上，方向完全错。
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $Default }
        $v = $Object[$Name]
        if ($null -eq $v) { return $Default }
        return $v
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Test-CadField {
    # 字段是否存在且非 null（区分「没写」和「写了 null」时用）
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        return ($Object.Contains($Name) -and $null -ne $Object[$Name])
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $false }
    return ($null -ne $prop.Value)
}

# ══════════════════════════════════════════════════════════════════
#  数值格式化
# ══════════════════════════════════════════════════════════════════

function Format-LispNum {
    param($Value)
    if ($null -eq $Value) { throw '数值不能为 null' }
    $d = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        throw "不是合法数值: '$Value'"
    }
    # 固定小数位，避免 1E+06 这种科学计数法（LISP 读不了）
    return $d.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-LispPoint {
    <#
      生成一个 LISP 点值表达式。
      必须用 (list x y) 而不是 (x y)：后者会被 LISP 求值成「调用函数 x」，
      在 (list "_.LINE" (0 0) ...) 里直接报 no function definition。
    #>
    param($Value, [string]$FieldName = 'point')
    if ($null -eq $Value) { throw "$FieldName 不能为 null" }
    if ($Value -is [string]) {
        # 允许 "10,20" 这种简写
        $parts = $Value -split ','
        if ($parts.Count -lt 2) { throw "$FieldName 格式错误，应为 [x,y] 或 `"x,y`"：$Value" }
        return "(list $(Format-LispNum $parts[0].Trim()) $(Format-LispNum $parts[1].Trim()))"
    }
    $arr = @($Value)
    if ($arr.Count -lt 2) { throw "$FieldName 至少需要两个分量" }
    return "(list $(Format-LispNum $arr[0]) $(Format-LispNum $arr[1]))"
}

function Format-LispString {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    # LISP 字符串：转义反斜杠与双引号
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-PointXY {
    # 取点的 x/y 分量，兼容数组与 "x,y" 字符串
    param($Value, [string]$FieldName = 'point')
    if ($null -eq $Value) { throw "$FieldName 不能为 null" }
    if ($Value -is [string]) {
        $parts = $Value -split ','
        if ($parts.Count -lt 2) { throw "$FieldName 格式错误：$Value" }
        return @([double]$parts[0].Trim(), [double]$parts[1].Trim())
    }
    $arr = @($Value)
    if ($arr.Count -lt 2) { throw "$FieldName 至少需要两个分量" }
    return @([double]$arr[0], [double]$arr[1])
}

# ══════════════════════════════════════════════════════════════════
#  单实体编译
# ══════════════════════════════════════════════════════════════════

function Compile-CadEntity {
    <#
      把一个 JSON 实体编译成若干行 LISP。
      返回 @{ index; type; layer; lines; note }
      出错抛异常，异常消息直接说明哪个字段错了。
    #>
    param(
        [Parameter(Mandatory)]$Entity,
        [int]$Index = 0,
        [string]$DefaultLayer = '0'
    )

    $rawType = Get-CadField $Entity 'type'
    if (-not $rawType) { throw "entities[$Index] 缺少 type 字段" }

    $type  = ([string]$rawType).ToLowerInvariant()
    $layer = [string](Get-CadField $Entity 'layer' $DefaultLayer)
    $lines = New-Object System.Collections.Generic.List[string]
    $note  = ''

    # 切图层（非 0 图层才需要）
    if ($layer -and $layer -ne '0') {
        $lines.Add("(setvar `"CLAYER`" $(Format-LispString $layer))")
    }

    $tag = "entities[$Index]($type)"

    switch ($type) {

        'line' {
            $p1 = Get-CadField $Entity 'p1'
            $p2 = Get-CadField $Entity 'p2'
            if ($null -eq $p1 -or $null -eq $p2) { throw "$tag 需要 p1 与 p2" }
            $s1 = Format-LispPoint $p1 "$tag.p1"
            $s2 = Format-LispPoint $p2 "$tag.p2"
            $lines.Add("(cadcmd (list `"_.LINE`" $s1 $s2 `"`"))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"line|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "line $s1 -> $s2"
        }

        'polyline' {
            $points = Get-CadField $Entity 'points'
            if ($null -eq $points -or @($points).Count -lt 2) { throw "$tag 需要至少两个 points" }
            $pts = @($points) | ForEach-Object { Format-LispPoint $_ "$tag.points[]" }
            $closed = [bool](Get-CadField $Entity 'closed' $false)
            $tail = if ($closed) { ' "_C"' } else { ' ""' }
            $lines.Add("(cadcmd (list `"_.PLINE`" $($pts -join ' ')$tail))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"polyline|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "polyline $($pts.Count) pts closed=$closed"
        }

        'circle' {
            $c = Get-CadField $Entity 'c'
            if ($null -eq $c) { throw "$tag 需要 c" }
            $r = Get-CadField $Entity 'r'
            if ($null -eq $r) { $r = Get-CadField $Entity 'radius' }
            if ($null -eq $r) { throw "$tag 需要 r" }
            $sc = Format-LispPoint $c "$tag.c"
            $lines.Add("(cadcmd (list `"_.CIRCLE`" $sc $(Format-LispNum $r)))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"circle|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "circle $sc r=$r"
        }

        'arc' {
            $c = Get-CadField $Entity 'c'
            $r = Get-CadField $Entity 'r'
            if ($null -eq $c -or $null -eq $r) { throw "$tag 需要 c 与 r" }
            $a1 = Get-CadField $Entity 'start'
            if ($null -eq $a1) { $a1 = Get-CadField $Entity 'startAngle' }
            $a2 = Get-CadField $Entity 'end'
            if ($null -eq $a2) { $a2 = Get-CadField $Entity 'endAngle' }
            if ($null -eq $a1 -or $null -eq $a2) { throw "$tag 需要 start 与 end（角度制）" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:ARC $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $r) $(Format-LispNum $a1) $(Format-LispNum $a2))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"arc|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "arc r=$r $a1->$a2 deg"
        }

        'rect' {
            $p1 = Get-CadField $Entity 'p1'
            $p2 = Get-CadField $Entity 'p2'
            if ($null -eq $p1 -or $null -eq $p2) { throw "$tag 需要 p1 与 p2" }
            $s1 = Format-LispPoint $p1 "$tag.p1"
            $s2 = Format-LispPoint $p2 "$tag.p2"
            $lines.Add("(cadcmd (list `"_.RECTANG`" $s1 $s2))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"rect|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "rect $s1 -> $s2"
        }

        'ellipse' {
            $c = Get-CadField $Entity 'c'
            if ($null -eq $c) { throw "$tag 需要 c" }
            $rx = Get-CadField $Entity 'rx'
            if ($null -eq $rx) { $rx = Get-CadField $Entity 'r' }
            if ($null -eq $rx) { throw "$tag 需要 rx" }
            $ry = Get-CadField $Entity 'ry'
            if ($null -eq $ry) { throw "$tag 需要 ry" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:ELLIPSE $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $rx) $(Format-LispNum $ry))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"ellipse|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "ellipse rx=$rx ry=$ry"
        }

        'point' {
            $at = Get-CadField $Entity 'at'
            if ($null -eq $at) { $at = Get-CadField $Entity 'c' }
            if ($null -eq $at) { throw "$tag 需要 at" }
            $xy = Get-PointXY $at "$tag.at"
            $lines.Add("(c:POINT $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"point|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "point $($xy[0]),$($xy[1])"
        }

        'spline' {
            $points = Get-CadField $Entity 'points'
            if ($null -eq $points -or @($points).Count -lt 3) { throw "$tag 需要至少三个 points" }
            $pts = @($points) | ForEach-Object { Format-LispPoint $_ "$tag.points[]" }
            # SPLINE 需要：起点、后续点、回车结束、起点切线、终点切线
            $lines.Add("(cadcmd (list `"_.SPLINE`" $($pts -join ' ') `"`" `"`" `"`"))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"spline|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "spline $($pts.Count) pts"
        }

        'polygon' {
            $c = Get-CadField $Entity 'c'
            $r = Get-CadField $Entity 'r'
            $sides = Get-CadField $Entity 'sides'
            if ($null -eq $c -or $null -eq $r -or $null -eq $sides) { throw "$tag 需要 c / r / sides" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:POLYGON $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $r) $([int]$sides))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"polygon|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "polygon sides=$sides"
        }

        'gear' {
            $c = Get-CadField $Entity 'c'
            $r = Get-CadField $Entity 'r'
            $teeth = Get-CadField $Entity 'teeth'
            if ($null -eq $c -or $null -eq $r -or $null -eq $teeth) { throw "$tag 需要 c / r / teeth" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:GEAR $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $r) $([int]$teeth))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"gear|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "gear teeth=$teeth"
        }

        'centerline' {
            $c = Get-CadField $Entity 'c'
            $len = Get-CadField $Entity 'len'
            if ($null -eq $len) { $len = Get-CadField $Entity 'length' }
            if ($null -eq $c -or $null -eq $len) { throw "$tag 需要 c 与 len（长度）" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:CENTERLINE $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $len))")
            # c:CENTERLINE 一次画两条线，回执给最后一条的 handle
            $lines.Add("(cadsay `"E$Index`" (strcat `"centerline|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "centerline len=$len"
        }

        'boltpattern' {
            $c = Get-CadField $Entity 'c'
            $r = Get-CadField $Entity 'r'
            $count = Get-CadField $Entity 'count'
            if ($null -eq $c -or $null -eq $r -or $null -eq $count) { throw "$tag 需要 c / r / count" }
            $xy = Get-PointXY $c "$tag.c"
            $lines.Add("(c:BOLTPATTERN $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $r) $([int]$count))")
            # 一次画出 n+1 个圆（n 个孔 + 1 个分布圆），回执给最后那个
            $lines.Add("(cadsay `"E$Index`" (strcat `"boltpattern|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "boltpattern n=$count"
        }

        'text' {
            $at = Get-CadField $Entity 'at'
            $value = Get-CadField $Entity 'value'
            if ($null -eq $at -or $null -eq $value) { throw "$tag 需要 at 与 value" }
            $h = Get-CadField $Entity 'height' 2.5
            $align = 'BL'
            if (Test-CadField $Entity 'align') { $align = ([string](Get-CadField $Entity 'align')).ToUpperInvariant() }
            $rot = Get-CadField $Entity 'rotation' 0
            $lines.Add("(cadcmd (list `"_.TEXT`" `"_J`" `"_$align`" $(Format-LispPoint $at "$tag.at") $(Format-LispNum $h) $(Format-LispNum $rot) $(Format-LispString ([string]$value))))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"text|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "text '$value' h=$h"
        }

        'mtext' {
            $at = Get-CadField $Entity 'at'
            $value = Get-CadField $Entity 'value'
            if ($null -eq $at -or $null -eq $value) { throw "$tag 需要 at 与 value" }
            $w = Get-CadField $Entity 'width' 100
            $h = Get-CadField $Entity 'height' 10
            $xy = Get-PointXY $at "$tag.at"
            # ★ PowerShell 里逗号的优先级高于 + ★
            #   @($xy[0] + $w, $xy[1] + $h) 会被解析成 ($xy[0] + ($w, ($xy[1] + $h)))
            #   → 「[System.Object[]] 不包含名为 'op_Addition' 的方法」
            #   必须先把每个分量算进变量再组数组。
            $x0 = [double]$xy[0]; $y0 = [double]$xy[1]
            $x1 = $x0 + [double]$w; $y1 = $y0 + [double]$h
            $corner = @($x1, $y1)
            $lines.Add("(c:MTEXT $(Format-LispNum $x0) $(Format-LispNum $y0) $(Format-LispNum $w) $(Format-LispNum $h) $(Format-LispString ([string]$value)))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"mtext|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "mtext '$value' w=$w h=$h corner=$x1,$y1"
        }

        'dimlinear' {
            $p1 = Get-CadField $Entity 'p1'
            $p2 = Get-CadField $Entity 'p2'
            if ($null -eq $p1 -or $null -eq $p2) { throw "$tag 需要 p1 与 p2" }
            $at = Get-CadField $Entity 'at'
            if ($null -eq $at) {
                $a = Get-PointXY $p1 "$tag.p1"; $b = Get-PointXY $p2 "$tag.p2"
                $at = @((($a[0] + $b[0]) / 2.0), ([Math]::Max($a[1], $b[1]) + 10))
            }
            $a = Get-PointXY $p1 "$tag.p1"; $b = Get-PointXY $p2 "$tag.p2"; $t = Get-PointXY $at "$tag.at"
            $lines.Add("(c:DIMLIN $(Format-LispNum $a[0]) $(Format-LispNum $a[1]) $(Format-LispNum $b[0]) $(Format-LispNum $b[1]) $(Format-LispNum $t[0]) $(Format-LispNum $t[1]))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"dimlinear|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = 'dimlinear'
        }

        'dimaligned' {
            $p1 = Get-CadField $Entity 'p1'
            $p2 = Get-CadField $Entity 'p2'
            if ($null -eq $p1 -or $null -eq $p2) { throw "$tag 需要 p1 与 p2" }
            $at = Get-CadField $Entity 'at'
            if ($null -eq $at) {
                $a0 = Get-PointXY $p1 "$tag.p1"; $b0 = Get-PointXY $p2 "$tag.p2"
                $at = @((($a0[0] + $b0[0]) / 2.0), ([Math]::Max($a0[1], $b0[1]) + 10))
            }
            $a = Get-PointXY $p1 "$tag.p1"; $b = Get-PointXY $p2 "$tag.p2"; $t = Get-PointXY $at "$tag.at"
            $lines.Add("(c:DIMALIGN $(Format-LispNum $a[0]) $(Format-LispNum $a[1]) $(Format-LispNum $b[0]) $(Format-LispNum $b[1]) $(Format-LispNum $t[0]) $(Format-LispNum $t[1]))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"dimaligned|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = 'dimaligned'
        }

        'dimradius' {
            # 三种写法都接受：
            #   1) c + r         → 边缘点取 (cx+r, cy)，最常用
            #   2) c + edge      → 显式给圆周上的点
            #   3) edge 单独给   → 只有边缘点也算得出来，但缺圆心无法校验
            $c = Get-CadField $Entity 'c'
            $r = Get-CadField $Entity 'r'
            if ($null -eq $r) { $r = Get-CadField $Entity 'radius' }
            $edge = Get-CadField $Entity 'edge'
            if ($null -eq $edge) { $edge = Get-CadField $Entity 'at' }
            $txt = Get-CadField $Entity 'text'
            if ($null -eq $txt) { $txt = Get-CadField $Entity 'textAt' }

            if ($null -eq $c) { throw "$tag 需要 c（圆心）" }
            $xy = Get-PointXY $c "$tag.c"

            if ($null -ne $edge) {
                $ex = Get-PointXY $edge "$tag.edge"
            } elseif ($null -ne $r) {
                # ★ 同样要先把分量算进变量，别在 @() 里直接做加法 ★
                $ex0 = [double]$xy[0] + [double]$r
                $ex1 = [double]$xy[1]
                $ex = @($ex0, $ex1)
            } else {
                throw "$tag 需要 r（半径）或 edge（圆周上的点）"
            }

            if ($null -eq $txt) {
                $tx0 = ([double]$xy[0] + [double]$ex[0]) / 2.0
                $ty0 = ([double]$xy[1] + [double]$ex[1]) / 2.0
                $txt = @($tx0, $ty0)
            }
            $t = Get-PointXY $txt "$tag.text"

            $lines.Add("(c:DIMRAD $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $ex[0]) $(Format-LispNum $ex[1]) $(Format-LispNum $t[0]) $(Format-LispNum $t[1]))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"dimradius|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "dimradius edge=$($ex[0]),$($ex[1])"
        }

        'hatch' {
            $pat = [string](Get-CadField $Entity 'pattern' 'ANSI31')
            $sc = Get-CadField $Entity 'scale' 1
            # seed（内部点）与 at 是同义字段，两种写法都接受
            $seed = Get-CadField $Entity 'seed'
            if ($null -eq $seed) { $seed = Get-CadField $Entity 'at' }
            if ($null -eq $seed) { throw "$tag 需要 seed（内部点坐标）或 at" }
            $xy = Get-PointXY $seed "$tag.seed"
            $lines.Add("(c:HATCH $(Format-LispString $pat) $(Format-LispNum $sc) $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"hatch|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "hatch $pat seed=$($xy[0]),$($xy[1])"
        }

        'solid' {
            $points = Get-CadField $Entity 'points'
            if ($null -eq $points -or @($points).Count -lt 3) { throw "$tag 需要至少三个 points" }
            $pts = @($points)
            while ($pts.Count -lt 4) { $pts += $pts[-1] }
            $formatted = $pts | ForEach-Object { Format-LispPoint $_ "$tag.points[]" }
            $lines.Add("(cadcmd (list `"_.SOLID`" $($formatted -join ' ') `"`"))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"solid|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = 'solid'
        }

        'block' {
            $name = Get-CadField $Entity 'name'
            $at = Get-CadField $Entity 'at'
            if (-not $name) { throw "$tag 需要 name" }
            if ($null -eq $at) { throw "$tag 需要 at" }
            $sx = Get-CadField $Entity 'scaleX' 1
            $sy = Get-CadField $Entity 'scaleY' $sx
            $rot = Get-CadField $Entity 'rotation' 0
            $xy = Get-PointXY $at "$tag.at"
            $lines.Add("(c:INSERTBLOCK $(Format-LispString ([string]$name)) $(Format-LispNum $xy[0]) $(Format-LispNum $xy[1]) $(Format-LispNum $sx) $(Format-LispNum $sy) $(Format-LispNum $rot))")
            $lines.Add("(cadsay `"E$Index`" (strcat `"block|`" (cdr (assoc 5 (entget (entlast))))))")
            $note = "insert block $name"
        }

        'erase' {
            $et = Get-CadField $Entity 'entityType'
            $ly = Get-CadField $Entity 'layer'
            if ($et) {
                $lines.Add("(c:DELTYPE $(Format-LispString ([string]$et)))")
                $note = "erase type $et"
            } elseif ($ly) {
                $lines.Add("(c:DELLAYER $(Format-LispString ([string]$ly)))")
                $note = "erase layer $ly"
            } else {
                throw "$tag 需要 entityType 或 layer"
            }
        }

        default {
            throw "$tag 未知 type: '$type'（支持：line/polyline/circle/arc/rect/ellipse/point/spline/polygon/gear/centerline/boltpattern/text/mtext/dimlinear/dimaligned/dimradius/hatch/solid/block/erase）"
        }
    }

    return [pscustomobject]@{
        index = $Index
        type  = $type
        layer = $layer
        lines = $lines.ToArray()
        note  = $note
    }
}

# ══════════════════════════════════════════════════════════════════
#  整个 JSON 图纸 → LISP
# ══════════════════════════════════════════════════════════════════

function Compile-CadSpec {
    <#
      把完整 JSON 图纸描述编译成一份可执行的 LISP 源。
      返回 @{ lisp; entityCount; layers; entities; warnings }
    #>
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$CoreLspPath
    )

    if (-not (Test-Path -LiteralPath $CoreLspPath -PathType Leaf)) {
        throw "cadcore.lsp 不存在: $CoreLspPath"
    }

    $sb = New-Object System.Text.StringBuilder
    $warnings = New-Object System.Collections.Generic.List[string]
    $compiled = New-Object System.Collections.Generic.List[object]
    $layerNames = New-Object System.Collections.Generic.List[string]

    $core = ConvertTo-CadPath -Path $CoreLspPath

    [void]$sb.AppendLine(';; ── 由 CadCompiler.ps1 生成，请勿手改 ──')
    [void]$sb.AppendLine('(setvar "SECURELOAD" 0)')
    [void]$sb.AppendLine("(load `"$core`")")
    [void]$sb.AppendLine('(if (not (c:SETUP)) (princ "\n@@SETUP_FAILED@@"))')

    # ── 单位（INSUNITS）──
    # 这是整张图最容易被忽略、又最贵的一个属性。
    # 不设 INSUNITS 的图纸，插进别人的图里会被当成「无单位」按 1:1 硬塞，
    # 于是 φ80 的法兰在总装里变成 φ80 英寸 ≈ 2 米 —— 图上每个尺寸标注都对，
    # 装配出来是废品。所以 units 必须真的写进图纸头，而不是只留在 JSON 里。
    #
    # units 缺失时不动 INSUNITS（保持种子模板的原值），但记 warning：
    # 悄悄替用户选一个单位，比不选更危险。
    $unitName = Get-CadField $Spec 'units'
    if ($unitName) {
        $unitCode = -1
        if (Get-Command Get-CadUnitCode -ErrorAction SilentlyContinue) {
            $unitCode = Get-CadUnitCode -Name ([string]$unitName)
        }
        if ($unitCode -ge 0) {
            [void]$sb.AppendLine("(cadunits $unitCode)")
        } else {
            $warnings.Add("units='$unitName' 不是可识别的单位名（可用 mm/cm/m/in/ft/mil/yd/mi/km/unitless），已保持图纸原设置")
        }
    } else {
        $warnings.Add('未声明 units，图纸将沿用模板的 INSUNITS；下游工具可能按无单位处理，建议在 spec 顶层写明')
    }

    # ── 图层 ──
    # LISP 没有可选参数：c:LAYER 声明了 (name color ltype)，少传一个就是
    # 「参数太少」运行时错误，所以这里永远补齐三个实参。
    # 另外实体可能引用没在 layers[] 里声明的图层，(setvar "CLAYER" ...) 会失败，
    # 所以先把实体用到的图层全部收集起来，缺的自动补建。
    $layers = Get-CadField $Spec 'layers'
    $declared = New-Object System.Collections.Generic.List[string]
    $layerDefs = New-Object System.Collections.Generic.List[object]

    if ($layers) {
        $li = 0
        foreach ($ly in @($layers)) {
            $nm = Get-CadField $ly 'name'
            if (-not $nm) { $warnings.Add("layers[$li] 没有 name，已跳过"); $li++; continue }
            $declared.Add([string]$nm)

            # 颜色：必须是 ACI 整数 1–255（7 = 白/黑，随背景反转）。
            # 用户写 "red"、"#FF0000"、300 都是常见的，直接 [int] 强转会在
            # StrictMode 下抛异常把整张图带崩 —— 图层是基础设施，坏一个值
            # 不该让全部实体停工，回落到 7 并记 warning 才合理。
            $rawColor = Get-CadField $ly 'color' 7
            $color = 7
            $parsed = 0
            if ([int]::TryParse([string]$rawColor, [ref]$parsed)) {
                if ($parsed -ge 1 -and $parsed -le 255) {
                    $color = $parsed
                } else {
                    $warnings.Add("layers[$li]($nm).color=$rawColor 超出 1–255，已改用 7")
                }
            } else {
                $warnings.Add("layers[$li]($nm).color=$rawColor 不是 1–255 的整数，已改用 7")
            }

            # 线型：不存在的线型名不会让 c:LAYER 报错（内部有 tblsearch 兜底），
            # 但要在报告里留痕，免得用户以为线型生效了。
            $ltype = [string](Get-CadField $ly 'ltype' '')

            $layerDefs.Add([pscustomobject]@{
                name  = [string]$nm
                color = $color
                ltype = $ltype
            }) | Out-Null
            $li++
        }
    }

    # 收集实体/块内实体引用到的图层
    $referenced = New-Object System.Collections.Generic.List[string]
    $collect = {
        param($list)
        foreach ($e in @($list)) {
            $ly = Get-CadField $e 'layer'
            if ($ly -and -not $referenced.Contains([string]$ly)) { $referenced.Add([string]$ly) }
        }
    }
    $entitiesTop = Get-CadField $Spec 'entities'
    if ($entitiesTop) { & $collect $entitiesTop }
    $blocksTop = Get-CadField $Spec 'blocks'
    if ($blocksTop) {
        foreach ($blk in @($blocksTop)) {
            $bents = Get-CadField $blk 'entities'
            if ($bents) { & $collect $bents }
        }
    }
    foreach ($r in $referenced) {
        if ($r -eq '0') { continue }
        if (-not $declared.Contains($r)) {
            $warnings.Add("图层 '$r' 被实体引用但未在 layers[] 声明，已自动补建（颜色 7）")
            $layerDefs.Add([pscustomobject]@{ name = $r; color = 7; ltype = '' }) | Out-Null
            $declared.Add($r)
        }
    }

    foreach ($ld in $layerDefs) {
        [void]$sb.AppendLine("(c:LAYER $(Format-LispString $ld.name) $($ld.color) $(Format-LispString $ld.ltype))")
    }
    $layerNames = $declared

    # ── 块定义（必须先于插入）──
    $blocks = Get-CadField $Spec 'blocks'
    if ($blocks) {
        $bi = 0
        foreach ($blk in @($blocks)) {
            $bname = Get-CadField $blk 'name'
            if (-not $bname) { $warnings.Add("blocks[$bi] 没有 name，已跳过"); $bi++; continue }
            $bname = [string]$bname
            $base = Get-CadField $blk 'base'
            $baseX = 0; $baseY = 0
            if ($null -ne $base) {
                $bxy = Get-PointXY $base "blocks[$bi].base"
                $baseX = $bxy[0]; $baseY = $bxy[1]
            }

            [void]$sb.AppendLine(";; block $bname")
            # 用 c:BEGBLOCK / c:ENDBLOCK 包住块内实体。
            # 绝不能用 (command "_.-BLOCK" name pt) —— -BLOCK 给完基点后立刻
            # 进入「选择对象:」，后面的画图命令会被当选择点吃掉，图上出现
            # *无效选择* 并卡死到超时。详见 cadcore.lsp 的块构建器注释。
            [void]$sb.AppendLine("(c:BEGBLOCK $(Format-LispString $bname) $(Format-LispNum $baseX) $(Format-LispNum $baseY))")
            $bents = Get-CadField $blk 'entities'
            if ($bents) {
                $ei = 0
                foreach ($be in @($bents)) {
                    try {
                        $c = Compile-CadEntity -Entity $be -Index $ei -DefaultLayer '0'
                        foreach ($l in $c.lines) { [void]$sb.AppendLine($l) }
                    } catch {
                        $warnings.Add("blocks[$bi]($bname).entities[$ei] 编译失败：$($_.Exception.Message)")
                    }
                    $ei++
                }
            }
            [void]$sb.AppendLine("(c:ENDBLOCK)")
            $bi++
        }
    }

    # ── 实体 ──
    $idx = 0
    $entities = Get-CadField $Spec 'entities'
    if ($entities) {
        foreach ($ent in @($entities)) {
            try {
                $c = Compile-CadEntity -Entity $ent -Index $idx
                foreach ($l in $c.lines) { [void]$sb.AppendLine($l) }
                $compiled.Add($c) | Out-Null
            } catch {
                $warnings.Add("entities[$idx] 编译失败：$($_.Exception.Message)")
                [void]$sb.AppendLine("(cadsay `"ENTFAIL_$idx`" `"compile-error`")")
            }
            $idx++
        }
    }

    # ── 收尾：缩放 + 统计 ──
    if ((Get-CadField $Spec 'zoom' $true) -ne $false) {
        [void]$sb.AppendLine('(c:ZOOMEXT)')
    }
    [void]$sb.AppendLine('(c:TYPESTAT)')
    [void]$sb.AppendLine('(c:EXTENTS)')
    [void]$sb.AppendLine('(c:COUNT)')

    # ── 存盘 ──
    $save = Get-CadField $Spec 'save'
    if ($save) {
        $dwg = Get-CadField $save 'dwg'
        # DWG 版本：SAVEAS 的文件格式关键字，合法值 R14/2000/2004/2007/2010/2013/2018
        # （注意不是 "16"/"2013" 这种任意串 —— 不认的关键字会让 SAVEAS 报「无效的选项关键字」
        #   并把后续命令一起吞掉，所以这里要白名单化）
        $ver = [string](Get-CadField $save 'version' '2018')
        $ver = switch -Regex ($ver) {
            '^(?i)r1[24]$|^(?i)14$'          { 'R14' }
            '^(?i)2000$'                     { '2000' }
            '^(?i)2004$'                     { '2004' }
            '^(?i)2007$'                     { '2007' }
            '^(?i)2010$'                     { '2010' }
            '^(?i)2013$'                     { '2013' }
            '^(?i)2018$'                     { '2018' }
            default {
                $warnings.Add("save.version='$ver' 不是有效的 DWG 格式（可用 R14/2000/2004/2007/2010/2013/2018），已改用 2018")
                '2018'
            }
        }

        if ($dwg) {
            [void]$sb.AppendLine("(c:SAVEAS $(Format-LispString (ConvertTo-CadPath -Path ([string]$dwg))) $(Format-LispString $ver))")
        }

        $dxf = Get-CadField $save 'dxf'
        if ($dxf) {
            $dxfPath = $null
            if ($dxf -is [string]) { $dxfPath = [string]$dxf }
            elseif ($dwg) { $dxfPath = [IO.Path]::ChangeExtension([string]$dwg, '.dxf') }
            if ($dxfPath) {
                # DXF 版本与 DWG 版本是两个独立开关：DXFOUT 用 _V <版本名>，精度另给。
                $dxfVer = [string](Get-CadField $save 'dxfVersion' '2018')
                $dxfVer = switch -Regex ($dxfVer) {
                    '^(?i)r1[24]$|^(?i)14$'  { 'R12' }
                    '^(?i)2000$'             { '2000' }
                    '^(?i)2004$'             { '2004' }
                    '^(?i)2007$'             { '2007' }
                    '^(?i)2010$'             { '2010' }
                    '^(?i)2013$'             { '2013' }
                    '^(?i)2018$'             { '2018' }
                    default {
                        # ★ 静默回落是最坏的选项 ★
                        # 用户写了 dxfVersion='R9' 却拿到 2018 文件，若不记 warning，
                        # 他会在下游工具（老 CAM/老检具）里遇到「打不开」而不知道原因。
                        $warnings.Add("save.dxfVersion='$dxfVer' 不是有效的 DXF 版本（可用 R12/2000/2004/2007/2010/2013/2018），已改用 2018")
                        '2018'
                    }
                }
                [void]$sb.AppendLine("(c:SAVEDXF $(Format-LispString (ConvertTo-CadPath -Path $dxfPath)) $(Format-LispString $dxfVer) `"16`")")
            } else {
                $warnings.Add('save.dxf 为 true 但 save.dwg 未指定，无法推导 DXF 路径，已跳过')
            }
        }

        # PDF：Invoke-CadDraw 已把 save.pdf 规范成完整路径，save.pdfSize 存图纸尺寸。
        # 但直接调用 Compile-CadSpec 的场景可能只给 {"pdf":true}，
        # 那就按 save.dwg 换扩展名推导。
        $pdf = Get-CadField $save 'pdf'
        $pdfPath = $null
        if ($pdf -is [string] -and $pdf) { $pdfPath = [string]$pdf }
        elseif ($pdf -and $dwg) { $pdfPath = [IO.Path]::ChangeExtension([string]$dwg, '.pdf') }
        if ($pdfPath) {
            $size = [string](Get-CadField $save 'pdfSize' 'A3')
            [void]$sb.AppendLine("(c:PLOTPDF $(Format-LispString (ConvertTo-CadPath -Path $pdfPath)) $(Format-LispString $size))")
        } elseif ($pdf -and -not $dwg) {
            $warnings.Add('save.pdf 为 true 但 save.dwg 未指定，无法推导 PDF 路径，已跳过')
        }
    }

    [void]$sb.AppendLine('(princ "\n@@DONE@@")')
    [void]$sb.AppendLine('(princ)')
    return [pscustomobject]@{
        lisp        = $sb.ToString()
        entityCount = $compiled.Count
        layers      = $layerNames.ToArray()
        entities    = $compiled.ToArray()
        warnings    = $warnings.ToArray()
    }
}
# ═══════════════════════════════════════════════════════════════════
# spec 多视图（views[]）：把一份 spec 拆成若干张可独立保存的视图
# ═══════════════════════════════════════════════════════════════════
# 结构约定（与对方 image-redraw-spec 对齐，证据四级沿用我方体系）：
#   spec.views = [ { id/view/name, entities?: [entity...] } ... ]
#   实体可选 view_id 指向 views[].id；带 view_id 的实体**只**属于那个视图，
#   顶层 entities 不再重复它（避免一次画两遍）。
#   constraints.required_view_ids = ['v1','v2'] 声明哪些视图必须产出。
#
# 拆分规则（Get-CadSpecViewSpecs 返回的每个子 spec）：
#   1. 全局配置照搬：units / layers / blocks / zoom / calibration。
#   2. 该视图实体 = views[i].entities + 顶层 entities 里 view_id 匹配的。
#   3. view_id='' 或不写的顶层实体归所有视图共享。
#   4. save 按视图重写：视图有 save 用视图的；否则克隆顶层 save，
#      dwg/dxf/pdf 文件名前插 '<视图id>-'（已有路径保留目录只换文件名）。
#   5. 图纸名 = drawing + '-' + 视图 id。
function Get-CadSpecViewSpecs {
    param([Parameter(Mandatory)]$Spec)

    $views = Get-CadField $Spec 'views'
    if (-not $views) { return @() }

    # 顶层各段
    $topEntities = @(Get-CadField $Spec 'entities' @())
    $layers = Get-CadField $Spec 'layers'
    $blocks = Get-CadField $Spec 'blocks'
    $units = Get-CadField $Spec 'units'
    $zoom = Get-CadField $Spec 'zoom'
    $calib = Get-CadField $Spec 'calibration'
    $save = Get-CadField $Spec 'save'
    $drawName = [string](Get-CadField $Spec 'name' 'drawing')
    if (-not $drawName) { $drawName = 'drawing' }

    # 顶层实体按 view_id 分桶：'' = 共享
    $shared = New-Object System.Collections.Generic.List[object]
    $byView = @{}
    $viewIds = @()
    foreach ($v in @($views)) {
        $vid = [string](Get-CadField $v 'id' '')
        if ($vid) { $viewIds += $vid }
    }
    foreach ($ent in $topEntities) {
        if ($null -eq $ent) { continue }
        $vid = ([string](Get-CadField $ent 'view_id' '')).Trim()
        if ($vid) {
            if (-not $byView.ContainsKey($vid)) { $byView[$vid] = New-Object System.Collections.Generic.List[object] }
            $byView[$vid].Add($ent)
        } else {
            $shared.Add($ent)
        }
    }

    $out = New-Object System.Collections.Generic.List[object]
    $vi = 0
    foreach ($v in @($views)) {
        $vid = ([string](Get-CadField $v 'id' '')).Trim()
        $vName = ([string](Get-CadField $v 'name' $vid)).Trim()
        if (-not $vid) { $vi++; continue }

        # 视图实体：视图自带 + 顶层 view_id 匹配 + 共享
        $ents = New-Object System.Collections.Generic.List[object]
        foreach ($e in @(Get-CadField $v 'entities' @())) { if ($null -ne $e) { $ents.Add($e) } }
        if ($byView.ContainsKey($vid)) { foreach ($e in $byView[$vid]) { $ents.Add($e) } }
        foreach ($e in $shared) { $ents.Add($e) }

        # 克隆顶层 save，文件名前插 '<vid>-'
        $vSave = $null
        $vSaveRaw = Get-CadField $v 'save'
        if ($vSaveRaw) {
            $vSave = $vSaveRaw
        } elseif ($save) {
            $vSave = $save.PSObject.Copy()
            foreach ($key in @('dwg', 'dxf', 'pdf')) {
                $p = Get-CadField $vSave $key
                if ($p -is [string] -and $p -and ($p -notmatch '^[A-Za-z]:') -and ($p -notmatch '^\\\\')) {
                    $dir = Split-Path -Parent $p
                    $leaf = Split-Path -Leaf $p
                    $vSave | Add-Member -NotePropertyName $key -NotePropertyValue $(if ($dir) { Join-Path $dir "$vid-$leaf" } else { "$vid-$leaf" }) -Force
                }
            }
        }

        $sub = [ordered]@{}
        if ($units) { $sub['units'] = $units }
        if ($layers) { $sub['layers'] = $layers }
        if ($blocks) { $sub['blocks'] = $blocks }
        if ($calib) { $sub['calibration'] = $calib }
        $sub['name'] = if ($vName -and $vName -ne $vid) { "$drawName-$vName" } else { "$drawName-$vid" }
        $sub['entities'] = $ents.ToArray()
        if ($vSave) { $sub['save'] = $vSave }
        if ($null -ne $zoom) { $sub['zoom'] = $zoom }
        $out.Add([pscustomobject]$sub)
        $vi++
    }

    return $out.ToArray()
}
