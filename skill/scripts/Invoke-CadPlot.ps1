<#
    Invoke-CadPlot.ps1 — 把已有 DWG 打印成 PDF
    ────────────────────────────────────────────────────────────────
    和 Invoke-CadDraw 的 save.pdf 是同一套 -PLOT 序列，区别在于：
      · Invoke-CadDraw：先画图，再顺手打印
      · 本脚本：图已经存在，只打印

    实测要点（都写进 cadcore.lsp 的 c:PLOTPDF 注释里了，这里列行为）：
      · accoreconsole **没有** EXPORTPDF 命令，只能走 -PLOT + DWG To PDF.pc3
      · -PLOT 有严格固定的 17 步提示，错位会把 "_M" 当命令名
      · 图纸尺寸必须给全名，"A3" 会被忽略并回落 ANSI A
      · 打印完成后 _.QUIT 还会问是否保存，必须补 _N 应答

    用法：
      .\Invoke-CadPlot.ps1 -Path drawing.dwg
      .\Invoke-CadPlot.ps1 -Path drawing.dwg -Output plan.pdf -PaperSize A2
      .\Invoke-CadPlot.ps1 -Path drawing.dwg -Orientation Portrait -PlotArea Limits
      .\Invoke-CadPlot.ps1 -Path drawing.dwg -AsJson
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Output,
    [ValidateSet('A0', 'A1', 'A2', 'A3', 'A4', 'B', 'C', 'D', 'E')]
    [string]$PaperSize = 'A3',
    [ValidateSet('Landscape', 'Portrait')]
    [string]$Orientation = 'Landscape',
    [ValidateSet('Extents', 'Display', 'Limits', 'Window')]
    [string]$PlotArea = 'Extents',
    [ValidateSet('monochrome.ctb', 'none')]
    [string]$StyleTable = 'monochrome.ctb',
    [switch]$AsJson,
    [int]$TimeoutSeconds = 180,
    [string]$AccoreConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')

