<#
    CadSpecCheck.ps1 — 出图前的 spec 预检
    ────────────────────────────────────────────────────────────────
    这个模块只做一件事：在 accoreconsole 被叫起来之前，把 JSON 里那些
    「一定会失败」或「一定会画错」的地方找出来，用一条人话说明白。

    为什么必须有它：
      accoreconsole 出图一次 4 秒，失败一次要等超时（默认 180 秒）。
      而绝大多数失败根本不需要 AutoCAD 参与判断 ——
      "circle 少了 r"、"rect 的两个角点重合"、"螺栓圆阵列的 count 是 0"
      这些都是纯数据问题，本地几毫秒就能判。
      更贵的是「画成功了但画错了」：半径 -20 会得到一个报错，
      但半径 20000 会得到一张 20 米宽的图纸，成果看起来完整、尺寸全错。
      那才是真正会流到下游的灾难。

    三类检查：
      1. 结构 → 字段在不在、类型对不对、必需字段有没有别名兜住
      2. 几何 → 会不会画出零尺寸 / 负尺寸 / 坐标溢出 / 重复实体
      3. 约束 → 用户自己声明的 constraints（单位、图层、包络、间隙、闭合）

    返回对象不做裁决，只列问题。裁决在 Invoke-CadDraw.ps1：
      errors   → blocked，一个实体都不画
      warnings → pass_with_warnings，画完提示复核

    用法：
      . .\CadSpecCheck.ps1
      $r = Test-CadSpecStrict -Spec $spec
      $r.errors    # string[]
      $r.warnings  # string[]
      $r.evidence  # CadEvidence 对象数组
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════
#  实体字段表
# ══════════════════════════════════════════════════════════════════
#  字段名用 | 分隔别名：'r|radius' 表示 r 和 radius 都认，有一个就够。
#  类型记号：
#    point     单个点（[x,y] / {x,y} / 数字会报错，因为单位不明的标量没意义）
#    points2   点数组，至少 2 个
#    points3   点数组，至少 3 个
#    posnum    必须 > 0
#    num       任意有限数
#    int3      整数，至少 3
#    int1      整数，至少 1
#    string    非空字符串
#    bool      布尔
#
#  这张表是「编译器真正需要的字段」的镜像，不是「所有合法字段」。
#  编译器有默认值的字段（height/scale/align…）放 opt，缺了不算错。

# 注意：条目必须写成 @{ n = '字段名'; k = '类型' } 这种具名记录，
# 不能写成 @('points', 'points2') 这样的二元数组。
# 因为 PowerShell 的数组子表达式会压平嵌套数组：
#     @( @('points','points2') )   →  @('points','points2')   ← 变成一个二元数组！
# 于是 foreach 拿到的是 'points' 这个字符串而不是「别名组」，
# 再取 $req[0] 就得到首字符 'p'，报错文案会变成「缺少必需字段 p」。
# 这个坑只有在「只有一个必需字段」的条目上才会触发（polyline/spline/solid），
# 一旦后面再补一个字段就自动消失 —— 是最难复现的那种 bug。用具名记录一次性根治。

$script:CadSpecSchema = [ordered]@{
    line        = @{ req = @(@{ n = 'p1'; k = 'point' }, @{ n = 'p2'; k = 'point' });               opt = @() }
    polyline    = @{ req = @(@{ n = 'points'; k = 'points2' });                                     opt = @(@{ n = 'closed'; k = 'bool' }) }
    circle      = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }); opt = @() }
    arc         = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }); opt = @(@{ n = 'start|startAngle'; k = 'num' }, @{ n = 'end|endAngle'; k = 'num' }) }
    rect        = @{ req = @(@{ n = 'p1'; k = 'point' }, @{ n = 'p2'; k = 'point' });               opt = @() }
    ellipse     = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'rx|r'; k = 'posnum' }, @{ n = 'ry'; k = 'posnum' }); opt = @() }
    point       = @{ req = @();                                                                     opt = @(@{ n = 'at|c'; k = 'point' }) }
    spline      = @{ req = @(@{ n = 'points'; k = 'points3' });                                     opt = @() }
    polygon     = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }, @{ n = 'sides|n'; k = 'int3' }); opt = @() }
    gear        = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }, @{ n = 'teeth|n'; k = 'int3' }); opt = @() }
    centerline  = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'len|length'; k = 'posnum' }); opt = @() }
    boltpattern = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }, @{ n = 'count|n'; k = 'int1' }); opt = @() }
    text        = @{ req = @(@{ n = 'at'; k = 'point' }, @{ n = 'value|text'; k = 'string' });      opt = @(@{ n = 'height'; k = 'posnum' }, @{ n = 'align'; k = 'string' }, @{ n = 'rotation'; k = 'num' }) }
    mtext       = @{ req = @(@{ n = 'at'; k = 'point' }, @{ n = 'value|text'; k = 'string' });      opt = @(@{ n = 'width'; k = 'posnum' }, @{ n = 'height'; k = 'posnum' }) }
    dimlinear   = @{ req = @(@{ n = 'p1'; k = 'point' }, @{ n = 'p2'; k = 'point' });               opt = @(@{ n = 'at'; k = 'point' }, @{ n = 'text'; k = 'string' }) }
    dimaligned  = @{ req = @(@{ n = 'p1'; k = 'point' }, @{ n = 'p2'; k = 'point' });               opt = @(@{ n = 'at'; k = 'point' }, @{ n = 'text'; k = 'string' }) }
    dimradius   = @{ req = @(@{ n = 'c|center'; k = 'point' }, @{ n = 'r|radius'; k = 'posnum' }); opt = @(@{ n = 'edge|at'; k = 'point' }, @{ n = 'text'; k = 'string' }, @{ n = 'textAt'; k = 'point' }) }
    hatch       = @{ req = @(@{ n = 'seed|at'; k = 'point' });                                      opt = @(@{ n = 'pattern'; k = 'string' }, @{ n = 'scale'; k = 'posnum' }) }
    solid       = @{ req = @(@{ n = 'points'; k = 'points3' });                                     opt = @() }
    block       = @{ req = @(@{ n = 'name'; k = 'string' }, @{ n = 'at'; k = 'point' });            opt = @(@{ n = 'scaleX'; k = 'num' }, @{ n = 'scaleY'; k = 'num' }, @{ n = 'rotation'; k = 'num' }) }
    erase       = @{ req = @();                                                                     opt = @(@{ n = 'entityType'; k = 'string' }, @{ n = 'layer'; k = 'string' }) }
}

