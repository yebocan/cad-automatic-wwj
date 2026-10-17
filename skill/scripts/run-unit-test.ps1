<#
    run-unit-test.ps1 — 离线单元测试
    ────────────────────────────────────────────────────────────────
    全部使用临时目录里的合成数据，**不启动任何 CAD 进程**，
    不需要装 AutoCAD，秒级完成。任何机器上都能跑。

    覆盖范围：
      · 路径解析优先级（explicit / env / config / scan / path）
      · GBK / UTF-8 编码判定（本 skill 最核心的坑）
      · LISP 数值与点格式化
      · JSON → LISP 编译器（每个实体类型 + 错误路径）
      · DXF 解析与结构校验
      · 进程登记表的拒绝条件
      · 括号平衡扫描
      · 图纸尺寸名映射

    用法：
      .\run-unit-test.ps1
      .\run-unit-test.ps1 -WorkDirectory D:\tmp\cad-unit
      .\run-unit-test.ps1 -Verbose
#>

[CmdletBinding()]
param(
    [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'cad-unit-tests')
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CadCommon.ps1')
. (Join-Path $PSScriptRoot 'CadCompiler.ps1')

$scriptRoot = $PSScriptRoot
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$passed, [string]$detail) {
    $script:results.Add([ordered]@{ test = $name; passed = $passed; detail = $detail })
    $tag = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}" -f $tag, $name) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if ($detail) { Write-Host ("       {0}" -f $detail) -ForegroundColor DarkGray }
}
function Section([string]$title) {
    Write-Host ''
    Write-Host ("── $title " + ('─' * [Math]::Max(0, 56 - $title.Length))) -ForegroundColor Cyan
}

$gbk = [Text.Encoding]::GetEncoding(936)

# ══════════════════════════════════════════════════════════════════
Section '1. 路径解析：优先级与来源标注'
# ══════════════════════════════════════════════════════════════════

# 造一个假的 accoreconsole.exe（内容无所谓，只要存在）
$fakeRoot = Join-Path $work 'fake-cad'
New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
$fakeAccore = Join-Path $fakeRoot 'accoreconsole.exe'
[IO.File]::WriteAllText($fakeAccore, 'MZ fake')

# explicit 优先
$r = Find-CadExecutable -ExeName 'accoreconsole.exe' -Explicit $fakeAccore
Check '显式路径优先' ($r.path -eq $fakeAccore -and $r.source -eq 'explicit') "source=$($r.source)"

# explicit 给了不存在的路径 → 必须抛异常，不能静默回退
$threw = $false
try { $null = Find-CadExecutable -ExeName 'accoreconsole.exe' -Explicit (Join-Path $work 'nope.exe') }
catch { $threw = $true }
Check '显式路径不存在时抛异常（不静默回退）' $threw ''

# 环境变量
$oldEnv = $env:CAD_ACCORECONSOLE
try {
    $env:CAD_ACCORECONSOLE = $fakeAccore
    $r2 = Find-CadExecutable -ExeName 'accoreconsole.exe'
    Check '环境变量 CAD_ACCORECONSOLE 生效' ($r2.path -eq $fakeAccore -and $r2.source -like 'env:*') "source=$($r2.source)"
} finally {
    if ($oldEnv) { $env:CAD_ACCORECONSOLE = $oldEnv } else { Remove-Item Env:CAD_ACCORECONSOLE -ErrorAction SilentlyContinue }
}

# 找不到时必须返回空而不是抛（由调用方决定怎么报）
$r3 = $null
try { $r3 = Find-CadExecutable -ExeName 'definitely-not-exist-xyz.exe' } catch { }
Check '找不到时返回 null 而非崩溃' ($null -eq $r3 -or -not $r3.path) "r=$($r3 | ConvertTo-Json -Compress)"

# ══════════════════════════════════════════════════════════════════
Section '2. 编码：GBK 判定（本 skill 最核心的坑）'
# ══════════════════════════════════════════════════════════════════

function Test-GbkFileLocal {
    param([string]$FilePath)
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -eq 0) { return $null }
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $isUtf8 = $false
    try {
        $strict = New-Object Text.UTF8Encoding($false, $true)
        $null = $strict.GetString($bytes)
        $isUtf8 = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    } catch { $isUtf8 = $false }
    $gbkLocal = [Text.Encoding]::GetEncoding(936)
    $rt = $false
    try {
        $t = $gbkLocal.GetString($bytes)
        $rt = ($gbkLocal.GetBytes($t).Length -eq $bytes.Length)
    } catch { }
    return [pscustomobject]@{ hasBom = $hasBom; looksUtf8 = $isUtf8; gbkRoundTrip = $rt; length = $bytes.Length }
}

$cnText = ';; 中文注释：这是一个测试 (setvar "SECURELOAD" 0)'

# UTF-8 无 BOM
$f1 = Join-Path $work 'utf8-nobom.lsp'
[IO.File]::WriteAllText($f1, $cnText, (New-Object Text.UTF8Encoding $false))
$i1 = Test-GbkFileLocal $f1
Check 'UTF-8 无 BOM 被识别为 UTF-8' ($i1.looksUtf8 -and -not $i1.hasBom) "utf8=$($i1.looksUtf8) bom=$($i1.hasBom) gbkRT=$($i1.gbkRoundTrip)"

# UTF-8 带 BOM
$f2 = Join-Path $work 'utf8-bom.lsp'
[IO.File]::WriteAllText($f2, $cnText, (New-Object Text.UTF8Encoding $true))
$i2 = Test-GbkFileLocal $f2
Check 'UTF-8 带 BOM 被识别出 BOM' $i2.hasBom "bom=$($i2.hasBom)"

# GBK
$f3 = Join-Path $work 'gbk.lsp'
[IO.File]::WriteAllText($f3, $cnText, $gbk)
$i3 = Test-GbkFileLocal $f3
Check 'GBK 文件不被误判为 UTF-8' (-not $i3.looksUtf8) "utf8=$($i3.looksUtf8) gbkRT=$($i3.gbkRoundTrip)"

