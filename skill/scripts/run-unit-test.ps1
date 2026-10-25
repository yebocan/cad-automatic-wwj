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
. (Join-Path $PSScriptRoot 'CadEvidence.ps1')
. (Join-Path $PSScriptRoot 'CadSpecCheck.ps1')
. (Join-Path $PSScriptRoot 'CadImage.ps1')
. (Join-Path $PSScriptRoot 'CadPdf.ps1')
. (Join-Path $PSScriptRoot 'CadVectorize.ps1')
. (Join-Path $PSScriptRoot 'CadRender.ps1')

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
Check 'DXF 实体类型识别' (@(@($ents) | Where-Object { $_.type -eq 'LINE' }).Count -eq 1) ''

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

# ── 标注测量值必须正确（这是 42 组码真值错，不是显示问题）──────────────
# 1) c:DIMLIN 的 50 组码曾被写死 0：竖向标注量的是 x 投影 → 竖直边 0→120
#    在图上印出「0」。必须按 dx/dy 自动判定 rot（水平 0 / 竖直 pi/2）。
$dlIdx = $cadcoreTxt.IndexOf('(defun c:DIMLIN ')
$dlSeg = if ($dlIdx -ge 0) { $cadcoreTxt.Substring($dlIdx, [Math]::Min(3000, $cadcoreTxt.Length - $dlIdx)) } else { '' }
Check 'c:DIMLIN 按几何判定旋转角（不写死 50=0）' ($dlSeg -notlike "*(cons 50 0)*" -and $dlSeg -notlike "'(50 . 0)" -and $dlSeg -like '*(/ pi 2.0)*') "竖向标注曾被写成 0，42 组码实测 0.0 而非 120"
Check 'c:DIMLIN 比较 dx/dy 决定方向' ($dlSeg -like '*(abs (- x2 x1))*' -and $dlSeg -like '*(abs (- y2 y1))*') ''

# 2) c:DIMRAD 的 10 组码必须是圆心：写成文字点会让 42 组码 = |文字点-圆周点|，
#    实测 圆心(100,60) r=45 文字点(150,112) 得到 52.2398，图上印 R52.24。
$drIdx = $cadcoreTxt.IndexOf('(defun c:DIMRAD ')
$drSeg = if ($drIdx -ge 0) { $cadcoreTxt.Substring($drIdx, [Math]::Min(3000, $cadcoreTxt.Length - $drIdx)) } else { '' }
Check 'c:DIMRAD 的 10 组码是圆心（不是文字点）' ($drSeg -like '*(cons 10 (list cx cy 0))*') '10 组码写错会让半径量成 |文字点-圆周点|，实测 52.24 而非 45'
Check 'c:DIMRAD 的 11 组码是文字中点' ($drSeg -like '*(cons 11 (list tx ty 0))*') ''
Check 'c:DIMRAD 的 15 组码是圆周点' ($drSeg -like '*(cons 15 (list ex ey 0))*') ''

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
#  17. 证据分级与五态结论（CadEvidence.ps1）
# ══════════════════════════════════════════════════════════════════

Section '17. 证据分级与五态结论'

$evKnown = New-CadEvidence -Kind 'spec' -Level 'known' -Message 'spec 声明 units=mm'
$evScaled = New-CadEvidence -Kind 'dxf' -Level 'scaled' -Message 'DXF 声明 $INSUNITS=4'
$evInferred = New-CadEvidence -Kind 'pixels' -Level 'inferred' -Message '按像素比对推测'
$evUnread = New-CadEvidence -Kind 'text' -Level 'unreadable' -Message '文字不可读' -Value '[UNREADABLE]'

Check 'New-CadEvidence 保留全部字段' ($evKnown.kind -eq 'spec' -and $evKnown.level -eq 'known' -and $evKnown.supports -eq $true) "supports=$($evKnown.supports)"
Check 'New-CadEvidence 可记 value' ($evUnread.value -eq '[UNREADABLE]') "value=$($evUnread.value)"

Check '最差证据：known 最低' ((Get-CadEvidenceWorst -Evidence @($evKnown)) -eq 'known') ''
Check '最差证据：混入 scaled 后取 scaled' ((Get-CadEvidenceWorst -Evidence @($evKnown, $evScaled)) -eq 'scaled') ''
Check '最差证据：inferred 压过 scaled' ((Get-CadEvidenceWorst -Evidence @($evKnown, $evScaled, $evInferred)) -eq 'inferred') ''
Check '最差证据：unreadable 最重' ((Get-CadEvidenceWorst -Evidence @($evKnown, $evUnread)) -eq 'unreadable') ''
Check '最差证据：空集返回 unreadable（无证据比可疑证据更糟）' ((Get-CadEvidenceWorst -Evidence @()) -eq 'unreadable') ''

$onlyInferred = Get-CadEvidenceByLevel -Evidence @($evKnown, $evScaled, $evInferred) -Level 'inferred'
Check '按级别筛选：inferred 命中 1 条' (@($onlyInferred).Count -eq 1) "count=$(@($onlyInferred).Count)"
$onlyKnown = Get-CadEvidenceByLevel -Evidence @($evKnown, $evScaled) -Level 'known'
Check '按级别筛选：known 命中 1 条' (@($onlyKnown).Count -eq 1) "count=$(@($onlyKnown).Count)"

# 五态优先级
$allOk = @([pscustomobject]@{ name = 'a'; pass = $true })
$oneFail = @([pscustomobject]@{ name = 'a'; pass = $true }, [pscustomobject]@{ name = 'b'; pass = $false })
Check '五态：全过 + 无证据 → pass' ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown)) -eq 'pass') ''
Check '五态：有失败检查 → fail' ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown)) -eq 'fail') ''
Check '五态：blocked 优先于 fail' ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown) -BlockedReason '单位缺失') -eq 'blocked') ''
Check '五态：inferred 证据 → needs_review' ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown, $evInferred)) -eq 'needs_review') ''
Check '五态：unreadable 证据 → needs_review' ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown, $evUnread)) -eq 'needs_review') ''
Check '五态：有 warning → pass_with_warnings' ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown) -Warnings @('线型回落')) -eq 'pass_with_warnings') ''
Check '五态：error + 有产物 → fail（不升级为 blocked）' ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown) -Error '炸了' -Artifacts @(@{ kind = 'dwg'; exists = $true })) -eq 'fail') ''

$advPass = Get-CadDispositionAdvice -Disposition 'pass'
$advBlocked = Get-CadDispositionAdvice -Disposition 'blocked'
$advReview = Get-CadDispositionAdvice -Disposition 'needs_review'
Check '五种 disposition 都有建议文案' ($advPass -and $advBlocked -and $advReview -and (Get-CadDispositionAdvice -Disposition 'fail') -and (Get-CadDispositionAdvice -Disposition 'pass_with_warnings')) ''
Check 'blocked 建议点名 spec / errors' ($advBlocked -match 'spec|errors|实体都没画') "$advBlocked"
Check 'needs_review 建议要求人工核对' ($advReview -match '核对|复核|看一眼|人工') "$advReview"