# 单位名白名单：和 CadEvidence.ps1 的 $script:CadUnitTable 一致
$script:CadSpecUnitNames = @(
    'unitless', 'none', '无单位',
    'in', 'inch', 'inches', '英寸',
    'ft', 'foot', 'feet', '英尺',
    'mm', '毫米', '公厘',
    'cm', '厘米',
    'm', 'meter', 'metre', '米',
    'km', '千米', '公里',
    'mil', '密尔',
    'yd', 'yard', '码',
    'mi', 'mile', '英里',
    'microinch', '微英寸'
)

# 坐标绝对值上限。超过这个数基本只有两种可能：
#   1. 单位搞错（把 0.05 m 写成 50 mm 的图不会超，但把 50 mm 写成 50 m 会）
#   2. 手滑多打几个零
# 1e7 mm = 10 公里，任何机械零件图纸都不会到这个量级。
$script:CadSpecMaxCoord = 1e7


# ══════════════════════════════════════════════════════════════════
#  内部工具
# ══════════════════════════════════════════════════════════════════

function Get-CheckField {
    <#
      从 PSCustomObject 或 IDictionary 里取字段，取不到返回 $Default。
      CadCompiler.ps1 里有同名逻辑（Get-CadField），但那个模块可能没被
      dot-source 进来 —— 本模块要能独立工作，所以自带一份。

      这个「普通版」会经过 PowerShell 的返回值枚举（数组被展开一层），
      对以下三类字段是安全的：
        · 标量（type/name/value/height…）
        · 单点（p1/p2/c/at —— 展开一层正好得到 [x, y] 两个数）
        · 对象列表（entities/blocks/layers —— 展开一层后 @() 能还原）
      对「点列表」不安全：[[0,0]] 展开后变成 [0,0]，与「一个点」无法区分。
      点列表请用 Get-CheckFieldRaw。
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $Default }
        $v = $Object[$Name]
        if ($null -eq $v) { return $Default }
        return $v
    }

    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-CheckFieldRaw {
    <#
      保真版取字段：返回 @{ found = 布尔; value = 原值 }。

      为什么要包一层哈希表而不是直接用逗号 `return ,$v`：
        `,$v` 确实能挡住枚举，但它把调用方也一起害了 ——
        取 entities（1 个实体）时拿到的是「装着 1 个数组的数组」，
        @() 包一层还原不出来，后面读 $ents[0].type 全是空。
        哈希表本身不会被枚举，值原封不动放在 .value 里，
        调用方自己决定要不要 @() —— 这才是可控的语义。

      「点列表」必须走这里：
        points = [[0,0]]  →  .value 是「1 个点的数组」
        points = [0,0]    →  .value 是「两个数字」
      两者在普通返回值下都会变成「两个数字」，只有在保真路径下能区分，
      而「你把一个点写成了点列表」正是最该报出来的错误。
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return @{ found = $false; value = $Default } }

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return @{ found = $false; value = $Default } }
        $v = $Object[$Name]
        if ($null -eq $v) { return @{ found = $false; value = $Default } }
        return @{ found = $true; value = $v }
    }

    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return @{ found = $false; value = $Default } }
    if ($null -eq $p.Value) { return @{ found = $false; value = $Default } }
    return @{ found = $true; value = $p.Value }
}

function Get-CheckAliasFieldRaw {
    <# 别名组的保真版：返回 @{ name; found; value }。 #>
    param($Object, [string]$Spec, $Default = $null)

    foreach ($n in $Spec.Split('|')) {
        $r = Get-CheckFieldRaw -Object $Object -Name $n
        if ($r.found) { return @{ name = $n; found = $true; value = $r.value } }
    }
    return @{ name = $null; found = $false; value = $Default }
}

function Get-CheckAliasField {
    <#
      按 'a|b|c' 依次找，返回第一个存在的字段值；全都没有返回 $Default。
      同时报出命中的是哪个名字，方便错误信息说清「你写的是 radius，
       编译器要的是 r —— 我们认了，但下次别混写」。
    #>
    param($Object, [string]$Spec, $Default = $null)

    foreach ($n in $Spec.Split('|')) {
        $v = Get-CheckField -Object $Object -Name $n
        if ($null -ne $v) { return @{ name = $n; value = $v } }
    }
    return @{ name = $null; value = $Default }
}

function ConvertTo-CheckPoint {
    <#
      把各种写法的点统一成 [double[]]。
      支持：[x,y] / [x,y,z] / {x:..,y:..} / "10,20"。
      解析不了返回 $null（调用方负责报错，这里不抛）。
    #>
    param($Value)

    if ($null -eq $Value) { return $null }

    # 数组 / ArrayList / List
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $arr = @($Value)
        if ($arr.Count -lt 2) { return $null }
        $x = 0.0; $y = 0.0; $z = 0.0
        if (-not [double]::TryParse([string]$arr[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $null }
        if (-not [double]::TryParse([string]$arr[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$y)) { return $null }
        if ($arr.Count -ge 3) {
            if (-not [double]::TryParse([string]$arr[2], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$z)) { $z = 0.0 }
        }
        return [double[]]@($x, $y, $z)
    }

    # {x:..,y:..}
    $px = Get-CheckField $Value 'x'
    $py = Get-CheckField $Value 'y'
    if ($null -ne $px -and $null -ne $py) {
        $x = 0.0; $y = 0.0; $z = 0.0
        if (-not [double]::TryParse([string]$px, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $null }
        if (-not [double]::TryParse([string]$py, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$y)) { return $null }
        $pz = Get-CheckField $Value 'z'
        if ($null -ne $pz) { [void][double]::TryParse([string]$pz, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$z) }
        return [double[]]@($x, $y, $z)
    }

    # "10,20"
    if ($Value -is [string]) {
        $parts = $Value.Split(',')
        if ($parts.Count -ge 2) {
            $x = 0.0; $y = 0.0
            if ([double]::TryParse($parts[0].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$x) -and
                [double]::TryParse($parts[1].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$y)) {
                return [double[]]@($x, $y, 0.0)
            }
        }
    }

    return $null
}

function Test-CheckFinite {
    <# 数字必须是有限的：NaN / Infinity 会让 LISP 收到 "1.#INF"，整图崩掉。 #>
    param($Value, [ref]$Out)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $false }
    $d = 0.0
    $s = [string]$Value
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $false }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }
    $Out.Value = $d
    return $true
}


