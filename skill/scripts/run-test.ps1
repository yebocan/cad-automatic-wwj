<#
.SYNOPSIS
    cad-automatic-wwj 集成自检 —— 真实调用 accoreconsole，逐项断言产物。

.DESCRIPTION
    与 run-unit-test.ps1 的分工：
      · run-unit-test.ps1    纯离线，只验编码/编译/解析/登记表这些纯逻辑，不启动 CAD。
      · run-test.ps1（本脚本）真的开 accoreconsole 出图，验「产物真的落地且内容对」。

    为什么必须分开：离线单测能证明「生成的 LISP 长这样」，但证明不了
    「accoreconsole 真的按这个 LISP 画出了东西」。两者都过才算这个 skill 可用。

    所有产物写在 -OutputDirectory 下，绝不写进 skill 安装目录。

.PARAMETER Test
    all     —— 全部例程（默认）
    draw    —— 出图：DWG / DXF / PDF 三产物 + 回执标记
    inspect —— 体检：DXF 与 DWG 两条路径
    export  —— 导出：DWG → DXF 各版本
    plot    —— 打印：改方向/图纸尺寸
    repair  —— 修复：故意造坏再让它修

.PARAMETER KeepArtifacts
    保留临时工作目录（默认清理，只留报告里记的产物路径）。
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'draw', 'inspect', 'export', 'plot', 'repair')]
    [string]$Test = 'all',

    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'cad-integration-tests'),

    [string]$AccoreConsole,

    # 总预算。每个子步骤还会各自带超时，这里是兜底闸。
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 900,

    # 出图后是否再用 Invoke-CadInspect 独立复核（默认复核 —— 不复核就只是
    # 「脚本说成功」，那不算证据）。
    [switch]$SkipCrossCheck,

    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CadCommon.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$drawScript = Join-Path $PSScriptRoot 'Invoke-CadDraw.ps1'
$inspectScript = Join-Path $PSScriptRoot 'Invoke-CadInspect.ps1'
$exportScript = Join-Path $PSScriptRoot 'Export-CadToDxf.ps1'
$plotScript = Join-Path $PSScriptRoot 'Invoke-CadPlot.ps1'
$repairScript = Join-Path $PSScriptRoot 'Invoke-CadRepair.ps1'

foreach ($f in @($drawScript, $inspectScript, $exportScript, $plotScript, $repairScript)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "缺少必需脚本: $f" }
}

# ══════════════════════════════════════════════════════════════════
#  结果收集
# ══════════════════════════════════════════════════════════════════

$checks = [Collections.Generic.List[object]]::new()

function Add-Check([string]$name, [bool]$passed, [string]$detail = '') {
    $script:checks.Add([pscustomobject]@{ check = $name; passed = $passed; detail = $detail })
    $mark = if ($passed) { 'PASS' } else { 'FAIL' }
    $line = "[$mark] $name"
    if ($detail) { $line += " — $detail" }
    Write-Output $line
}

function Section([string]$title) {
    Write-Output ''
    Write-Output ("── $title " + ('─' * [Math]::Max(4, 68 - $title.Length)))
}

# 总超时闸：任何等待都要先过这道闸，避免某个轮询卡死整轮自检
$script:deadline = (Get-Date).AddSeconds($TimeoutSeconds)
function Get-RemainingSeconds {
    return [int][Math]::Max(0, ($script:deadline - (Get-Date)).TotalSeconds)
}
function Assert-Budget([string]$stage, [int]$need) {
    $left = Get-RemainingSeconds
    if ($left -lt $need) { throw "总超时预算不足（$stage 需要 ${need}s，剩 ${left}s）" }
    return $left
}