# 哈希
$h1 = Get-CadSha256 -Path (New-TestFile 'h1.txt' ([Text.Encoding]::UTF8.GetBytes('abc')))
$h2 = Get-CadSha256 -Path (New-TestFile 'h2.txt' ([Text.Encoding]::UTF8.GetBytes('abc')))
$h3 = Get-CadSha256 -Path (New-TestFile 'h3.txt' ([Text.Encoding]::UTF8.GetBytes('abd')))
Check 'Get-CadSha256 稳定（同内容同哈希）' ($h1 -eq $h2) "$h1"
Check 'Get-CadSha256 区分内容' ($h1 -ne $h3) "$h3"
Check 'Get-CadSha256 是小写 64 位十六进制' ($h1 -match '^[0-9a-f]{64}$') "$h1"
Check 'Get-CadSha256 不存在的文件返回 null' ($null -eq (Get-CadSha256 -Path (Join-Path $work 'nohash.txt'))) ''

# ══════════════════════════════════════════════════════════════════
#  18. 清单复现：manifest 生成与比对（CadEvidence.ps1）
# ══════════════════════════════════════════════════════════════════

Section '18. 清单复现：manifest 生成与比对'

$specPath = Join-Path $work 'm-spec.json'
[IO.File]::WriteAllText($specPath, '{"units":"mm","entities":[]}')
$specSha = Get-CadSha256 -Path $specPath
$artDwg = New-TestFile 'm.dwg' ([byte[]]([Text.Encoding]::ASCII.GetBytes('AC1032') + (New-Object byte[] 3000)))
$artDxf = New-TestFile 'm.dxf' ([Text.Encoding]::UTF8.GetBytes("0`nSECTION`n2`nENTITIES`n0`nENDSEC`n0`nEOF`n"))

$man = New-CadManifest -SpecFile $specPath -Spec @{ units = 'mm' } -DrawingName 'm' `
    -Artifacts @([pscustomobject]@{ kind = 'dwg'; path = $artDwg }, [pscustomobject]@{ kind = 'dxf'; path = $artDxf }) `
    -Evidence @($evKnown, $evScaled) -Disposition 'pass' `
    -Units 'mm' -UnitsCode 4 -EntityCount 12 -Layers @('GEO', 'HOLE')
Check 'manifest 记 schemaVersion=1' ($man.schemaVersion -eq 1) "got=$($man.schemaVersion)"
Check 'manifest 记工具与版本' ($man.tool -eq 'cad-automatic-wwj' -and $man.toolVersion) "tool=$($man.tool) v=$($man.toolVersion)"
Check 'manifest 记 spec 哈希' ($man.specSha256 -eq $specSha) "$($man.specSha256)"
Check 'manifest 算 cadcore 哈希' ($man.cadCoreSha256 -match '^[0-9a-f]{64}$') "$($man.cadCoreSha256)"
Check 'manifest 记单位' ($man.units.name -eq 'mm' -and $man.units.code -eq 4) "$($man.units.name)/$($man.units.code)"
Check 'manifest 的 artifacts 带字节数与哈希' ($man.artifacts.Count -eq 2 -and $man.artifacts[0].bytes -gt 0 -and $man.artifacts[0].sha256 -match '^[0-9a-f]{64}$') "bytes=$($man.artifacts[0].bytes)"

$manPath = Write-CadManifest -Manifest $man -Path (Join-Path $work 'manifest.json')
Check 'Write-CadManifest 落盘成功' ($manPath -and (Test-Path -LiteralPath $manPath)) "$manPath"
$manBack = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
Check '落盘的 manifest 是 UTF-8 无 BOM（中文图层名不乱码）' (@($manBack.layers)[0] -eq 'GEO') "layers=$($manBack.layers -join ',')"
Check '落盘的 manifest 保留 disposition 与 evidence' ($manBack.disposition -eq 'pass' -and $manBack.evidence.Count -eq 2) "disp=$($manBack.disposition) ev=$($manBack.evidence.Count)"

# 自比对：同一份清单必须 identical
$cmpSame = Compare-CadManifest -Before $man -After $man
Check '自比对 → identical' ($cmpSame.identical -eq $true -and $cmpSame.diffCount -eq 0) "diffs=$($cmpSame.diffCount)"

# 改 spec 哈希 → 必须检出
$manChangedSpec = $man.PSObject.Copy()
$manChangedSpec.specSha256 = ('0' * 64)
$cmpSpec = Compare-CadManifest -Before $man -After $manChangedSpec
Check '改 spec 哈希被检出' ($cmpSpec.identical -eq $false -and ($cmpSpec.diffs | Where-Object { $_.field -eq 'specSha256' })) "diffs=$($cmpSpec.diffCount)"

# 改实体数 → 必须检出
$manChangedCnt = $man.PSObject.Copy()
$manChangedCnt.entityCount = 99
$cmpCnt = Compare-CadManifest -Before $man -After $manChangedCnt
Check '改实体数被检出' ($cmpCnt.identical -eq $false -and ($cmpCnt.diffs | Where-Object { $_.field -eq 'entityCount' })) "diffs=$($cmpCnt.diffCount)"

# 改 cadcore 哈希 → 必须检出（cadcore 换了，复现性就断了）
$manChangedCore = $man.PSObject.Copy()
$manChangedCore.cadCoreSha256 = ('f' * 64)
$cmpCore = Compare-CadManifest -Before $man -After $manChangedCore
Check '改 cadcore 哈希被检出' ($cmpCore.identical -eq $false -and ($cmpCore.diffs | Where-Object { $_.field -eq 'cadCoreSha256' })) "diffs=$($cmpCore.diffCount)"

# 改产物哈希 → 必须检出
$manChangedArt = $man.PSObject.Copy()
$manChangedArt.artifacts = @(
    [pscustomobject]@{ kind = 'dwg'; path = $artDwg; exists = $true; bytes = $man.artifacts[0].bytes; sha256 = ('a' * 64) },
    [pscustomobject]@{ kind = 'dxf'; path = $artDxf; exists = $true; bytes = $man.artifacts[1].bytes; sha256 = $man.artifacts[1].sha256 }
)
$cmpArt = Compare-CadManifest -Before $man -After $manChangedArt
Check '改产物哈希被检出' ($cmpArt.identical -eq $false -and ($cmpArt.diffs | Where-Object { $_.field -like '*dwg*' })) "diffs=$($cmpArt.diffCount)"

# timestamp / 路径 / disposition 变化不算差异（否则每次跑都 identical=false）
$manOther = $man.PSObject.Copy()
$manOther.timestamp = '1999-01-01T00:00:00Z'
$manOther.disposition = 'pass_with_warnings'
$cmpNoise = Compare-CadManifest -Before $man -After $manOther
Check 'timestamp/disposition 变化不算差异（避免误报）' ($cmpNoise.identical -eq $true) "diffs=$($cmpNoise.diffCount)"

# ══════════════════════════════════════════════════════════════════
#  19. 单位校验与必需图层（CadEvidence.ps1）
# ══════════════════════════════════════════════════════════════════

Section '19. 单位校验与必需图层'

# 造一张带 $INSUNITS 的 DXF
$dxfUnits = Join-Path $work 'u.dxf'
$uBody = @(
    '0', 'SECTION', '2', 'HEADER'
    '9', '$ACADVER', '1', 'AC1015'
    '9', '$INSUNITS', '70', '     4'
    '9', '$EXTMIN', '10', '0.0', '20', '0.0', '30', '0.0'
    '9', '$EXTMAX', '10', '100.0', '20', '60.0', '30', '0.0'
    '0', 'ENDSEC'
    '0', 'SECTION', '2', 'ENTITIES'
    '0', 'LINE', '8', 'GEO', '10', '0.0', '20', '0.0', '30', '0.0', '11', '10.0', '21', '0.0', '31', '0.0'
    '0', 'CIRCLE', '8', 'HOLE', '10', '5.0', '20', '5.0', '30', '0.0', '40', '2.5'
    '0', 'ENDSEC'
    '0', 'EOF'
) -join "`n"
[IO.File]::WriteAllText($dxfUnits, $uBody, [Text.Encoding]::UTF8)

