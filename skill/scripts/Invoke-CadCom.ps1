<#
    Invoke-CadCom.ps1 — 通过 COM 自动化操控正在运行的 AutoCAD
    ────────────────────────────────────────────────────────────────
    什么时候该用这条通道：
      · 需要真实图形窗口（用户要看着它画）
      · 需要 accoreconsole 不支持的能力（ActiveX 方法、SelectionSets、Plot 对象）
      · 需要读取已打开文档的实时状态

    什么时候不该用：
      · 批量出图 → 用 Invoke-CadDraw，快 10 倍且无残留进程
      · 只要文件产物 → accoreconsole 通道更稳

    ── 实测要点（本机 AutoCAD 2018 / 22.0s）────────────────────────
    1) ProgID 只有 "AutoCAD.Application.22"，裸的 "AutoCAD.Application"
       没有 CurVer，直接 New-Object 会失败。本脚本用 Resolve-CadComProgId
       枚举注册表取最高版本。
    2) 首次 New-Object 约 25 秒（要起完整 acad.exe）。
    3) ★ 点参数封送是最大的坑 ★
       AddCircle/AddText 接受内联数组，但 AddLine 不行 —— 会报
       "Value does not fall within the expected range"。
       原因是 PowerShell 把数组沿管道展开成多个参数：
         $ms.AddLine(@(0,0,0), @(1,1,1))   → 实际传了 6 个 double
       唯一可靠写法是让点先落进变量、且返回时用逗号阻止展开：
         function New-CadComPoint { ...; return , $a }
         $p1 = New-CadComPoint 0 0
         $ms.AddLine($p1, $p2)
       必须 3 个分量（x,y,z）；只给 2 个会报「安全数组中的元素数目不正确」。
    4) Quit() 是异步的，调用后 acad.exe 还会活几秒。必须轮询等它消失，
       超时再强杀，否则会留下看不见的进程。
    5) DisplayAlerts 在 2018 上不可写，赋值会抛异常 —— 属正常，降级为警告。
    6) ★ 图纸空间必须走 Layout.Block，绝不能走 $doc.PaperSpace ★
       实测（探针 probe9-12）：只要 $doc.PaperSpace 或 $lay.Block 经
       scriptblock / InvokeReturnAsIs 返回，COM 集合就被管道展开成
       Object[]，AddCircle 直接报「不包含名为 'AddCircle' 的方法」。
       直接赋值 $blk = $lay.Block 得到真 __ComObject（name=*Paper_Space），
       AddCircle/AddLine/AddText/AddPViewport 全部可用。
       前提：先 $doc.ActiveLayout = $lay（并 SetVariable TILEMODE 0）。

    用法：
      .\Invoke-CadCom.ps1 -Action Info
      .\Invoke-CadCom.ps1 -Action Draw -SpecFile drawing.json -Output out.dwg
      .\Invoke-CadCom.ps1 -Action Open -Path drawing.dwg
      .\Invoke-CadCom.ps1 -Action Export -Path drawing.dwg -Output out.pdf
      .\Invoke-CadCom.ps1 -Action PaperSpace -SpecFile drawing.json -Output out.pdf
      .\Invoke-CadCom.ps1 -Action Info -Visible
#>