# ══════════════════════════════════════════════════════════════════
#  1. 结构检查
# ══════════════════════════════════════════════════════════════════

function Test-CadSpecEntity {
    <#
      检查单个实体的字段。返回 @{ errors; warnings; type }。
      这是纯静态检查，不碰几何语义。
    #>
    param($Entity, [string]$Tag)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $rawType = Get-CheckField $Entity 'type'
    if ($null -eq $rawType -or -not ([string]$rawType).Trim()) {
        $errors.Add("$Tag 缺少 type 字段")
        return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray(); type = $null }
    }

    $type = ([string]$rawType).Trim().ToLowerInvariant()
    if (-not $script:CadSpecSchema.Contains($type)) {
        $all = ($script:CadSpecSchema.Keys -join '/')
        $errors.Add("$Tag 的 type='$type' 不受支持；可用类型：$all")
        return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray(); type = $type }
    }

    $schema = $script:CadSpecSchema[$type]
    $tmp = 0.0

    # ── 必需字段（别名组里至少有一个）──
    foreach ($req in $schema.req) {
        $spec = [string]$req.n
        $kind = [string]$req.k
        # 点列表必须走保真取值：[[0,0]] 与 [0,0] 的区别只有这一条路能看出来
        $hit = if ($kind -eq 'points2' -or $kind -eq 'points3') {
            Get-CheckAliasFieldRaw -Object $Entity -Spec $spec
        } else {
            Get-CheckAliasField -Object $Entity -Spec $spec
        }

        if ($null -eq $hit.value) {
            $shown = $spec.Replace('|', ' 或 ')
            $errors.Add("$Tag($type) 缺少必需字段 $shown")
            continue
        }

        # 别名用了非首位写法时提示一次，不打断
        $canonical = $spec.Split('|')[0]
        if ($hit.name -ne $canonical) {
            $warnings.Add("$Tag($type) 用了别名 '$($hit.name)'（规范写法是 '$canonical'），本次按等价处理")
        }

        switch ($kind) {
            'point' {
                $p = ConvertTo-CheckPoint $hit.value
                if ($null -eq $p) { $errors.Add("$Tag($type).$($hit.name) 不是合法点（要 [x,y] 或 {x,y}）") }
                else {
                    $r = $null
                    if (Test-CheckFinite $p[0] -Out ([ref]$tmp)) { $r = $tmp }
                    if ($null -eq $r) { $errors.Add("$Tag($type).$($hit.name) 的 x 不是有限数") }
                }
            }
            'points2' {
                $arr = @($hit.value)
                # 一个点写成点列表是高频错误：points:[0,0] 而不是 [[0,0]]。
                # 保真取值下它的形态是「两个数字」，这里能明确指出来。
                if ($arr.Count -ge 2 -and @($arr | Where-Object { $_ -isnot [System.Collections.IEnumerable] -or $_ -is [string] }).Count -eq $arr.Count) {
                    $errors.Add("$Tag($type).$($hit.name) 是平铺的数字数组；点列表要写嵌套数组，如 [[0,0],[10,0]]")
                    continue
                }
                if ($arr.Count -lt 2) { $errors.Add("$Tag($type).$($hit.name) 至少需要 2 个点，收到 $($arr.Count) 个") }
                $bi = 0
                foreach ($pp in $arr) {
                    if ($null -eq (ConvertTo-CheckPoint $pp)) { $errors.Add("$Tag($type).$($hit.name)[$bi] 不是合法点") }
                    $bi++
                }
            }
            'points3' {
                $arr = @($hit.value)
                if ($arr.Count -ge 3 -and @($arr | Where-Object { $_ -isnot [System.Collections.IEnumerable] -or $_ -is [string] }).Count -eq $arr.Count) {
                    $errors.Add("$Tag($type).$($hit.name) 是平铺的数字数组；点列表要写嵌套数组，如 [[0,0],[10,0],[20,5]]")
                    continue
                }
                if ($arr.Count -lt 3) { $errors.Add("$Tag($type).$($hit.name) 至少需要 3 个点，收到 $($arr.Count) 个") }
                $bi = 0
                foreach ($pp in $arr) {
                    if ($null -eq (ConvertTo-CheckPoint $pp)) { $errors.Add("$Tag($type).$($hit.name)[$bi] 不是合法点") }
                    $bi++
                }
            }
            'posnum' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) {
                    $errors.Add("$Tag($type).$($hit.name) 不是有限数")
                } elseif ($tmp -le 0) {
                    $errors.Add("$Tag($type).$($hit.name) 必须大于 0，收到 $tmp")
                }
            }
            'num' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) { $errors.Add("$Tag($type).$($hit.name) 不是有限数") }
            }
            'int3' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) { $errors.Add("$Tag($type).$($hit.name) 不是整数") }
                elseif ($tmp -lt 3) { $errors.Add("$Tag($type).$($hit.name) 至少为 3，收到 $([int]$tmp)") }
                elseif ([math]::Abs($tmp - [math]::Round($tmp)) -gt 1e-9) { $errors.Add("$Tag($type).$($hit.name) 必须是整数，收到 $tmp") }
            }
            'int1' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) { $errors.Add("$Tag($type).$($hit.name) 不是整数") }
                elseif ($tmp -lt 1) { $errors.Add("$Tag($type).$($hit.name) 至少为 1，收到 $([int]$tmp)") }
                elseif ([math]::Abs($tmp - [math]::Round($tmp)) -gt 1e-9) { $errors.Add("$Tag($type).$($hit.name) 必须是整数，收到 $tmp") }
            }
            'string' {
                if (-not ([string]$hit.value).Trim()) { $errors.Add("$Tag($type).$($hit.name) 不能是空字符串") }
            }
            'bool' {
                # 什么都当布尔，不报错
            }
        }
    }

    # ── 可选字段：给了就得对 ──
    foreach ($opt in $schema.opt) {
        $spec = [string]$opt.n
        $kind = [string]$opt.k
        $hit = Get-CheckAliasField -Object $Entity -Spec $spec
        if ($null -eq $hit.value) { continue }

        switch ($kind) {
            'point' {
                if ($null -eq (ConvertTo-CheckPoint $hit.value)) { $errors.Add("$Tag($type).$($hit.name) 不是合法点") }
            }
            'posnum' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) { $errors.Add("$Tag($type).$($hit.name) 不是有限数") }
                elseif ($tmp -le 0) { $errors.Add("$Tag($type).$($hit.name) 必须大于 0，收到 $tmp") }
            }
            'num' {
                if (-not (Test-CheckFinite $hit.value -Out ([ref]$tmp))) { $errors.Add("$Tag($type).$($hit.name) 不是有限数") }
            }
            'string' { }
            'bool' { }
        }
    }

    # ── 类型专属的额外要求 ──
    switch ($type) {
        'arc' {
            # start/end 编译器要，schema 里放 opt 是因为别名组，这里补强
            $a1 = Get-CheckAliasField -Object $Entity -Spec 'start|startAngle'
            $a2 = Get-CheckAliasField -Object $Entity -Spec 'end|endAngle'
            if ($null -eq $a1.value -and $null -eq $a2.value) {
                $errors.Add("$Tag(arc) 缺少 start 与 end（角度制）")
            } elseif ($null -eq $a1.value -or $null -eq $a2.value) {
                $errors.Add("$Tag(arc) 的 start 与 end 必须同时给")
            }
        }
        'point' {
            $hit = Get-CheckAliasField -Object $Entity -Spec 'at|c'
            if ($null -eq $hit.value) { $errors.Add("$Tag(point) 缺少 at（或 c）") }
        }
        'erase' {
            $et = Get-CheckField $Entity 'entityType'
            $ly = Get-CheckField $Entity 'layer'
            if ($null -eq $et -and $null -eq $ly) {
                $errors.Add("$Tag(erase) 需要 entityType 或 layer 之一，否则没有可删的目标")
            }
        }
    }

    return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray(); type = $type }
}