# 各例程都要一张可用 DWG 当输入。单独跑 export/plot/repair 时
# draw 例程没跑过，目录里什么都没有，不能直接判失败 —— 现画一张最小的。
# 这是「例程之间不互相依赖」的关键：任何单例程都必须能独立成立。
function Get-TestDwg {
    param([string]$PreferSubdir = 'draw', [string]$PreferName = 'integration-draw.dwg')

    $p = Join-Path $runDir "$PreferSubdir\$PreferName"
    if (Test-Path -LiteralPath $p) { return $p }
    $p = Join-Path $runDir 'mini\integration-mini.dwg'
    if (Test-Path -LiteralPath $p) { return $p }

    $miniSpec = Join-Path $runDir 'mini.json'
    $miniOut = Join-Path $runDir 'mini'
    [ordered]@{
        name     = 'integration-mini'
        layers   = @([ordered]@{ name = 'GEO'; color = 7 })
        entities = @(
            [ordered]@{ type = 'circle'; c = @(50, 50); r = 25 }
            [ordered]@{ type = 'line'; p1 = @(0, 0); p2 = @(100, 100) }
        )
        save     = [ordered]@{ dwg = 'integration-mini.dwg'; dxf = $true }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $miniSpec -Encoding UTF8
    & $drawScript -SpecFile $miniSpec -OutputDir $miniOut -AsJson -TimeoutSeconds (Get-RemainingSeconds) | Out-Null
    return (Join-Path $miniOut 'integration-mini.dwg')
}

# ══════════════════════════════════════════════════════════════════
#  环境准备
# ══════════════════════════════════════════════════════════════════

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$runToken = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDir = Join-Path $outputRoot ('run_' + $runToken)
New-Item -ItemType Directory -Path $runDir | Out-Null

$report = [ordered]@{
    skill      = $script:CadSkillName
    test       = $Test
    startedAt  = (Get-Date).ToString('o')
    runDir     = $runDir
    accore     = $null
    sections   = @()
    checks     = @()
    passed     = 0
    failed     = 0
    status     = 'unknown'
    durationMs = 0
    error      = $null
}

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$runStartedAt = (Get-Date)

try {
    Section '0. 环境'
    $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    if (-not $accoreInfo -or -not $accoreInfo.path) {
        Add-Check 'accoreconsole 可定位' $false '找不到 accoreconsole.exe，请先跑 Set-CadPath.ps1'
        throw 'accoreconsole 未配置'
    }
    $report.accore = $accoreInfo
    Add-Check 'accoreconsole 可定位' $true "$($accoreInfo.path)（来源 $($accoreInfo.source)）"

    $coreLsp = Join-Path $PSScriptRoot 'cadcore.lsp'
    Add-Check 'cadcore.lsp 存在' (Test-Path -LiteralPath $coreLsp) (Split-Path -Leaf $coreLsp)

    # 源文件必须是 UTF-8（给人看/git diff），运行时副本才转 GBK。
    # 这条以前踩过：把源文件转成 GBK 后 git diff 全是二进制。
    $coreBytes = [IO.File]::ReadAllBytes($coreLsp)
    $hasBom = ($coreBytes.Length -ge 3 -and $coreBytes[0] -eq 0xEF -and $coreBytes[1] -eq 0xBB -and $coreBytes[2] -eq 0xBF)
    Add-Check 'cadcore.lsp 源文件无 BOM' (-not $hasBom) "bytes=$($coreBytes.Length)"

    $stale = @(Get-CadOwnedProcesses)
    Add-Check '无遗留登记进程' ($stale.Count -eq 0) "count=$($stale.Count)"
    if ($stale.Count -gt 0) {
        foreach ($s in $stale) { Write-Output "        遗留: pid=$($s.pid) kind=$($s.kind) source=$($s.source)" }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 1：出图 —— DWG / DXF / PDF 三产物
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'draw')) {
        Section '1. 出图：三产物 + 回执'
        Assert-Budget 'draw' 60 | Out-Null

        $specPath = Join-Path $runDir 'draw.json'
        $drawOut = Join-Path $runDir 'draw'
        $spec = [ordered]@{
            name    = 'integration-draw'
            units   = 'mm'
            layers  = @(
                [ordered]@{ name = 'GEO'; color = 7 },
                [ordered]@{ name = 'HOLE'; color = 1 },
                [ordered]@{ name = 'DIM'; color = 3 },
                [ordered]@{ name = 'TXT'; color = 5 }
            )
            # 块定义必须能被真正建出来：-BLOCK 不能「开着让后面实体自动入块」，
            # 必须先把实体画到模型空间再用选择集一次性喂进去。
            # 集成测试放一个 2 圆的块 + 一次带缩放的插入，覆盖这条链路。
            blocks   = @(
                [ordered]@{
                    name     = 'BOLT_M12'
                    base     = @(0, 0)
                    entities = @(
                        [ordered]@{ type = 'circle'; c = @(0, 0); r = 6 }
                        [ordered]@{ type = 'circle'; c = @(0, 0); r = 3 }
                    )
                }
            )
            entities = @(
                [ordered]@{ type = 'rect'; layer = 'GEO'; p1 = @(0, 0); p2 = @(200, 120) }
                [ordered]@{ type = 'circle'; layer = 'HOLE'; c = @(60, 60); r = 20 }
                [ordered]@{ type = 'circle'; layer = 'HOLE'; c = @(140, 60); r = 20 }
                [ordered]@{ type = 'line'; layer = 'GEO'; p1 = @(60, 60); p2 = @(140, 60) }
                [ordered]@{ type = 'arc'; layer = 'GEO'; c = @(100, 60); r = 50; start = 0; end = 180 }
                [ordered]@{ type = 'polyline'; layer = 'GEO'; points = @(@(0, 130), @(100, 160), @(200, 130)) }
                [ordered]@{ type = 'text'; layer = 'TXT'; at = @(10, 128); height = 6; value = '集成自检图纸' }
                [ordered]@{ type = 'mtext'; layer = 'TXT'; at = @(10, 110); width = 80; height = 4; value = "多行文字`n第二行" }
                [ordered]@{ type = 'dimlinear'; layer = 'DIM'; p1 = @(0, 0); p2 = @(200, 0); at = @(100, -15) }
                [ordered]@{ type = 'dimaligned'; layer = 'DIM'; p1 = @(0, 130); p2 = @(100, 160); at = @(40, 155) }
                [ordered]@{ type = 'dimradius'; layer = 'DIM'; c = @(60, 60); r = 20 }
                [ordered]@{ type = 'hatch'; layer = 'GEO'; pattern = 'ANSI31'; scale = 2; at = @(100, 30) }
                [ordered]@{ type = 'block'; layer = 'HOLE'; name = 'BOLT_M12'; at = @(170, 30); scaleX = 2; scaleY = 2; rotation = 15 }
            )
            save     = [ordered]@{ dwg = 'integration-draw.dwg'; dxf = $true; pdf = 'A4' }
        }
        $spec | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $specPath -Encoding UTF8

        $drawRaw = & $drawScript -SpecFile $specPath -OutputDir $drawOut -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
        $draw = $null
        try { $draw = $drawRaw | ConvertFrom-Json } catch { }
        if (-not $draw) {
            Add-Check 'draw.ran' $false ("出图脚本没有返回可解析的 JSON：" + $drawRaw.Trim())
        } else {
            $report.sections += 'draw'
            Add-Check 'draw.status' ($draw.status -eq 'ok') "status=$($draw.status)"
            Add-Check 'draw.exitCode' ($draw.exitCode -eq 0) "exitCode=$($draw.exitCode) ($($draw.exitName))"
            Add-Check 'draw.notTimedOut' (-not $draw.timedOut) "timedOut=$($draw.timedOut) durationMs=$($draw.durationMs)"

            $checksArr = @($draw.checks)
            $failedChecks = @($checksArr | Where-Object { -not $_.pass })
            Add-Check 'draw.内部校验全过' ($failedChecks.Count -eq 0) `
                ("$($checksArr.Count - $failedChecks.Count)/$($checksArr.Count) 通过" +
                 $(if ($failedChecks.Count -gt 0) { '；失败: ' + (($failedChecks | ForEach-Object { $_.name }) -join ', ') } else { '' }))

            # 产物独立断言：不信脚本自述，自己看文件
            $dwgPath = Join-Path $drawOut 'integration-draw.dwg'
            $dxfPath = Join-Path $drawOut 'integration-draw.dxf'
            $pdfPath = Join-Path $drawOut 'integration-draw.pdf'

            $dwgOk = (Test-Path -LiteralPath $dwgPath) -and ((Get-Item -LiteralPath $dwgPath).Length -gt 2048)
            Add-Check 'draw.DWG 落地' $dwgOk `
                $(if (Test-Path -LiteralPath $dwgPath) { "$((Get-Item -LiteralPath $dwgPath).Length) 字节" } else { '文件不存在' })

            $dxfChk = $null
            if (Test-Path -LiteralPath $dxfPath) { $dxfChk = Test-CadDxfFile -Path $dxfPath }
            Add-Check 'draw.DXF 结构有效' ($null -ne $dxfChk -and $dxfChk.valid) `
                $(if ($dxfChk) { "valid=$($dxfChk.valid) 实体=$($dxfChk.entityCount) 段=$($dxfChk.sectionCount) reason=$($dxfChk.reason)" } else { '文件不存在' })

            $pdfOk = (Test-Path -LiteralPath $pdfPath) -and ((Get-Item -LiteralPath $pdfPath).Length -gt 1024)
            $pdfHead = ''
            if (Test-Path -LiteralPath $pdfPath) {
                $pb = [IO.File]::ReadAllBytes($pdfPath)
                if ($pb.Length -ge 4) { $pdfHead = [Text.Encoding]::ASCII.GetString($pb, 0, 4) }
            }
            Add-Check 'draw.PDF 落地且是 PDF' ($pdfOk -and $pdfHead -eq '%PDF') `
                $(if (Test-Path -LiteralPath $pdfPath) { "$((Get-Item -LiteralPath $pdfPath).Length) 字节 head=$pdfHead" } else { '文件不存在' })

            # 回执标记：@@DONE@@ 与 @@COUNT=n@@ 都在，说明 LISP 真的跑到底了。
            # 报告里的 markers 是 {名称: 值} 字典（Invoke-CadDraw 已归并），
            # 不要用 Get-CadMarker —— 它吃的是执行结果对象，不是报告对象。
            $markerDict = $draw.markers
            $doneVal = $null
            if ($markerDict -and $markerDict.PSObject.Properties.Name -contains 'DONE') { $doneVal = $markerDict.DONE }
            Add-Check 'draw.回执 @@DONE@@' ($null -ne $doneVal) "DONE=$doneVal"
            $countVal = $null
            if ($markerDict -and $markerDict.PSObject.Properties.Name -contains 'COUNT') { $countVal = $markerDict.COUNT }
            Add-Check 'draw.回执 @@COUNT@@' ($null -ne $countVal) "COUNT=$countVal"

            # 交叉复核：用另一个脚本独立读这张图，不看绘图方的结论
            if (-not $SkipCrossCheck -and $dxfChk -and $dxfChk.valid) {
                $insRaw = & $inspectScript -Path $dxfPath -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
                $ins = $null
                try { $ins = $insRaw | ConvertFrom-Json } catch { }
                if (-not $ins) {
                    Add-Check 'draw.交叉复核可解析' $false ("Inspect 没有返回 JSON：" + $insRaw.Trim())
                } else {
                    Add-Check 'draw.交叉复核 ok' ($ins.status -eq 'ok') "status=$($ins.status) 实体=$($ins.entityCount)"
                    # 声明的 12 个实体里，hatch 会产生额外边界实体、arc 可能拆分，
                    # 所以断言「不少于声明数 - 1」而不是「等于」。
                    # （dimradius 的标注会引用而不新增实体，实际落地通常正好等于声明数。）
                    Add-Check 'draw.交叉复核实体数合理' ($ins.entityCount -ge 12) "entityCount=$($ins.entityCount)（声明 13，含 1 个块插入）"
                    $types = @($ins.entityTypes)
                    $hasCircle = @($types | Where-Object { $_.type -eq 'CIRCLE' }).Count -gt 0
                    $hasText = @($types | Where-Object { $_.type -in 'TEXT', 'MTEXT' }).Count -gt 0
                    $hasDim = @($types | Where-Object { $_.type -eq 'DIMENSION' }).Count -gt 0
                    Add-Check 'draw.交叉复核含圆/文字/标注' ($hasCircle -and $hasText -and $hasDim) `
                        ("类型: " + (($types | ForEach-Object { "$($_.type)=$($_.count)" }) -join ' '))
                    # 块必须真的被建出来并被引用 —— 这条是「-BLOCK 卡死」的直接回归哨兵。
                    # 块定义里的 2 个圆会进 BLOCKS 段，模型空间里那个 INSERT 才是证据。
                    $hasInsert = @($types | Where-Object { $_.type -eq 'INSERT' }).Count -gt 0
                    Add-Check 'draw.模型空间有块插入（INSERT）' $hasInsert `
                        ("类型: " + (($types | ForEach-Object { "$($_.type)=$($_.count)" }) -join ' '))
                    $blkSection = Get-CadDxfBlockNames -Path $dxfPath
                    $blkNamed = @($blkSection | Where-Object { $_ -eq 'BOLT_M12' }).Count -gt 0
                    Add-Check 'draw.块定义 BOLT_M12 存在' $blkNamed ("块: " + ($blkSection -join ', '))
                    # 中文必须没被编码搞坏 —— 这是本 skill 最容易复发的一条
                    $mtext = @(@(Get-CadDxfEntities -Path $dxfPath) | Where-Object { $_.type -eq 'MTEXT' })
                    $mtextOk = $mtext.Count -ge 1 -and $mtext[0].text -like '*多行文字*'
                    Add-Check 'draw.中文未乱码' $mtextOk $(if ($mtext.Count -ge 1) { "MTEXT=[$($mtext[0].text)]" } else { '没有 MTEXT' })
                }
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 2：体检 —— DXF 与 DWG 两条路径
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'inspect')) {
        Section '2. 体检：DXF 与 DWG 两条路径'
        Assert-Budget 'inspect' 40 | Out-Null

        # 复用上一例程的产物；单独跑 inspect 时现画一张
        $dwgPath = Join-Path $runDir 'draw\integration-draw.dwg'
        $dxfPath = Join-Path $runDir 'draw\integration-draw.dxf'
        if (-not (Test-Path -LiteralPath $dwgPath)) {
            $miniSpec = Join-Path $runDir 'mini.json'
            $miniOut = Join-Path $runDir 'mini'
            [ordered]@{
                name     = 'integration-mini'
                layers   = @([ordered]@{ name = 'GEO'; color = 7 })
                entities = @(
                    [ordered]@{ type = 'circle'; c = @(50, 50); r = 25 }
                    [ordered]@{ type = 'line'; p1 = @(0, 0); p2 = @(100, 100) }
                )
                save     = [ordered]@{ dwg = 'integration-mini.dwg'; dxf = $true }
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $miniSpec -Encoding UTF8
            & $drawScript -SpecFile $miniSpec -OutputDir $miniOut -AsJson -TimeoutSeconds (Get-RemainingSeconds) | Out-Null
            $dwgPath = Join-Path $miniOut 'integration-mini.dwg'
            $dxfPath = Join-Path $miniOut 'integration-mini.dxf'
        }

        if (Test-Path -LiteralPath $dxfPath) {
            $r = & $inspectScript -Path $dxfPath -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
            $o = $null; try { $o = $r | ConvertFrom-Json } catch { }
            if (-not $o) {
                Add-Check 'inspect.DXF 可解析' $false ($r.Trim())
            } else {
                $report.sections += 'inspect-dxf'
                Add-Check 'inspect.DXF status' ($o.status -eq 'ok') "status=$($o.status) format=$($o.format)"
                Add-Check 'inspect.DXF 有实体' ($o.entityCount -gt 0) "entityCount=$($o.entityCount)"
                Add-Check 'inspect.DXF 有图层' (@($o.layers).Count -gt 0) ("layers=" + (@($o.layers) -join ','))
                Add-Check 'inspect.DXF 有范围' ($null -ne $o.extents) `
                    $(if ($o.extents) { "X[$($o.extents.minX),$($o.extents.maxX)] Y[$($o.extents.minY),$($o.extents.maxY)]" } else { 'extents=null' })
            }
        } else {
            Add-Check 'inspect.DXF 源文件存在' $false $dxfPath
        }

        # DWG 路径：内部要先转 DXF 再读，最容易卡在转换上
        if (Test-Path -LiteralPath $dwgPath) {
            $r2 = & $inspectScript -Path $dwgPath -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
            $o2 = $null; try { $o2 = $r2 | ConvertFrom-Json } catch { }
            if (-not $o2) {
                Add-Check 'inspect.DWG 可解析' $false ($r2.Trim())
            } else {
                $report.sections += 'inspect-dwg'
                Add-Check 'inspect.DWG status' ($o2.status -eq 'ok') "status=$($o2.status) format=$($o2.format)"
                Add-Check 'inspect.DWG 有实体' ($o2.entityCount -gt 0) "entityCount=$($o2.entityCount)"
                Add-Check 'inspect.DWG 实体数与 DXF 一致' `
                    ($null -eq $dxfPath -or -not (Test-Path -LiteralPath $dxfPath) -or `
                     $o2.entityCount -eq (Test-CadDxfFile -Path $dxfPath).entityCount) `
                    "dwg=$($o2.entityCount)"
            }
        } else {
            Add-Check 'inspect.DWG 源文件存在' $false $dwgPath
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 3：导出 —— DWG → DXF 多版本
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'export')) {
        Section '3. 导出：DWG → DXF 多版本'
        Assert-Budget 'export' 40 | Out-Null

        $dwgPath = Get-TestDwg
        if (-not (Test-Path -LiteralPath $dwgPath)) {
            Add-Check 'export.源 DWG 存在' $false '没能造出可导出的 DWG'
        } else {
            $expDir = Join-Path $runDir 'export'
            New-Item -ItemType Directory -Path $expDir -Force | Out-Null
            # 只测两个有代表性的版本：最新（2018）与最老（R12）。
            # 全测一遍要 5 次 accoreconsole 启动，性价比太低。
            foreach ($ver in @('2018', 'R12')) {
                $outFile = Join-Path $expDir "export-$ver.dxf"
                $r = & $exportScript -Path $dwgPath -Output $outFile -Version $ver -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
                $o = $null; try { $o = $r | ConvertFrom-Json } catch { }
                if (-not $o) {
                    Add-Check "export.$ver 可解析" $false ($r.Trim())
                    continue
                }
                $report.sections += "export-$ver"
                Add-Check "export.$ver status" ($o.status -eq 'ok') "status=$($o.status) version=$($o.version)"
                Add-Check "export.$ver 文件落地" ((Test-Path -LiteralPath $outFile) -and ((Get-Item -LiteralPath $outFile).Length -gt 1024)) `
                    $(if (Test-Path -LiteralPath $outFile) { "$((Get-Item -LiteralPath $outFile).Length) 字节" } else { '不存在' })
                $chk = $null
                if (Test-Path -LiteralPath $outFile) { $chk = Test-CadDxfFile -Path $outFile }
                Add-Check "export.$ver 结构有效" ($chk -and $chk.valid) `
                    $(if ($chk) { "实体=$($chk.entityCount) 版本=$($chk.version)" } else { '未生成' })
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 4：打印 —— 改方向与图纸尺寸
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'plot')) {
        Section '4. 打印：改方向与图纸尺寸'
        Assert-Budget 'plot' 40 | Out-Null

        $dwgPath = Get-TestDwg
        if (-not (Test-Path -LiteralPath $dwgPath)) {
            Add-Check 'plot.源 DWG 存在' $false '没能造出可打印的 DWG'
        } else {
            $plotDir = Join-Path $runDir 'plot'
            New-Item -ItemType Directory -Path $plotDir -Force | Out-Null
            # 与出图例程的 A4/横向 区分开，才证明参数真的生效
            $outPdf = Join-Path $plotDir 'plot-a3-portrait.pdf'
            $r = & $plotScript -Path $dwgPath -Output $outPdf -PaperSize 'A3' -Orientation 'Portrait' `
                               -PlotArea 'Extents' -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
            $o = $null; try { $o = $r | ConvertFrom-Json } catch { }
            if (-not $o) {
                Add-Check 'plot 可解析' $false ($r.Trim())
            } else {
                $report.sections += 'plot'
                Add-Check 'plot.status' ($o.status -eq 'ok') "status=$($o.status)"
                Add-Check 'plot.paperSize' ($o.paperSize -eq 'A3') "paperSize=$($o.paperSize) orientation=$($o.orientation)"
                # 用结构化校验而不是只看 4 字节头：截断的 PDF 头也对，
                # 但没有 %%EOF 和页面对象，属于「PLOT 半途死掉」的产物。
                $pdfInfo = Test-CadPdfFile -Path $outPdf
                Add-Check 'plot.PDF 结构有效' ([bool]$pdfInfo.valid) `
                    $(if ($pdfInfo.valid) { "$($pdfInfo.byteLength) 字节 / $($pdfInfo.pageCount) 页" } else { "invalid: $($pdfInfo.reason)" })
                Add-Check 'plot.orientation 生效' ($o.orientation -eq 'Portrait') "orientation=$($o.orientation)"
                Add-Check 'plot.plotArea 回显' ($o.plotArea -eq 'Extents') "plotArea=$($o.plotArea)"
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 5：修复 —— 故意造坏再让它修
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'repair')) {
        Section '5. 修复：造坏再修'
        Assert-Budget 'repair' 30 | Out-Null

        # 造三个可修的坏：0 字节 DWG、遗留工作目录、缺目标目录
        $repairDir = Join-Path $runDir 'repair'
        New-Item -ItemType Directory -Path $repairDir -Force | Out-Null
        $emptyDwg = Join-Path $repairDir 'broken.dwg'
        [IO.File]::WriteAllBytes($emptyDwg, @())
        $missingDir = Join-Path $repairDir 'not-yet'
        $staleWork = Join-Path $script:CadStateDir ('draw-stale-' + $runToken)
        New-Item -ItemType Directory -Path $staleWork -Force | Out-Null

        $r = & $repairScript -Path $emptyDwg -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
        $o = $null; try { $o = $r | ConvertFrom-Json } catch { }
        if (-not $o) {
            Add-Check 'repair 可解析' $false ($r.Trim())
        } else {
            $report.sections += 'repair'
            Add-Check 'repair.status 非 failed' ($o.status -ne 'failed') "status=$($o.status)"
            $findings = @($o.findings)
            Add-Check 'repair.有 findings' ($findings.Count -gt 0) "findings=$($findings.Count)"
            $r09 = @($findings | Where-Object { $_.id -eq 'R09' })
            Add-Check 'repair.识别 0 字节 DWG' ($r09.Count -eq 1) `
                $(if ($r09.Count -eq 1) { "severity=$($r09[0].severity) repairable=$($r09[0].repairable) repaired=$($r09[0].repaired)" } else { '未识别到 R09' })
            $r05 = @($findings | Where-Object { $_.id -eq 'R05' })
            Add-Check 'repair.识别遗留工作目录' ($r05.Count -ge 1) `
                $(if ($r05.Count -ge 1) { "repaired=$($r05[0].repaired)" } else { '未识别到 R05' })
            # 修完要真的消失，不能只是报告说修了
            Add-Check 'repair.0 字节 DWG 已清理' (-not (Test-Path -LiteralPath $emptyDwg)) `
                $(if (Test-Path -LiteralPath $emptyDwg) { '文件仍在' } else { '已删除' })
            Add-Check 'repair.遗留目录已清理' (-not (Test-Path -LiteralPath $staleWork)) `
                $(if (Test-Path -LiteralPath $staleWork) { '目录仍在' } else { '已删除' })

            # -DryRun 必须不动任何东西
            $dryDwg = Join-Path $repairDir 'dry.dwg'
            [IO.File]::WriteAllBytes($dryDwg, @())
            $r2 = & $repairScript -Path $dryDwg -DryRun -AsJson -TimeoutSeconds (Get-RemainingSeconds) 2>&1 | Out-String
            $o2 = $null; try { $o2 = $r2 | ConvertFrom-Json } catch { }
            Add-Check 'repair.DryRun 模式标记' ($o2 -and $o2.mode -eq 'dry-run') $(if ($o2) { "mode=$($o2.mode)" } else { '解析失败' })
            Add-Check 'repair.DryRun 不删文件' (Test-Path -LiteralPath $dryDwg) '文件应保留'
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  收尾：进程必须干净
    # ══════════════════════════════════════════════════════════════
    Section '6. 收尾'
    $leftover = @(Get-CadOwnedProcesses)
    Add-Check '无残留登记进程' ($leftover.Count -eq 0) `
        $(if ($leftover.Count -eq 0) { '干净' } else { (($leftover | ForEach-Object { "pid=$($_.pid)" }) -join ', ') })

    # 只统计「本轮开始之后才启动的」accoreconsole。
    # 用户可能本来就有别的 CAD 任务在跑，把别人的进程算成自己的残留是误报；
    # 反过来，用「有没有进程」一刀切也会把历史僵尸当成新失败。
    $accoreProcs = @(Get-Process -Name 'accoreconsole' -ErrorAction SilentlyContinue |
                     Where-Object {
                         try { $_.StartTime -ge $runStartedAt } catch { $true }
                     })
    Add-Check '本轮无残留 accoreconsole' ($accoreProcs.Count -eq 0) `
        $(if ($accoreProcs.Count -eq 0) { '干净' }
          else { (($accoreProcs | ForEach-Object { "pid=$($_.Id)" }) -join ', ') })

    $others = @(Get-Process -Name 'accoreconsole' -ErrorAction SilentlyContinue |
                Where-Object { try { $_.StartTime -lt $runStartedAt } catch { $false } })
    if ($others.Count -gt 0) {
        Write-Output "        提示: 另有 $($others.Count) 个早于本轮启动的 accoreconsole（非本 skill 启动，未触碰）: $(($others | ForEach-Object { "pid=$($_.Id)" }) -join ', ')"
    }

} catch {
    $report.error = $_.Exception.Message
    Add-Check '未抛异常' $false $_.Exception.Message
} finally {
    $stopwatch.Stop()
    $report.durationMs = [int]$stopwatch.ElapsedMilliseconds
    $report.checks = @($checks)
    $report.passed = @($checks | Where-Object { $_.passed }).Count
    $report.failed = @($checks | Where-Object { -not $_.passed }).Count
    $report.status = if ($report.failed -eq 0 -and -not $report.error) { 'pass' } else { 'fail' }

    $reportPath = Join-Path $runDir 'report.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if (-not $KeepArtifacts) {
        # 只清临时工作目录，产物（runDir 下的 dwg/dxf/pdf）保留
        $stale = @(Get-ChildItem -Path $script:CadStateDir -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^(draw|plot|inspect|export|repair)-' })
        foreach ($d in $stale) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ══════════════════════════════════════════════════════════════════
#  输出
# ══════════════════════════════════════════════════════════════════

Write-Output ''
Write-Output ('═' * 66)
if ($report.status -eq 'pass') {
    Write-Output "  集成自检  ·  $($report.passed) / $($report.passed + $report.failed) 通过，0 失败"
} else {
    Write-Output "  集成自检  ·  $($report.passed) / $($report.passed + $report.failed) 通过，$($report.failed) 失败"
    if ($report.error) { Write-Output "  错误: $($report.error)" }
}
Write-Output ('═' * 66)
Write-Output "  例程    : $Test"
Write-Output "  耗时    : $([Math]::Round($report.durationMs / 1000, 1)) 秒"
Write-Output "  产物    : $runDir"
Write-Output "  报告    : $reportPath"
Write-Output ('═' * 66)

if ($report.failed -gt 0 -or $report.error) { exit 1 } else { exit 0 }