[CmdletBinding()]
param(
    [ValidateSet('Info', 'Draw', 'Open', 'Export', 'PaperSpace', 'Quit')]
    [string]$Action = 'Info',
    [string]$SpecFile,
    [string]$Path,
    [string]$Output,
    [ValidateSet('A0', 'A1', 'A2', 'A3', 'A4', 'B', 'C', 'D', 'E')]
    [string]$PaperSize = 'A3',
    [ValidateSet('monochrome.ctb', 'none')]
    [string]$StyleTable = 'monochrome.ctb',
    # PaperSpace：布局名（默认 CAD_PS），已存在则复用
    [string]$LayoutName = 'CAD_PS',
    [switch]$Visible,
    [switch]$KeepOpen,
    [switch]$AsJson,
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadCompiler.ps1')

# ──────────────────────────────────────────────────────────────────
#  ★ 点构造函数：逗号是必须的，见文件头说明 3) ★
#
#  为什么不能套两层函数：
#    PowerShell 的函数输出每经过一层管道就展开一层数组。
#    New-CadComPoint 返回 , $a  → 调用方拿到 $a（double[]）✔ 正好一层
#    若再包一层 ConvertTo-CadComPoint 转手 → 又展开一次 → 变成 3 个 double ✘
#  所以这里只留一个函数，直接在函数内构造数组。
# ──────────────────────────────────────────────────────────────────
function ConvertTo-CadComPoint {
    param($Value, [string]$FieldName = 'point')
    $xy = Get-PointXY -Value $Value -FieldName $FieldName
    $a = New-Object 'double[]' 3
    $a[0] = [double]$xy[0]
    $a[1] = [double]$xy[1]
    $a[2] = 0.0
    return , $a
}

# ──────────────────────────────────────────────────────────────────
#  图纸尺寸：COM 的 CanonicalMediaName 与命令行 -PLOT 的全名不是一套
#
#    -PLOT 命令行 : "ISO A3 (420.00 x 297.00 毫米)"   ← 有空格和括号
#    COM 属性     : "ISO_A3_(420.00_x_297.00_MM)"     ← 下划线，MM 大写
#
#  实测本机 DWG To PDF.pc3 共 93 个 CanonicalMediaName，全部是
#  ISO_full_bleed_* 与 ISO_* 两种前缀。A 系列取 ISO_A3_(420.00_x_297.00_MM)，
#  横向/纵向靠 CanonicalMediaName 里的宽高顺序区分，所以这里按
#  PaperSize 给横版值。
# ──────────────────────────────────────────────────────────────────
function Get-CadComMediaName {
    param([string]$PaperSize)
    $map = @{
        'A4' = 'ISO_A4_(297.00_x_210.00_MM)'
        'A3' = 'ISO_A3_(420.00_x_297.00_MM)'
        'A2' = 'ISO_A2_(594.00_x_420.00_MM)'
        'A1' = 'ISO_A1_(841.00_x_594.00_MM)'
        'A0' = 'ISO_A0_(1189.00_x_841.00_MM)'
        'B'  = 'ISO_B1_(1000.00_x_707.00_MM)'
        'C'  = 'ISO_C1_(917.00_x_1297.00_MM)'
        'D'  = 'ISO_A1_(841.00_x_594.00_MM)'
        'E'  = 'ISO_A0_(1189.00_x_841.00_MM)'
    }
    if ($map.ContainsKey($PaperSize)) { return $map[$PaperSize] }
    return $null
}

# ── 共用：在指定文档里创建 spec 声明的图层 ─────────────────────
# 已存在则忽略；颜色非法时降级默认色并记警告。Draw / PaperSpace 都用。
function New-CadComLayers {
    param($Doc, $Spec, [System.Collections.Generic.List[string]]$Warnings)
    foreach ($l in @(Get-CadField $Spec 'layers' @())) {
        $ln = [string](Get-CadField $l 'name' '')
        if (-not $ln -or $ln -eq '0') { continue }
        try { $null = $Doc.Layers.Add($ln) } catch { }   # 已存在则忽略
        try {
            $ly = $Doc.Layers.Item($ln)
            $col = Get-CadField $l 'color' $null
            if ($null -ne $col) { $ly.Color = [int]$col }
        } catch {
            $Warnings.Add("图层 '$ln' 设置属性失败: $($_.Exception.Message)")
        }
    }
}

# ── 共用：往一个 Block（ModelSpace 或 Layout.Block）里画 spec 实体 ──
# ★ 目标块必须直接赋值取得（$doc.ModelSpace / $lay.Block），不能经 scriptblock ★
# 返回 @{ drawn = 实际画出的实体数 }；不支持的类型记 warning 跳过。
function Add-CadComEntities {
    param($Block, $Spec, [System.Collections.Generic.List[string]]$Warnings)
    $drawn = 0
    $idx = 0
    foreach ($ent in @(Get-CadField $Spec 'entities' @())) {
        $type = [string](Get-CadField $ent 'type' '')
        $layer = [string](Get-CadField $ent 'layer' '0')
        $obj = $null
        try {
            switch ($type) {
                'line' {
                    $p1 = ConvertTo-CadComPoint (Get-CadField $ent 'p1') "entities[$idx].p1"
                    $p2 = ConvertTo-CadComPoint (Get-CadField $ent 'p2') "entities[$idx].p2"
                    $obj = $Block.AddLine($p1, $p2)
                }
                'circle' {
                    $c = ConvertTo-CadComPoint (Get-CadField $ent 'c') "entities[$idx].c"
                    $r = [double](Get-CadField $ent 'r' 10)
                    $obj = $Block.AddCircle($c, $r)
                }
                'arc' {
                    $c = ConvertTo-CadComPoint (Get-CadField $ent 'c') "entities[$idx].c"
                    $r = [double](Get-CadField $ent 'r' 10)
                    $a1 = [double](Get-CadField $ent 'startAngle' 0)
                    $a2 = [double](Get-CadField $ent 'endAngle' 90)
                    # COM 的 AddArc 角度单位是弧度，JSON 里写的是度
                    $obj = $Block.AddArc($c, $r, $a1 * [Math]::PI / 180.0, $a2 * [Math]::PI / 180.0)
                }
                'text' {
                    $at = ConvertTo-CadComPoint (Get-CadField $ent 'at') "entities[$idx].at"
                    $h = [double](Get-CadField $ent 'height' 5)
                    $txt = [string](Get-CadField $ent 'value' '')
                    $obj = $Block.AddText($txt, $at, $h)
                }
                'point' {
                    $at = ConvertTo-CadComPoint (Get-CadField $ent 'at') "entities[$idx].at"
                    $obj = $Block.AddPoint($at)
                }
                'polyline' {
                    $pts = @(Get-CadField $ent 'points' @())
                    if ($pts.Count -lt 2) { throw "polyline 至少需要 2 个点" }
                    # AddLightWeightPolyline 收一维 double 数组 [x1,y1,x2,y2,...]
                    $flat = New-Object 'double[]' ($pts.Count * 2)
                    for ($i = 0; $i -lt $pts.Count; $i++) {
                        $xy = Get-PointXY -Value $pts[$i] -FieldName "entities[$idx].points[$i]"
                        $flat[$i * 2] = $xy[0]
                        $flat[$i * 2 + 1] = $xy[1]
                    }
                    # 注意：方法调用的括号里不能用逗号操作符（PS 语法错误），
                    # 必须先把数组落进变量再传，PowerShell 才不会展开它。
                    $flatArg = $flat
                    $obj = $Block.AddLightWeightPolyline($flatArg)
                }
                default {
                    $Warnings.Add("COM 通道不支持实体类型 '$type'（支持 line/circle/arc/text/point/polyline）。批量出图请用 Invoke-CadDraw。")
                    $idx++
                    continue
                }
            }

            if ($obj -and $layer -and $layer -ne '0') {
                try { $obj.Layer = $layer }
                catch { $Warnings.Add("entities[$idx] 设置图层 '$layer' 失败: $($_.Exception.Message)") }
            }
            $drawn++
        } catch {
            $Warnings.Add("绘制 entities[$idx] ($type) 失败: $($_.Exception.Message)")
        }
        $idx++
    }
    return @{ drawn = $drawn }
}

# ── 共用：配置布局打印参数并 PlotToFile 出 PDF ─────────────────
# PlotToFile 是异步的（先 0 字节再慢慢写），必须轮询大小稳定。
# $TargetLayout 是 Layout 对象（模型空间出图传 $doc.ActiveLayout，
# 图纸空间传新建的布局）。
function Invoke-CadComPlot {
    param($Doc, $TargetLayout, [string]$OutFull, [string]$PaperSize,
          [string]$StyleTable, [System.Collections.Generic.List[string]]$Warnings,
          [int]$TimeoutSeconds)
    $TargetLayout.ConfigName = 'DWG To PDF.pc3'
    # CanonicalMediaName 要下划线格式，和命令行 -PLOT 的显示名不一样
    $mediaName = Get-CadComMediaName -PaperSize $PaperSize
    if ($mediaName) {
        try { $TargetLayout.CanonicalMediaName = $mediaName }
        catch { $Warnings.Add("设置图纸尺寸 '$mediaName' 失败，沿用文档默认: $($_.Exception.Message)") }
    }
    try { $TargetLayout.PlotType = 1 } catch { }          # 1 = acExtents
    try { $TargetLayout.CenterPlot = $true } catch { }
    try { $TargetLayout.UseStandardScale = $true } catch { }
    try { $TargetLayout.StandardScale = 0 } catch { }     # 0 = acScaleToFit
    if ($StyleTable -eq 'monochrome.ctb') {
        try {
            $TargetLayout.PlotWithPlotStyles = $true
            $TargetLayout.StyleSheet = 'monochrome.ctb'
        } catch { }
    }
    try { $Doc.Plot.QuietErrorMode = $true } catch { }

    $r = $Doc.Plot.PlotToFile($OutFull)
    if (-not $r) { $Warnings.Add('PlotToFile 返回 False（打印可能未启动）') }

    # 轮询：等文件大小稳定且非空
    $lastSize = -1
    $stable = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $sz = 0
        if (Test-Path -LiteralPath $OutFull) { $sz = (Get-Item -LiteralPath $OutFull).Length }
        if ($sz -ne $lastSize) { $lastSize = $sz; $stable = 0 }
        else { $stable++ }
        if ($sz -gt 0 -and $stable -ge 3) { break }
    }
    if (-not (Test-Path -LiteralPath $OutFull)) {
        throw "Plot.PlotToFile 未生成文件: $OutFull（日志见警告）"
    }
    $finalSize = (Get-Item -LiteralPath $OutFull).Length
    if ($finalSize -eq 0) {
        throw "Plot.PlotToFile 生成了 0 字节 PDF: $OutFull（等待 ${TimeoutSeconds}s 仍未写入）"
    }
    return $finalSize
}

