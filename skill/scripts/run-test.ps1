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
    evidence —— 证据链与清单：五态结论 + manifest 自比对
    pdf2dxf  —— PDF 矢量路径 → DXF

.PARAMETER KeepArtifacts
    保留临时工作目录（默认清理，只留报告里记的产物路径）。
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'draw', 'inspect', 'export', 'plot', 'repair', 'evidence', 'pdf2dxf')]
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
. (Join-Path $PSScriptRoot 'CadEvidence.ps1')
. (Join-Path $PSScriptRoot 'CadPdf.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$drawScript = Join-Path $PSScriptRoot 'Invoke-CadDraw.ps1'
$inspectScript = Join-Path $PSScriptRoot 'Invoke-CadInspect.ps1'
$exportScript = Join-Path $PSScriptRoot 'Export-CadToDxf.ps1'
$plotScript = Join-Path $PSScriptRoot 'Invoke-CadPlot.ps1'
$repairScript = Join-Path $PSScriptRoot 'Invoke-CadRepair.ps1'
$pdf2dxfScript = Join-Path $PSScriptRoot 'Convert-CadPdfToDxf.ps1'

foreach ($f in @($drawScript, $inspectScript, $exportScript, $plotScript, $repairScript, $pdf2dxfScript)) {
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
    #  例程 7：证据链与清单 —— 五态结论 + manifest 自比对
    #
    #  这一例程不启动 accoreconsole：证据分级、五态结论、manifest 全是
    #  纯逻辑，放在集成测试里是为了证明「draw 例程产出的那份清单
    #  真的能被读回来、真的能检出差异」。
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'evidence')) {
        Section '7. 证据链与清单：五态结论 + manifest'
        Assert-Budget 'evidence' 20 | Out-Null

        $evDir = Join-Path $runDir 'evidence'
        New-Item -ItemType Directory -Path $evDir -Force | Out-Null

        # 五态优先级：blocked > fail > needs_review > pass_with_warnings > pass
        $evKnown    = New-CadEvidence -Kind 'test' -Level 'known'    -Message '直接读到' -Source 'run-test'
        $evScaled   = New-CadEvidence -Kind 'test' -Level 'scaled'   -Message '换算得到' -Source 'run-test'
        $evInferred = New-CadEvidence -Kind 'test' -Level 'inferred' -Message '推断'     -Source 'run-test'
        $evUnread   = New-CadEvidence -Kind 'test' -Level 'unreadable' -Message '读不到' -Source 'run-test'

        $allOk = @([pscustomobject]@{ name = 'a'; pass = $true })
        $oneFail = @([pscustomobject]@{ name = 'a'; pass = $true }, [pscustomobject]@{ name = 'b'; pass = $false })

        Add-Check 'evidence.全 known → pass' ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown)) -eq 'pass') ''
        Add-Check 'evidence.有 warning → pass_with_warnings' `
            ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown) -Warnings @('线型回落')) -eq 'pass_with_warnings') ''
        Add-Check 'evidence.unreadable → needs_review' `
            ((Get-CadDisposition -Checks $allOk -Evidence @($evKnown, $evUnread)) -eq 'needs_review') ''
        Add-Check 'evidence.error 且有产物 → fail（不升级 blocked）' `
            ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown) -Error '炸了' -Artifacts @(@{ kind = 'dwg'; exists = $true })) -eq 'fail') ''
        # blocked 与 fail 的分界不是「有没有产物」，而是「有没有给出阻塞原因」：
        #   blocked = 明确知道为什么跑不下去（环境缺失、输入不可读），给出原因
        #   fail    = 真的跑了但结果不对
        # 产物存在与否只影响调用方能不能救回半成品，不改变结论档位。
        Add-Check 'evidence.有阻塞原因 → blocked' `
            ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown) -Error '炸了' -Artifacts @() -BlockedReason 'accoreconsole 定位不到') -eq 'blocked') ''
        Add-Check 'evidence.无阻塞原因 → fail' `
            ((Get-CadDisposition -Checks $oneFail -Evidence @($evKnown) -Error '炸了' -Artifacts @()) -eq 'fail') ''

        # manifest：写一份、读回来、自比对 identical，再改一个数让它检出差异
        $manSpec = Join-Path $evDir 'manifest-spec.json'
        $manBody = @{ units = 'mm'; entities = @(@{ type = 'line'; p1 = @(0, 0); p2 = @(10, 0) }) }
        [IO.File]::WriteAllText($manSpec, ($manBody | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

        $manPath = Join-Path $evDir 'manifest.json'
        $artifact = Join-Path $evDir 'artifact.dwg'
        [IO.File]::WriteAllBytes($artifact, ([byte[]](1..64)))
        $man = New-CadManifest -SpecFile $manSpec -Spec $manBody -DrawingName 'evidence-probe' `
            -Artifacts @(@{ kind = 'dwg'; path = $artifact }) -Evidence @($evKnown) `
            -Disposition 'pass' -Units 'mm' -UnitsCode 4 -EntityCount 1 -Layers @('GEO')
        Add-Check 'manifest.specSha256 已算' ([string]$man.specSha256).Length -eq 64 "specSha256=$($man.specSha256)"
        Add-Check 'manifest.cadCoreSha256 已算' ([string]$man.cadCoreSha256).Length -eq 64 "cadCoreSha256=$($man.cadCoreSha256)"

        $wrote = Write-CadManifest -Manifest $man -Path $manPath
        Add-Check 'manifest 落盘' ([string]$wrote -eq $manPath -and (Test-Path -LiteralPath $manPath)) "path=$wrote"

        $cmp = $null
        # Compare-CadManifest 吃的是两个清单**对象**（-Before / -After），
        # 不是文件路径。先读回来再比 —— 这样也顺带验了 Write 落盘的 JSON
        # 能被读回成同一份清单（复现链条的最后一环）。
        $readBack = $null
        try { $readBack = (Get-Content -LiteralPath $manPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
        if ($readBack) { $cmp = Compare-CadManifest -Before $readBack -After $man }
        Add-Check 'manifest 自比对 identical' ($cmp -and $cmp.identical) $(if ($cmp) { "diffs=$($cmp.diffCount)" } else { '读不到' })

        # 改实体数后必须检出差异
        if ($readBack) {
            $man2 = $readBack.PSObject.Copy()
            $man2 | Add-Member -NotePropertyName 'entityCount' -NotePropertyValue 99 -Force
            $cmp2 = Compare-CadManifest -Before $man -After $man2
            $diffText = @($cmp2.diffs | ForEach-Object { $_.field }) -join ','
            Add-Check 'manifest 检出实体数差异' ($cmp2 -and -not $cmp2.identical -and $diffText -match 'entityCount') "diffs=$diffText"
        } else {
            Add-Check 'manifest 检出实体数差异' $false '清单读不回来'
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  例程 8：PDF 矢量路径 → DXF
    #
    #  用上一例程留下的真 PDF（plot 或 draw 的产物）当输入。
    #  没有可用 PDF 时自己造一个只含矢量内容流的简易 PDF，
    #  不让这一例程因为前一个例程被跳过而失效。
    # ══════════════════════════════════════════════════════════════
    if ($Test -in @('all', 'pdf2dxf')) {
        Section '8. PDF 矢量路径 → DXF'
        Assert-Budget 'pdf2dxf' 30 | Out-Null

        $pdfDir = Join-Path $runDir 'pdf2dxf'
        New-Item -ItemType Directory -Path $pdfDir -Force | Out-Null

        # 优先用本套例程自己产出的真 PDF（最有说服力）
        $srcPdf = $null
        foreach ($cand in @(
            (Join-Path $runDir 'plot\plot-a3-portrait.pdf'),
            (Join-Path $runDir 'draw\integration-draw.pdf')
        )) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $srcPdf = $cand; break }
        }

        $madePdf = $false
        if (-not $srcPdf) {
            # 自造：一条折线 + 一个矩形，只画不填。Flate 不用（避免依赖
            # 压缩流是否可解），直接写未压缩内容流 —— 解析器两条路都支持。
            $content = "1 0 0 RG 1 w`n10 10 m 100 10 l 100 60 l 10 60 l s`n120 10 40 40 re S`n"
            $cb = [Text.Encoding]::ASCII.GetBytes($content)
            $objs = New-Object System.Collections.Generic.List[string]
            $objs.Add('1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj')
            $objs.Add('2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj')
            $objs.Add('3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]/Contents 4 0 R>>endobj')
            $objs.Add("4 0 obj<</Length $($cb.Length)>>stream`n$($content)endstream endobj")
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('%PDF-1.4' + "`n")
            $offsets = New-Object System.Collections.Generic.List[int]
            $body = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $objs.Count; $i++) {
                $offsets.Add($sb.Length + $body.Length) | Out-Null
                [void]$body.Append($objs[$i] + "`n")
            }
            [void]$sb.Append($body.ToString())
            $xrefPos = $sb.Length
            [void]$sb.Append("xref`n0 $($objs.Count + 1)`n0000000000 65535 f `n")
            foreach ($off in $offsets) { [void]$sb.Append(("{0:d10} 00000 n `n" -f $off)) }
            [void]$sb.Append("trailer<</Size $($objs.Count + 1)/Root 1 0 R>>`nstartxref`n$xrefPos`n%%EOF`n")
            $srcPdf = Join-Path $pdfDir 'synthetic.pdf'
            [IO.File]::WriteAllBytes($srcPdf, [Text.Encoding]::ASCII.GetBytes($sb.ToString()))
            $madePdf = $true
        }

        $pdfInfo = Get-CadPdfInfo -Path $srcPdf
        Add-Check 'pdf2dxf.源 PDF 可读' ([string]$pdfInfo.version -match '^\d+\.\d+$') `
            $(if ($srcPdf) { "version=$($pdfInfo.version) pages=$($pdfInfo.pageCount) streams=$($pdfInfo.streamCount) madeSelf=$madePdf" } else { '无源 PDF' })

        $outDxf = Join-Path $pdfDir 'vector.dxf'
        # Convert-CadPdfToDxf 是纯本地解析，不启动任何进程 —— 没有
        # -TimeoutSeconds 参数。给它传超时只会报「找不到参数」。
        $r = & $pdf2dxfScript -Path $srcPdf -Output $outDxf -AsJson 2>&1 | Out-String
        $o = $null; try { $o = $r | ConvertFrom-Json } catch { }
        if (-not $o) {
            Add-Check 'pdf2dxf 可解析' $false ($r.Trim())
        } else {
            $report.sections += 'pdf2dxf'
            # status ∈ ok | parsed（没指定 -Output）| empty（没解析出路径）
            Add-Check 'pdf2dxf.status' ($o.status -in @('ok', 'parsed')) "status=$($o.status)"
            Add-Check 'pdf2dxf 解析出路径' ($o.pathCount -ge 1) "pathCount=$($o.pathCount) stroke=$($o.strokePaths) fill=$($o.fillPaths)"
            Add-Check 'pdf2dxf DXF 落地' ((Test-Path -LiteralPath $outDxf) -and ((Get-Item -LiteralPath $outDxf).Length -gt 512)) `
                $(if (Test-Path -LiteralPath $outDxf) { "$((Get-Item -LiteralPath $outDxf).Length) 字节 entities=$($o.entities)" } else { '未生成' })
            $dxfChk2 = $null
            if (Test-Path -LiteralPath $outDxf) { $dxfChk2 = Test-CadDxfFile -Path $outDxf }
            Add-Check 'pdf2dxf DXF 结构有效' ($dxfChk2 -and $dxfChk2.valid) `
                $(if ($dxfChk2) { "valid=$($dxfChk2.valid) 实体=$($dxfChk2.entityCount) 版本=$($dxfChk2.version)" } else { '未生成' })

            # 坐标必须落在 MediaBox 内 —— 这是 CTM 丢失 bug 的直接哨兵
            $mb = @($pdfInfo.mediaBox)
            $inBox = $true
            if ($o.extents) {
                $w = [double]$pdfInfo.mediaBox[2]; $h = [double]$pdfInfo.mediaBox[3]
                $minX = [double]$o.extents.minX; $minY = [double]$o.extents.minY
                $maxX = [double]$o.extents.maxX; $maxY = [double]$o.extents.maxY
                $inBox = ($minX -ge -0.5) -and ($minY -ge -0.5) -and ($maxX -le ($w + 0.5)) -and ($maxY -le ($h + 0.5))
            }
            Add-Check 'pdf2dxf 范围落在 MediaBox 内（CTM 未丢失）' $inBox `
                $(if ($o.extents) { "extents=($($o.extents.minX),$($o.extents.minY))–($($o.extents.maxX),$($o.extents.maxY)) mediaBox=$($pdfInfo.mediaBox -join ',')" } else { '无 extents' })

            # 读回来的实体必须真的在目标图层上
            if (Test-Path -LiteralPath $outDxf) {
                $pEnts = @(Get-CadDxfEntities -Path $outDxf -Limit 5000)
                $pLayers = @($pEnts | ForEach-Object { [string]$_.layer } | Sort-Object -Unique)
                Add-Check 'pdf2dxf 图层为 PDF_STROKE' (($pLayers -join ',') -eq 'PDF_STROKE' -or ($pLayers -contains 'PDF_STROKE')) `
                    ("layers=" + ($pLayers -join ',') + " entities=" + $pEnts.Count)
            }
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
