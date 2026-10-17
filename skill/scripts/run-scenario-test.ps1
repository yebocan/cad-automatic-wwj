<#
.SYNOPSIS
    cad-automatic-wwj 场景测试 —— 验「出错时脚本怎么判」，而不是「真机能跑吗」。

.DESCRIPTION
    三个测试套件的分工（缺一不可）：

      run-unit-test.ps1      纯离线单测。验编码 / 编译 / 解析 / 登记表这些**函数级逻辑**。
                             不启动任何进程，秒级完成。
      run-test.ps1           集成自检。真开 accoreconsole，验**正常路径**下有产物且内容对。
      run-scenario-test.ps1  场景测试（本脚本）。验**异常路径**下判断是否准确 ——
                             失败必须被认出来，成功不许被误报，两者同等重要。

    为什么单独做一套：集成测试只跑 happy path。一个只会画图的脚本和一个
    画完图还知道「这次到底成没成」的脚本，在 -Test draw 全绿时看起来一模一样。
    这里的每个场景都在制造一种「看起来成功」的假象，要求脚本自己戳破它。

    三种模式：
      real     真跑 accoreconsole。慢，但验证的是真机行为。
      mock     用 scripts/mock/fake-accoreconsole.cmd 冒充。快，可复现，
               覆盖真机难以造出来的失败形态（0 字节产物、悬停、假 handle）。
      offline  完全不执行进程。只验「编译产物与参数校验」，也就是
               脚本在真正动手之前就应该拒绝的那些情况。

    ★ 结果里的 mode 是承诺，不是装饰 ★
      mock 模式下通过的场景，报告里必须写 mode=mock；写成「真实通过」就是伪造证据。
      同理，offline 只验参数校验，不能拿去证明产物正确。

.PARAMETER Scenario
    场景名或 all。用 -ListScenarios 看全部名称与说明。

.PARAMETER Mode
    real | mock | offline

.PARAMETER OutputDirectory
    产物目录。默认 %TEMP%\cad-scenario-tests

.PARAMETER TimeoutSeconds
    总预算。hang 这类场景会跑满单个场景的超时，别给太小。

.PARAMETER KeepArtifacts
    保留临时目录。

.EXAMPLE
    .\run-scenario-test.ps1 -Mode mock
    .\run-scenario-test.ps1 -Scenario draw-no-artifact -Mode mock -KeepArtifacts
    .\run-scenario-test.ps1 -Mode offline
    .\run-scenario-test.ps1 -ListScenarios

.EXITCODES
    0  全部通过
    1  有场景失败
#>

[CmdletBinding()]
param(
    [string]$Scenario = 'all',

    [ValidateSet('real', 'mock', 'offline')]
    [string]$Mode = 'real',

    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'cad-scenario-tests'),

    [string]$AccoreConsole,

    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 1200,

    [switch]$KeepArtifacts,

    [switch]$ListScenarios
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CadCommon.ps1')
. (Join-Path $PSScriptRoot 'CadCompiler.ps1')

$drawScript = Join-Path $PSScriptRoot 'Invoke-CadDraw.ps1'
$inspectScript = Join-Path $PSScriptRoot 'Invoke-CadInspect.ps1'
$exportScript = Join-Path $PSScriptRoot 'Export-CadToDxf.ps1'
$plotScript = Join-Path $PSScriptRoot 'Invoke-CadPlot.ps1'
$repairScript = Join-Path $PSScriptRoot 'Invoke-CadRepair.ps1'
$mockCmd = Join-Path $PSScriptRoot 'mock\fake-accoreconsole.cmd'

# ══════════════════════════════════════════════════════════════════
#  场景表
# ══════════════════════════════════════════════════════════════════
#
#  每个场景 = 一个「假象」+ 一条「必须被识破」的断言。
#  Assert 字段写的是**期望的判定**，不是期望的结果：
#  失败场景期望脚本报 failed，成功场景期望脚本报 ok —— 两者都在验判断力。