$report = [ordered]@{
    status      = 'unknown'
    action      = $Action
    progId      = $null
    version     = $null
    documents   = @()
    activeDoc   = $null
    entityCount = $null
    layout      = $null
    paperSpaceCount = $null
    output      = $null
    bytes       = 0
    warnings    = @()
    error       = $null
    durationMs  = $null
}
$warnings = New-Object System.Collections.Generic.List[string]
$started = Get-Date
$acad = $null
$doc = $null

try {
    Initialize-CadState | Out-Null
    $progInfo = Resolve-CadComProgId
    if (-not $progInfo -or -not $progInfo.progId) {
        throw @"
找不到可用的 AutoCAD COM ProgID。
本机注册表里没有 AutoCAD.Application.* 项。
如果 AutoCAD 是精简版/绿色版，可能未注册 COM 自动化接口，
这种情况请改用 accoreconsole 通道（Invoke-CadDraw）。
"@
    }
    $report.progId = $progInfo.progId

    Write-Verbose "创建 COM 对象 $($progInfo.progId)（首次约 25 秒）..."
    try {
        $acad = New-Object -ComObject $progInfo.progId
    } catch {
        throw "创建 COM 对象 '$($progInfo.progId)' 失败: $($_.Exception.Message)。请确认 AutoCAD 已正确安装并注册。"
    }

    $acad.Visible = [bool]$Visible
    try { $report.version = [string]$acad.Version } catch { $report.version = 'unknown' }

    # 2018 上 DisplayAlerts 不可写，赋值会抛 —— 降级为警告，不影响主流程
    try { $acad.DisplayAlerts = $false }
    catch { $warnings.Add('DisplayAlerts 不可写（AutoCAD 2018 已知行为，不影响出图）') }

    switch ($Action) {
        'Info' {
            $docs = @()
            for ($i = 0; $i -lt $acad.Documents.Count; $i++) {
                $d = $acad.Documents.Item($i)
                $docs += [pscustomobject]@{
                    name  = [string]$d.Name
                    path  = [string]$d.FullName
                    saved = [bool]$d.Saved
                }
            }
            $report.documents = $docs
            if ($acad.Documents.Count -gt 0) {
                $report.activeDoc = [string]$acad.ActiveDocument.Name
            }
            $report.status = 'ok'
        }

        'Open' {
            if (-not $Path) { throw 'Open 需要 -Path' }
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件不存在: $Path" }
            $full = (Resolve-Path -LiteralPath $Path).Path
            $doc = $acad.Documents.Open($full)
            $report.activeDoc = [string]$doc.Name
            $report.documents = @([pscustomobject]@{
                    name = [string]$doc.Name; path = [string]$doc.FullName; saved = [bool]$doc.Saved
                })
            $report.status = 'ok'
        }

        'Draw' {
            if (-not $SpecFile) { throw 'Draw 需要 -SpecFile' }
            if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { throw "文件不存在: $SpecFile" }
            $specPath = (Resolve-Path -LiteralPath $SpecFile).Path
            $spec = [IO.File]::ReadAllText($specPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

            # 新建文档。Documents.Add() 会带一个默认模板（通常是 Drawing1）
            $doc = $acad.Documents.Add()

            # 先建图层（实体引用不存在图层时，某些版本会直接报错）
            New-CadComLayers -Doc $doc -Spec $spec -Warnings $warnings

            # ★ ModelSpace 必须直接赋值，不能经 scriptblock（见文件头第 6 条）★
            $ms = $doc.ModelSpace
            $r = Add-CadComEntities -Block $ms -Spec $spec -Warnings $warnings
            $drawn = $r.drawn

            if ($Output) {
                $outFull = if ([IO.Path]::IsPathRooted($Output)) { $Output }
                else { Join-Path (Get-Location).Path $Output }
                $outFull = [IO.Path]::GetFullPath($outFull)
                if ([IO.Path]::GetExtension($outFull).ToLowerInvariant() -ne '.dwg') { $outFull += '.dwg' }
                $d = Split-Path -Parent $outFull
                if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }
                $doc.SaveAs($outFull)
                $report.output = $outFull
            }

            $report.entityCount = $drawn
            $report.activeDoc = [string]$doc.Name
            if ($drawn -eq 0) { $report.status = 'partial' } else { $report.status = 'ok' }
        }

        'Export' {
            if (-not $Path) { throw 'Export 需要 -Path（要导出的 dwg）' }
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件不存在: $Path" }
            $full = (Resolve-Path -LiteralPath $Path).Path
            $doc = $acad.Documents.Open($full)

            if (-not $Output) { $Output = [IO.Path]::ChangeExtension($full, '.pdf') }
            elseif (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path (Split-Path -Parent $full) $Output }
            $outFull = [IO.Path]::GetFullPath($Output)
            if ([IO.Path]::GetExtension($outFull).ToLowerInvariant() -ne '.pdf') { $outFull += '.pdf' }
            $d = Split-Path -Parent $outFull
            if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }

            # ── Plot 对象：ActiveX 打印接口（共用 helper，见 Invoke-CadComPlot）──
            $layout = $doc.ActiveLayout
            $finalSize = Invoke-CadComPlot -Doc $doc -TargetLayout $layout -OutFull $outFull `
                -PaperSize $PaperSize -StyleTable $StyleTable -Warnings $warnings `
                -TimeoutSeconds $TimeoutSeconds
            $report.output = $outFull
            $report.bytes = $finalSize
            $report.status = 'ok'
        }

        'PaperSpace' {
            if (-not $SpecFile) { throw 'PaperSpace 需要 -SpecFile' }
            if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { throw "文件不存在: $SpecFile" }
            $specPath = (Resolve-Path -LiteralPath $SpecFile).Path
            $spec = [IO.File]::ReadAllText($specPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

            # 输出路径：默认与 spec 同名的 .pdf
            if (-not $Output) { $Output = [IO.Path]::ChangeExtension($specPath, '.pdf') }
            elseif (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path (Get-Location).Path $Output }
            $outFull = [IO.Path]::GetFullPath($Output)
            if ([IO.Path]::GetExtension($outFull).ToLowerInvariant() -ne '.pdf') { $outFull += '.pdf' }
            $d = Split-Path -Parent $outFull
            if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }

            # 新建文档 + 图层
            $doc = $acad.Documents.Add()
            New-CadComLayers -Doc $doc -Spec $spec -Warnings $warnings

            # ── 布局：已存在则复用，否则新建 ───────────────────────
            $psLayout = $null
            foreach ($existing in $doc.Layouts) {
                if ([string]$existing.Name -eq $LayoutName) { $psLayout = $existing; break }
            }
            if (-not $psLayout) {
                try { $psLayout = $doc.Layouts.Add($LayoutName) }
                catch { throw "创建布局 '$LayoutName' 失败: $($_.Exception.Message)" }
            }
            $report.layout = $LayoutName

            # 切到布局（图纸空间）。TILEMODE=0 保持图纸空间模式。
            $doc.ActiveLayout = $psLayout
            try { $null = $doc.SetVariable('TILEMODE', 0) } catch { }

            # ── 模型空间画实体 ─────────────────────────────────────
            # spec 里 entities 画进模型空间（真实几何），图纸空间放标题框 + 视口
            $ms = $doc.ModelSpace
            $rModel = Add-CadComEntities -Block $ms -Spec $spec -Warnings $warnings

            # ── 图纸空间：Layout.Block 直接建标题框 + 文字 + 视口 ──
            # ★ $psLayout.Block 必须直接赋值；经 scriptblock 返回会退化 Object[] ★
            $blk = $psLayout.Block
            $psDrawn = 0
            # 标题框（简化：图纸边缘内缩 10mm 的矩形）+ 标题文字
            try {
                $media = Get-CadComMediaName -PaperSize $PaperSize
                $pw = 420.0; $ph = 297.0   # A3 缺省
                if ($PaperSize -eq 'A4') { $pw = 297.0; $ph = 210.0 }
                elseif ($PaperSize -eq 'A2') { $pw = 594.0; $ph = 420.0 }
                elseif ($PaperSize -eq 'A1') { $pw = 841.0; $ph = 594.0 }
                elseif ($PaperSize -eq 'A0') { $pw = 1189.0; $ph = 841.0 }
                $m = 10.0
                $pA = ConvertTo-CadComPoint (@($m, $m, 0)) "paper corner A"
                $pB = ConvertTo-CadComPoint (@(($pw - $m), ($ph - $m), 0)) "paper corner B"
                $null = $blk.AddLine($pA, (ConvertTo-CadComPoint @(($pw - $m), $m, 0) 'border p2'))
                $null = $blk.AddLine((ConvertTo-CadComPoint @(($pw - $m), $m, 0) 'border p2b'), $pB)
                $null = $blk.AddLine($pB, (ConvertTo-CadComPoint @($m, ($ph - $m), 0) 'border p4'))
                $null = $blk.AddLine((ConvertTo-CadComPoint @($m, ($ph - $m), 0) 'border p4b'), $pA)
                $psDrawn += 4
                # ★ 数组字面量里做算术必须整体加括号：不加括号的算术元素会被解析成
                #   算术加逗号列表（逗号优先级低于加号），得到 Object[] 再对它做加法
                #   直接报「op_Addition 不存在」。必须给算术整体加括号。
                $titleAt = ConvertTo-CadComPoint @(($m + 5), ($ph - $m - 8), 0) 'title position'
                $titleObj = $blk.AddText([string](Get-CadField $spec 'name' '图纸'), $titleAt, 6.0)
                $psDrawn++
                try { $titleObj.Layer = '0' } catch { }
            } catch {
                $warnings.Add("图纸空间标题框/文字失败: $($_.Exception.Message)")
            }
            # 视口：显示模型空间内容
            try {
                $vp = $blk.AddPViewport((ConvertTo-CadComPoint @(($pw / 2.0), (($ph - 30.0) / 2.0), 0) 'viewport center'), ($pw - 40.0), ($ph - 60.0))
                $vp.Display($true)
                $psDrawn++
            } catch {
                $warnings.Add("创建视口失败: $($_.Exception.Message)")
            }

            # ── 打印该布局 ─────────────────────────────────────────
            $finalSize = Invoke-CadComPlot -Doc $doc -TargetLayout $psLayout -OutFull $outFull `
                -PaperSize $PaperSize -StyleTable $StyleTable -Warnings $warnings `
                -TimeoutSeconds $TimeoutSeconds

            $report.entityCount = $rModel.drawn
            $report.paperSpaceCount = $psDrawn
            $report.output = $outFull
            $report.bytes = $finalSize
            $report.activeDoc = [string]$doc.Name
            if ($rModel.drawn -eq 0 -and $psDrawn -eq 0) { $report.status = 'partial' } else { $report.status = 'ok' }
        }

        'Quit' {
            $report.status = 'ok'
        }
    }

    if ($doc -and -not $KeepOpen) {
        try { $doc.Close($false) } catch { $warnings.Add("关闭文档失败: $($_.Exception.Message)") }
    }
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $report.warnings = $warnings.ToArray()
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds

    # ── 退出 AutoCAD ────────────────────────────────────────────
    # Quit() 是异步的：调用后 acad.exe 还会活几秒。必须轮询等它消失，
    # 超时再强杀，否则会留下看不见的进程。
    if ($acad) {
        if (-not $KeepOpen) {
            try { $acad.Quit() } catch { }
        }
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($acad) } catch { }
        $acad = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    if (-not $KeepOpen) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $alive = @(Get-Process -Name 'acad' -ErrorAction SilentlyContinue)
            if ($alive.Count -eq 0) { break }
            Start-Sleep -Milliseconds 400
        }
        $alive = @(Get-Process -Name 'acad' -ErrorAction SilentlyContinue)
        if ($alive.Count -gt 0) {
            $report.warnings = @($report.warnings) + "AutoCAD 未在 20 秒内自行退出（PID $($alive.Id -join ',')），已强制结束"
            foreach ($p in $alive) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  COM 通道  ·  {0}  ·  {1}" -f $report.action, $report.status)
    Write-Host ('═' * 62)
    Write-Host ("  ProgID   : {0}" -f $report.progId)
    Write-Host ("  版本     : {0}" -f $report.version)
    if ($report.activeDoc) { Write-Host ("  当前文档 : {0}" -f $report.activeDoc) }
    if ($report.documents -and @($report.documents).Count -gt 0) {
        Write-Host '  已打开   :'
        foreach ($d in $report.documents) { Write-Host ("             {0}" -f $d.name) }
    }
    if ($null -ne $report.entityCount) { Write-Host ("  已画实体 : {0}" -f $report.entityCount) }
    if ($report.output) { Write-Host ("  输出     : {0}" -f $report.output) }
    if ($report.warnings -and @($report.warnings).Count -gt 0) {
        foreach ($w in $report.warnings) { Write-Host ("  ! {0}" -f $w) }
    }
    if ($report.error) { Write-Host ("  错误     : {0}" -f $report.error) }
    Write-Host ("  耗时     : {0:N1} 秒" -f ($report.durationMs / 1000.0))
    Write-Host ('═' * 62)
}

if ($report.status -eq 'ok' -or $report.status -eq 'partial') { exit 0 } else { exit 1 }