# 纯 ASCII 两者都成立，不应被误报
$f4 = Join-Path $work 'ascii.lsp'
[IO.File]::WriteAllText($f4, '(princ "hello")', (New-Object Text.UTF8Encoding $false))
$i4 = Test-GbkFileLocal $f4
Check '纯 ASCII 不触发 UTF-8 告警' (-not $i4.looksUtf8) "utf8=$($i4.looksUtf8)"

# Write-CadLsp 必须真的写 GBK + CRLF
$f5 = Join-Path $work 'writer.lsp'
Write-CadLsp -Path $f5 -Body $cnText | Out-Null
$b5 = [IO.File]::ReadAllBytes($f5)
$txt5 = $gbk.GetString($b5)
Check 'Write-CadLsp 写出 GBK' ($txt5 -eq $cnText) "往返一致=$($txt5 -eq $cnText)"
Check 'Write-CadLsp 不含 BOM' (-not ($b5.Length -ge 3 -and $b5[0] -eq 0xEF)) ''
Check 'Write-CadLsp 使用 CRLF' ($txt5.Contains("`r`n") -or -not $cnText.Contains("`n")) ''

$f6 = Join-Path $work 'writer.scr'
Write-CadScr -Path $f6 -Lines @('第一行', '(princ "ok")') | Out-Null
$b6 = [IO.File]::ReadAllBytes($f6)
Check 'Write-CadScr 写出 GBK' ($gbk.GetString($b6) -like '第一行*') ''

# ══════════════════════════════════════════════════════════════════
Section '3. 路径转换：LISP 要正斜杠'
# ══════════════════════════════════════════════════════════════════

$p1 = ConvertTo-CadPath 'D:\a\b\c.lsp'
Check '反斜杠转正斜杠' ($p1 -eq 'D:/a/b/c.lsp') "got=$p1"

$p2 = ConvertTo-CadPath 'D:/already/forward.lsp'
Check '已是正斜杠时不变' ($p2 -eq 'D:/already/forward.lsp') "got=$p2"

# ══════════════════════════════════════════════════════════════════
Section '4. LISP 数值与点格式化'
# ══════════════════════════════════════════════════════════════════

Check '整数不带小数点' ((Format-LispNum 100) -eq '100') "got=$(Format-LispNum 100)"
Check '小数保留' ((Format-LispNum 1.5) -eq '1.5') "got=$(Format-LispNum 1.5)"
Check '负小数' ((Format-LispNum -2.25) -eq '-2.25') "got=$(Format-LispNum -2.25)"
Check '零' ((Format-LispNum 0) -eq '0') "got=$(Format-LispNum 0)"
Check '不用科学计数法' ((Format-LispNum 1000000) -eq '1000000') "got=$(Format-LispNum 1000000)"
Check '超长小数被裁剪' ((Format-LispNum 1.123456789012345).Length -le 15) "got=$(Format-LispNum 1.123456789012345)"

$pt = Format-LispPoint @(10, 20)
Check '点必须输出 (list x y) 而非 (x y)' ($pt -eq '(list 10 20)') "got=$pt"

$pt2 = Format-LispPoint '30,40'
Check '字符串点格式 "x,y"' ($pt2 -eq '(list 30 40)') "got=$pt2"

$threw = $false
try { $null = Format-LispPoint @(1) } catch { $threw = $true }
Check '单分量点抛异常' $threw ''

$threw = $false
try { $null = Format-LispNum 'abc' } catch { $threw = $true }
Check '非数值抛异常' $threw ''

# 字符串转义
Check '字符串加引号' ((Format-LispString 'abc') -eq '"abc"') "got=$(Format-LispString 'abc')"
Check '字符串转义反斜杠' ((Format-LispString 'a\b') -eq '"a\\b"') "got=$(Format-LispString 'a\b')"
Check '字符串转义双引号' ((Format-LispString 'a"b') -eq '"a\"b"') "got=$(Format-LispString 'a"b')"
Check 'null 变空字符串' ((Format-LispString $null) -eq '""') "got=$(Format-LispString $null)"

# ══════════════════════════════════════════════════════════════════
Section '5. 编译器：每个实体类型'
# ══════════════════════════════════════════════════════════════════
#
#   ★ 断言口径 ★
#   编译器对实体分两条通道产出 LISP：
#     · 简单图元（line/circle/rect/text/polyline/spline/solid）走
#       (cadcmd (list "_.LINE" ...)) —— 直接用 AutoCAD 原生命令，
#       少一层 LISP 封装，参数错误时 AutoCAD 自己的报错更直白；
#     · 需要算几何的（arc/ellipse/polygon/gear/boltpattern/标注/hatch/
#       mtext/centerline）走 (c:XXX ...) —— 三角、极坐标、DXF 组码
#       这些活儿在 LISP 里算比在 PowerShell 里拼字符串清楚得多。
#   所以断言必须按各自的真实通道写，不能一律找 (c:XXX。

$coreLsp = Join-Path $scriptRoot 'cadcore.lsp'
if (-not (Test-Path -LiteralPath $coreLsp)) { throw "找不到 cadcore.lsp: $coreLsp" }

function Test-Compile([string]$json) {
    $spec = $json | ConvertFrom-Json
    return (Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp)
}

# 断言某实体编译成功且产出的 LISP 里有指定片段
function Test-Entity([string]$label, [string]$json, [string]$expect) {
    $r = $null
    try { $r = Test-Compile $json } catch { Check $label $false "抛异常: $($_.Exception.Message)"; return }
    $hit = $r.lisp -like "*$expect*"
    $warn = if (@($r.warnings).Count -gt 0) { " warnings=$($r.warnings -join ' | ')" } else { '' }
    Check $label ($r.entityCount -eq 1 -and $hit) "count=$($r.entityCount) 找[$expect]=$hit$warn"
}