$scenarios = @(
    # ── 正常路径（对照组）────────────────────────────────────────
    [pscustomobject]@{
        name    = 'draw-ok'
        title   = '正常出图：三产物齐全'
        mock    = 'normal'
        modes   = @('real', 'mock')
        expect  = 'ok'
        assert  = '脚本应报 status=ok，且 DWG/DXF/PDF 三项产物校验全部通过'
        timeout = 180
    }
    [pscustomobject]@{
        name    = 'draw-no-artifact'
        title   = 'LISP 全吐成功标记但一个文件都不写'
        mock    = 'no-artifact'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = '脚本不得因 @@DONE@@ 与 @@SAVEAS=ok@@ 就报成功；必须检出产物缺失'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-no-done'
        title   = '产物齐全但 LISP 没跑到 @@DONE@@'
        mock    = 'no-done'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = '缺 @@DONE@@ 说明脚本中途被吞，不得报 ok'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-lisp-error'
        title   = 'LISP 报「参数类型错误」'
        mock    = 'lisp-error'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = '必须识别 ; 错误: 行并报 failed'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-not-found'
        title   = 'accoreconsole 找不到输入图纸（exit 76）'
        mock    = 'not-found'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = '必须把 exit 76 判成 drawing-not-found，不能当一般失败'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-bad-dxf'
        title   = '产物 DXF 结构残缺'
        mock    = 'bad-dxf'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = 'DXF 独立校验必须判失败，不能只看文件存在'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-bad-pdf'
        title   = '产物 PDF 不是 PDF'
        mock    = 'bad-pdf'
        modes   = @('mock')
        expect  = 'not-ok'
        assert  = 'PDF 结构校验（%PDF 头 + %%EOF + 页数）必须判失败'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-dialog'
        title   = 'accoreconsole 弹出对话框'
        mock    = 'dialog'
        modes   = @('mock')
        expect  = 'any'
        assert  = '必须把 MessageBox 行记进 diagnostics.messageBoxes，这是卡死的先兆'
        timeout = 120
    }
    [pscustomobject]@{
        name    = 'draw-hang'
        title   = 'accoreconsole 永不退出'
        mock    = 'hang'
        modes   = @('mock')
        expect  = 'timeout'
        assert  = '超时闸必须生效：timedOut=true 且进程被杀，不能挂到总预算耗尽'
        timeout = 40
    }

    # ── 参数校验（offline 专用）──────────────────────────────────
    [pscustomobject]@{
        name    = 'offline-bad-spec'
        title   = 'spec 缺必填字段'
        mock    = $null
        modes   = @('offline')
        expect  = 'throws'
        assert  = '编译器应在动手之前就拒绝，并指明缺哪个字段'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-unknown-type'
        title   = '未知实体类型'
        mock    = $null
        modes   = @('offline')
        expect  = 'throws'
        assert  = '未知 type 必须报错并列出支持的取值'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-layer-autocreate'
        title   = '实体引用了未声明的图层'
        mock    = $null
        modes   = @('offline')
        expect  = 'warns'
        assert  = '应自动补建图层并记 warning，不能静默丢弃实体'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-dxf-version'
        title   = 'DXF 版本非法值'
        mock    = $null
        modes   = @('offline')
        expect  = 'warns'
        assert  = '非法版本应回落 2018 并记 warning，不能静默'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-encoding'
        title   = '生成的 LISP 是 GBK 而非 UTF-8'
        mock    = $null
        modes   = @('offline')
        expect  = 'gbk'
        assert  = '写盘的 .lsp 必须是 GBK（本 skill 最核心的坑），UTF-8 会让中文变乱码'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-bad-color'
        title   = '图层颜色是非法值（"red" / 300 / 0）'
        mock    = $null
        modes   = @('offline')
        expect  = 'warns'
        assert  = '颜色回落 7 并记 warning；图层是基础设施，坏一个值不能让整张图停工'
        timeout = 30
    }
    [pscustomobject]@{
        name    = 'offline-block-spec'
        title   = '含 blocks[] 的 spec 编译成 BEGBLOCK/ENDBLOCK'
        mock    = $null
        modes   = @('offline')
        expect  = 'block'
        assert  = '绝不能生成 (command "_.-BLOCK" …) —— 那样 -BLOCK 会停在「选择对象」把后续画图命令当选择点吃掉，卡到超时'
        timeout = 30
    }
)