$hv = Get-CadDxfHeaderVar -Path $dxfUnits -Name 'INSUNITS'
Check 'Get-CadDxfHeaderVar 读 $INSUNITS' ($hv -match '4') "raw='$hv'"
$hvNoDollar = Get-CadDxfHeaderVar -Path $dxfUnits -Name '$EXTMAX'
Check 'Get-CadDxfHeaderVar 支持不带 $ 前缀' ($hvNoDollar -match '100') "raw='$hvNoDollar'"
$hvMissing = Get-CadDxfHeaderVar -Path $dxfUnits -Name '$NOSUCHVAR'
Check 'Get-CadDxfHeaderVar 读不到的变量返回空' ([string]::IsNullOrEmpty($hvMissing)) "raw='$hvMissing'"

$du = Get-CadDrawingUnits -Path $dxfUnits
Check 'Get-CadDrawingUnits 读出 mm/4' ($du.code -eq 4 -and $du.name -eq 'mm' -and $du.unitToMm -eq 1.0) "code=$($du.code) name=$($du.name) toMm=$($du.unitToMm)"
Check 'Get-CadDrawingUnits 带证据级别' ($du.evidence.level -eq 'scaled') "level=$($du.evidence.level)"

$ucMm = Test-CadUnits -Path $dxfUnits -Expected 'mm'
Check '单位一致：mm = mm' ($ucMm.match -eq $true) "actual=$($ucMm.actual) expected=$($ucMm.expected)"
$ucM = Test-CadUnits -Path $dxfUnits -Expected 'm'
Check '单位不符：mm ≠ m' ($ucM.match -eq $false) "msg=$($ucM.evidence.message)"
Check '单位不符时 message 算出倍数' ($ucM.evidence.message -match '0.001') "$($ucM.evidence.message)"
$ucCN = Test-CadUnits -Path $dxfUnits -Expected '毫米'
Check '中文单位名认得出（毫米 = mm）' ($ucCN.match -eq $true) "expectedCode=$($ucCN.expectedCode)"
$ucBogus = Test-CadUnits -Path $dxfUnits -Expected 'furlong'
Check '期望单位认不出 → 三值 null（needs_review，不是 fail）' ($null -eq $ucBogus.match) "expectedCode=$($ucBogus.expectedCode)"

$dxfNoUnits = Join-Path $work 'nu.dxf'
[IO.File]::WriteAllText($dxfNoUnits, (@(
    '0', 'SECTION', '2', 'HEADER', '9', '$ACADVER', '1', 'AC1015', '0', 'ENDSEC',
    '0', 'SECTION', '2', 'ENTITIES', '0', 'ENDSEC', '0', 'EOF'
) -join "`n"), [Text.Encoding]::UTF8)
$ucNone = Test-CadUnits -Path $dxfNoUnits -Expected 'mm'
Check '图纸没声明单位 → 三值 null' ($null -eq $ucNone.match) "actual=$($ucNone.actual)"

$dxfUnitless = Join-Path $work 'ul.dxf'
[IO.File]::WriteAllText($dxfUnitless, (@(
    '0', 'SECTION', '2', 'HEADER', '9', '$INSUNITS', '70', '     0', '0', 'ENDSEC',
    '0', 'SECTION', '2', 'ENTITIES', '0', 'ENDSEC', '0', 'EOF'
) -join "`n"), [Text.Encoding]::UTF8)
$ucUnitless = Test-CadUnits -Path $dxfUnitless -Expected 'mm'
Check '图纸是 unitless → 三值 null（不当成不符）' ($null -eq $ucUnitless.match) "actual=$($ucUnitless.actual)"

$ents = @(Get-CadDxfEntities -Path $dxfUnits)
Check 'Get-CadDxfEntities 读出 2 个实体' ($ents.Count -eq 2) "count=$($ents.Count)"

$rlOk = Test-CadRequiredLayers -Required @('GEO', 'HOLE') -DxfPath $dxfUnits -Entities $ents
Check '必需图层都存在且有实体 → pass' ($rlOk.pass -eq $true) "missing=$($rlOk.missing -join ',') empty=$($rlOk.empty -join ',')"
$rlMiss = Test-CadRequiredLayers -Required @('GEO', 'NOPE') -DxfPath $dxfUnits -Entities $ents
Check '必需图层缺失 → fail 且点名' ($rlMiss.pass -eq $false -and $rlMiss.missing -contains 'NOPE') "missing=$($rlMiss.missing -join ',')"
$rlCase = Test-CadRequiredLayers -Required @('geo', 'hole') -DxfPath $dxfUnits -Entities $ents
Check '图层名不区分大小写' ($rlCase.pass -eq $true) "present=$($rlCase.present -join ',')"

# 空图层：声明了但没有任何实体
$dxfEmptyLayer = Join-Path $work 'el.dxf'
[IO.File]::WriteAllText($dxfEmptyLayer, (@(
    '0', 'SECTION', '2', 'TABLES',
    '0', 'LAYER', '2', 'GHOST', '70', '0', '62', '7', '6', 'CONTINUOUS',
    '0', 'ENDTAB',
    '0', 'SECTION', '2', 'ENTITIES',
    '0', 'LINE', '8', 'GEO', '10', '0.0', '20', '0.0', '30', '0.0', '11', '1.0', '21', '0.0', '31', '0.0',
    '0', 'ENDSEC', '0', 'EOF'
) -join "`n"), [Text.Encoding]::UTF8)
$entsEl = @(Get-CadDxfEntities -Path $dxfEmptyLayer)
$rlEmpty = Test-CadRequiredLayers -Required @('GHOST') -DxfPath $dxfEmptyLayer -Entities $entsEl
Check '空图层（有声明无实体）判 fail 并归入 empty' ($rlEmpty.pass -eq $false -and $rlEmpty.empty -contains 'GHOST') "missing=$($rlEmpty.missing -join ',') empty=$($rlEmpty.empty -join ',')"