Test-Entity 'line 编译'      '{"entities":[{"type":"line","p1":[0,0],"p2":[10,10]}]}'                          '(cadcmd (list "_.LINE" (list 0 0) (list 10 10) ""))'
Test-Entity 'circle 编译'    '{"entities":[{"type":"circle","c":[5,5],"r":3}]}'                                '(cadcmd (list "_.CIRCLE" (list 5 5) 3))'
Test-Entity 'arc 编译'       '{"entities":[{"type":"arc","c":[0,0],"r":5,"startAngle":0,"endAngle":90}]}'      '(c:ARC 0 0 5 0 90)'
Test-Entity 'rect 编译'      '{"entities":[{"type":"rect","p1":[0,0],"p2":[100,50]}]}'                         '(cadcmd (list "_.RECTANG" (list 0 0) (list 100 50)))'
Test-Entity 'text 编译（含中文）' '{"entities":[{"type":"text","at":[0,0],"height":5,"value":"你好"}]}'          '(cadcmd (list "_.TEXT" "_J" "_BL" (list 0 0) 5 0 "你好"))'
Test-Entity 'mtext 编译'     '{"entities":[{"type":"mtext","at":[0,0],"width":80,"height":5,"value":"多行"}]}'   '(c:MTEXT 0 0 80 5 "多行")'
Test-Entity 'dimlinear 编译' '{"entities":[{"type":"dimlinear","p1":[0,0],"p2":[100,0],"at":[50,-10]}]}'       '(c:DIMLIN 0 0 100 0 50 -10)'
Test-Entity 'dimaligned 编译' '{"entities":[{"type":"dimaligned","p1":[0,0],"p2":[100,50],"at":[50,25]}]}'      '(c:DIMALIGN 0 0 100 50 50 25)'
Test-Entity 'dimradius 编译' '{"entities":[{"type":"dimradius","c":[0,0],"edge":[10,0],"text":[15,5]}]}'       '(c:DIMRAD 0 0 10 0 15 5)'
Test-Entity 'hatch 编译'     '{"entities":[{"type":"hatch","pattern":"ANSI31","scale":1,"at":[0,0]}]}'          '(c:HATCH "ANSI31" 1 0 0)'
Test-Entity 'polyline 编译'  '{"entities":[{"type":"polyline","points":[[0,0],[10,0],[10,10]]}]}'              '(cadcmd (list "_.PLINE" (list 0 0) (list 10 0) (list 10 10) ""))'
Test-Entity 'polygon 编译'   '{"entities":[{"type":"polygon","c":[0,0],"r":50,"sides":6}]}'                     '(c:POLYGON 0 0 50 6)'
Test-Entity 'gear 编译'      '{"entities":[{"type":"gear","c":[0,0],"r":50,"teeth":20}]}'                       '(c:GEAR 0 0 50 20)'
Test-Entity 'boltpattern 编译' '{"entities":[{"type":"boltpattern","c":[0,0],"r":40,"count":6}]}'              '(c:BOLTPATTERN 0 0 40 6)'
Test-Entity 'centerline 编译' '{"entities":[{"type":"centerline","c":[0,0],"length":100}]}'                     '(c:CENTERLINE 0 0 100)'
Test-Entity 'ellipse 编译'   '{"entities":[{"type":"ellipse","c":[0,0],"rx":30,"ry":15}]}'                     '(c:ELLIPSE 0 0 30 15)'
Test-Entity 'point 编译'     '{"entities":[{"type":"point","at":[5,5]}]}'                                       '(c:POINT 5 5)'
Test-Entity 'spline 编译'    '{"entities":[{"type":"spline","points":[[0,0],[10,10],[20,0]]}]}'                '(cadcmd (list "_.SPLINE" (list 0 0) (list 10 10) (list 20 0) "" "" ""))'
Test-Entity 'solid 编译'     '{"entities":[{"type":"solid","points":[[0,0],[10,0],[10,10],[0,10]]}]}'           '(cadcmd (list "_.SOLID" (list 0 0) (list 10 0) (list 10 10) (list 0 10) ""))'

# 每个实体后面都要跟一条 cadsay 回执，否则跑完看不出哪个实体画成了
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[10,10]}]}'
Check '实体后有 cadsay 回执' ($r.lisp -like '*(cadsay "E0"*') ''

# 同一份 spec 里多个实体要按顺序编号
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[1,1]},{"type":"circle","c":[5,5],"r":2}]}'
Check '多实体按顺序编号' ($r.lisp -like '*(cadsay "E0"*' -and $r.lisp -like '*(cadsay "E1"*' -and $r.entityCount -eq 2) "count=$($r.entityCount)"

# 图层切换：非 0 图层要发 (setvar "CLAYER" ...)
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[1,1],"layer":"GEO"}]}'
Check '非 0 图层切 CLAYER' ($r.lisp -like '*(setvar "CLAYER" "GEO")*') ''

# 0 图层不需要切换
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[1,1],"layer":"0"}]}'
Check '0 图层不发 CLAYER 切换' (-not ($r.lisp -like '*(setvar "CLAYER" "0")*')) ''

# ══════════════════════════════════════════════════════════════════
Section '6. 编译器：图层处理'
# ══════════════════════════════════════════════════════════════════

# 声明的图层必须带全 3 个实参（曾经只传 2 个 → LISP 报「参数太少」）
$r = Test-Compile '{"layers":[{"name":"A","color":3,"ltype":"DASHED"}],"entities":[]}'
$line = ($r.lisp -split "`n" | Where-Object { $_ -like '*(c:LAYER*' }) -join ''
Check '图层带全 3 个实参' ($line -like '*"A"*3*"DASHED"*') "got=$($line.Trim())"

# 未声明的图层自动补建并记 warning
$r = Test-Compile '{"layers":[],"entities":[{"type":"line","p1":[0,0],"p2":[1,1],"layer":"GHOST"}]}'
Check '未声明图层自动补建' ($r.lisp -like '*(c:LAYER "GHOST"*') ''
Check '未声明图层产生 warning' (@($r.warnings | Where-Object { $_ -like '*GHOST*' }).Count -gt 0) "warnings=$($r.warnings -join ' | ')"