$report = [ordered]@{
    status     = 'unknown'
    source     = $null
    output     = $null
    bytes      = 0
    paperSize  = $PaperSize
    # 方向与打印区域是调用方传入的关键决策，报告里必须回显，
    # 否则调用方无法确认自己请求的 Portrait/Window 是否真被采纳。
    orientation = $Orientation
    plotArea    = $PlotArea
    # 结构校验结果（%PDF 头 + %%EOF + 页数），不是「文件存在」的别名
    pages      = 0
    valid      = $false
    warnings   = @()
    error      = $null
    durationMs = $null
}
$warnings = New-Object System.Collections.Generic.List[string]
$started = Get-Date
$tempDir = $null

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "源文件不存在: $Path"
    }
    $src = (Resolve-Path -LiteralPath $Path).Path
    $report.source = $src
    if ([IO.Path]::GetExtension($src).ToLowerInvariant() -ne '.dwg') {
        throw "只接受 .dwg 输入。要打印 DXF 请先另存为 DWG。"
    }

    if (-not $Output) { $Output = [IO.Path]::ChangeExtension($src, '.pdf') }
    elseif (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path (Split-Path -Parent $src) $Output }
    $outFull = [IO.Path]::GetFullPath($Output)
    if ([IO.Path]::GetExtension($outFull) -ne '.pdf') { $outFull = $outFull + '.pdf' }
    $outDir = Split-Path -Parent $outFull
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    $report.output = $outFull

    Initialize-CadState | Out-Null
    $accoreInfo = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    $accore = $accoreInfo.path

    $tempDir = Join-Path $script:CadStateDir ("plot-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $coreWork = Join-Path $tempDir 'cadcore.lsp'
    Write-CadLsp -Path $coreWork -Body ([IO.File]::ReadAllText((Join-Path $scriptDir 'cadcore.lsp'), [Text.Encoding]::UTF8)) | Out-Null

    # 参数翻译成 -PLOT 的应答符号
    $oriFlag = if ($Orientation -eq 'Portrait') { '_P' } else { '_L' }
    $areaFlag = switch ($PlotArea) {
        'Extents' { '_E' }
        'Display' { '_D' }
        'Limits'  { '_L' }
        'Window'  { '_W' }
    }
    $styleArg = if ($StyleTable -eq 'none') { '""' } else { "`"$StyleTable`"" }

    # 这里刻意不用 c:PLOTPDF，因为它固定了横向/范围；本脚本要能改方向与范围，
    # 所以直接展开完整的 17 步序列。
    $lsp = Join-Path $tempDir 'plot.lsp'
    Write-CadLsp -Path $lsp -Body @"
(setvar "SECURELOAD" 0)
(load "$(ConvertTo-CadPath $coreWork)")
(c:SETUP)
(cadcmd (list "_.-PLOT"
  "_Y" "Model" "DWG To PDF.pc3"
  (cadpaper "$PaperSize")
  "_M" "$oriFlag" "_N" "$areaFlag" "_F" "_C"
  "_Y" $styleArg "_Y" "_A"
  "$(ConvertTo-CadPath $outFull)"
  "_N" "_Y"))
(if (findfile "$(ConvertTo-CadPath $outFull)")
  (princ (strcat "\n@@PLOTPDF=ok=" "$(ConvertTo-CadPath $outFull)" " size=" (itoa (vl-file-size "$(ConvertTo-CadPath $outFull)")) "@@"))
  (princ "\n@@PLOTPDF=FAILED@@"))
(princ "\n@@DONE@@")
(princ)
"@ | Out-Null

    $scr = Join-Path $tempDir 'plot.scr'
    Write-CadScr -Path $scr -Lines @(
        '(setvar "SECURELOAD" 0)',
        '(setvar "FILEDIA" 0)',
        '(setvar "CMDDIA" 0)',
        '(setvar "CMDECHO" 0)',
        '(setvar "EXPERT" 5)',
        "(load `"$(ConvertTo-CadPath $lsp)`")",
        '_.QUIT', '_N', '_N'
    ) | Out-Null

    $run = Invoke-CadCoreConsole -AccoreConsole $accore -Script $scr `
        -InputDwg $src -WorkingDirectory $tempDir -TimeoutSeconds $TimeoutSeconds

    if ($run.lispError) { $warnings.Add("LISP 报错: $($run.lispErrorLines -join ' | ')") }
    if ($run.timedOut) { $warnings.Add("执行超时（${TimeoutSeconds}s）") }

    $marker = Get-CadMarker -Result $run -Name 'PLOTPDF'
    if ($marker -and "$marker" -match '^FAILED') {
        $warnings.Add('LISP 报告 PLOTPDF 失败')
    }

    $exists = Test-Path -LiteralPath $outFull -PathType Leaf
    if (-not $exists) {
        throw "打印失败，未生成 PDF（exit=$($run.exitCode) $($run.exitName)）。日志: $($run.stdoutFile)"
    }
    $report.bytes = (Get-Item -LiteralPath $outFull).Length
    # 结构校验而不是只看大小：PLOT 半途失败会留下空壳 PDF。
    $pdfInfo = Test-CadPdfFile -Path $outFull
    $report.pages = $pdfInfo.pageCount
    $report.valid = [bool]$pdfInfo.valid
    if (-not $pdfInfo.valid) {
        $warnings.Add("PDF 结构校验未通过: $($pdfInfo.reason)")
    }

    $report.status = if ($pdfInfo.valid) { 'ok' } else { 'invalid' }
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $report.warnings = $warnings.ToArray()
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  打印 PDF  ·  {0}" -f $report.status)
    Write-Host ('═' * 62)
    Write-Host ("  源文件  : {0}" -f $report.source)
    Write-Host ("  输出    : {0}  ({1:N0} 字节)" -f $report.output, $report.bytes)
    Write-Host ("  图纸    : {0} / {1} / {2}" -f $report.paperSize, $Orientation, $PlotArea)
    if ($report.warnings -and @($report.warnings).Count -gt 0) {
        foreach ($w in $report.warnings) { Write-Host ("  ! {0}" -f $w) }
    }
    if ($report.error) { Write-Host ("  错误    : {0}" -f $report.error) }
    Write-Host ('═' * 62)
}

if ($report.status -eq 'ok') { exit 0 } else { exit 1 }