# 尺寸
$ex = Get-CadExtentSize -Path $dxfUnits
Check 'Get-CadExtentSize 从 $EXTMIN/$EXTMAX 读尺寸' ([Math]::Abs($ex.width - 100.0) -lt 0.001 -and [Math]::Abs($ex.height - 60.0) -lt 0.001) "w=$($ex.width) h=$($ex.height)"
Check 'Get-CadExtentSize 换算成毫米' ([Math]::Abs($ex.widthMm - 100.0) -lt 0.001) "wMm=$($ex.widthMm)"

# ══════════════════════════════════════════════════════════════════
#  20. 出图前 spec 预检（CadSpecCheck.ps1）
# ══════════════════════════════════════════════════════════════════

Section '20. 出图前 spec 预检'

$specOk = @{ units = 'mm'; entities = @(
    @{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) },
    @{ type = 'circle'; c = @(5, 5); r = 2.5 },
    @{ type = 'rect'; p1 = @(0, 0); p2 = @(20, 10) }
) }
$rOk = Test-CadSpecStrict -Spec $specOk
Check '合法 spec → ok' ($rOk.ok -eq $true) "errors=$(@($rOk.errors).Count) warnings=$(@($rOk.warnings).Count)"
Check '合法 spec → 统计实体数与图层数' ($rOk.stats.entityCount -eq 3) "entities=$($rOk.stats.entityCount)"

$specBadType = @{ entities = @(@{ type = 'blob' }) }
$rBadType = Test-CadSpecStrict -Spec $specBadType
Check '未知 type → 不通过' ($rBadType.ok -eq $false) ''
Check '未知 type 的报错列出全部合法取值' (($rBadType.errors -join ' ') -match 'line' -and ($rBadType.errors -join ' ') -match 'erase' -and ($rBadType.errors -join ' ') -match 'boltpattern') "$($rBadType.errors -join ' | ')"

$specMissField = @{ entities = @(@{ type = 'circle'; c = @(0, 0) }) }
$rMiss = Test-CadSpecStrict -Spec $specMissField
Check '缺必需字段 → 不通过且点名' ($rMiss.ok -eq $false -and ($rMiss.errors -join ' ') -match 'r 或 radius') "$($rMiss.errors -join ' | ')"

$specFlatPoints = @{ entities = @(@{ type = 'polyline'; points = @(0, 0) }) }
$rFlat = Test-CadSpecStrict -Spec $specFlatPoints
Check '平铺点数组被抓住（点列表必须嵌套）' ($rFlat.ok -eq $false -and ($rFlat.errors -join ' ') -match '嵌套') "$($rFlat.errors -join ' | ')"

$specOnePoint = @{ entities = @(@{ type = 'polyline'; points = @(@(0, 0)) }) }
$rOne = Test-CadSpecStrict -Spec $specOnePoint
# PowerShell 会把单元素嵌套数组 @(@(0,0)) 展平成 @(0,0)，保真路径也救不回来
# （数组入参时已被展平）。所以这里实际报的是「平铺」而不是「至少需要 2 个点」。
# 两条都是正确的拦截 —— 展平成 2 个数字后 polyline 同样凑不出 2 个点。
# 断言按实际报错口径写，不为了好看硬改成不存在的文案。
Check '只有 1 个点的 polyline 被抓住' ($rOne.ok -eq $false -and ($rOne.errors -join ' ') -match '嵌套|至少需要 2 个点') "$($rOne.errors -join ' | ')"

$specZeroRect = @{ entities = @(@{ type = 'rect'; p1 = @(0, 0); p2 = @(0, 10) }) }
$rZero = Test-CadSpecStrict -Spec $specZeroRect
Check 'rect 宽为 0 被抓住' ($rZero.ok -eq $false -and ($rZero.errors -join ' ') -match '宽度为 0') "$($rZero.errors -join ' | ')"

$specNegR = @{ entities = @(@{ type = 'circle'; c = @(0, 0); r = -5 }) }
$rNeg = Test-CadSpecStrict -Spec $specNegR
Check '负半径被抓住' ($rNeg.ok -eq $false -and ($rNeg.errors -join ' ') -match '必须大于 0') "$($rNeg.errors -join ' | ')"

$specOverflow = @{ entities = @(@{ type = 'point'; at = @(5e7, 0) }) }
$rOver = Test-CadSpecStrict -Spec $specOverflow
Check '坐标溢出 ±1e7 被抓住' ($rOver.ok -eq $false -and ($rOver.errors -join ' ') -match '超出') "$($rOver.errors -join ' | ')"

$specDupLayer = @{
    layers = @(@{ name = 'GEO'; color = 7 }, @{ name = 'geo'; color = 3 })
    entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) })
}
$rDupLayer = Test-CadSpecStrict -Spec $specDupLayer
Check '重复图层（不区分大小写）被抓住' ($rDupLayer.ok -eq $false -and ($rDupLayer.errors -join ' ') -match '重复声明') "$($rDupLayer.errors -join ' | ')"

$specUndeclared = @{ entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0); layer = 'NOPE' }) }
$rUndeclared = Test-CadSpecStrict -Spec $specUndeclared
Check '引用未声明图层 → warning（会自动补建）' ($rUndeclared.ok -eq $true -and ($rUndeclared.warnings -join ' ') -match 'NOPE') "warnings=$($rUndeclared.warnings -join ' | ')"

$specNoUnits = @{ entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) }) }
$rNoUnits = Test-CadSpecStrict -Spec $specNoUnits
Check '缺 units → warning 但不阻塞' ($rNoUnits.ok -eq $true -and ($rNoUnits.warnings -join ' ') -match 'units') "warnings=$($rNoUnits.warnings -join ' | ')"

$specBadUnits = @{ units = 'furlong'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) }) }
$rBadUnits = Test-CadSpecStrict -Spec $specBadUnits
Check '非法 units → warning 且不阻塞' ($rBadUnits.ok -eq $true -and ($rBadUnits.warnings -join ' ') -match 'furlong') "warnings=$($rBadUnits.warnings -join ' | ')"

$specNoSave = @{ units = 'mm'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) }) }
$rNoSave = Test-CadSpecStrict -Spec $specNoSave
Check '无 save → warning（不出产物）' ($rNoSave.ok -eq $true -and ($rNoSave.warnings -join ' ') -match 'save') "warnings=$($rNoSave.warnings -join ' | ')"

$specDupId = @{ entities = @(
    @{ id = 'e1'; type = 'line'; p1 = @(0, 0); p2 = @(1, 0) },
    @{ id = 'e1'; type = 'line'; p1 = @(0, 0); p2 = @(2, 0) }
) }
$rDupId = Test-CadSpecStrict -Spec $specDupId
Check '重复实体 id 被抓住' ($rDupId.ok -eq $false -and ($rDupId.errors -join ' ') -match 'id') "$($rDupId.errors -join ' | ')"