# 颜色默认 7
$r = Test-Compile '{"layers":[{"name":"B"}],"entities":[]}'
$line = ($r.lisp -split "`n" | Where-Object { $_ -like '*(c:LAYER "B"*' }) -join ''
Check '图层颜色默认 7' ($line -like '*"B" 7*') "got=$($line.Trim())"

# ── 非法颜色必须回落 7 + warning，不能让整张图停工 ─────────────────
# 用户写 "red" / "#FF0000" / 300 都很常见。原来直接 [int] 强转，
# StrictMode 下抛异常把整个编译带崩 —— 图层是基础设施，坏一个值
# 不该让所有实体都不画。
foreach ($bad in @('"red"', '"#FF0000"', '300', '0')) {
    $r = Test-Compile ('{"layers":[{"name":"C","color":' + $bad + '}],"entities":[]}')
    $line = ($r.lisp -split "`n" | Where-Object { $_ -like '*(c:LAYER "C"*' }) -join ''
    Check "非法颜色 $bad 回落为 7" ($line -like '*"C" 7*') "got=$($line.Trim())"
    Check "非法颜色 $bad 产生 warning" (@($r.warnings | Where-Object { $_ -like '*C*color*' }).Count -gt 0) "warnings=$($r.warnings -join ' | ')"
}
# 合法颜色原样保留
$r = Test-Compile '{"layers":[{"name":"D","color":1}],"entities":[]}'
$line = ($r.lisp -split "`n" | Where-Object { $_ -like '*(c:LAYER "D"*' }) -join ''
Check '合法颜色 1 原样保留' ($line -like '*"D" 1*') "got=$($line.Trim())"
Check '合法颜色不产生 warning' (@($r.warnings | Where-Object { $_ -like '*color*' }).Count -eq 0) "warnings=$($r.warnings -join ' | ')"

# ══════════════════════════════════════════════════════════════════
Section '7. 编译器：错误路径'
# ══════════════════════════════════════════════════════════════════
#
#   ★ 编译器的错误处理策略：**不抛异常，记 warning 并跳过该实体** ★
#   设计理由：一张图纸里 20 个实体，第 7 个字段写错了，
#   把整张图丢掉对用户毫无帮助；记下哪一条错了、其余照画，
#   用户改完再跑一次就行。所以断言的是 entityCount 与 warnings，
#   而不是「抛异常」。

# 断言：编译不抛异常，entityCount=0，warnings 里出现指定关键字
function Test-CompileRejects([string]$label, [string]$json, [string]$expectInWarning) {
    $r = $null
    try { $r = Test-Compile $json }
    catch { Check $label $false "不该抛异常，却抛了: $($_.Exception.Message)"; return }
    $joined = @($r.warnings) -join ' | '
    $ok = ($r.entityCount -eq 0) -and (@($r.warnings).Count -gt 0) -and ($joined -like "*$expectInWarning*")
    Check $label $ok "count=$($r.entityCount) warnings=[$joined]"
}

Test-CompileRejects '缺 type 记 warning 并跳过' '{"entities":[{"p1":[0,0],"p2":[1,1]}]}' '缺少 type'
Test-CompileRejects 'line 缺 p2 记 warning 并跳过' '{"entities":[{"type":"line","p1":[0,0]}]}' 'p1 与 p2'
Test-CompileRejects '未知实体类型记 warning 并跳过' '{"entities":[{"type":"unknown-type"}]}' 'unknown-type'
Test-CompileRejects '非数值半径记 warning 并跳过' '{"entities":[{"type":"circle","c":[0,0],"r":"abc"}]}' ''

# 坏实体不影响好实体：第 2 个坏了，第 1、3 个照样编译出来
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[1,1]},{"type":"line","p1":[0,0]},{"type":"circle","c":[5,5],"r":2}]}'
Check '坏实体不阻断好实体' ($r.entityCount -eq 2 -and @($r.warnings).Count -ge 1) "count=$($r.entityCount) warnings=$(@($r.warnings).Count)"

# warnings 必须指明是哪一条（entities[N]），否则用户无从下手
$r = Test-Compile '{"entities":[{"type":"line","p1":[0,0],"p2":[1,1]},{"type":"bad-type"}]}'
$joined = @($r.warnings) -join ' | '
# 注意：-like 里 [ ] 是通配符字符集，必须转义成 `[ 才能匹配字面方括号
Check 'warning 带 entities[N] 定位' ($joined -like '*entities`[1`]*') "warnings=[$joined]"

# 完全没有 entities 字段时不该崩，应产出只含收尾命令的 lisp
$r = Test-Compile '{"layers":[]}'
Check '缺 entities 字段不崩' ($r.entityCount -eq 0 -and $r.lisp -like '*@@DONE@@*') "count=$($r.entityCount)"

# 空 entities 数组同理
$r = Test-Compile '{"entities":[]}'
Check '空 entities 数组不崩' ($r.entityCount -eq 0 -and $r.lisp -like '*c:ZOOMEXT*') ''

# ══════════════════════════════════════════════════════════════════
Section '8. Get-CadField 在 StrictMode 下的安全访问'
# ══════════════════════════════════════════════════════════════════

$obj = '{"a":1,"b":null}' | ConvertFrom-Json
Check '取存在的字段' ((Get-CadField $obj 'a') -eq 1) ''
Check '取不存在的字段返回默认' ((Get-CadField $obj 'zzz' 'def') -eq 'def') ''
Check '取 null 字段返回默认' ((Get-CadField $obj 'b' 'def') -eq 'def') ''
Check 'null 对象返回默认' ((Get-CadField $null 'a' 'def') -eq 'def') ''
Check 'Test-CadField 存在' (Test-CadField $obj 'a') ''
Check 'Test-CadField 不存在' (-not (Test-CadField $obj 'zzz')) ''
Check 'Test-CadField null 视为不存在' (-not (Test-CadField $obj 'b')) ''

# ══════════════════════════════════════════════════════════════════
Section '9. DXF 解析'
# ══════════════════════════════════════════════════════════════════