# ══════════════════════════════════════════════════════════════════
#  2. 几何检查
# ══════════════════════════════════════════════════════════════════

function Get-CadEntityPoints {
    <# 收集一个实体的所有关键点，用于包络与坐标溢出检查。 #>
    param($Entity)

    $pts = New-Object System.Collections.Generic.List[object]

    foreach ($f in @('p1', 'p2', 'p3', 'p4', 'c', 'center', 'at', 'seed', 'edge', 'textAt')) {
        $v = Get-CheckField $Entity $f
        if ($null -eq $v) { continue }
        $p = ConvertTo-CheckPoint $v
        if ($null -ne $p) { $pts.Add($p) }
    }

    # points 必须保真：[[0,0]] 展开后会变成 [0,0]，包络就算错了
    $rawPoints = Get-CheckFieldRaw $Entity 'points'
    if ($rawPoints.found) {
        foreach ($pp in @($rawPoints.value)) {
            $p = ConvertTo-CheckPoint $pp
            if ($null -ne $p) { $pts.Add($p) }
        }
    }

    # 带半径的实体要把圆周边界算进去，否则包络会明显偏小
    $tmp = 0.0
    $c = Get-CheckAliasField -Object $Entity -Spec 'c|center'
    if ($null -ne $c.value) {
        $cp = ConvertTo-CheckPoint $c.value
        if ($null -ne $cp) {
            $rHit = Get-CheckAliasField -Object $Entity -Spec 'r|radius'
            if ($null -ne $rHit.value -and (Test-CheckFinite $rHit.value -Out ([ref]$tmp)) -and $tmp -gt 0) {
                $pts.Add([double[]]@(($cp[0] - $tmp), ($cp[1] - $tmp), 0.0))
                $pts.Add([double[]]@(($cp[0] + $tmp), ($cp[1] + $tmp), 0.0))
            }
        }
    }

    return $pts.ToArray()
}