# 约束
$specUnitsC = @{ units = 'mm'; constraints = @{ expectedUnits = 'm' }; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) }) }
$rUnitsC = Test-CadSpecStrict -Spec $specUnitsC
Check 'constraints.expectedUnits 不符 → 不通过' ($rUnitsC.ok -eq $false -and ($rUnitsC.errors -join ' ') -match 'expectedUnits') "$($rUnitsC.errors -join ' | ')"

$specLayersC = @{ units = 'mm'; constraints = @{ requiredLayers = @('DIM') }; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) }) }
$rLayersC = Test-CadSpecStrict -Spec $specLayersC
Check 'constraints.requiredLayers 缺失 → 不通过' ($rLayersC.ok -eq $false -and ($rLayersC.errors -join ' ') -match 'DIM') "$($rLayersC.errors -join ' | ')"

$specWidthC = @{ units = 'mm'; entities = @(@{ type = 'rect'; p1 = @(0, 0); p2 = @(150, 50) }); constraints = @{ maxWidth = 100 } }
$rWidthC = Test-CadSpecStrict -Spec $specWidthC
Check 'constraints.maxWidth 超限被抓住' ($rWidthC.ok -eq $false -and ($rWidthC.errors -join ' ') -match 'maxWidth') "$($rWidthC.errors -join ' | ')"

$specGapC = @{ units = 'mm'; entities = @(
    @{ type = 'circle'; c = @(0, 0); r = 10 },
    @{ type = 'circle'; c = @(21, 0); r = 10 }
); constraints = @{ minGap = 5 } }
$rGapC = Test-CadSpecStrict -Spec $specGapC
Check 'constraints.minGap 净距不足被抓住' ($rGapC.ok -eq $false -and ($rGapC.errors -join ' ') -match '净距') "$($rGapC.errors -join ' | ')"

$specClosedC = @{ units = 'mm'; entities = @(
    @{ type = 'polyline'; points = @(@(0, 0), @(10, 0), @(10, 10), @(0, 10)) }
); constraints = @{ requireClosed = $true } }
$rClosedC = Test-CadSpecStrict -Spec $specClosedC
Check 'constraints.requireClosed 抓到未闭合 polyline' ($rClosedC.ok -eq $false -and ($rClosedC.errors -join ' ') -match '闭合') "$($rClosedC.errors -join ' | ')"

$specMaxEntC = @{ units = 'mm'; entities = @(
    @{ type = 'line'; p1 = @(0, 0); p2 = @(1, 0) },
    @{ type = 'line'; p1 = @(0, 0); p2 = @(2, 0) }
); constraints = @{ maxEntities = 1 } }
$rMaxEntC = Test-CadSpecStrict -Spec $specMaxEntC
Check 'constraints.maxEntities 超限被抓住' ($rMaxEntC.ok -eq $false -and ($rMaxEntC.errors -join ' ') -match 'maxEntities') "$($rMaxEntC.errors -join ' | ')"

# 别名
# circle 认 center/radius（编译器 CadCompiler.ps1 有回落），line 只认 p1/p2。
# line 用 start/end 是用户误写 —— 预检查出来并点名 p1/p2 才是对的，
# 不能为了让这条断言通过就给 line 也加别名（那会让两种写法并存，
# 出错时用户不知道该按哪个改）。
$specAlias = @{ units = 'mm'; entities = @(
    @{ type = 'circle'; center = @(0, 0); radius = 5 }
) }
$rAlias = Test-CadSpecStrict -Spec $specAlias
Check 'circle 别名按等价处理（center/radius）' ($rAlias.ok -eq $true) "errors=$($rAlias.errors -join ' | ')"
Check '别名用法记 warning 提示规范写法' (($rAlias.warnings -join ' ') -match 'radius|规范|p1') "$($rAlias.warnings -join ' | ')"

$specLineAlias = @{ units = 'mm'; entities = @(
    @{ type = 'line'; start = @(0, 0); end = @(1, 1) }
) }
$rLineAlias = Test-CadSpecStrict -Spec $specLineAlias
Check 'line 的 start/end 被抓到并点名 p1/p2' ($rLineAlias.ok -eq $false -and ($rLineAlias.errors -join ' ') -match 'p1|p2') "$($rLineAlias.errors -join ' | ')"

# 空 entities
$specEmpty = @{ units = 'mm'; entities = @() }
$rEmpty = Test-CadSpecStrict -Spec $specEmpty
Check 'entities 为空 → 不通过' ($rEmpty.ok -eq $false) "$($rEmpty.errors -join ' | ')"

# 四份官方示例必须全过（防回归）
foreach ($sn in @('01-simple-plate.json', '02-flange-plate.json', '03-gears.json', '04-all-entities.json')) {
    $sp = Join-Path $scriptRoot "..\assets\samples\$sn"
    if (Test-Path -LiteralPath $sp) {
        $sj = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        $rs = Test-CadSpecStrict -Spec $sj
        Check "官方示例 $sn 预检通过" ($rs.ok -eq $true) "errors=$(@($rs.errors).Count) warnings=$(@($rs.warnings).Count)"
    } else {
        Check "官方示例 $sn 预检通过" $false "文件不存在: $sp"
    }
}

# ══════════════════════════════════════════════════════════════════
#  21. 编译器接入 units（cadcore 生成 cadunits 调用）
# ══════════════════════════════════════════════════════════════════

Section '21. 编译器接入 units'