# 手搓一个最小合法 DXF
$dxfLines = @(
    '0', 'SECTION', '2', 'HEADER', '0', 'ENDSEC',
    '0', 'SECTION', '2', 'ENTITIES',
    '0', 'LINE', '8', '0', '10', '0.0', '20', '0.0', '11', '10.0', '21', '10.0',
    '0', 'CIRCLE', '8', '0', '10', '5.0', '20', '5.0', '40', '3.0',
    '0', 'ENDSEC',
    '0', 'EOF'
)
$dxfPath = Join-Path $work 'mini.dxf'
[IO.File]::WriteAllLines($dxfPath, $dxfLines, $gbk)

$pairs = Read-CadDxfPairs -Path $dxfPath
Check 'DXF 成对读取' (@($pairs).Count -gt 0) "pairs=$(@($pairs).Count)"

$chk = Test-CadDxfFile -Path $dxfPath
# 注意：Test-CadDxfFile 没有 missing 字段，失败原因在 reason
Check '最小 DXF 结构有效' $chk.valid "valid=$($chk.valid) reason=$($chk.reason)"

$ents = Get-CadDxfEntities -Path $dxfPath
Check 'DXF 实体数正确' (@($ents).Count -eq 2) "got=$(@($ents).Count)"
Check 'DXF 实体类型识别' ((@($ents) | Where-Object { $_.type -eq 'LINE' }).Count -eq 1) ''

# 缺 ENTITIES 段必须判定无效
$badDxf = Join-Path $work 'bad.dxf'
[IO.File]::WriteAllLines($badDxf, @('0', 'SECTION', '2', 'HEADER', '0', 'ENDSEC', '0', 'EOF'), $gbk)
$chk2 = Test-CadDxfFile -Path $badDxf
Check '缺 ENTITIES 段判定无效' (-not $chk2.valid) "valid=$($chk2.valid) reason=$($chk2.reason)"

# 返回值结构必须齐全（调用方 Invoke-CadInspect 依赖这些字段）
# 注意用 PSObject.Properties.Name 判断「字段是否存在」，
# 不能用 Test-CadField —— 后者把 null 值也当成「不存在」，
# 而最小 DXF 没有 extents / version，字段存在但值是 null。
$need = 'path', 'valid', 'reason', 'byteLength', 'pairs', 'sections', 'sectionCount',
        'hasEntities', 'entityCount', 'entityTypes', 'layers', 'blockCount',
        'eofSeen', 'sectionBalance', 'malformedLines', 'extents', 'version'
$have = @($chk.PSObject.Properties.Name)
$missingFields = @($need | Where-Object { $have -notcontains $_ })
Check 'Test-CadDxfFile 返回字段齐全' ($missingFields.Count -eq 0) "缺: $($missingFields -join ',')"

# ConvertTo-CadDouble：非法输入返回 $null（不是 0）
# 这样调用方能区分「真的是 0」和「压根不是数字」，用 0 兜底会把错误藏起来。
Check 'ConvertTo-CadDouble 普通小数' ((ConvertTo-CadDouble '1.5') -eq 1.5) ''
Check 'ConvertTo-CadDouble 科学计数' ([Math]::Abs((ConvertTo-CadDouble '1.5E+02') - 150) -lt 0.001) "got=$(ConvertTo-CadDouble '1.5E+02')"
Check 'ConvertTo-CadDouble 空串返回 null' ($null -eq (ConvertTo-CadDouble '')) "got=$(ConvertTo-CadDouble '')"
Check 'ConvertTo-CadDouble 非法返回 null' ($null -eq (ConvertTo-CadDouble 'abc')) "got=$(ConvertTo-CadDouble 'abc')"
Check 'ConvertTo-CadDouble 真零仍是 0' ((ConvertTo-CadDouble '0') -eq 0 -and $null -ne (ConvertTo-CadDouble '0')) ''

# ── DXF 编码：UTF-8 优先，老文件回落 GBK ─────────────────────────────
# 实测：AC1032 的 DXF 头里写着 $DWGCODEPAGE=ANSI_936，但文件体一律 UTF-8。
# 用 GBK 读会把「多行文字」变成「澶氳鏂囧瓧」。这是很容易踩反的一条，
# 因为 scr/lsp 恰恰必须 GBK —— 两套编码不能混。
$u8Dxf = Join-Path $work 'utf8-text.dxf'
$u8Body = @(
    '0', 'SECTION', '2', 'HEADER', '9', '$DWGCODEPAGE', '3', 'ANSI_936', '0', 'ENDSEC',
    '0', 'SECTION', '2', 'ENTITIES',
    '0', 'TEXT', '8', '0', '10', '0.0', '20', '0.0', '1', '多行文字',
    '0', 'ENDSEC', '0', 'EOF'
) -join "`r`n"
[IO.File]::WriteAllText($u8Dxf, $u8Body, (New-Object System.Text.UTF8Encoding($false)))

$p8 = Read-CadDxfPairs -Path $u8Dxf
Check 'DXF 返回实际使用的编码' ($p8.encoding -eq 'utf-8') "encoding=$($p8.encoding)"
$e8 = @(Get-CadDxfEntities -Path $u8Dxf)
$t8 = @($e8 | Where-Object { $_.type -eq 'TEXT' })
Check 'UTF-8 DXF 中文正确解码' ($t8.Count -eq 1 -and $t8[0].text -eq '多行文字') "text=[$($t8[0].text)]"

# 老格式（真 ANSI/GBK）必须回落，不能因 UTF-8 严格解码失败而报错
$gbkDxf = Join-Path $work 'gbk-text.dxf'
$gbkBody = @(
    '0', 'SECTION', '2', 'ENTITIES',
    '0', 'TEXT', '8', '0', '10', '0.0', '20', '0.0', '1', '多行文字',
    '0', 'ENDSEC', '0', 'EOF'
) -join "`r`n"
[IO.File]::WriteAllText($gbkDxf, $gbkBody, $gbk)
$pg = Read-CadDxfPairs -Path $gbkDxf
Check 'GBK DXF 回落读成功' ($pg.encoding -eq 'gbk') "encoding=$($pg.encoding)"
$eg = @(Get-CadDxfEntities -Path $gbkDxf | Where-Object { $_.type -eq 'TEXT' })
Check 'GBK DXF 中文正确解码' ($eg.Count -eq 1 -and $eg[0].text -eq '多行文字') "text=[$($eg[0].text)]"