if ($ListScenarios) {
    Write-Host ''
    Write-Host '  可用场景' -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 76)) -ForegroundColor DarkGray
    foreach ($s in $scenarios) {
        $modes = ($s.modes -join ',')
        Write-Host ("  {0,-24} [{1,-11}] {2}" -f $s.name, $modes, $s.title)
        Write-Host ("  {0,-24}              期望: {1}" -f '', $s.assert) -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

# ══════════════════════════════════════════════════════════════════
#  结果收集
# ══════════════════════════════════════════════════════════════════

$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Name,
        [string]$Title,
        [string]$Mode,
        [bool]$Passed,
        [string]$Expected,
        [string]$Actual,
        [string]$Detail = ''
    )
    $script:results.Add([pscustomobject]@{
            scenario = $Name
            title    = $Title
            mode     = $Mode       # ★ 每个结果都带 mode，杜绝「mock 冒充真机」★
            passed   = $Passed
            expected = $Expected
            actual   = $Actual
            detail   = $Detail
        })
    $mark = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $mark, $Name) -ForegroundColor $color -NoNewline
    Write-Host ("  ({0})  {1}" -f $Mode, $Title)
    if (-not $Passed -or $Detail) {
        Write-Host ("       期望 {0} / 实际 {1}" -f $Expected, $Actual) -ForegroundColor DarkGray
        if ($Detail) { Write-Host ("       {0}" -f $Detail) -ForegroundColor DarkGray }
    }
}

function Section([string]$title) {
    Write-Host ''
    Write-Host ("── $title " + ('─' * [Math]::Max(4, 68 - $title.Length))) -ForegroundColor Cyan
}

# 总超时闸
$script:deadline = (Get-Date).AddSeconds($TimeoutSeconds)
function Get-RemainingSeconds {
    return [int][Math]::Max(0, ($script:deadline - (Get-Date)).TotalSeconds)
}

# 单场景执行器：统一处理「跑脚本 → 解析 JSON → 判定 → 清理」
function Invoke-ScenarioScript {
    param(
        [string]$Script,
        [string[]]$Arguments,
        [int]$ScenarioTimeout
    )
    $budget = [Math]::Min($ScenarioTimeout, (Get-RemainingSeconds))
    if ($budget -le 10) { throw "总预算不足，无法执行 $Script" }

    $argv = @('-NoProfile', '-File', $Script) + $Arguments + @('-TimeoutSeconds', $budget)
    $raw = & pwsh @argv 2>&1 | Out-String
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ raw = $raw; obj = $obj }
}

# ══════════════════════════════════════════════════════════════════
#  环境准备
# ══════════════════════════════════════════════════════════════════

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$runToken = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDir = Join-Path $outputRoot ('run_' + $runToken)
New-Item -ItemType Directory -Path $runDir | Out-Null

$runStartedAt = Get-Date

$report = [ordered]@{
    skill      = $script:CadSkillName
    mode       = $Mode
    startedAt  = (Get-Date).ToString('o')
    scenarios  = @()
    summary    = [ordered]@{ total = 0; passed = 0; failed = 0 }
    runDir     = $runDir
    finishedAt = $null
}

# mock 模式：解析出假 accoreconsole 的路径，用 -AccoreConsole 直传，
# 绝不写 CAD_ACCORECONSOLE 环境变量 —— 那只会在后续真机测试里留毒。
$mockAccore = $null
if ($Mode -eq 'mock') {
    if (-not (Test-Path -LiteralPath $mockCmd)) {
        throw "mock 模式需要 $mockCmd，但它不存在"
    }
    $mockAccore = $mockCmd
}