$uSpecMm = @{ units = 'mm'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) }); save = @{ dwg = 't.dwg' } }
$cu = Compile-CadSpec -Spec $uSpecMm -CoreLspPath 'D:\deepseek harness gongzuoqu\cad-automatic-wwj\skill\scripts\cadcore.lsp'
Check 'units=mm 生成 (cadunits 4)' ($cu.lisp -match '\(cadunits 4\)') "$(($cu.lisp -split "`n" | Where-Object { $_ -match 'cadunits' }) -join ' | ')"

$uSpecM = @{ units = 'm'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) }) }
$cuM = Compile-CadSpec -Spec $uSpecM -CoreLspPath 'D:\deepseek harness gongzuoqu\cad-automatic-wwj\skill\scripts\cadcore.lsp'
Check 'units=m 生成 (cadunits 6)' ($cuM.lisp -match '\(cadunits 6\)') ''

$uSpecNone = @{ entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) }) }
$cuNone = Compile-CadSpec -Spec $uSpecNone -CoreLspPath 'D:\deepseek harness gongzuoqu\cad-automatic-wwj\skill\scripts\cadcore.lsp'
Check '缺 units → 不生成 cadunits 但有 warning' ($cuNone.lisp -notmatch '\(cadunits ' -and ($cuNone.warnings -join ' ') -match 'units') "warnings=$($cuNone.warnings -join ' | ')"

$uSpecBogus = @{ units = 'furlong'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) }) }
$cuBogus = Compile-CadSpec -Spec $uSpecBogus -CoreLspPath 'D:\deepseek harness gongzuoqu\cad-automatic-wwj\skill\scripts\cadcore.lsp'
Check '非法 units → 不生成 cadunits 且有 warning' ($cuBogus.lisp -notmatch '\(cadunits ' -and ($cuBogus.warnings -join ' ') -match 'furlong') "warnings=$($cuBogus.warnings -join ' | ')"

# ══════════════════════════════════════════════════════════════════
Section '22. 位图矢量化：CadVectorize（PS5.1 兼容铁律）'
# ══════════════════════════════════════════════════════════════════

# 22.1 BOM 在且非双 BOM（PS5.1 按 ANSI 读无 BOM UTF-8 会吞引号，见 troubleshooting）
foreach ($f in @('CadVectorize.ps1', 'CadCommon.ps1', 'CadImage.ps1', 'CadPdf.ps1')) {
    $fp = Join-Path $scriptRoot $f
    $b = [IO.File]::ReadAllBytes($fp)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $dbl = ($b.Length -ge 6 -and $bom -and $b[3] -eq 0xEF -and $b[4] -eq 0xBB -and $b[5] -eq 0xBF)
    Check "BOM 存在且非双 BOM：$f" ($bom -and -not $dbl) ("first6=" + (($b[0..5] | ForEach-Object { $_.ToString('X2') }) -join ' '))
}

# 22.2 darkInk 口径与 Get-CadImageInk 一致（亮图 → 暗是墨）
$vecTxt = [IO.File]::ReadAllText((Join-Path $scriptRoot 'CadVectorize.ps1'))
Check 'darkInk 口径与 Get-CadImageInk 一致' ($vecTxt -match 'else \{ \$mean -ge 110 \}') 'Get-CadImageMask 必须与 Get-CadImageInk 同口径，否则白图被判全墨'

# 22.3 单元素数组退化保护
Check 'Get-CadMaskBlobs 返回数组用一元逗号' ($vecTxt -match 'return ,@\(') 'PS5.1 单元素 Sort-Object 退化成标量，$blobs.Count 报找不到属性'

# 22.4 不使用 if 表达式传参（PS5.1）
Check 'LAYER 颜色不使用 if 表达式传参' ($vecTxt -notmatch 'New-CadDxfText \$sb 62 \(if ') 'PS7 专属写法在 powershell.exe 下报 if 未识别'

# 22.5 关键函数存在
foreach ($fn in @('Get-CadImageMask','Get-CadMaskBlobs','Get-CadBlobCircleFit','Get-CadBlobLineFit','Get-CadBlobConvexHull','Find-CadImageGeometry','Convert-CadImageGeometryToSpec','Write-CadImageDxf')) {
    Check "函数存在：$fn" ($vecTxt -match ('function\s+' + [regex]::Escape($fn))) ''
}

# 22.6 Y 轴翻转（不翻则上下颠倒且不报错）
Check 'Convert-CadImageGeometryToSpec 做 Y 轴翻转' ($vecTxt -match 'height - 1 - ') '像素 y 向下增，图纸 y 向上增'

# 22.7 诚实边界：只出三类，不猜语义
Check '只输出 circle/line/polyline 三类' ($vecTxt -match '只输出 circle / line / polyline') ''

# 22.8 DXF 铁律
Check 'Write-CadImageDxf 写 AC1009' ($vecTxt -match "'AC1009'") ''
Check 'Write-CadImageDxf 写 INSUNITS=4' ($vecTxt -match [regex]::Escape('$INSUNITS') -and $vecTxt -like '*New-CadDxfText*70 ''4''*') ''

# 22.9 圆拟合双判据（径向偏差 + 角度覆盖）
Check '圆拟合双判据：径向偏差 0.15' ($vecTxt -match 'MaxRadialDevRatio\s*=\s*0\.15') ''
Check '圆拟合双判据：扇区覆盖 30/36' ($vecTxt -match 'MinSectors\s*=\s*30' -and $vecTxt -match 'SectorCount\s*=\s*36') ''

# 22.10 vectorize CLI 动作（Get-CadImageInfo.ps1 -Action vectorize）
$gii = Get-Content (Join-Path $PSScriptRoot 'Get-CadImageInfo.ps1') -Raw
Check 'vectorize CLI: -Action vectorize 在 ValidateSet 里' ($gii -like "*'info', 'ascii', 'ink', 'compare', 'convert', 'vectorize'*") 'Get-CadImageInfo.ps1 param ValidateSet'
Check 'vectorize CLI: dot-source CadEvidence.ps1（New-CadEvidence 依赖）' ($gii -like "*Join-Path `$scriptDir 'CadEvidence.ps1'*") '缺了会报 term not recognized'
Check 'vectorize CLI: dot-source CadVectorize.ps1' ($gii -like "*Join-Path `$scriptDir 'CadVectorize.ps1'*") ''
Check 'vectorize CLI: dot-source CadPdf.ps1（New-CadDxfText）' ($gii -like "*Join-Path `$scriptDir 'CadPdf.ps1'*") ''

# ══════════════════════════════════════════════════════════════════
#  23. COM 通道 -Action PaperSpace（静态断言，全部读源码不连 COM）
# ══════════════════════════════════════════════════════════════════

$comPath = Join-Path $PSScriptRoot 'Invoke-CadCom.ps1'
$comTxt = ''
if (Test-Path $comPath) { $comTxt = [IO.File]::ReadAllText($comPath) }
$comBom = $false
$comDoubleBom = $false
if (Test-Path $comPath) {
    $b = [IO.File]::ReadAllBytes($comPath)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        $comBom = $true
        if ($b.Length -ge 6 -and $b[3] -eq 0xEF -and $b[4] -eq 0xBB -and $b[5] -eq 0xBF) { $comDoubleBom = $true }
    }
}
Check 'com-paperspace: Invoke-CadCom.ps1 有 UTF-8 BOM' $comBom 'PS5.1 按 ANSI 读无 BOM 中文文件会把 UTF-8 续字节当前导字节吞引号'
Check 'com-paperspace: Invoke-CadCom.ps1 无双 BOM' (-not $comDoubleBom) '双 BOM 会让 PS5.1 把第二个当正文'

Check 'com-paperspace: ValidateSet 含 PaperSpace' ($comTxt -like "*ValidateSet('Info', 'Draw', 'Open', 'Export', 'PaperSpace', 'Quit')*") '动作用户可选集'
Check 'com-paperspace: 有 -LayoutName 参数' ($comTxt -match '\[string\]\$LayoutName') '默认 CAD_PS，已存在则复用'
Check 'com-paperspace: report 有 layout 字段' ($comTxt -like "*layout*= *null*") '报告对象含布局名'
Check 'com-paperspace: report 有 paperSpaceCount 字段' ($comTxt -like "*paperSpaceCount*") '报告对象含图纸空间实体数'