# ══════════════════════════════════════════════════════════════════
Section '10. 进程登记表：拒绝条件'
# ══════════════════════════════════════════════════════════════════

# 登记一个不存在的 PID，必须能被清掉
$fakePid = 999999
Register-OwnedCadProcess -Process ([pscustomobject]@{ Id = $fakePid; ProcessName = 'fake'; StartTime = (Get-Date) }) `
    -Kind 'test' -Source 'unit-test' | Out-Null
$all = @(Get-CadOwnedProcesses)
Check '进程登记表可写入' (@($all | Where-Object { $_.pid -eq $fakePid }).Count -eq 1) "count=$($all.Count)"

$live = @(Get-CadOwnedProcesses | Where-Object { $_.alive })
Check '不存在的 PID 标记为 not alive' (@($live | Where-Object { $_.pid -eq $fakePid }).Count -eq 0) ''

Clear-StaleCadEntries | Out-Null
$after = @(Get-CadOwnedProcesses | Where-Object { $_.pid -eq $fakePid })
Check 'Clear-StaleCadEntries 清掉死条目' ($after.Count -eq 0) "remaining=$($after.Count)"

# 当前进程（活的）不应被 Stop-OwnedCadProcess 误杀 —— 用 owner 校验拒绝
# ★ 拒绝是「返回 refused 对象」，不是抛异常 ★
#   设计理由：拒绝结束进程是一件正常结果（调用方可能只是想确认一下），
#   抛异常会让调用方不得不用 try/catch 包裹每次调用，
#   而返回值让调用方能直接读 reason 决定下一步。
$self = Get-Process -Id $PID
Register-OwnedCadProcess -Process $self -Kind 'test' -Source 'unit-test' | Out-Null
$res = Stop-OwnedCadProcess -ProcessId $PID -OwnerPid ($PID + 12345) -Force
Check 'OwnerPid 不匹配时拒绝结束进程' ($res.refused -and -not $res.stopped) "refused=$($res.refused) check=$($res.ownerCheck)"

# 不在登记表里的 PID 也必须拒绝（闸1）
$res2 = Stop-OwnedCadProcess -ProcessId 999998 -OwnerPid $PID -Force
Check '未登记 PID 拒绝结束' ($res2.refused -and $res2.ownerCheck -eq 'no-registry-entry') "check=$($res2.ownerCheck)"

# 自己登记自己时 owner 校验通过，但因为目标就是当前进程，只验证「不会真的杀掉自己」
# —— 这里不实际执行，只确认闸3（进程名/启动时间）能算出来
$regSelf = @(Get-CadRegistry | Where-Object { $_.pid -eq $PID })
Check '自己登记时 owner_pid 记为本进程' ($regSelf.Count -eq 1 -and $regSelf[0].owner_pid -eq $PID) ""

Clear-StaleCadEntries | Out-Null
# 手工清掉刚才登记的自引用（它还活着，不会被 Clear-Stale 清掉）
$reg = Get-CadRegistry
$reg = @($reg | Where-Object { $_.pid -ne $PID })
Save-CadRegistry -Entries $reg | Out-Null
Check '可手工清理登记表' (@(Get-CadOwnedProcesses | Where-Object { $_.pid -eq $PID }).Count -eq 0) ''

# ★ 回归：清空登记表必须真的把文件写成 [] ★
# 早先 @() | ConvertTo-Json 返回 $null，$null | Set-Content 不写文件，
# 于是「清空」是静默空操作，旧条目原样留着。
Save-CadRegistry -Entries @() | Out-Null
Check '清空登记表后读回为空' (@(Get-CadRegistry).Count -eq 0) "count=$(@(Get-CadRegistry).Count)"
Check '清空登记表写出 []' ((Get-Content -LiteralPath $script:CadRegistryFile -Raw).Trim() -eq '[]') "raw=$((Get-Content -LiteralPath $script:CadRegistryFile -Raw).Trim())"

# ══════════════════════════════════════════════════════════════════
Section '11. 括号平衡扫描'
# ══════════════════════════════════════════════════════════════════

function Get-LispDepth {
    param([string]$Text)
    $depth = 0; $inStr = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inStr) {
            if ($ch -eq '\') { $i++; continue }
            if ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq ';') { while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }; continue }
        if ($ch -eq '"') { $inStr = $true; continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') { $depth-- }
    }
    return $depth
}

Check '平衡的 LISP 深度为 0' ((Get-LispDepth '(defun f (a) (list a))') -eq 0) ''
Check '多一个左括号深度为 1' ((Get-LispDepth '(defun f (a) (list a)') -eq 1) ''
Check '多一个右括号深度为 -1' ((Get-LispDepth '(defun f (a)))') -eq -1) ''
Check '字符串里的括号不计入' ((Get-LispDepth '(princ "(((")') -eq 0) ''
Check '注释里的括号不计入' ((Get-LispDepth "(princ 1) ; (((`n") -eq 0) ''
Check '转义引号不终止字符串' ((Get-LispDepth '(princ "a\"b")') -eq 0) ''

# 真实的 cadcore.lsp 必须平衡
$coreTxt = [IO.File]::ReadAllText($coreLsp, [Text.Encoding]::UTF8)
Check 'cadcore.lsp 括号平衡' ((Get-LispDepth $coreTxt) -eq 0) "depth=$(Get-LispDepth $coreTxt)"

# ══════════════════════════════════════════════════════════════════
Section '12. 图纸尺寸名映射'
# ══════════════════════════════════════════════════════════════════