function Test-CadSpecGeometry {
    <#
      几何语义检查：schema 过得去但画出来一定错的东西。
      返回 @{ errors; warnings }。
    #>
    param($Spec, [object[]]$Entities)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $tmp = 0.0

    $seenGeom = @{}
    $i = 0
    foreach ($ent in $Entities) {
        if ($null -eq $ent) { $i++; continue }
        $type = ([string](Get-CheckField $ent 'type' '')).Trim().ToLowerInvariant()
        $tag = "entities[$i]($type)"

        # ── 坐标溢出 ──
        foreach ($p in @(Get-CadEntityPoints $ent)) {
            $ax = [math]::Abs($p[0]); $ay = [math]::Abs($p[1])
            if ($ax -gt $script:CadSpecMaxCoord -or $ay -gt $script:CadSpecMaxCoord) {
                $errors.Add("$tag 的坐标 ($([math]::Round($p[0], 3)), $([math]::Round($p[1], 3))) 超出 ±$($script:CadSpecMaxCoord)；多半是单位或小数点写错了")
                break
            }
        }

        switch ($type) {
            'rect' {
                $p1 = ConvertTo-CheckPoint (Get-CheckField $ent 'p1')
                $p2 = ConvertTo-CheckPoint (Get-CheckField $ent 'p2')
                if ($null -ne $p1 -and $null -ne $p2) {
                    $w = [math]::Abs($p2[0] - $p1[0])
                    $h = [math]::Abs($p2[1] - $p1[1])
                    if ($w -lt 1e-9 -and $h -lt 1e-9) {
                        $errors.Add("$tag 的两个角点完全重合 (p1=p2)，画不出矩形")
                    } elseif ($w -lt 1e-9) {
                        $errors.Add("$tag 的宽度为 0（p1.x = p2.x），RECTANG 会退化成一条线")
                    } elseif ($h -lt 1e-9) {
                        $errors.Add("$tag 的高度为 0（p1.y = p2.y），RECTANG 会退化成一条线")
                    }
                }
            }
            'line' {
                $p1 = ConvertTo-CheckPoint (Get-CheckField $ent 'p1')
                $p2 = ConvertTo-CheckPoint (Get-CheckField $ent 'p2')
                if ($null -ne $p1 -and $null -ne $p2) {
                    $d = [math]::Sqrt([math]::Pow($p2[0] - $p1[0], 2) + [math]::Pow($p2[1] - $p1[1], 2))
                    if ($d -lt 1e-9) { $errors.Add("$tag 的首尾点重合，长度 0") }
                }
            }
            'polyline' {
                $arr = @((Get-CheckFieldRaw $ent 'points').value)
                if ($arr.Count -ge 2) {
                    $first = ConvertTo-CheckPoint $arr[0]
                    $last = ConvertTo-CheckPoint $arr[$arr.Count - 1]
                    $closed = [bool](Get-CheckField $ent 'closed' $false)
                    if ($null -ne $first -and $null -ne $last -and -not $closed) {
                        $d = [math]::Sqrt([math]::Pow($last[0] - $first[0], 2) + [math]::Pow($last[1] - $first[1], 2))
                        if ($d -lt 1e-9) {
                            $warnings.Add("$tag 的首尾点重合但 closed=false；建议改 closed=true（否则多一个重复顶点）")
                        }
                    }
                }
            }
            'spline' {
                $arr = @((Get-CheckFieldRaw $ent 'points').value)
                $distinct = @{}
                foreach ($pp in $arr) {
                    $p = ConvertTo-CheckPoint $pp
                    if ($null -ne $p) { $distinct["$([math]::Round($p[0], 6))|$([math]::Round($p[1], 6))"] = 1 }
                }
                if ($arr.Count -ge 3 -and $distinct.Count -lt 3) {
                    $errors.Add("$tag 的 $($arr.Count) 个点里只有 $($distinct.Count) 个不同位置，画不出样条")
                }
            }
            'solid' {
                $arr = @((Get-CheckFieldRaw $ent 'points').value)
                $distinct = @{}
                foreach ($pp in $arr) {
                    $p = ConvertTo-CheckPoint $pp
                    if ($null -ne $p) { $distinct["$([math]::Round($p[0], 6))|$([math]::Round($p[1], 6))"] = 1 }
                }
                if ($distinct.Count -lt 3) {
                    $errors.Add("$tag 的有效顶点只有 $($distinct.Count) 个，SOLID 至少需要 3 个不同位置")
                }
                if ($arr.Count -gt 4) {
                    $warnings.Add("$tag 给了 $($arr.Count) 个点，SOLID 只取前 4 个")
                }
            }
            'hatch' {
                # 填充靠「内部点」定位边界，点落在图形外面就填不出东西
                $seedHit = Get-CheckAliasField -Object $ent -Spec 'seed|at'
                if ($null -eq $seedHit.value) {
                    $errors.Add("$tag 缺少 seed（或 at）内部点；没有内部点 HATCH 找不到填充边界")
                }
                $scHit = Get-CheckAliasField -Object $ent -Spec 'scale'
                if ($null -ne $scHit.value -and (Test-CheckFinite $scHit.value -Out ([ref]$tmp))) {
                    if ($tmp -gt 1000) { $warnings.Add("$tag 的 scale=$tmp 过大，填充线会稀到看不见") }
                    if ($tmp -lt 0.001) { $warnings.Add("$tag 的 scale=$tmp 过小，填充线会密到糊成一片（并显著拖慢绘图）") }
                }
            }
            'text' {
                $hHit = Get-CheckAliasField -Object $ent -Spec 'height'
                if ($null -ne $hHit.value -and (Test-CheckFinite $hHit.value -Out ([ref]$tmp)) -and $tmp -gt 10000) {
                    $warnings.Add("$tag 的 height=$tmp 异常大，文字会盖住整张图")
                }
            }
            'block' {
                foreach ($sn in @('scaleX', 'scaleY')) {
                    $sv = Get-CheckField $ent $sn
                    if ($null -ne $sv -and (Test-CheckFinite $sv -Out ([ref]$tmp)) -and [math]::Abs($tmp) -lt 1e-9) {
                        $errors.Add("$tag 的 $sn=0，块会被压成不可见的零尺寸")
                    }
                }
            }
        }

        # ── 完全重复的实体 ──
        # 同一位置同一半径的两个圆，多半是复制粘贴多出来的一段。
        # 不报错（有些图纸确实要画两遍），但值得提一句。
        if ($type -in @('circle', 'arc', 'point', 'line', 'rect')) {
            $sigParts = @($type)
            foreach ($f in @('p1', 'p2', 'c', 'center', 'at')) {
                $v = Get-CheckField $ent $f
                if ($null -eq $v) { continue }
                $p = ConvertTo-CheckPoint $v
                if ($null -ne $p) { $sigParts += "$([math]::Round($p[0], 4))_$([math]::Round($p[1], 4))" }
            }
            $rHit = Get-CheckAliasField -Object $ent -Spec 'r|radius'
            if ($null -ne $rHit.value) { $sigParts += "r$([math]::Round([double]$rHit.value, 4))" }

            $sig = $sigParts -join '|'
            if ($seenGeom.ContainsKey($sig)) {
                $warnings.Add("$tag 与 $($seenGeom[$sig]) 完全重叠（同类型同位置同尺寸），确认是否多画了一份")
            } else {
                $seenGeom[$sig] = $tag
            }
        }

        $i++
    }

    return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray() }
}


# ══════════════════════════════════════════════════════════════════
#  3. 约束检查（用户声明的 constraints）
# ══════════════════════════════════════════════════════════════════