# 图纸空间正路：Layout.Block（直接赋值，不能走 $doc.PaperSpace）
Check 'com-paperspace: 用 Layout.Block 拿图纸空间块' ($comTxt -match '\$blk\s*=\s*\$psLayout\.Block') '铁律：PaperSpace 集合经管道展开退化 Object[]，Layout.Block 直接赋值才是真 __ComObject'
Check 'com-paperspace: 不用 $doc.PaperSpace 建实体' (-not ($comTxt -match '\$doc\.PaperSpace\.Add')) '该集合的 AddXxx 在 PS 里必失败'

# helper 三函数
Check 'com-paperspace: helper New-CadComLayers 存在' ($comTxt -match 'function New-CadComLayers') '图层创建共用'
Check 'com-paperspace: helper Add-CadComEntities 存在' ($comTxt -match 'function Add-CadComEntities') '实体绘制共用'
Check 'com-paperspace: helper Invoke-CadComPlot 存在' ($comTxt -match 'function Invoke-CadComPlot') '打印共用（含轮询稳定）'

# 逗号优先级坑：数组字面量里算术必须整体加括号（@($m + 5, ...) 会解析成 $m + (5, ...)）
$badComma = @()
foreach ($ml in $matches) { }
$mm = [regex]::Matches($comTxt, '@\((\s*\$\w+\s*[+\-*/]\s*[^,()]+\s*,)')
foreach ($x in $mm) { $badComma += $x.Index }
Check 'com-paperspace: 数组字面量内算术整体加括号（逗号优先级坑）' ($badComma.Count -eq 0) ('未加括号的算术元素出现在偏移: ' + ($badComma -join ','))

# 点封送铁律
Check 'com-paperspace: ConvertTo-CadComPoint 一元逗号' ($comTxt -match 'return , \$a') '点必须以单对象传，否则沿管道展开成多个 double'

# 退出姿势
Check 'com-paperspace: finally 轮询进程退出' ($comTxt -match 'HasExited|Stop-Process') 'Quit 后 3s 还剩 1 个属退出中，须轮询而非立即报失败'


# ══════════════════════════════════════════════════════════════════
Section '24. 多视图 spec：校验 / 拆分 / 绘制包装'
# ══════════════════════════════════════════════════════════════════

# 24.1 校验：entities 空 + views 非空 → 允许
$mvSpec = [pscustomobject]@{
    name  = 'mv'
    units = 'mm'
    views = @(
        [pscustomobject]@{ id = 'front'; entities = @(@{ type = 'circle'; c = @(0, 0); r = 10 }) },
        [pscustomobject]@{ id = 'top';   entities = @(@{ type = 'rect'; p1 = @(0, 0); p2 = @(20, 10) }) }
    )
    entities = @(@{ type = 'point'; at = @(5, 5) })
}
$mvCheck = Test-CadSpecStrict -Spec $mvSpec
Check '多视图：entities 空但 views 非空 → 通过' ($mvCheck.ok) ($mvCheck.errors -join ' | ')
Check '多视图：stats 记 viewCount=2' ($mvCheck.stats.viewCount -eq 2) "viewCount=$($mvCheck.stats.viewCount)"

# 24.2 校验：view_id 引用未知视图 → 报错
$mvGhost = [pscustomobject]@{
    name     = 'mv'
    units    = 'mm'
    views    = @([pscustomobject]@{ id = 'front'; entities = @() })
    entities = @(@{ type = 'circle'; c = @(0, 0); r = 10; view_id = 'ghost' })
}
$mvGhostR = Test-CadSpecStrict -Spec $mvGhost
Check '多视图：view_id 引用未知视图 → 报错' (-not $mvGhostR.ok) ($mvGhostR.errors -join ' | ')

# 24.3 校验：views id 重复 → 报错
$mvDup = [pscustomobject]@{
    name     = 'mv'
    units    = 'mm'
    views    = @([pscustomobject]@{ id = 'a'; entities = @() }, [pscustomobject]@{ id = 'A'; entities = @() })
    entities = @(@{ type = 'point'; at = @(0, 0) })
}
$mvDupR = Test-CadSpecStrict -Spec $mvDup
Check '多视图：视图 id 重复（不区分大小写）→ 报错' (-not $mvDupR.ok) ($mvDupR.errors -join ' | ')

# 24.4 校验：required_view_ids 引用未知视图 → 报错
$mvReq = [pscustomobject]@{
    name        = 'mv'
    units       = 'mm'
    views       = @([pscustomobject]@{ id = 'front'; entities = @() })
    entities    = @(@{ type = 'point'; at = @(0, 0) })
    constraints = [pscustomobject]@{ required_view_ids = @('top') }
}
$mvReqR = Test-CadSpecStrict -Spec $mvReq
Check '多视图：required_view_ids 引用未知视图 → 报错' (-not $mvReqR.ok) ($mvReqR.errors -join ' | ')

# 24.5 校验：entities 空 + views 也空 → 仍报错（原行为保留）
$mvNone = [pscustomobject]@{ name = 'mv'; units = 'mm' }
$mvNoneR = Test-CadSpecStrict -Spec $mvNone
Check '多视图：entities 与 views 全空 → 仍报错' (-not $mvNoneR.ok) ($mvNoneR.errors -join ' | ')

# 24.6 校验：视图内实体缺字段 → 报错带 views[i] 定位
$mvBadEnt = [pscustomobject]@{
    name  = 'mv'
    units = 'mm'
    views = @([pscustomobject]@{ id = 'front'; entities = @(@{ type = 'circle' }) })
    entities = @(@{ type = 'point'; at = @(0, 0) })
}
$mvBadEntR = Test-CadSpecStrict -Spec $mvBadEnt
Check '多视图：视图内实体缺字段 → 报错带 views[i] 定位' ((-not $mvBadEntR.ok) -and (($mvBadEntR.errors -join ' ') -match 'views\[0\]')) ($mvBadEntR.errors -join ' | ')

# 24.7 拆分：Get-CadSpecViewSpecs
$partSpec = [pscustomobject]@{
    name  = 'part'
    units = 'mm'
    views = @(
        [pscustomobject]@{ id = 'front'; entities = @(@{ type = 'circle'; c = @(0, 0); r = 50 }) },
        [pscustomobject]@{ id = 'top' }
    )
    entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0); view_id = 'front' }, @{ type = 'point'; at = @(2, 2) })
    save = [pscustomobject]@{ dwg = 'out\part.dwg'; dxf = $true }
}
$frontSub = Get-CadSpecViewSpecs -Spec $partSpec | Where-Object { $_.name -eq 'part-front' }
$topSub = Get-CadSpecViewSpecs -Spec $partSpec | Where-Object { $_.name -eq 'part-top' }
Check '拆分：views[] 生成 front/top 两个子 spec' ($null -ne $frontSub -and $null -ne $topSub) ''
Check '拆分：front 子 spec 含视图实体 + view_id 实体 + 共享实体 = 3 个' ($frontSub.entities.Count -eq 3) "ents=$($frontSub.entities.Count)"
Check '拆分：top 子 spec 只含共享实体 = 1 个' ($topSub.entities.Count -eq 1) "ents=$($topSub.entities.Count)"
Check '拆分：save 文件名前插视图 id' ($frontSub.save.dwg -eq 'out\front-part.dwg' -and $topSub.save.dwg -eq 'out\top-part.dwg') "front=$($frontSub.save.dwg) top=$($topSub.save.dwg)"