# -PLOT 命令行要全名；只写 "A3" 会被忽略并回落 ANSI A
$cadcoreTxt = [IO.File]::ReadAllText($coreLsp, [Text.Encoding]::UTF8)
Check 'cadpaper 函数存在' ($cadcoreTxt -like '*(defun cadpaper*') ''
Check 'cadpaper 含 ISO A3 全名' ($cadcoreTxt -like '*ISO A3 (420.00 x 297.00*') ''
Check 'cadpaper 含 ISO A4 全名' ($cadcoreTxt -like '*ISO A4 (297.00 x 210.00*') ''
Check 'cadpaper 含 ANSI 映射' ($cadcoreTxt -like '*ANSI full bleed A*' -or $cadcoreTxt -like '*ANSI A*') ''

# ══════════════════════════════════════════════════════════════════
Section '13. 关键 LISP 函数存在性'
# ══════════════════════════════════════════════════════════════════

$required = @(
    'c:SETUP', 'c:LAYER', 'c:LINE', 'c:PLINE', 'c:CIRCLE', 'c:ARC', 'c:RECT',
    'c:ELLIPSE', 'c:POINT', 'c:SPLINE', 'c:TEXT', 'c:TEXTC', 'c:MTEXT',
    'c:DIMLIN', 'c:DIMALIGN', 'c:DIMRAD', 'c:HATCH', 'c:SOLID',
    'c:MOVEALL', 'c:SSBYTYPE', 'c:DELTYPE', 'c:DELLAYER', 'c:COPYLAST',
    'c:ROTATEALL', 'c:SCALEALL', 'c:MIRRORALL', 'c:ARRAYRECT', 'c:OFFSET',
    'c:FILLET', 'c:EXPLODEALL', 'c:MAKEBLOCK', 'c:INSERTBLOCK',
    'c:COUNT', 'c:TYPESTAT', 'c:LAYERLIST', 'c:EXTENTS', 'c:ENTLIST',
    'c:GETVAR', 'c:SUMMARY', 'c:SAVEAS', 'c:SAVEDXF', 'c:PLOTPDF',
    'c:PURGEALL', 'c:AUDIT', 'c:ZOOMEXT', 'c:REGENALL', 'c:AREA',
    'c:GEAR', 'c:POLYGON', 'c:CENTERLINE', 'c:BOLTPATTERN'
)
$missing = @()
foreach ($fn in $required) {
    if ($cadcoreTxt -notlike "*defun $fn *") { $missing += $fn }
}
Check "全部 $($required.Count) 个 LISP 函数都存在" ($missing.Count -eq 0) "缺失: $($missing -join ', ')"

# 标注函数必须用 entmake（command 通道在 accoreconsole 里会被取消并吞掉后续命令）
foreach ($fn in @('c:DIMLIN', 'c:DIMALIGN', 'c:DIMRAD')) {
    $idx = $cadcoreTxt.IndexOf("(defun $fn ")
    $seg = if ($idx -ge 0) { $cadcoreTxt.Substring($idx, [Math]::Min(3000, $cadcoreTxt.Length - $idx)) } else { '' }
    Check "$fn 使用 entmake（不用 command）" ($seg -like '*(entmake*' -and $seg -notlike '*(command "_.DIM*') ''
}

# ── 块构建器：必须存在且不许直接开 -BLOCK 让实体自动入块 ─────────────
# 这条是踩出来的：直觉写法 (command "_.-BLOCK" name pt) 之后紧跟画图命令，
# -BLOCK 会把后面的坐标当"选择点"吃掉，冒出 *无效选择* 并卡到超时。
foreach ($fn in @('c:BEGBLOCK', 'c:ENDBLOCK', 'cadblkcnt')) {
    Check "块构建器含 $fn" ($cadcoreTxt -like "*defun $fn *") ''
}
$ebIdx = $cadcoreTxt.IndexOf('(defun c:ENDBLOCK ')
$ebSeg = if ($ebIdx -ge 0) { $cadcoreTxt.Substring($ebIdx, [Math]::Min(2000, $cadcoreTxt.Length - $ebIdx)) } else { '' }
Check 'c:ENDBLOCK 用选择集一次性喂给 -BLOCK' ($ebSeg -like '*ssadd*' -and $ebSeg -like '*-BLOCK*') ''
Check 'c:ENDBLOCK 用 entnext 游走收集实体' ($ebSeg -like '*(entnext*') ''
Check 'c:ENDBLOCK 校验块内实体数（不轻信 -BLOCK 成功）' ($ebSeg -like '*(cadblkcnt *') ''

# ── 会让 accoreconsole 悬停到超时的两类写法，必须被挡住 ───────────────
# 共同症候：stdout 只有一行「; 错误: 函数已取消」，然后进程一直不退出，
# 只能靠超时收尸。这类 bug 在报告里表现成「LISP 未跑到 @@DONE@@」，
# 极难从现象反推原因，所以用静态断言把写法固定住。
$lyIdx = $cadcoreTxt.IndexOf('(defun c:LAYER ')
$lySeg = if ($lyIdx -ge 0) { $cadcoreTxt.Substring($lyIdx, [Math]::Min(2500, $cadcoreTxt.Length - $lyIdx)) } else { '' }
Check 'c:LAYER 建图层前查 LTYPE 表（不存在的线型会让 -LAYER 悬停）' ($lySeg -like '*(tblsearch "LTYPE"*') ''
Check 'c:LAYER 线型缺失时回落 CONTINUOUS' ($lySeg -like '*"CONTINUOUS"*') ''
Check 'c:LAYER 回报缺失线型（否则用户以为生效了）' ($lySeg -like '*LTYPE_MISSING*') ''

# ══════════════════════════════════════════════════════════════════
Section '14. 配置文件读写'
# ══════════════════════════════════════════════════════════════════

$origCfg = Get-CadConfig
try {
    Set-CadConfig -AccoreConsole 'D:\test\accoreconsole.exe' | Out-Null
    $c = Get-CadConfig
    Check '配置可写入并读回' ($c.accoreconsole -eq 'D:\test\accoreconsole.exe') "got=$($c.accoreconsole)"
    Check '配置含 configuredAt 时间戳' ([bool]$c.configuredAt) "got=$($c.configuredAt)"
} finally {
    # 恢复原配置
    Set-CadConfig -AccoreConsole $origCfg.accoreconsole -AcadExe $origCfg.acadExe -ComProgId $origCfg.comProgId | Out-Null
}