function Test-CadSpecConstraints {
    <#
      constraints 是可选的。没写就全部跳过，不产生任何噪声。
      支持的键：
        expectedUnits   字符串，必须和顶层 units 一致
        requiredLayers  字符串数组，每个都必须在 layers[] 里声明
        maxWidth        图纸包络宽度上限
        maxHeight       图纸包络高度上限
        minGap          圆与圆之间最小间隙（净距，不是圆心距）
        requireClosed   布尔，所有 polyline 必须 closed=true
        maxEntities     实体总数上限
    #>
    param($Spec, [object[]]$Entities, [object[]]$Layers)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $cons = Get-CheckField $Spec 'constraints'
    if ($null -eq $cons) { return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray(); checked = 0 } }

    $checked = 0
    $tmp = 0.0

    # ── expectedUnits ──
    $eu = Get-CheckField $cons 'expectedUnits'
    if ($null -ne $eu) {
        $checked++
        $declared = Get-CheckField $Spec 'units'
        if ($null -eq $declared) {
            $errors.Add("constraints.expectedUnits='$eu' 但 spec 没有 units 字段，无法核对")
        } else {
            $dName = if ($declared -is [string]) { [string]$declared } else { [string](Get-CheckField $declared 'name' '') }
            if ($dName.Trim().ToLowerInvariant() -ne ([string]$eu).Trim().ToLowerInvariant()) {
                $errors.Add("constraints.expectedUnits='$eu' 与 units='$dName' 冲突")
            }
        }
    }

    # ── requiredLayers ──
    $rl = Get-CheckField $cons 'requiredLayers'
    if ($null -ne $rl) {
        $checked++
        $declaredNames = New-Object System.Collections.Generic.List[string]
        foreach ($ly in @($Layers)) {
            if ($null -eq $ly) { continue }
            $nm = [string](Get-CheckField $ly 'name' '')
            if ($nm) { $declaredNames.Add($nm.ToLowerInvariant()) }
        }
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($want in @($rl)) {
            $w = ([string]$want).Trim()
            if (-not $w) { continue }
            if (-not $declaredNames.Contains($w.ToLowerInvariant())) { $missing.Add($w) }
        }
        if ($missing.Count -gt 0) {
            $errors.Add("constraints.requiredLayers 里的图层未在 layers[] 声明：$($missing -join ', ')")
        }
    }

    # ── 包络 ──
    $minX = [double]::MaxValue; $minY = [double]::MaxValue
    $maxX = [double]::MinValue; $maxY = [double]::MinValue
    $hasPt = $false
    foreach ($ent in $Entities) {
        if ($null -eq $ent) { continue }
        foreach ($p in @(Get-CadEntityPoints $ent)) {
            if ($p[0] -lt $minX) { $minX = $p[0] }
            if ($p[1] -lt $minY) { $minY = $p[1] }
            if ($p[0] -gt $maxX) { $maxX = $p[0] }
            if ($p[1] -gt $maxY) { $maxY = $p[1] }
            $hasPt = $true
        }
    }

    $mw = Get-CheckField $cons 'maxWidth'
    if ($null -ne $mw) {
        $checked++
        if (-not $hasPt) {
            $warnings.Add('constraints.maxWidth 已声明，但没有任何实体点可用于计算包络')
        } elseif (Test-CheckFinite $mw -Out ([ref]$tmp)) {
            $w = $maxX - $minX
            if ($w -gt $tmp + 1e-9) { $errors.Add("图纸宽度 $([math]::Round($w, 3)) 超出 constraints.maxWidth=$tmp") }
        }
    }

    $mh = Get-CheckField $cons 'maxHeight'
    if ($null -ne $mh) {
        $checked++
        if (-not $hasPt) {
            $warnings.Add('constraints.maxHeight 已声明，但没有任何实体点可用于计算包络')
        } elseif (Test-CheckFinite $mh -Out ([ref]$tmp)) {
            $h = $maxY - $minY
            if ($h -gt $tmp + 1e-9) { $errors.Add("图纸高度 $([math]::Round($h, 3)) 超出 constraints.maxHeight=$tmp") }
        }
    }

    # ── 圆间最小净距 ──
    $mg = Get-CheckField $cons 'minGap'
    if ($null -ne $mg) {
        $checked++
        if (Test-CheckFinite $mg -Out ([ref]$tmp)) {
            $circles = New-Object System.Collections.Generic.List[object]
            $ci = 0
            foreach ($ent in $Entities) {
                if ($null -eq $ent) { $ci++; continue }
                $t = ([string](Get-CheckField $ent 'type' '')).Trim().ToLowerInvariant()
                if ($t -eq 'circle' -or $t -eq 'arc') {
                    $c = Get-CheckAliasField -Object $ent -Spec 'c|center'
                    $r = Get-CheckAliasField -Object $ent -Spec 'r|radius'
                    $cp = ConvertTo-CheckPoint $c.value
                    $rv = 0.0
                    if ($null -ne $cp -and $null -ne $r.value -and (Test-CheckFinite $r.value -Out ([ref]$rv))) {
                        $circles.Add([pscustomobject]@{ index = $ci; x = $cp[0]; y = $cp[1]; r = $rv })
                    }
                }
                $ci++
            }

            $a = 0
            while ($a -lt $circles.Count) {
                $b = $a + 1
                while ($b -lt $circles.Count) {
                    $c1 = $circles[$a]; $c2 = $circles[$b]
                    $d = [math]::Sqrt([math]::Pow($c2.x - $c1.x, 2) + [math]::Pow($c2.y - $c1.y, 2))
                    $gap = $d - $c1.r - $c2.r
                    if ($gap -lt $tmp - 1e-9) {
                        $errors.Add(("entities[{0}] 与 entities[{1}] 的净距 {2} 小于 constraints.minGap={3}（圆心距 {4}）" -f `
                                    $c1.index, $c2.index, [math]::Round($gap, 4), $tmp, [math]::Round($d, 4)))
                    }
                    $b++
                }
                $a++
            }
        }
    }

    # ── polyline 必须闭合 ──
    $rc = Get-CheckField $cons 'requireClosed'
    if ($null -ne $rc -and [bool]$rc) {
        $checked++
        $pi = 0
        foreach ($ent in $Entities) {
            if ($null -eq $ent) { $pi++; continue }
            $t = ([string](Get-CheckField $ent 'type' '')).Trim().ToLowerInvariant()
            if ($t -eq 'polyline' -and -not [bool](Get-CheckField $ent 'closed' $false)) {
                $errors.Add("entities[$pi](polyline) 未闭合，但 constraints.requireClosed=true")
            }
            $pi++
        }
    }

    # ── 实体总数 ──
    $me = Get-CheckField $cons 'maxEntities'
    if ($null -ne $me) {
        $checked++
        if (Test-CheckFinite $me -Out ([ref]$tmp)) {
            if ($Entities.Count -gt $tmp) {
                $errors.Add("实体总数 $($Entities.Count) 超出 constraints.maxEntities=$([int]$tmp)")
            }
        }
    }

    return @{ errors = $errors.ToArray(); warnings = $warnings.ToArray(); checked = $checked }
}


# ══════════════════════════════════════════════════════════════════
#  4. 总入口
# ══════════════════════════════════════════════════════════════════

function Test-CadSpecStrict {
    <#
      对一个已解析的 spec 对象做全套预检。
      返回 @{ ok; errors; warnings; evidence; stats }。

      ok = 没有任何 errors。warnings 不影响 ok。
      evidence 是 CadEvidence 对象数组（需要 CadEvidence.ps1 已加载）。
    #>
    param([Parameter(Mandatory)]$Spec)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[object]

    $hasEvidenceModule = $null -ne (Get-Command New-CadEvidence -ErrorAction SilentlyContinue)

    # ── 顶层结构 ──
    if ($null -eq $Spec) {
        $errors.Add('spec 是 null')
        return [pscustomobject]@{ ok = $false; errors = $errors.ToArray(); warnings = $warnings.ToArray(); evidence = $evidence.ToArray(); stats = $null }
    }
    if ($Spec -is [string] -or $Spec -is [ValueType]) {
        $errors.Add('spec 顶层必须是 JSON 对象，收到的是 ' + $Spec.GetType().Name)
        return [pscustomobject]@{ ok = $false; errors = $errors.ToArray(); warnings = $warnings.ToArray(); evidence = $evidence.ToArray(); stats = $null }
    }

    # ── 单位 ──
    $units = Get-CheckField $Spec 'units'
    $unitName = $null
    if ($null -eq $units) {
        $warnings.Add('spec 未声明 units；图纸会被当作无单位，下游按 mm 处理前请自行确认')
        if ($hasEvidenceModule) {
            $evidence.Add((New-CadEvidence -Kind 'units' -Level 'inferred' `
                        -Message 'spec 未声明 units，图纸单位只能靠下游假设' -Source 'Test-CadSpecStrict' -Supports $false))
        }
    } else {
        $unitName = if ($units -is [string]) { [string]$units } else { [string](Get-CheckField $units 'name' '') }
        $unitName = $unitName.Trim()
        if (-not $unitName) {
            $errors.Add('units 字段是空的；要写成 "mm" 这样的字符串')
        } elseif (-not ($script:CadSpecUnitNames -contains $unitName.ToLowerInvariant())) {
            $warnings.Add("units='$unitName' 不在已知单位表里；若下游要做单位换算，请改用 mm/cm/m/in/ft 等标准名")
            if ($hasEvidenceModule) {
                $evidence.Add((New-CadEvidence -Kind 'units' -Level 'inferred' `
                            -Message "units='$unitName' 无法识别，未做单位换算" -Value $unitName -Source 'Test-CadSpecStrict' -Supports $false))
            }
        } else {
            if ($hasEvidenceModule) {
                $evidence.Add((New-CadEvidence -Kind 'units' -Level 'known' `
                            -Message "spec 声明 units='$unitName'" -Value $unitName -Source 'Test-CadSpecStrict'))
            }
        }
    }

    # ── entities ──
    $entities = @(Get-CheckField $Spec 'entities' @())
    # 多视图 spec：views[] 非空时顶层 entities 允许为空（每视图的实体在
    # views[i].entities 或共享实体里，拆分后逐视图再查）
    $views = @(Get-CheckField $Spec 'views' @())
    if ($entities.Count -eq 0 -and $views.Count -eq 0) {
        $errors.Add('entities 是空的，没有可画的东西')
    }

    # ── views（多视图）──
    $viewIds = @{}
    $vi = 0
    foreach ($vw in $views) {
        if ($null -eq $vw) { $errors.Add("views[$vi] 是 null"); $vi++; continue }
        $vid = ([string](Get-CheckField $vw 'id' '')).Trim()
        if (-not $vid) {
            $errors.Add("views[$vi] 缺少 id")
        } elseif ($viewIds.ContainsKey($vid.ToLowerInvariant())) {
            $errors.Add("视图 id '$vid' 重复（views[$($viewIds[$vid.ToLowerInvariant()])] 与 views[$vi]）")
        } else {
            $viewIds[$vid.ToLowerInvariant()] = $vi
        }
        # 视图内实体也要过结构检查（拆分前就地查一遍，报错带上视图编号）
        $vent = @(Get-CheckField $vw 'entities' @())
        $vei = 0
        foreach ($ve in $vent) {
            if ($null -eq $ve) { $errors.Add("views[$vi].entities[$vei] 是 null"); $vei++; continue }
            $r = Test-CadSpecEntity -Entity $ve -Tag "views[$vi]($vid).entities[$vei]"
            foreach ($e in $r.errors) { $errors.Add($e) }
            foreach ($w in $r.warnings) { $warnings.Add($w) }
            $vei++
        }
        # 视图内实体引用的图层：同样只警告自动补建
        foreach ($ve in $vent) {
            if ($null -eq $ve) { continue }
            $ly = [string](Get-CheckField $ve 'layer' '')
            if ($ly.Trim() -and -not $layerNames.ContainsKey($ly.ToLowerInvariant())) {
                if (-not $autoLayers.ContainsKey($ly.ToLowerInvariant())) { $autoLayers[$ly.ToLowerInvariant()] = $ly }
            }
        }
        $vi++
    }

    # ── 实体 view_id 必须引用已知视图 ──
    if ($viewIds.Count -gt 0) {
        $ei = 0
        foreach ($ent in $entities) {
            if ($null -ne $ent) {
                $vref = ([string](Get-CheckField $ent 'view_id' '')).Trim()
                if ($vref -and -not $viewIds.ContainsKey($vref.ToLowerInvariant())) {
                    $errors.Add("entities[$ei] 的 view_id='$vref' 没有对应的 views[] 条目")
                }
            }
            $ei++
        }
    }

    # ── constraints.required_view_ids ──
    $conRaw = Get-CheckField $Spec 'constraints'
    if ($null -ne $conRaw) {
        $reqViews = @(Get-CheckField $conRaw 'required_view_ids' @())
        foreach ($rv in $reqViews) {
            $rkey = ([string]$rv).Trim().ToLowerInvariant()
            if ($rkey -and -not $viewIds.ContainsKey($rkey)) {
                $errors.Add("constraints.required_view_ids 里的视图 '$rv' 没有在 views[] 里定义")
            }
        }
    }


    # ── 图层 ──
    $layers = @(Get-CheckField $Spec 'layers' @())
    $layerNames = @{}
    $li = 0
    foreach ($ly in $layers) {
        if ($null -eq $ly) { $li++; continue }
        $nm = [string](Get-CheckField $ly 'name' '')
        if (-not $nm.Trim()) {
            $errors.Add("layers[$li] 缺少 name")
            $li++
            continue
        }
        $key = $nm.ToLowerInvariant()
        if ($layerNames.ContainsKey($key)) {
            $errors.Add("图层 '$nm' 重复声明（layers[$($layerNames[$key])] 与 layers[$li]）")
        } else {
            $layerNames[$key] = $li
        }
        # 图层名里的字符会原样进 (setvar "CLAYER" "...")，控制字符会毁掉 LISP
        if ($nm -match '[\r\n\t]') { $errors.Add("layers[$li] 的名字 '$nm' 含控制字符（换行/制表），会导致 LISP 源码损坏") }
        $li++
    }

    # ── 块定义 ──
    $blocks = @(Get-CheckField $Spec 'blocks' @())
    $blockNames = @{}
    $bi = 0
    foreach ($blk in $blocks) {
        if ($null -eq $blk) { $bi++; continue }
        $nm = [string](Get-CheckField $blk 'name' '')
        if (-not $nm.Trim()) { $errors.Add("blocks[$bi] 缺少 name"); $bi++; continue }
        $key = $nm.ToLowerInvariant()
        if ($blockNames.ContainsKey($key)) { $errors.Add("块名 '$nm' 重复定义（blocks[$($blockNames[$key])] 与 blocks[$bi]）") }
        else { $blockNames[$key] = $bi }
        $bents = @(Get-CheckField $blk 'entities' @())
        if ($bents.Count -eq 0) { $warnings.Add("blocks[$bi]('$nm') 没有任何实体，会建成一个空块") }
        $bei = 0
        foreach ($be in $bents) {
            $r = Test-CadSpecEntity -Entity $be -Tag "blocks[$bi]($nm).entities[$bei]"
            foreach ($e in $r.errors) { $errors.Add($e) }
            foreach ($w in $r.warnings) { $warnings.Add($w) }
            $bei++
        }
        $bi++
    }

    # ── 实体逐个结构检查 ──
    $ei = 0
    foreach ($ent in $entities) {
        if ($null -eq $ent) { $errors.Add("entities[$ei] 是 null"); $ei++; continue }
        $r = Test-CadSpecEntity -Entity $ent -Tag "entities[$ei]"
        foreach ($e in $r.errors) { $errors.Add($e) }
        foreach ($w in $r.warnings) { $warnings.Add($w) }
        $ei++
    }

    # ── 实体 id 唯一性 ──
    $ids = @{}
    $ei = 0
    foreach ($ent in $entities) {
        if ($null -ne $ent) {
            $id = Get-CheckField $ent 'id'
            if ($null -ne $id -and ([string]$id).Trim()) {
                $key = ([string]$id).Trim().ToLowerInvariant()
                if ($ids.ContainsKey($key)) {
                    $errors.Add("实体 id '$id' 重复（entities[$($ids[$key])] 与 entities[$ei]）")
                } else {
                    $ids[$key] = $ei
                }
            }
        }
        $ei++
    }

    # ── 块插入引用的名字必须存在 ──
    $ei = 0
    foreach ($ent in $entities) {
        if ($null -ne $ent) {
            $t = ([string](Get-CheckField $ent 'type' '')).Trim().ToLowerInvariant()
            if ($t -eq 'block') {
                $nm = [string](Get-CheckField $ent 'name' '')
                if ($nm.Trim() -and -not $blockNames.ContainsKey($nm.ToLowerInvariant())) {
                    $errors.Add("entities[$ei](block) 插入的块 '$nm' 没有在 blocks[] 里定义")
                }
            }
        }
        $ei++
    }

    # ── 实体引用的图层：自动补建，但要提示 ──
    # 编译器会补建颜色 7 的图层，但用户以为自己定义了样式却没生效，
    # 这属于「静默改变外观」，必须说出来。
    $autoLayers = @{}
    $ei = 0
    foreach ($ent in $entities) {
        if ($null -ne $ent) {
            $ly = [string](Get-CheckField $ent 'layer' '')
            if ($ly.Trim() -and -not $layerNames.ContainsKey($ly.ToLowerInvariant())) {
                if (-not $autoLayers.ContainsKey($ly.ToLowerInvariant())) { $autoLayers[$ly.ToLowerInvariant()] = $ly }
            }
        }
        $ei++
    }
    foreach ($k in $autoLayers.Keys) {
        $warnings.Add("图层 '$($autoLayers[$k])' 被实体引用但未在 layers[] 声明；出图时会自动补建为颜色 7 / CONTINUOUS")
    }

    # ── 几何 ──
    $geo = Test-CadSpecGeometry -Spec $Spec -Entities $entities
    foreach ($e in $geo.errors) { $errors.Add($e) }
    foreach ($w in $geo.warnings) { $warnings.Add($w) }

    # ── 约束 ──
    $con = Test-CadSpecConstraints -Spec $Spec -Entities $entities -Layers $layers
    foreach ($e in $con.errors) { $errors.Add($e) }
    foreach ($w in $con.warnings) { $warnings.Add($w) }

    # ── 存盘设置 ──
    $save = Get-CheckField $Spec 'save'
    if ($null -eq $save) {
        $warnings.Add('spec 没有 save 字段；只会得到一份临时 DWG，不会生成持久产物')
    } else {
        if ($null -eq (Get-CheckField $save 'dwg') -and $null -eq (Get-CheckField $save 'dxf') -and $null -eq (Get-CheckField $save 'pdf')) {
            $warnings.Add('save 里既没有 dwg 也没有 dxf/pdf；不会生成任何持久产物')
        }
    }

    $stats = [pscustomobject][ordered]@{
        entityCount    = $entities.Count
        blockCount     = $blocks.Count
        layerCount     = $layers.Count
        viewCount      = $views.Count
        declaredLayers = @($layerNames.Keys)
        autoLayers     = @($autoLayers.Values)
        units          = $unitName
        constraints    = $con.checked
        errorCount     = $errors.Count
        warningCount   = $warnings.Count
    }

    return [pscustomobject][ordered]@{
        ok       = ($errors.Count -eq 0)
        errors   = $errors.ToArray()
        warnings = $warnings.ToArray()
        evidence = $evidence.ToArray()
        stats    = $stats
    }
}