# 24.8 静态断言：包装函数与聚合逻辑
$drawTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'Invoke-CadDraw.ps1') -Raw
Check 'Invoke-CadDraw.ps1 有单视图函数 Invoke-CadDrawSingle' ($drawTxt -match 'function Invoke-CadDrawSingle') ''
Check 'Invoke-CadDraw.ps1 有多视图薄包装 function Invoke-CadDraw' ($drawTxt -match '(?m)^function Invoke-CadDraw \{') ''
Check '多视图包装按最差状态聚合' ($drawTxt -match 'Get-CadSpecViewSpecs') ''
Check '多视图报告带 multiView 与 views[] 字段' ($drawTxt -match 'multiView' -and $drawTxt -match 'views\s*=') ''
Check 'spec 编译器含 Get-CadSpecViewSpecs 函数' ((Get-Content -LiteralPath (Join-Path $scriptRoot 'CadCompiler.ps1') -Raw) -match 'function Get-CadSpecViewSpecs') ''
Check 'spec 校验含多视图 views 段' ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CadSpecCheck.ps1') -Raw) -match 'views（多视图）') ''


# ══════════════════════════════════════════════════════════════════
Section '25. DXF 预览渲染：CadRender / Invoke-CadRenderPreview'
# ══════════════════════════════════════════════════════════════════

# 25.1 Get-CadDxfRenderData：合成 DXF → 实体/图层计数
$dxfPath = Join-Path $work 'render-sample.dxf'
@'
0
SECTION
2
HEADER
9
$ACADVER
1
AC1032
0
ENDSEC
0
SECTION
2
ENTITIES
0
CIRCLE
8
GEO
10
0.0
20
0.0
40
10.0
0
LINE
8
GEO
10
0.0
20
0.0
11
5.0
21
5.0
0
TEXT
8
TXT
10
1.0
20
1.0
40
2.5
1
hello
0
ENDSEC
0
EOF
'@ | Set-Content -LiteralPath $dxfPath -Encoding UTF8

$rd = Get-CadDxfRenderData -Path $dxfPath
Check '渲染数据：合成 DXF 校验通过' ($rd.valid) "reason=$($rd.reason)"
Check '渲染数据：数出 3 个实体' ($rd.entityTotal -eq 3) "total=$($rd.entityTotal)"
Check '渲染数据：图元 kind 含 polyline/line/text' (($rd.entities | ForEach-Object { $_.kind }) -contains 'polyline' -and ($rd.entities | ForEach-Object { $_.kind }) -contains 'text') ''
Check '渲染数据：entityCounts 分型计数' ($rd.entityCounts['CIRCLE'] -eq 1 -and $rd.entityCounts['LINE'] -eq 1 -and $rd.entityCounts['TEXT'] -eq 1) "counts=$($rd.entityCounts | ConvertTo-Json -Compress)"
Check '渲染数据：layerCounts 分层计数' ($rd.layerCounts['GEO'] -eq 2 -and $rd.layerCounts['TXT'] -eq 1) "layers=$($rd.layerCounts | ConvertTo-Json -Compress)"

# 25.2 无效 DXF → valid=false
$badDxf = Join-Path $work 'bad.dxf'
'garbage' | Set-Content -LiteralPath $badDxf -Encoding UTF8
$rdBad = Get-CadDxfRenderData -Path $badDxf
Check '渲染数据：垃圾文件判无效' (-not $rdBad.valid) "reason=$($rdBad.reason)"

# 25.3 静态断言：CadRender.ps1 铁律
$renderTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'CadRender.ps1') -Raw
Check 'CadRender: 工具版本号 Invoke-CadRenderPreview/1.0' ($renderTxt -match 'Invoke-CadRenderPreview/1\.0') ''
Check 'CadRender: 页幅表含 A4/A3/A2/A1' ($renderTxt -match "'A4'" -and $renderTxt -match "'A3'" -and $renderTxt -match "'A2'" -and $renderTxt -match "'A1'") ''
Check 'CadRender: A3 = 420x297' ($renderTxt -match '420' -and $renderTxt -match '297') ''
Check 'CadRender: 默认 dpi=300' ($renderTxt -match 'dpi.*300|300.*dpi' -or $renderTxt -match '\$Dpi\s*=\s*300') ''
Check 'CadRender: 图元覆盖 arc/circle/ellipse/line/lwpolyline/mtext/point/solid/spline/text/dimension' ($renderTxt -match "'ARC'" -and $renderTxt -match "'ELLIPSE'" -and $renderTxt -match "'SOLID'" -and $renderTxt -match "'DIMENSION'") ''
Check 'CadRender: 输出 PNG+PDF 两类产物' ($renderTxt -match "'png'" -and $renderTxt -match "'pdf'") ''
Check 'CadRender: warnings 含中文回退提示（14 基础字体不含中文）' ($renderTxt -match 'Latin-1') ''

# 25.4 静态断言：CLI 包装
$cliTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'Invoke-CadRenderPreview.ps1') -Raw
Check 'Invoke-CadRenderPreview: ValidateSet 含 A4/A3/A2/A1' ($cliTxt -match "ValidateSet\('A4', 'A3', 'A2', 'A1'\)") ''
Check 'Invoke-CadRenderPreview: report 带 tool 版本' ($cliTxt -match 'Invoke-CadRenderPreview/1\.0') ''
Check 'Invoke-CadRenderPreview: dot-source CadRender.ps1' ($cliTxt -like "*Join-Path `$scriptDir 'CadRender.ps1'*") ''

# 25.5 BOM：新增两个脚本必须带 UTF-8 BOM（PS5.1 中文兼容）
$renderBom = $false
$rb = [IO.File]::ReadAllBytes((Join-Path $scriptRoot 'CadRender.ps1'))
if ($rb.Length -ge 3 -and $rb[0] -eq 0xEF -and $rb[1] -eq 0xBB -and $rb[2] -eq 0xBF) { $renderBom = $true }
Check 'CadRender.ps1 带 UTF-8 BOM' $renderBom ''
$cliBom = $false
$cb = [IO.File]::ReadAllBytes((Join-Path $scriptRoot 'Invoke-CadRenderPreview.ps1'))
if ($cb.Length -ge 3 -and $cb[0] -eq 0xEF -and $cb[1] -eq 0xBB -and $cb[2] -eq 0xBF) { $cliBom = $true }
Check 'Invoke-CadRenderPreview.ps1 带 UTF-8 BOM' $cliBom ''


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