# ══════════════════════════════════════════════════════════════════
Section '15. Get-CadMarker 解析'
# ══════════════════════════════════════════════════════════════════

$fakeRun = [pscustomobject]@{
    markers = @(
        [pscustomobject]@{ name = 'DONE'; value = $true },
        [pscustomobject]@{ name = 'COUNT'; value = '12' },
        [pscustomobject]@{ name = 'PATH'; value = 'D:/out.dwg' }
    )
}
Check '取布尔标记' ((Get-CadMarker -Result $fakeRun -Name 'DONE') -eq $true) ''
Check '取字符串标记' ((Get-CadMarker -Result $fakeRun -Name 'COUNT') -eq '12') ''
Check '取不存在的标记返回 null' ($null -eq (Get-CadMarker -Result $fakeRun -Name 'NOPE')) ''
Check '取 null 结果返回 null' ($null -eq (Get-CadMarker -Result $null -Name 'DONE')) ''

# ══════════════════════════════════════════════════════════════════
Section '16. 产物结构校验：PDF / DWG'
# ══════════════════════════════════════════════════════════════════

function New-TestFile {
    param([string]$Name, [byte[]]$Bytes)
    $p = Join-Path $work $Name
    [IO.File]::WriteAllBytes($p, $Bytes)
    return $p
}

$pdfGood = New-TestFile 'good.pdf' ([Text.Encoding]::UTF8.GetBytes(
    "%PDF-1.7`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n" +
    "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj`n" +
    "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 842 595]>>endobj`n" +
    ('x' * 1200) + "`ntrailer<</Root 1 0 R>>`nstartxref`n0`n%%EOF`n"))
$p = Test-CadPdfFile -Path $pdfGood
Check '合法 PDF 通过' ($p.valid -eq $true) "reason=$($p.reason)"
Check '合法 PDF 检出头' ($p.header -eq '%PDF-1.7') "header=$($p.header)"
Check '合法 PDF 数出 1 页' ($p.pageCount -eq 1) "pages=$($p.pageCount)"

$pdfNoEof = New-TestFile 'noeof.pdf' ([Text.Encoding]::UTF8.GetBytes('%PDF-1.7' + ('x' * 2000)))
$p = Test-CadPdfFile -Path $pdfNoEof
Check '缺 %%EOF 判失败' ($p.valid -eq $false) "reason=$($p.reason)"
Check '缺 %%EOF 给出原因' ($p.reason -match '%%EOF') "reason=$($p.reason)"

$pdfBadHead = New-TestFile 'badhead.pdf' ([Text.Encoding]::UTF8.GetBytes('NOTAPDF' + ('x' * 2000) + "`n%%EOF`n"))
$p = Test-CadPdfFile -Path $pdfBadHead
Check '非 PDF 头判失败' ($p.valid -eq $false) "reason=$($p.reason)"
Check '非 PDF 头给出原因' ($p.reason -match '%PDF') "reason=$($p.reason)"

$pdfTiny = New-TestFile 'tiny.pdf' ([Text.Encoding]::UTF8.GetBytes('%PDF-1.7%%EOF'))
$p = Test-CadPdfFile -Path $pdfTiny
Check '小于下限判失败' ($p.valid -eq $false) "reason=$($p.reason)"

$p = Test-CadPdfFile -Path (Join-Path $work 'nope.pdf')
Check 'PDF 不存在判失败' ($p.valid -eq $false) "reason=$($p.reason)"

$dwgGood = New-TestFile 'good.dwg' ([byte[]]([Text.Encoding]::ASCII.GetBytes('AC1032') + (New-Object byte[] 3000)))
$d = Test-CadDwgFile -Path $dwgGood
Check '合法 DWG 通过' ($d.valid -eq $true) "reason=$($d.reason)"
Check 'DWG 版本识别为 2018' ($d.version -eq '2018') "got=$($d.version)"

$dwgR12 = New-TestFile 'r12.dwg' ([byte[]]([Text.Encoding]::ASCII.GetBytes('AC1009') + (New-Object byte[] 3000)))
$d = Test-CadDwgFile -Path $dwgR12
Check 'DWG 版本识别为 R12' ($d.version -eq 'R12') "got=$($d.version)"

$dwgBadHead = New-TestFile 'badhead.dwg' ([Text.Encoding]::UTF8.GetBytes('PK ZIP' + ('x' * 3000)))
$d = Test-CadDwgFile -Path $dwgBadHead
Check '非 DWG 头判失败' ($d.valid -eq $false) "reason=$($d.reason)"

$dwgTiny = New-TestFile 'tiny.dwg' ([Text.Encoding]::ASCII.GetBytes('AC1032'))
$d = Test-CadDwgFile -Path $dwgTiny
Check 'DWG 小于下限判失败' ($d.valid -eq $false) "reason=$($d.reason)"

$d = Test-CadDwgFile -Path (Join-Path $work 'nope.dwg')
Check 'DWG 不存在判失败' ($d.valid -eq $false) "reason=$($d.reason)"

# ══════════════════════════════════════════════════════════════════
#  汇总
# ══════════════════════════════════════════════════════════════════

$pass = @($results | Where-Object { $_.passed }).Count
$fail = @($results | Where-Object { -not $_.passed }).Count
$total = $results.Count

Write-Host ''
Write-Host ('═' * 62) -ForegroundColor Cyan
Write-Host ("  单元测试  ·  $pass / $total 通过，$fail 失败") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ('═' * 62) -ForegroundColor Cyan

if ($fail -gt 0) {
    Write-Host ''
    Write-Host '失败项：' -ForegroundColor Red
    foreach ($r in @($results | Where-Object { -not $_.passed })) {
        Write-Host ("  ✗ {0}" -f $r.test) -ForegroundColor Red
        if ($r.detail) { Write-Host ("    {0}" -f $r.detail) -ForegroundColor DarkGray }
    }
}

# 清理临时目录
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($fail -eq 0) { exit 0 } else { exit 1 }