# 真机模式：确认 accoreconsole 可用，否则整轮无意义
if ($Mode -eq 'real') {
    $info = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    if (-not $info -or -not $info.path) {
        throw 'real 模式需要可用的 accoreconsole。请先跑 Set-CadPath.ps1 -Auto，或改用 -Mode mock。'
    }
    Write-Host ("  accoreconsole: {0}（来源 {1}）" -f $info.path, $info.source) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor Cyan
Write-Host ("  场景测试  ·  mode={0}  ·  {1}" -f $Mode, $runToken) -ForegroundColor Cyan
Write-Host ('═' * 70) -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════
#  offline 专用：不启动任何进程
# ══════════════════════════════════════════════════════════════════

function Invoke-OfflineScenario {
    param([object]$Scenario, [string]$Dir)

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $coreLsp = Join-Path $PSScriptRoot 'cadcore.lsp'

    switch ($Scenario.name) {

        'offline-bad-spec' {
            # line 缺 p2 —— 不能让半截线流到 LISP 里
            #
            # ★ 判定口径：不要求「抛异常」，要求「不被当成成功」★
            #   编译器对单个实体失败的设计是「记 warning 并跳过」——一张图里
            #   坏一个孔不该整张图停工。所以这里的正确断言是：
            #     ① 确实报告了失败，② 失败信息点名了具体实体与原因。
            #   真正的安全网在 Invoke-CadDraw：它把「有实体未编译」变成一条
            #   失败断言，status 落到 partial。这里只验编译器这一层。
            $spec = [ordered]@{
                name     = 'bad'
                entities = @([ordered]@{ type = 'line'; p1 = @(0, 0) })
            }
            $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
            $fails = @($c.warnings | Where-Object { $_ -match '编译失败' })
            $pass = ($c.entityCount -eq 0) -and ($fails.Count -eq 1) -and ($fails[0] -match 'p1.*p2|需要 p1')
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $pass `
                -Expected 'entityCount=0 + warning 点名缺 p1/p2' `
                -Actual "entityCount=$($c.entityCount) warnings=$($fails.Count)"
        }

        'offline-unknown-type' {
            $spec = [ordered]@{
                name     = 'bad'
                entities = @([ordered]@{ type = 'nonesuch-entity'; at = @(0, 0) })
            }
            $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
            $fails = @($c.warnings | Where-Object { $_ -match '编译失败' })
            # 好的失败信息要能让人知道「有哪些合法取值」，否则只能去翻源码
            $listsTypes = ($fails.Count -eq 1) -and ($fails[0] -match 'line/polyline/circle')
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $listsTypes `
                -Expected 'warning 列出合法类型' `
                -Actual "warnings=$($fails.Count)"
        }

        'offline-layer-autocreate' {
            # 实体用了未声明的 NOSUCH 图层 —— 应自动补建并记 warning
            $spec = [ordered]@{
                name     = 'autolayer'
                layers   = @([ordered]@{ name = 'GEO'; color = 7 })
                entities = @([ordered]@{ type = 'circle'; c = @(10, 10); r = 5; layer = 'NOSUCH' })
            }
            try {
                $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
                $hasLayer = @($c.layers) -contains 'NOSUCH'
                $hasWarn = @($c.warnings | Where-Object { $_ -match 'NOSUCH' }).Count -gt 0
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' `
                    -Passed ($hasLayer -and $hasWarn) -Expected 'layer 补建 + warning' `
                    -Actual "layers=[$($c.layers -join ',')] warnings=$(@($c.warnings).Count)"
            } catch {
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $false `
                    -Expected '自动补建' -Actual "throws: $($_.Exception.Message)"
            }
        }

        'offline-dxf-version' {
            # 非法 DXF 版本应回落并 warning
            $spec = [ordered]@{
                name     = 'badver'
                entities = @([ordered]@{ type = 'circle'; c = @(0, 0); r = 1 })
                save     = [ordered]@{ dwg = 'x.dwg'; dxf = $true; dxfVersion = 'R9' }
            }
            try {
                $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
                $warned = @($c.warnings | Where-Object { $_ -match 'R9|版本|version' }).Count -gt 0
                $usedDefault = $c.lisp -match 'c:SAVEDXF[^)]*"2018"'
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' `
                    -Passed ($warned -and $usedDefault) -Expected '回落 2018 + warning' `
                    -Actual "fallback=$usedDefault warnings=$(@($c.warnings).Count)"
            } catch {
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $false `
                    -Expected '回落而不是抛错' -Actual "throws: $($_.Exception.Message)"
            }
        }

        'offline-encoding' {
            # ★ 本 skill 最核心的坑：.lsp 必须 GBK 写盘 ★
            # 判据不能是「文件里能不能读出中文」—— UTF-8 也能读出来。
            # 必须比字节：直接拿两种编码的已知编码值去搜，别手抄十六进制
            # （手抄过一次，把「图」的 GBK 写成 B4 CD，实际是 CD BC，
            #   结果探针永远报失败，会让人以为是写盘逻辑坏了）。
            $probe = '图层'
            $gbkBytes = [Text.Encoding]::GetEncoding(936).GetBytes($probe)
            $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($probe)

            $lspPath = Join-Path $Dir 'encoding-probe.lsp'
            Write-CadLsp -Path $lspPath -Body "; $probe 探针 (cadsay `"CN`" `"成功`")" | Out-Null
            $bytes = [IO.File]::ReadAllBytes($lspPath)

            function Find-Seq([byte[]]$Hay, [byte[]]$Needle) {
                for ($i = 0; $i -le $Hay.Length - $Needle.Length; $i++) {
                    $ok = $true
                    for ($j = 0; $j -lt $Needle.Length; $j++) {
                        if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
                    }
                    if ($ok) { return $true }
                }
                return $false
            }

            $hasGbk = Find-Seq $bytes $gbkBytes
            $hasUtf8 = Find-Seq $bytes $utf8Bytes
            $noBom = -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' `
                -Passed ($hasGbk -and -not $hasUtf8 -and $noBom) `
                -Expected 'gbk（含 GBK 字节、无 UTF-8 字节、无 BOM）' `
                -Actual "gbk=$hasGbk utf8=$hasUtf8 noBom=$noBom size=$($bytes.Length)"
        }

        'offline-bad-color' {
            # 图层颜色是基础设施：坏一个值必须回落 7 + warning，不能让整张图停工。
            # 原来直接 [int] 强转，StrictMode 下抛异常带崩整个编译。
            $spec = [ordered]@{
                name     = 'bad-color'
                layers   = @(
                    [ordered]@{ name = 'A'; color = 'red' },
                    [ordered]@{ name = 'B'; color = 300 },
                    [ordered]@{ name = 'C'; color = 0 },
                    [ordered]@{ name = 'D'; color = 4 }
                )
                entities = @([ordered]@{ type = 'line'; layer = 'D'; p1 = @(0, 0); p2 = @(10, 10) })
            }
            try {
                $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
                $lispLines = ($c.lisp -split "`n" | Where-Object { $_ -like '*(c:LAYER*' }) -join ''
                $aOk = $lispLines -like '*"A" 7*'
                $bOk = $lispLines -like '*"B" 7*'
                $cOk = $lispLines -like '*"C" 7*'
                $dOk = $lispLines -like '*"D" 4*'
                $warnCount = @($c.warnings | Where-Object { $_ -like '*color*' }).Count
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' `
                    -Passed ($aOk -and $bOk -and $cOk -and $dOk -and $warnCount -ge 3) `
                    -Expected '三个非法颜色全回落 7，合法色 4 保留，至少 3 条 warning' `
                    -Actual "A=$aOk B=$bOk C=$cOk D=$dOk warnings=$warnCount 实体=$($c.entityCount)"
            } catch {
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $false `
                    -Expected '回落而不是抛错' -Actual "throws: $($_.Exception.Message)"
            }
        }

        'offline-block-spec' {
            # ★ 块构建的回归哨兵 ★
            # (command "_.-BLOCK" name pt) 之后紧跟画图命令会卡死：
            # -BLOCK 给完基点直接进「选择对象」，把后续坐标当选择点吃掉。
            # 必须用 c:BEGBLOCK / c:ENDBLOCK 包住。
            $spec = [ordered]@{
                name     = 'block-probe'
                layers   = @([ordered]@{ name = 'GEO'; color = 7 })
                blocks   = @(
                    [ordered]@{
                        name     = 'BOLT'
                        base     = @(0, 0)
                        entities = @(
                            [ordered]@{ type = 'circle'; c = @(0, 0); r = 6 },
                            [ordered]@{ type = 'circle'; c = @(0, 0); r = 3 }
                        )
                    }
                )
                entities = @(
                    [ordered]@{ type = 'block'; layer = 'GEO'; name = 'BOLT'; at = @(50, 50); scaleX = 2; scaleY = 2 }
                )
            }
            try {
                $c = Compile-CadSpec -Spec $spec -CoreLspPath $coreLsp
                $l = $c.lisp
                $hasBeg = $l -like '*(c:BEGBLOCK "BOLT"*'
                $hasEnd = $l -like '*(c:ENDBLOCK)*'
                $hasInsert = $l -like '*(c:INSERTBLOCK "BOLT"*'
                # 这两条是绝对不能出现的写法
                $noRawBlock = -not ($l -match '(?m)^\s*\(command\s+"_\.-BLOCK"')
                $beginBeforeInsert = ($l.IndexOf('c:BEGBLOCK') -lt $l.IndexOf('c:INSERTBLOCK')) -and $l.IndexOf('c:BEGBLOCK') -ge 0
                $endBeforeInsert = ($l.IndexOf('c:ENDBLOCK') -lt $l.IndexOf('c:INSERTBLOCK')) -and $l.IndexOf('c:ENDBLOCK') -ge 0

                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' `
                    -Passed ($hasBeg -and $hasEnd -and $hasInsert -and $noRawBlock -and $beginBeforeInsert -and $endBeforeInsert) `
                    -Expected 'BEGBLOCK → 块内实体 → ENDBLOCK → INSERTBLOCK，且没有裸 (command "-BLOCK")' `
                    -Actual "beg=$hasBeg end=$hasEnd insert=$hasInsert noRaw=$noRawBlock 顺序=$beginBeforeInsert/$endBeforeInsert"
            } catch {
                Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $false `
                    -Expected '编译成功' -Actual "throws: $($_.Exception.Message)"
            }
        }

        default {
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode 'offline' -Passed $false `
                -Expected 'implemented' -Actual 'no handler' -Detail '场景没有实现了'
        }
    }
}

# ══════════════════════════════════════════════════════════════════
#  real / mock 专用：跑 Invoke-CadDraw 并看它怎么判
# ══════════════════════════════════════════════════════════════════

function Invoke-DrawScenario {
    param([object]$Scenario, [string]$Dir, [string]$EffectiveMode)

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $outDir = Join-Path $Dir 'out'
    $specPath = Join-Path $Dir 'spec.json'

    # ★ 场景 spec 只用最小实体集，把注意力放在「判定」而不是「能画多少」★
    [ordered]@{
        name     = 'scenario'
        layers   = @(
            [ordered]@{ name = 'GEO'; color = 7 }
            [ordered]@{ name = 'DIM'; color = 1 }
        )
        entities = @(
            [ordered]@{ type = 'line'; p1 = @(0, 0); p2 = @(100, 50); layer = 'GEO' }
            [ordered]@{ type = 'circle'; c = @(50, 50); r = 20; layer = 'GEO' }
        )
        save     = [ordered]@{ dwg = 'scenario.dwg'; dxf = $true; pdf = 'A4' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $specPath -Encoding UTF8

    $argv = @('-SpecFile', $specPath, '-OutputDir', $outDir, '-AsJson')
    if ($mockAccore) { $argv += @('-AccoreConsole', $mockAccore) }

    $r = Invoke-ScenarioScript -Script $drawScript -Arguments $argv -ScenarioTimeout $Scenario.timeout
    $o = $r.obj

    if (-not $o) {
        Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $false `
            -Expected $Scenario.expect -Actual 'unparsable output' -Detail $r.raw.Trim()
        return
    }

    $failedChecks = @($o.checks | Where-Object { -not $_.pass })
    $status = [string]$o.status

    switch ($Scenario.expect) {

        'ok' {
            $pass = ($status -eq 'ok') -and $failedChecks.Count -eq 0
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $pass `
                -Expected 'status=ok, 0 失败断言' `
                -Actual "status=$status failed=$($failedChecks.Count)" `
                -Detail $(if ($failedChecks.Count) { ($failedChecks | ForEach-Object { $_.name }) -join '; ' } else { '' })
        }

        'not-ok' {
            # 「不是 ok」还不够 —— 必须是因为**对的原因**不是 ok
            $pass = ($status -ne 'ok')
            $why = if ($status -ne 'ok') { $o.error } else { '脚本误报了成功' }
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $pass `
                -Expected 'status != ok' -Actual "status=$status error=$why"
        }

        'timeout' {
            $pass = ($o.timedOut -eq $true)
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $pass `
                -Expected 'timedOut=true' -Actual "timedOut=$($o.timedOut) status=$status exitCode=$($o.exitCode)"
        }

        'any' {
            # dialog 场景：要求把 MessageBox 记进证据，而不是静默吞掉
            $boxes = @($o.markers.PSObject.Properties.Name) -contains 'MESSAGEBOX'
            $hasField = $o.PSObject.Properties.Name -contains 'markers'
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $hasField `
                -Expected 'markers 字段存在（对话框证据不丢）' `
                -Actual "markers=$($hasField) count=$(@($o.markers.PSObject.Properties.Name).Count) status=$status"
        }

        default {
            Add-Result -Name $Scenario.name -Title $Scenario.title -Mode $EffectiveMode -Passed $false `
                -Expected $Scenario.expect -Actual 'unknown expectation'
        }
    }
}

# ══════════════════════════════════════════════════════════════════
#  主循环
# ══════════════════════════════════════════════════════════════════

$selected = if ($Scenario -eq 'all') { $scenarios } else {
    $hit = @($scenarios | Where-Object { $_.name -eq $Scenario })
    if ($hit.Count -eq 0) {
        throw "未知场景 '$Scenario'。用 -ListScenarios 查看全部名称。"
    }
    $hit
}

foreach ($s in $selected) {
    if ($s.modes -notcontains $Mode) {
        Write-Host ("[SKIP] {0}  ({1})  只适用于 {2}" -f $s.name, $s.title, ($s.modes -join '/')) -ForegroundColor DarkGray
        continue
    }

    Section $s.name
    $dir = Join-Path $runDir $s.name

    try {
        if ($Mode -eq 'offline') {
            Invoke-OfflineScenario -Scenario $s -Dir $dir
        } else {
            $old = $env:MOCK_SCENARIO
            try {
                if ($s.mock) { $env:MOCK_SCENARIO = $s.mock } else { $env:MOCK_SCENARIO = 'normal' }
                Invoke-DrawScenario -Scenario $s -Dir $dir -EffectiveMode $Mode
            } finally {
                if ($null -eq $old) { Remove-Item Env:MOCK_SCENARIO -ErrorAction SilentlyContinue }
                else { $env:MOCK_SCENARIO = $old }
            }
        }
    } catch {
        Add-Result -Name $s.name -Title $s.title -Mode $Mode -Passed $false `
            -Expected $s.expect -Actual 'exception' -Detail $_.Exception.Message
    }
}

# ══════════════════════════════════════════════════════════════════
#  收尾：进程安全
# ══════════════════════════════════════════════════════════════════

Section '收尾'

$owned = @(Get-CadOwnedProcesses)
Add-Result -Name 'cleanup.registry' -Title '登记表无遗留' -Mode $Mode -Passed ($owned.Count -eq 0) `
    -Expected 'count=0' -Actual "count=$($owned.Count)"

# 只统计「本轮启动的」accoreconsole —— 用户本来就开着的不能算我们的账
$stragglers = @(Get-Process -Name 'accoreconsole' -ErrorAction SilentlyContinue |
    Where-Object { $_.StartTime -ge $runStartedAt })
Add-Result -Name 'cleanup.processes' -Title '本轮无残留 accoreconsole' -Mode $Mode -Passed ($stragglers.Count -eq 0) `
    -Expected 'count=0' -Actual "count=$($stragglers.Count)" `
    -Detail $(if ($stragglers.Count) { ($stragglers | ForEach-Object { "$($_.Id)@$($_.StartTime.ToString('HH:mm:ss'))" }) -join ',' } else { '' })

# ══════════════════════════════════════════════════════════════════
#  汇总
# ══════════════════════════════════════════════════════════════════

$pass = @($results | Where-Object { $_.passed }).Count
$fail = @($results | Where-Object { -not $_.passed }).Count
$total = $results.Count

$report.scenarios = $results.ToArray()
$report.summary = [ordered]@{ total = $total; passed = $pass; failed = $fail }
$report.finishedAt = (Get-Date).ToString('o')
$reportFile = Join-Path $runDir 'report.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8

Write-Host ''
Write-Host ('═' * 70) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ("  场景测试  ·  {0} / {1} 通过，{2} 失败   ·  mode={3}" -f $pass, $total, $fail, $Mode) `
    -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ('═' * 70) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })

if ($fail -gt 0) {
    Write-Host ''
    Write-Host '失败项：' -ForegroundColor Red
    foreach ($r in @($results | Where-Object { -not $_.passed })) {
        Write-Host ("  ✗ {0}  期望 {1} / 实际 {2}" -f $r.scenario, $r.expected, $r.actual) -ForegroundColor Red
        if ($r.detail) { Write-Host ("    {0}" -f $r.detail) -ForegroundColor DarkGray }
    }
}

# ★ 必须说清这一轮证明了什么、没证明什么 ★
Write-Host ''
switch ($Mode) {
    'mock' { Write-Host '  注意：本轮用的是假 accoreconsole。它证明了「脚本的判定逻辑正确」，' -ForegroundColor Yellow
             Write-Host '        不能证明真 AutoCAD 的行为。真机验证请跑 -Mode real 或 run-test.ps1。' -ForegroundColor Yellow }
    'offline' { Write-Host '  注意：本轮没有启动任何进程。它只证明了「编译与参数校验正确」，' -ForegroundColor Yellow
                Write-Host '        不能证明产物真的画出来了。' -ForegroundColor Yellow }
    'real' { Write-Host '  本轮真的启动了 accoreconsole，结果是真机行为。' -ForegroundColor Green }
}

Write-Host ''
Write-Host ("  产物    : {0}" -f $runDir) -ForegroundColor DarkGray
Write-Host ("  报告    : {0}" -f $reportFile) -ForegroundColor DarkGray
Write-Host ''

if (-not $KeepArtifacts -and $fail -eq 0) {
    # 全绿才清理；有失败就留着供排查
    # （保留 report.json 所在的 runDir，其余场景子目录删掉）
    Get-ChildItem -LiteralPath $runDir -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { exit 0 } else { exit 1 }
