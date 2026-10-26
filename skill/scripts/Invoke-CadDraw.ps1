<#
    Invoke-CadDraw.ps1 — 从 JSON 图纸描述生成 DWG / DXF / PDF
    ────────────────────────────────────────────────────────────────
    这是本 skill 的主入口。AI 只写 JSON，本脚本负责：
      1. 校验 JSON 结构与字段
      2. 编译成 LISP（CadCompiler.ps1）
      3. 把 cadcore.lsp 复制到工作目录（GBK 转码，AutoCAD 只认 ANSI 代码页）
      4. 生成 scr（GBK）
      5. 调 accoreconsole 执行
      6. 解析 stdout 标记 + 独立校验产物文件
      7. 输出结构化 JSON 报告

    为什么 cadcore.lsp 要复制到工作目录：
      skill 安装目录本身在磁盘上是 UTF-8 的（Git / 编辑器写入）。
      AutoCAD 2018 的 LISP 读取器按系统 ANSI 代码页解析源文件，
      UTF-8 的中文注释会被解成乱码字节，某些字节恰好是引号/括号，
      于是报「参数类型错误: stringp nil」——位置还指向文件头。
      所以每次执行前把 cadcore.lsp 转成 GBK 复制一份，绝不让 AutoCAD
      直接读 skill 目录里的 UTF-8 原件。

    用法：
      .\Invoke-CadDraw.ps1 -SpecFile drawing.json
      .\Invoke-CadDraw.ps1 -SpecFile drawing.json -OutputDir out -KeepArtifacts
      .\Invoke-CadDraw.ps1 -SpecJson '{"entities":[{"type":"circle","c":[0,0],"r":50}]}' -Dwg out.dwg
      .\Invoke-CadDraw.ps1 -SpecFile drawing.json -DryRun     # 只编译不执行
      .\Invoke-CadDraw.ps1 -SpecFile drawing.json -AsJson     # 输出机器可读报告
#>

