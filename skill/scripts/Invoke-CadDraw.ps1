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
    [string]$AccoreConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadCompiler.ps1')

function Write-CadReport {
    param($Report, [switch]$Json)
    if ($Json) {
        $Report | ConvertTo-Json -Depth 8
    } else {
        Write-Host ''
        Write-Host ('═' * 62)
        Write-Host ("  cad-automatic-wwj  ·  {0}" -f $Report.status)
        Write-Host ('═' * 62)
        if ($Report.drawing) { Write-Host ("  图纸    : {0}" -f $Report.drawing) }
        if ($null -ne $Report.entityCount) { Write-Host ("  实体    : {0} 个" -f $Report.entityCount) }
        if ($Report.layers) { Write-Host ("  图层    : {0}" -f ($Report.layers -join ', ')) }
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
            }
        }
        if ($Report.warnings -and @($Report.warnings).Count -gt 0) {
            Write-Host '  警告    :'
            foreach ($w in $Report.warnings) { Write-Host ("            ! {0}" -f $w) }
        }
        if ($Report.error) { Write-Host ("  错误    : {0}" -f $Report.error) }
        if ($Report.logDir) { Write-Host ("  日志    : {0}" -f $Report.logDir) }
        Write-Host ('═' * 62)
    }
}

function Invoke-CadDraw {
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
    $report = [ordered]@{
        status      = 'unknown'
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
            $report.status = 'dry-run'
            $report.checks = $checks.ToArray()
            $report.warnings = $warnings.ToArray()
            $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
            return $report
        }

        # ── 6. 生成 scr 并执行 ───────────────────────────────────
        $scrPath = Join-Path $work 'draw.lsp.scr'
        Write-CadScr -Path $scrPath -Lines @(
            '(setvar "SECURELOAD" 0)',
            '(setvar "FILEDIA" 0)',
            '(setvar "CMDDIA" 0)',
            '(setvar "CMDECHO" 0)',
            '(setvar "OSMODE" 0)',
            '(setvar "EXPERT" 5)',
            "(load `"$(ConvertTo-CadPath $lspPath)`")",
            # QUIT 之后可能还会问「是否保存对 xxx 的修改？」，不给应答就挂住。
            # 多给几个 _N 兜底：多出来的空行对已退出的会话无害。
            '_.QUIT',
            '_N',
            '_N',
            '_N'
        ) | Out-Null

        $run = Invoke-CadCoreConsole -AccoreConsole $accore `
            -Script $scrPath -WorkingDirectory $work -TimeoutSeconds $TimeoutSeconds

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

        $report.artifacts = $artifacts.ToArray()
        $report.checks = $checks.ToArray()
        $report.warnings = $warnings.ToArray()

        $failed = @($checks | Where-Object { -not $_.pass })
        $report.status = if ($failed.Count -eq 0) { 'ok' } elseif ($doneMarker) { 'partial' } else { 'failed' }
        if ($failed.Count -gt 0) {
            $report.error = ($failed | ForEach-Object { $_.name }) -join '; '
        }

    } catch {
        $report.status = 'failed'
        $report.error = $_.Exception.Message
        $report.checks = $checks.ToArray()
        $report.warnings = $warnings.ToArray()
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

# ── 入口 ──────────────────────────────────────────────────────────
$result = Invoke-CadDraw -SpecFile $SpecFile -SpecJson $SpecJson -OutputDir $OutputDir `
    -Dwg $Dwg -DryRun:$DryRun -KeepArtifacts:$KeepArtifacts -TimeoutSeconds $TimeoutSeconds `
    -AccoreConsole $AccoreConsole

Write-CadReport -Report $result -Json:$AsJson

if ($result.status -in @('ok', 'dry-run')) { exit 0 }
elseif ($result.status -eq 'partial') { exit 3 }
else { exit 1 }