[CmdletBinding()]
param(
    [string]$SpecFile,
    [string]$SpecJson,
    [string]$OutputDir,
    [string]$Dwg,
    [switch]$DryRun,
    [switch]$KeepArtifacts,
    [switch]$AsJson,
    [int]$TimeoutSeconds = 180,
    # 显式指定 accoreconsole。留空则走 5 级解析链（参数→环境变量→配置→扫盘→PATH）。
    # 测试用它把假 accoreconsole 注进来，避免污染 CAD_ACCORECONSOLE 环境变量。
    [string]$AccoreConsole,
    # 跳过出图前的 spec 静态预检（只给「明知道 spec 有问题也要硬画」的场景用）
    [switch]$SkipPrecheck,
    # 出图后额外校验：图纸单位必须是这个（如 mm）
    [string]$ExpectedUnits,
    # 出图后额外校验：这些图层上必须真的有实体
    [string[]]$RequiredLayers,
    # 清单路径。留空则写到 <OutputDir>\manifest.json；给 '' 则不写清单
    [string]$Manifest,
    # 已有的清单文件，用来比对两次运行是否一致
    [string]$CompareManifest,
    # ── 模板底图 ──
    # 给一个已存在的 DWG，就在它上面接着画，而不是从空白图起画。
    # 用途：图框/标题栏/图层/标注样式/线型都在模板里，只往里面填几何。
    # 实现是 accoreconsole /i <base>，画完 SAVEAS 到 -Dwg 指定的路径；
    # 原文件不动（先复制到工作目录再打开，避免 AutoCAD 锁住用户的原图）。
    [string]$BaseDwg,
    # 模板里的哪些图层要保留（默认全保留）。给值时会把模板里不在这份
    # 清单上的图层 PURGE 掉 —— 只在模板塞了太多无关图层时才需要。
    [string[]]$KeepBaseLayers,
    # 保留模板里的实体（图框、标题栏）。默认 true。
    # 设为 false 表示「只借模板的图层/样式，不要它的图形」。
    [bool]$KeepBaseEntities = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadCompiler.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')
. (Join-Path $scriptDir 'CadSpecCheck.ps1')

function Write-CadReport {
    param($Report, [switch]$Json)
    if ($Json) {
        $Report | ConvertTo-Json -Depth 10
    } else {
        Write-Host ''
        Write-Host ('═' * 62)
        Write-Host ("  cad-automatic-wwj  ·  {0}" -f $Report.status)
        if ($Report.disposition) {
            Write-Host ("  结论    : {0}" -f $Report.disposition)
        }
        Write-Host ('═' * 62)
        if ($Report.drawing) { Write-Host ("  图纸    : {0}" -f $Report.drawing) }
        if ($null -ne $Report.entityCount) { Write-Host ("  实体    : {0} 个" -f $Report.entityCount) }
        if ($Report.layers) { Write-Host ("  图层    : {0}" -f ($Report.layers -join ', ')) }
        if ($Report.units -and $Report.units.name) {
            Write-Host ("  单位    : {0}（INSUNITS={1}）" -f $Report.units.name, $Report.units.code)
        }
        if ($Report.artifacts) {
            Write-Host '  产物    :'
            foreach ($a in $Report.artifacts) {
                if ($a.exists) {
                    Write-Host ("            ✓ {0}  ({1:N0} 字节)" -f $a.path, $a.bytes)
                } else {
                    Write-Host ("            ✗ {0}  (缺失)" -f $a.path)
                }
            }
        }
        if ($Report.checks) {
            Write-Host '  校验    :'
            foreach ($c in $Report.checks) {
                $mark = if ($c.pass) { '✓' } else { '✗' }
                Write-Host ("            {0} {1}" -f $mark, $c.name)
                if (-not $c.pass -and $c.detail) { Write-Host ("              {0}" -f $c.detail) }
            }
        }
        if ($Report.warnings -and @($Report.warnings).Count -gt 0) {
            Write-Host '  警告    :'
            foreach ($w in $Report.warnings) { Write-Host ("            ! {0}" -f $w) }
        }
        if ($Report.error) { Write-Host ("  错误    : {0}" -f $Report.error) }
        if ($Report.advice) { Write-Host ("  建议    : {0}" -f $Report.advice) }
        if ($Report.manifest) { Write-Host ("  清单    : {0}" -f $Report.manifest) }
        if ($Report.compare) {
            $cmpText = if ($Report.compare.identical) { '与基线一致' } else { "与基线有 $($Report.compare.diffCount) 处差异" }
            Write-Host ("  复现    : {0}" -f $cmpText)
        }
        if ($Report.logDir) { Write-Host ("  日志    : {0}" -f $Report.logDir) }
        Write-Host ('═' * 62)
    }
}

function Invoke-CadDrawSingle {
    param(
        [string]$SpecFile,
        [string]$SpecJson,
        [string]$OutputDir,
        [string]$Dwg,
        [switch]$DryRun,
        [switch]$KeepArtifacts,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    $warnings = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[object]
    $evidence = New-Object System.Collections.Generic.List[object]
    $report = [ordered]@{
        status      = 'unknown'
        # disposition 是给人看的五态结论，status 是给脚本看的机器状态。
        # 两者不合并：status 只有 ok/partial/failed/dry-run/blocked 五个值，
        # 而 disposition 要区分「有证据通过」和「只是没发现错」。
        disposition = $null
        advice      = $null
        drawing     = $null
        entityCount = $null
        layers      = @()
        artifacts   = @()
        checks      = @()
        warnings    = @()
        error       = $null
        logDir      = $null
        # 执行层证据：调用方（含 run-test.ps1）不看 checks 的措辞，
        # 直接看这几个字段判断「LISP 到底跑完没有」。
        exitCode    = $null
        exitName    = $null
        timedOut    = $false
        markers     = [ordered]@{}
        units       = $null
        unitsCheck  = $null
        layersCheck = $null
        evidence    = @()
        manifest    = $null
        compare     = $null
        durationMs  = $null
    }

    try {
        # ── 1. 读取 JSON ──────────────────────────────────────────
        if ($SpecFile) {
            if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) {
                throw "图纸描述文件不存在: $SpecFile"
            }
            $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SpecFile).Path, [Text.Encoding]::UTF8)
            $spec = $raw | ConvertFrom-Json
        } elseif ($SpecJson) {
            $spec = $SpecJson | ConvertFrom-Json
        } else {
            throw '需要 -SpecFile 或 -SpecJson'
        }
        if ($null -eq $spec) { throw 'JSON 解析结果为空' }

        $report.drawing = [string](Get-CadField $spec 'name' 'drawing')

        # ── 1.5 出图前静态预检 ───────────────────────────────────
        # accoreconsole 出图一次 4 秒，失败一次要等超时（默认 180 秒）。
        # 而绝大多数失败根本不需要 AutoCAD 参与判断：circle 少了 r、
        # rect 两个角点重合、螺栓阵列 count=0 —— 纯数据问题，本地几毫秒能判。
        #
        # ★ 更重要的是「画成功了但画错了」★
        #   半径 -20 会报错，但半径 20000 会得到一张 20 米宽的图纸，
        #   成果看起来完整、尺寸全错。那才是真正会流到下游的灾难。
        #   预检就是拦这一类：坐标溢出 ±1e7、包络超限、间隙不足。
        if (-not $SkipPrecheck) {
            $pre = Test-CadSpecStrict -Spec $spec
            foreach ($w in $pre.warnings) { $warnings.Add($w) }
            if ($pre.evidence) { foreach ($e in $pre.evidence) { $evidence.Add($e) } }

            $checks.Add([pscustomobject]@{
                name   = "出图前预检（$($pre.stats.entityCount) 实体 / $($pre.stats.layerCount) 图层）"
                pass   = [bool]$pre.ok
                detail = if ($pre.ok) { '' } else { "阻断性错误 $($pre.errors.Count) 条" }
                scope  = 'verdict'
            }) | Out-Null

            if (-not $pre.ok) {
                # 一个实体都不画。让用户改 spec，而不是让他在 DWG 里找哪儿错了。
                $report.disposition = 'blocked'
                $report.advice = Get-CadDispositionAdvice -Disposition 'blocked'
                $report.status = 'blocked'
                $report.error = 'spec 预检未通过：' + ($pre.errors -join '; ')
                $report.checks = $checks.ToArray()
                $report.warnings = $warnings.ToArray()
                $report.evidence = $evidence.ToArray()
                $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
                return $report
            }
        }

        # ── 2. 准备状态与工作目录 ────────────────────────────────
        Initialize-CadState | Out-Null
        # Resolve-CadAccoreConsole 返回 {path,source}，执行器需要的是路径字符串本身
        $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
        $accore = $accoreInfo.path
        if (-not $accore) {
            throw '找不到 accoreconsole.exe。请先运行 Set-CadPath.ps1 -Auto，或设置环境变量 CAD_ACCORECONSOLE。'
        }
        $checks.Add([pscustomobject]@{
            name = "accoreconsole 定位成功（$($accoreInfo.source)）"
            pass = $true
        }) | Out-Null

        if (-not $OutputDir) {
            $OutputDir = if ($SpecFile) { Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $SpecFile).Path) 'cad-out' }
                         else { Join-Path $script:CadStateDir 'out' }
        }
        if (-not (Test-Path -LiteralPath $OutputDir)) {
            New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        }
        $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

        # 工作目录：临时文件都放这里，除非要求保留
        $work = Join-Path $script:CadStateDir ("work-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $report.logDir = $work

        # ── 3. 准备 GBK 版 cadcore.lsp ───────────────────────────
        # 绝不直接 load skill 目录里的原件（那边是 UTF-8）
        $coreSrc = Join-Path $scriptDir 'cadcore.lsp'
        if (-not (Test-Path -LiteralPath $coreSrc -PathType Leaf)) {
            throw "cadcore.lsp 缺失: $coreSrc"
        }
        $coreWork = Join-Path $work 'cadcore.lsp'
        $coreText = [IO.File]::ReadAllText($coreSrc, [Text.Encoding]::UTF8)
        Write-CadLsp -Path $coreWork -Body $coreText | Out-Null
        $checks.Add([pscustomobject]@{ name = 'cadcore.lsp 已转码为 GBK'; pass = $true }) | Out-Null

        # ── 4. 决定输出路径 ──────────────────────────────────────
        $saveSpec = Get-CadField $spec 'save'
        if (-not $saveSpec) { $saveSpec = [pscustomobject]@{} }

        $dwgPath = if ($Dwg) { $Dwg } else { Get-CadField $saveSpec 'dwg' }
        if (-not $dwgPath) { $dwgPath = Join-Path $OutputDir ($report.drawing + '.dwg') }
        elseif (-not [IO.Path]::IsPathRooted($dwgPath)) { $dwgPath = Join-Path $OutputDir $dwgPath }
        $dwgPath = [IO.Path]::GetFullPath($dwgPath)
        $dwgDir = Split-Path -Parent $dwgPath
        if ($dwgDir -and -not (Test-Path -LiteralPath $dwgDir)) {
            New-Item -ItemType Directory -Force -Path $dwgDir | Out-Null
        }

        # ── 4.5 模板底图 ─────────────────────────────────────────
        # ★ 为什么要复制一份到工作目录 ★
        #   accoreconsole /i 打开的是「原文件」，SAVEAS 又写回同一个路径时
        #   AutoCAD 会报「图形正在使用中」。更糟的是：直接 /i 用户的原图，
        #   一旦脚本中途 QUIT 时误应答了 _Y，模板就被写脏了。
        #   所以先复制到 work/base.dwg，打开副本，SAVEAS 到 -Dwg。
        #   用户的原模板字节级不变 —— 这一点下面会用哈希独立验证。
        $baseWork = $null
        $baseInfo = $null
        $baseFull = $null
        $baseHashBefore = $null
        if ($BaseDwg) {
            if (-not (Test-Path -LiteralPath $BaseDwg -PathType Leaf)) {
                throw "模板底图不存在: $BaseDwg"
            }
            $baseFull = (Resolve-Path -LiteralPath $BaseDwg).Path
            $baseInfo = Test-CadDwgFile -Path $baseFull
            if (-not $baseInfo.valid) {
                throw "模板底图不是有效 DWG: $($baseInfo.reason)"
            }
            $baseWork = Join-Path $work 'base.dwg'
            Copy-Item -LiteralPath $baseFull -Destination $baseWork -Force
            $baseHashBefore = (Get-FileHash -LiteralPath $baseFull -Algorithm SHA256).Hash

            $checks.Add([pscustomobject]@{
                name = "模板底图已载入（$(Split-Path -Leaf $baseFull) / $($baseInfo.version) / $([math]::Round((Get-Item -LiteralPath $baseFull).Length/1kb,1)) KB）"
                pass = $true
            }) | Out-Null
            $evidence.Add((New-CadEvidence -Kind 'base-dwg' -Level 'known' `
                -Message "以 $baseFull 为模板起图（DWG $($baseInfo.version)），几何追加在模板实体之上；模板文件本身不修改" `
                -Value $baseFull -Source $baseFull)) | Out-Null
        }

        # SAVEAS 到已存在的文件会停在「此名称的图形已存在」等输入 →
        # 脚本挂到超时。目标就是模板本身时更要拦，否则等于原地覆盖。
        if ($baseWork -and $dwgPath -and (Test-Path -LiteralPath $dwgPath -PathType Leaf)) {
            # ★ 输出路径不能等于模板路径 ★
            #   模板模式下会先 Remove-Item 目标再 SAVEAS，如果目标就是模板，
            #   用户的原图会被删掉 —— 这是不可逆的数据损坏，必须先拦。
            if ([string]::Equals($dwgPath, $baseFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "输出 DWG 路径与模板底图相同（$dwgPath）。模板模式要求输出到另一个文件，否则会覆盖模板。"
            }
            Remove-Item -LiteralPath $dwgPath -Force
        }

        $dxfPath = $null
        $dxfSpec = Get-CadField $saveSpec 'dxf'
        if ($dxfSpec) {
            if ($dxfSpec -is [string]) {
                $dxfPath = if ([IO.Path]::IsPathRooted($dxfSpec)) { $dxfSpec } else { Join-Path $OutputDir $dxfSpec }
            } else {
                $dxfPath = [IO.Path]::ChangeExtension($dwgPath, '.dxf')
            }
            $dxfPath = [IO.Path]::GetFullPath($dxfPath)
        }

        # PDF 的 save 字段有两种写法，必须区分开：
        #   "save": {"pdf": "A3"}            → A3 是**图纸尺寸**，文件名自动取 <图纸名>.pdf
        #   "save": {"pdf": "out/plan.pdf"}  → 这是**路径**
        # 早先把 "A3" 当路径用，结果输出文件叫 "A3"（没有扩展名），
        # -PLOT 报无效文件名，还会把进程卡住不退出。
        $paperSizes = @('A0','A1','A2','A3','A4','ANSI A','ANSI B','ANSI C','ANSI D','ANSI E')
        $pdfPath = $null
        $pdfPaper = $null
        $pdfSpec = Get-CadField $saveSpec 'pdf'
        if ($pdfSpec -is [string] -and $pdfSpec) {
            if ($paperSizes -contains $pdfSpec.Trim().ToUpperInvariant() -or $pdfSpec -match '^ISO\s+A\d') {
                $pdfPaper = $pdfSpec.Trim().ToUpperInvariant()
                $pdfPath = Join-Path $OutputDir ($report.drawing + '.pdf')
            } else {
                $pdfPath = if ([IO.Path]::IsPathRooted($pdfSpec)) { $pdfSpec } else { Join-Path $OutputDir $pdfSpec }
                $pdfPaper = [string](Get-CadField $saveSpec 'pdfSize' 'A3')
            }
            $pdfPath = [IO.Path]::GetFullPath($pdfPath)
            # 没写扩展名就补 .pdf，否则 -PLOT 会把它当无效文件名
            if ([IO.Path]::GetExtension($pdfPath) -ne '.pdf') { $pdfPath = $pdfPath + '.pdf' }
        } elseif ($pdfSpec) {
            # 布尔 true：用默认名 + 默认尺寸
            $pdfPath = Join-Path $OutputDir ($report.drawing + '.pdf')
            $pdfPaper = [string](Get-CadField $saveSpec 'pdfSize' 'A3')
        }

        # 回填到 spec，让编译器按最终路径生成
        $saveSpec | Add-Member -NotePropertyName dwg -NotePropertyValue $dwgPath -Force
        if ($dxfPath) { $saveSpec | Add-Member -NotePropertyName dxf -NotePropertyValue $dxfPath -Force }
        if ($pdfPath) {
            $saveSpec | Add-Member -NotePropertyName pdf -NotePropertyValue $pdfPath -Force
            $saveSpec | Add-Member -NotePropertyName pdfSize -NotePropertyValue $pdfPaper -Force
        }
        $spec | Add-Member -NotePropertyName save -NotePropertyValue $saveSpec -Force

        # ── 5. 编译 ──────────────────────────────────────────────
        $compiled = Compile-CadSpec -Spec $spec -CoreLspPath $coreWork
        foreach ($w in $compiled.warnings) { $warnings.Add($w) }
        $report.entityCount = $compiled.entityCount
        $report.layers = $compiled.layers

        # ★ 部分实体编译失败 ≠ 成功 ★
        #   Compile-CadSpec 对单个实体失败是「记 warning 并跳过」，这样一张图里
        #   坏一个孔不该让整张图不画。但对调用方来说「画了 5 个实体里的 2 个」
        #   和「画了 5 个」是天壤之别 —— 少掉的可能是螺栓孔，装上就废。
        #   所以这里必须变成一条**失败的断言**，让 status 落到 partial，
        #   而不是只在 warnings 里留一句几乎没人看的话。
        $declaredCount = @(Get-CadField $spec 'entities' @()).Count
        $compileFailures = @($compiled.warnings | Where-Object { $_ -match '编译失败' })
        if ($compiled.entityCount -eq 0 -and @($warnings).Count -gt 0) {
            throw ("所有实体都编译失败：`n  " + ($warnings -join "`n  "))
        }
        $checks.Add([pscustomobject]@{
            name   = "JSON 编译成功（$($compiled.entityCount)/$declaredCount 个实体）"
            pass   = ($compileFailures.Count -eq 0)
            detail = if ($compileFailures.Count -gt 0) {
                "有 $($compileFailures.Count) 个实体未编译：$($compileFailures -join ' | ')"
            } else { '' }
        }) | Out-Null

        $lspPath = Join-Path $work 'drawing.lsp'
        Write-CadLsp -Path $lspPath -Body $compiled.lisp | Out-Null
        $checks.Add([pscustomobject]@{ name = 'LISP 已生成（GBK）'; pass = $true }) | Out-Null

        if ($DryRun) {
            # DryRun 只跑到编译层。产物层证据一条都没有，
            # 所以结论不可能是 pass —— 让证据层自己说 needs_review，
            # 而不是留个空 disposition 让调用方以为「没结论就是没事」。
            $report.status = 'dry-run'
            $report.evidence = $evidence.ToArray()
            $report.disposition = 'needs_review'
            $report.advice = '只做了出图前预检与 LISP 生成，没有真正执行；确认无误后去掉 -DryRun 再跑。'
            $report.checks = $checks.ToArray()
            $report.warnings = $warnings.ToArray()
            $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
            return $report
        }

        # ── 6. 生成 scr 并执行 ───────────────────────────────────
        # ★ 顺序是硬约束，不是风格问题 ★
        #   (load drawing.lsp) 一旦执行，里面就是逐个实体函数调用 —— 画完了。
        #   所以「清空模板实体」必须排在 load 之前；而 c:BASELAYERS 是
        #   cadcore 里定义的自定义命令，必须排在 load 之后。
        #   两者方向相反，顺序颠倒任一个都会静默出错：
        #     清空放到 load 之后 → 把刚画好的全删掉，最后得到空图
        #     清图层放到 load 之前 → no function definition
        $scrPath = Join-Path $work 'draw.lsp.scr'
        $scrLines = New-Object System.Collections.Generic.List[string]
        $scrLines.Add('(setvar "SECURELOAD" 0)')
        $scrLines.Add('(setvar "FILEDIA" 0)')
        $scrLines.Add('(setvar "CMDDIA" 0)')
        $scrLines.Add('(setvar "CMDECHO" 0)')
        $scrLines.Add('(setvar "OSMODE" 0)')
        $scrLines.Add('(setvar "EXPERT" 5)')

        if ($baseWork -and -not $KeepBaseEntities) {
            # 原生 ERASE，不依赖 cadcore —— 必须在 load 之前
            $scrLines.Add('(command "_.ERASE" "_ALL" "")')
        }

        $scrLines.Add("(load `"$(ConvertTo-CadPath $lspPath)`")")

        if ($baseWork -and $KeepBaseLayers -and @($KeepBaseLayers).Count -gt 0) {
            # 只删「清单外图层」上的模板实体；新实体画在清单内图层，不受影响
            $keepList = ($KeepBaseLayers | ForEach-Object { '"' + ($_ -replace '"', '') + '"' }) -join ' '
            $scrLines.Add("(c:BASELAYERS (list $keepList))")
        }

        # QUIT 之后可能还会问「是否保存对 xxx 的修改？」，不给应答就挂住。
        # 多给几个 _N 兜底：多出来的空行对已退出的会话无害。
        $scrLines.Add('_.QUIT')
        $scrLines.Add('_N')
        $scrLines.Add('_N')
        $scrLines.Add('_N')

        Write-CadScr -Path $scrPath -Lines $scrLines.ToArray() | Out-Null

        $run = Invoke-CadCoreConsole -AccoreConsole $accore `
            -Script $scrPath -WorkingDirectory $work -TimeoutSeconds $TimeoutSeconds `
            -InputDwg $baseWork

        $checks.Add([pscustomobject]@{
            name = "accoreconsole 退出码 $($run.exitCode) ($($run.exitName))"
            pass = ($run.exitCode -eq 0)
        }) | Out-Null

        if ($run.lispError) {
            $warnings.Add("LISP 运行期报错: $($run.lispErrorLines -join ' | ')")
        }
        if ($run.timedOut) {
            $warnings.Add("执行超时（${TimeoutSeconds}s），进程已终止")
        }
        if ($run.messageBoxes -and @($run.messageBoxes).Count -gt 0) {
            $warnings.Add("出现对话框（已拦截）: $($run.messageBoxes -join ' | ')")
        }

        $doneMarker = Get-CadMarker -Result $run -Name 'DONE'
        $checks.Add([pscustomobject]@{ name = 'LISP 执行到 @@DONE@@'; pass = [bool]$doneMarker }) | Out-Null

        # 执行层证据落到报告顶层，别只藏在 checks 的措辞里。
        # markers 是 {name,value} 数组（同名标记可能重复，后者覆盖前者）。
        $report.exitCode = $run.exitCode
        $report.exitName = $run.exitName
        $report.timedOut = [bool]$run.timedOut
        $markers = [ordered]@{}
        foreach ($mk in @($run.markers)) {
            if ($null -eq $mk) { continue }
            $markers[[string]$mk.name] = $mk.value
        }
        $report.markers = $markers

        $countMarker = Get-CadMarker -Result $run -Name 'COUNT'
        if ($countMarker) {
            $checks.Add([pscustomobject]@{
                name = "LISP 统计实体数 = $countMarker"
                pass = ([int]$countMarker -gt 0)
            }) | Out-Null
        }

        # 线型被替换：c:LAYER 打的是 @@LTYPE_MISSING.<图层>=<线型>@@。
        # -LAYER 的 _L 碰到库里没有的名字只会提示一行「未找到线型」然后继续
        # 等输入，脚本会挂在那一行到超时；所以 cadcore 先查 LTYPE 表，
        # 查不到就退回 CONTINUOUS，并留下这条标记告诉我们「用户想要的那个没生效」。
        foreach ($mk in @($run.markers)) {
            if ($null -eq $mk) { continue }
            $nm = [string]$mk.name
            if ($nm.StartsWith('LTYPE_MISSING.')) {
                $lyName = $nm.Substring('LTYPE_MISSING.'.Length)
                $warnings.Add("图层 '$lyName' 的线型 '$($mk.value)' 在本机不存在，已改用 CONTINUOUS")
            }
        }

        # ── 7. 独立校验产物（不信任 LISP 的自述）──────────────────
        $artifacts = New-Object System.Collections.Generic.List[object]

        if ($dwgPath) {
            $ex = Test-Path -LiteralPath $dwgPath -PathType Leaf
            $sz = if ($ex) { (Get-Item -LiteralPath $dwgPath).Length } else { 0 }
            $artifacts.Add([pscustomobject]@{ kind = 'dwg'; path = $dwgPath; exists = $ex; bytes = $sz }) | Out-Null
            # 大小 + 文件头双查：写入中断会留下几 KB 的半截 DWG，
            # 光判 >2000 字节挡不住。DWG 真身是 'AC10xx' 头。
            if ($ex) {
                $dwgInfo = Test-CadDwgFile -Path $dwgPath
                $verText = if ($dwgInfo.version) { " / $($dwgInfo.version)" } else { '' }
                $checks.Add([pscustomobject]@{
                    name = "DWG 结构有效（$([math]::Round($sz/1kb,1)) KB$verText）"
                    pass = [bool]$dwgInfo.valid
                }) | Out-Null
                if (-not $dwgInfo.valid) { $warnings.Add("DWG 校验未通过: $($dwgInfo.reason)") }
            } else {
                $checks.Add([pscustomobject]@{ name = 'DWG 已生成'; pass = $false }) | Out-Null
            }
        }

        if ($dxfPath) {
            $ex = Test-Path -LiteralPath $dxfPath -PathType Leaf
            $sz = if ($ex) { (Get-Item -LiteralPath $dxfPath).Length } else { 0 }
            $artifacts.Add([pscustomobject]@{ kind = 'dxf'; path = $dxfPath; exists = $ex; bytes = $sz }) | Out-Null
            if ($ex) {
                $dxfInfo = Test-CadDxfFile -Path $dxfPath
                $checks.Add([pscustomobject]@{
                    name = "DXF 结构有效（$($dxfInfo.entityCount) 实体 / $($dxfInfo.sectionCount) 段）"
                    pass = [bool]$dxfInfo.valid
                }) | Out-Null
                if (-not $dxfInfo.valid) { $warnings.Add("DXF 校验未通过: $($dxfInfo.reason)") }
                if ($dxfInfo.entityCount -ne $compiled.entityCount) {
                    $warnings.Add("DXF 实体数 $($dxfInfo.entityCount) 与 JSON 声明 $($compiled.entityCount) 不一致（块定义/填充会产生额外实体，属正常）")
                }
            } else {
                $checks.Add([pscustomobject]@{ name = 'DXF 已生成'; pass = $false }) | Out-Null
            }
        }

        if ($pdfPath) {
            $ex = Test-Path -LiteralPath $pdfPath -PathType Leaf
            $sz = if ($ex) { (Get-Item -LiteralPath $pdfPath).Length } else { 0 }
            $artifacts.Add([pscustomobject]@{ kind = 'pdf'; path = $pdfPath; exists = $ex; bytes = $sz }) | Out-Null
            # 只判 Test-Path 会把「PLOT 半途失败留下的空壳」当成功。
            # 这里查结构：%PDF 头 + %%EOF 尾 + 至少一页，三件事缺一不可。
            if ($ex) {
                $pdfInfo = Test-CadPdfFile -Path $pdfPath
                $checks.Add([pscustomobject]@{
                    name = "PDF 结构有效（$($pdfInfo.pageCount) 页 / $([math]::Round($sz/1kb,1)) KB）"
                    pass = [bool]$pdfInfo.valid
                }) | Out-Null
                if (-not $pdfInfo.valid) { $warnings.Add("PDF 校验未通过: $($pdfInfo.reason)") }
            } else {
                $checks.Add([pscustomobject]@{ name = 'PDF 已生成'; pass = $false }) | Out-Null
            }
        }

        # ── 7.5 单位校验（有 DXF 才做）────────────────────────────
        # 为什么放在产物校验之后：单位的证据来自 DXF 头，没有产物就无从谈起。
        # 为什么单位这么重要：一个 100×60 的矩形，INSUNITS=4 是垫片，
        # INSUNITS=6 是地块。DXF 字节几乎一样、实体数完全一样、屏幕上比例
        # 也一样，唯一能区分的就是 $INSUNITS。
        if ($dxfPath -and (Test-Path -LiteralPath $dxfPath -PathType Leaf)) {
            $unitInfo = Get-CadDrawingUnits -Path $dxfPath
            $report.units = [pscustomobject]@{
                code = $unitInfo.code
                name = $unitInfo.name
            }
            $evidence.Add($unitInfo.evidence) | Out-Null

            if ($ExpectedUnits) {
                $uc = Test-CadUnits -Path $dxfPath -Expected $ExpectedUnits
                $report.unitsCheck = $uc
                $evidence.Add($uc.evidence) | Out-Null
                # match 是三值：$true / $false / $null(不知道)
                # 只有 $false 才是失败断言；$null 交给证据层把它拉成 needs_review。
                if ($uc.match -eq $false) {
                    $checks.Add([pscustomobject]@{
                        name   = "单位符合期望（$ExpectedUnits）"
                        pass   = $false
                        detail = $uc.evidence.message
                        scope  = 'verdict'
                    }) | Out-Null
                } elseif ($uc.match -eq $true) {
                    $checks.Add([pscustomobject]@{
                        name  = "单位符合期望（$($unitInfo.name)）"
                        pass  = $true
                        scope = 'verdict'
                    }) | Out-Null
                } else {
                    $warnings.Add($uc.evidence.message)
                }
            }
        }

        # ── 7.5 模板底图的完整性校验 ─────────────────────────────
        # ★ 为什么要事后验一遍 ★
        #   模板模式最怕的不是画错，是「画对了但把模板写脏了」。
        #   用户的原模板是长期资产，被脚本改一次就再也回不去。
        #   这里用 SHA256 前后对比，是唯一能证明「没动过」的证据。
        if ($baseFull) {
            $baseHashAfter = (Get-FileHash -LiteralPath $baseFull -Algorithm SHA256).Hash
            $unchanged = ($baseHashBefore -eq $baseHashAfter)
            $checks.Add([pscustomobject]@{
                name   = if ($unchanged) { '模板底图未被修改（SHA256 一致）' }
                         else { '模板底图被改动了（SHA256 变化）' }
                pass   = $unchanged
                scope  = 'verdict'
                detail = if ($unchanged) { '' } else { "运行前 $($baseHashBefore.Substring(0,16))… → 运行后 $($baseHashAfter.Substring(0,16))…" }
            }) | Out-Null
            $report.baseDwg = [pscustomobject]@{
                path      = $baseFull
                version   = $baseInfo.version
                bytes     = (Get-Item -LiteralPath $baseFull).Length
                unchanged = $unchanged
                keepBaseEntities = $KeepBaseEntities
                keptLayers = @($KeepBaseLayers)
            }
        }

        # ── 7.6 必需图层的覆盖校验 ───────────────────────────────
        # 图层存在 ≠ 几何画在上面。空图层零成本就能建出来，
        # 而下游按图层筛几何（CAM 刀路、算量、出图过滤）只认后者。
        if ($RequiredLayers -and @($RequiredLayers).Count -gt 0) {
            $ents = @()
            if ($dxfPath -and (Test-Path -LiteralPath $dxfPath -PathType Leaf)) {
                $ents = @(Get-CadDxfEntities -Path $dxfPath)
            }
            $lc = Test-CadRequiredLayers -Required $RequiredLayers -DxfPath $dxfPath -Entities $ents
            $report.layersCheck = $lc
            if ($lc.evidence) { $evidence.Add($lc.evidence) | Out-Null }
            $checks.Add([pscustomobject]@{
                name  = if ($lc.pass) { "必需图层都有实体（$($lc.present.Count) 个）" }
                        else { "必需图层缺实体（缺 $($lc.missing.Count) 个 / 空 $($lc.empty.Count) 个）" }
                pass  = [bool]$lc.pass
                scope = 'verdict'
            }) | Out-Null
        }

        $report.artifacts = $artifacts.ToArray()
        $report.checks = $checks.ToArray()
        $report.warnings = $warnings.ToArray()
        $report.evidence = $evidence.ToArray()

        # ── status 与 disposition 是两件事，别混 ─────────────────
        #   status      执行/产物状态：图到底画出来没有。只看「产物层」检查
        #               （编译、执行、DWG/DXF/PDF 结构、统计数）。
        #   disposition 验收结论：这批产物能不能交。看**全部**检查 + 证据。
        #
        # 分开的理由：单位不符时三个产物都在、结构都完好，status 就该是 ok
        # （确实画出来了），但 disposition 必须是 fail（交出去会把 100mm 当
        # 100m 用）。以前两者都从 failed.Count 推，于是 status=partial 与
        # disposition=fail 同时出现，读报告的人以为「画了一半」。
        # $_.scope 是可选字段（只有 verdict 类 check 有）—— StrictMode 下直接
        # $_.scope 访问不存在的属性会抛「The property 'scope' cannot be found」，
        # 把整个报告构造炸掉（实测出现过一次：某轮第一个 check 没带 scope）。
        # 所以统一用 psobject 取，取不到给 $null。
        $artifactFailed = @($checks | Where-Object {
            $sc = $_.PSObject.Properties['scope']
            -not $_.pass -and (-not $sc -or $sc.Value -ne 'verdict')
        })
        $report.status = if ($artifactFailed.Count -eq 0) { 'ok' } elseif ($doneMarker) { 'partial' } else { 'failed' }
        # error 里要把验收类失败也写上：status=ok 但 disposition=fail 时，
        # 用户看到 advice 让他「先看 error」，error 却是空的就自相矛盾了。
        $failedAll = @($checks | Where-Object { -not $_.pass })
        if ($failedAll.Count -gt 0) {
            $report.error = ($failedAll | ForEach-Object { $_.name }) -join '; '
        }

        # ── 7.7 五态结论 ─────────────────────────────────────────
        $report.disposition = Get-CadDisposition -Checks $checks -Evidence $evidence `
            -Warnings $warnings -Error $report.error -Artifacts $artifacts
        $report.advice = Get-CadDispositionAdvice -Disposition $report.disposition

        # 「图出来了但验收不过」是个容易误读的组合：
        #   status=ok 说明产物没问题，disposition=fail 说明不能交。
        # 通用建议（「执行或产物校验失败」）会把人引去查产物，白跑一趟。
        if ($report.status -eq 'ok' -and $report.disposition -eq 'fail') {
            $verdictNames = @($failedAll | ForEach-Object { $_.name }) -join '、'
            $report.advice = "图纸与产物都已生成并通过结构校验，是验收条件没满足：$verdictNames。" +
                '按需改 spec，或调整 -ExpectedUnits / -RequiredLayers 后重跑；产物本身可以直接打开检查。'
        }

        # ── 7.8 清单落盘 + 复现比对 ───────────────────────────────
        # 清单把「这次运行到底是什么」钉成可复现的记录：
        # spec 哈希、cadcore 哈希、每个产物的哈希。同一份 spec 跑两次，
        # 哈希一致才说明产物真的相同，而不是「看起来差不多」。
        $manifestPath = $Manifest
        if (-not $PSBoundParameters.ContainsKey('Manifest')) {
            $manifestPath = Join-Path $OutputDir 'manifest.json'
        }
        if ($manifestPath) {
            $dwgInfoForManifest = $null
            $extInfo = $null
            if ($dxfPath -and (Test-Path -LiteralPath $dxfPath -PathType Leaf)) {
                $extInfo = Get-CadExtentSize -Path $dxfPath
            }
            $specSha = if ($SpecFile) { Get-CadSha256 -Path $SpecFile } else { $null }
            $mf = New-CadManifest -SpecFile $SpecFile -DrawingName $report.drawing `
                -Artifacts $artifacts -Evidence $evidence -Disposition $report.disposition `
                -AccoreConsole $accore -AccoreConsoleSource $accoreInfo.source `
                -CadCorePath $coreWork -Units $report.units.name -UnitsCode $report.units.code `
                -Extents $extInfo -EntityCount $compiled.entityCount -Layers $compiled.layers `
                -SpecSha256 $specSha
            $written = if ([IO.Path]::IsPathRooted($manifestPath)) { $manifestPath }
                       else { Join-Path $OutputDir $manifestPath }
            $saved = Write-CadManifest -Manifest $mf -Path $written
            if ($saved) {
                $report.manifest = $saved
            } else {
                $warnings.Add("清单写入失败: $written")
                $report.warnings = $warnings.ToArray()
            }

            if ($CompareManifest -and $saved -and (Test-Path -LiteralPath $CompareManifest -PathType Leaf)) {
                try {
                    $before = Get-Content -LiteralPath $CompareManifest -Raw -Encoding UTF8 | ConvertFrom-Json
                    $report.compare = Compare-CadManifest -Before $before -After $mf
                    if (-not $report.compare.identical) {
                        $warnings.Add("与基线清单不一致（$($report.compare.diffCount) 处）：" +
                            (($report.compare.diffs | ForEach-Object { "$($_.field): $($_.before) → $($_.after)" }) -join '; '))
                        $report.warnings = $warnings.ToArray()
                    }
                } catch {
                    $warnings.Add("基线清单读取失败: $($_.Exception.Message)")
                    $report.warnings = $warnings.ToArray()
                }
            }
        }

    } catch {
        $report.status = 'failed'
        $report.disposition = 'fail'
        $report.advice = Get-CadDispositionAdvice -Disposition 'fail'
        $report.error = $_.Exception.Message
        $report.checks = $checks.ToArray()
        $report.warnings = $warnings.ToArray()
        $report.evidence = $evidence.ToArray()
    } finally {
        $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
        # 清理工作目录（日志保留在 logDir 里，除非要求保留全部）
        if ($report.logDir -and (Test-Path -LiteralPath $report.logDir) -and -not $KeepArtifacts) {
            # 保留 stdout/stderr 便于排查，删掉中间 lsp/scr
            Get-ChildItem -LiteralPath $report.logDir -Include '*.lsp', '*.scr' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    return $report
}


# ═══════════════════════════════════════════════════════════════════
# 多视图薄包装：spec 顶层有 views[] 时逐视图出图并聚合报告
# ═══════════════════════════════════════════════════════════════════
# 单视图 spec 走 Invoke-CadDrawSingle，行为与旧版完全一致（65 项集成
# 测试的基线）。多视图 spec 拆成 N 份子 spec 逐个画，每份独立产物与
# manifest；聚合成一份顶层报告：views[].report + 汇总 status/disposition。
function Invoke-CadDraw {
    param(
        [string]$SpecFile,
        [string]$SpecJson,
        [string]$OutputDir,
        [string]$Dwg,
        [switch]$DryRun,
        [switch]$KeepArtifacts,
        [switch]$AsJson,
        [int]$TimeoutSeconds = 180,
        [string]$AccoreConsole,
        [switch]$SkipPrecheck,
        [string]$ExpectedUnits,
        [string[]]$RequiredLayers,
        [string]$Manifest,
        [string]$CompareManifest
    )

    $started = Get-Date

    # 读 spec（与单视图入口同样的三种来源）
    if ($SpecFile) {
        if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) {
            throw "图纸描述文件不存在: $SpecFile"
        }
        $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SpecFile).Path, [Text.Encoding]::UTF8)
        $spec = $raw | ConvertFrom-Json
    } elseif ($SpecJson) {
        $spec = $SpecJson | ConvertFrom-Json
    } else {
        throw '需要 -SpecFile 或 -SpecJson'
    }
    if ($null -eq $spec) { throw 'JSON 解析结果为空' }

    # 没有 views[] → 原路进单视图，报告形状不变
    $hasViews = $null -ne (Get-CadField $spec 'views')
    if (-not $hasViews) {
        $args1 = @{
            SpecFile = $SpecFile; SpecJson = $SpecJson; OutputDir = $OutputDir
            Dwg = $Dwg; DryRun = $DryRun; KeepArtifacts = $KeepArtifacts
            TimeoutSeconds = $TimeoutSeconds; AccoreConsole = $AccoreConsole
            SkipPrecheck = $SkipPrecheck; ExpectedUnits = $ExpectedUnits
            RequiredLayers = $RequiredLayers; CompareManifest = $CompareManifest
        }
        if ($PSBoundParameters.ContainsKey('Manifest')) { $args1.Manifest = $Manifest }
        return Invoke-CadDrawSingle @args1
    }

    # ── 多视图：拆分 + 逐视图调用 ──
    $subSpecs = Get-CadSpecViewSpecs -Spec $spec
    if (@($subSpecs).Count -eq 0) { return (Invoke-CadDrawSingle -SpecJson ($spec | ConvertTo-Json -Depth 20) -OutputDir $OutputDir -Dwg $Dwg -DryRun:$DryRun -KeepArtifacts:$KeepArtifacts -TimeoutSeconds $TimeoutSeconds -AccoreConsole $AccoreConsole -SkipPrecheck:$SkipPrecheck -ExpectedUnits $ExpectedUnits -RequiredLayers $RequiredLayers -CompareManifest $CompareManifest) }

    $viewsList = New-Object System.Collections.Generic.List[object]
    $allWarnings = New-Object System.Collections.Generic.List[string]
    $worstStatus = 'ok'
    $statusRank = @{ 'failed' = 4; 'blocked' = 3; 'partial' = 2; 'dry-run' = 1; 'ok' = 0 }
    $worstDisposition = 'pass'
    $dispRank = @{ 'fail' = 4; 'blocked' = 3; 'needs_review' = 2; 'pass_with_warnings' = 1; 'pass' = 0 }
    $totalEntity = 0
    $totalDuration = 0

    $si = 0
    foreach ($sub in @($subSpecs)) {
        $vid = ([string](Get-CadField $sub 'name' "view$si")) -replace ('^' + [regex]::Escape([string](Get-CadField $spec 'name' 'drawing')) + '-'), ''
        if (-not $vid) { $vid = "view$si" }

        $r = $null
        try {
            $argsV = @{
                SpecJson       = $sub | ConvertTo-Json -Depth 20
                OutputDir      = $OutputDir
                DryRun         = $DryRun
                KeepArtifacts  = $KeepArtifacts
                TimeoutSeconds = $TimeoutSeconds
                AccoreConsole  = $AccoreConsole
                SkipPrecheck   = $SkipPrecheck
                ExpectedUnits  = $ExpectedUnits
            }
            if ($RequiredLayers) { $argsV.RequiredLayers = $RequiredLayers }
            # Manifest 留给单视图自己按 OutputDir 落盘（每个视图独立 manifest.json
            # 会互相覆盖，所以这里不传，让单视图默认写到同一 OutputDir —— 但
            # 单视图的默认 manifest 名相同会覆盖，因此多视图时显式给每视图一个）
            $argsV.Manifest = if ($OutputDir) { Join-Path $OutputDir "manifest-$vid.json" } else { "manifest-$vid.json" }
            $r = Invoke-CadDrawSingle @argsV
        } catch {
            $r = [pscustomobject][ordered]@{
                status = 'failed'; disposition = 'fail'; advice = $null
                drawing = $vid; entityCount = 0; layers = @(); artifacts = @()
                checks = @(); warnings = @($($_.Exception.Message)); error = $_.Exception.Message
                logDir = $null; exitCode = $null; exitName = $null; timedOut = $false
                markers = [ordered]@{}; units = $null; unitsCheck = $null
                layersCheck = $null; evidence = @(); manifest = $null; compare = $null
                durationMs = 0
            }
        }

        foreach ($w in @($r.warnings)) { $allWarnings.Add("[视图 $vid] $w") }

        if ($statusRank[[string]$r.status] -gt $statusRank[$worstStatus]) { $worstStatus = [string]$r.status }
        $rd = [string]$r.disposition
        if (-not $dispRank.ContainsKey($rd)) { $rd = 'needs_review' }
        if ($dispRank[$rd] -gt $dispRank[$worstDisposition]) { $worstDisposition = $rd }

        $totalEntity += [int]$r.entityCount
        $totalDuration += [int]$r.durationMs

        $viewsList.Add([pscustomobject][ordered]@{
            id          = $vid
            name        = $r.drawing
            status      = $r.status
            disposition = $r.disposition
            entityCount = $r.entityCount
            artifacts   = $r.artifacts
            manifest    = $r.manifest
            error       = $r.error
            report      = $r
        })
        $si++
    }

    return [pscustomobject][ordered]@{
        status      = $worstStatus
        disposition = $worstDisposition
        advice      = Get-CadDispositionAdvice -Disposition $worstDisposition
        drawing     = [string](Get-CadField $spec 'name' 'drawing')
        entityCount = $totalEntity
        layers      = @()
        artifacts   = @($viewsList | ForEach-Object { $_.artifacts })
        checks      = @()
        warnings    = $allWarnings.ToArray()
        error       = $null
        logDir      = $null
        exitCode    = $null
        exitName    = $null
        timedOut    = $false
        markers     = [ordered]@{}
        units       = $null
        unitsCheck  = $null
        layersCheck = $null
        evidence    = @()
        manifest    = $null
        compare     = $null
        durationMs  = [int]((Get-Date) - $started).TotalMilliseconds
        multiView   = $true
        views       = $viewsList.ToArray()
    }
}
# ── 入口 ──────────────────────────────────────────────────────────
$drawArgs = @{
    SpecFile        = $SpecFile
    SpecJson        = $SpecJson
    OutputDir       = $OutputDir
    Dwg             = $Dwg
    DryRun          = $DryRun
    KeepArtifacts   = $KeepArtifacts
    TimeoutSeconds  = $TimeoutSeconds
    AccoreConsole   = $AccoreConsole
    SkipPrecheck    = $SkipPrecheck
    ExpectedUnits   = $ExpectedUnits
    RequiredLayers  = $RequiredLayers
    CompareManifest = $CompareManifest
}
# Manifest 单独处理：空串是「不写清单」的有效取值，
# 不能因为 $Manifest 是 '' 就当成「没传」而落回默认路径。
if ($PSBoundParameters.ContainsKey('Manifest')) { $drawArgs.Manifest = $Manifest }

$result = Invoke-CadDraw @drawArgs

Write-CadReport -Report $result -Json:$AsJson

if ($result.status -in @('ok', 'dry-run')) {
    # 0 只表示「图画出来了」。验收不过时得给 CI 一个能拦住它的码，
    # 否则 `Invoke-CadDraw.ps1 ... ; if ($LASTEXITCODE) {...}` 会当成功放行。
    if ($result.disposition -eq 'fail') { exit 5 }
    exit 0
}
elseif ($result.status -eq 'partial') { exit 3 }
elseif ($result.status -eq 'blocked') { exit 4 }
else { exit 1 }
