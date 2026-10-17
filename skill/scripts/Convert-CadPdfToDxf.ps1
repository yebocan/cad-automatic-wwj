#Requires -Version 5.1
<#
.SYNOPSIS
    把矢量 PDF 的线稿转成 DXF（CLI 包装，逻辑在 CadPdf.ps1）。

.DESCRIPTION
    只转矢量路径。文字、位图、渐变、裁剪一律不转，并在报告里逐项列出。
    如果这份 PDF 是扫描件（整页就是一张图），会明确报「没有可解析的矢量内容流」，
    而不是给一个空 DXF 让人以为成功了。

    单位提示：PDF 的坐标单位是「点」（1/72 英寸）。
      - 想在 CAD 里继续按点工作：什么都不传（-Scale 默认 1）。
      - 想要毫米：-Scale 0.352778
      - 想要英寸：-Scale 0.0138889

.PARAMETER Path
    输入 PDF。

.PARAMETER Output
    输出 DXF。省略则只解析不写文件。

.PARAMETER Page
    页码，从 1 开始。默认 1。

.PARAMETER Scale
    缩放系数。默认 1（保持 PDF 点为单位）。

.PARAMETER Layer
    线稿图层名，默认 PDF_STROKE。

.PARAMETER BezierSegments
    贝塞尔展平段数，默认 8。

.PARAMETER IncludeFill
    连填充路径轮廓一起导出。

.PARAMETER AsJson
    JSON 输出。

.EXAMPLE
    .\Convert-CadPdfToDxf.ps1 -Path plan.pdf -Output plan.dxf

.EXAMPLE
    .\Convert-CadPdfToDxf.ps1 -Path plan.pdf -Output plan.dxf -Scale 0.352778 -BezierSegments 16 -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$Output,
    [int]$Page = 1,
    [double]$Scale = 1.0,
    [string]$Layer = 'PDF_STROKE',
    [int]$BezierSegments = 8,
    [switch]$IncludeFill,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')
. (Join-Path $scriptDir 'CadPdf.ps1')

function Write-CadPdfReport {
    param([object]$Report)

    Write-Host ''
    Write-Host "PDF → DXF  ·  $($Report.status)" -ForegroundColor Cyan
    Write-Host "  源文件    : $($Report.source)"
    if ($Report.output) { Write-Host "  输出      : $($Report.output)  ($([math]::Round($Report.bytes / 1KB, 1)) KB)" }
    Write-Host "  PDF 版本  : $($Report.pdfVersion)  ·  $($Report.pageCount) 页  ·  流 $($Report.streamCount) 个"
    Write-Host "  解析流    : 过滤 $($Report.streamFilter)  ·  $($Report.streamBytes) 字节 → $($Report.expandedBytes) 字节"
    Write-Host "  路径      : 共 $($Report.pathCount) 条（描边 $($Report.strokePaths) / 填充 $($Report.fillPaths)）→ 导出 $($Report.exportedPaths) 条"
    if ($Report.entities -gt 0) {
        Write-Host "  DXF 实体  : $($Report.entities)"
    }
    if ($Report.extents) {
        $e = $Report.extents
        Write-Host ("  范围      : ({0}, {1}) – ({2}, {3})  宽 {4} / 高 {5}" -f
            [math]::Round($e.minX, 3), [math]::Round($e.minY, 3),
            [math]::Round($e.maxX, 3), [math]::Round($e.maxY, 3),
            [math]::Round($e.maxX - $e.minX, 3), [math]::Round($e.maxY - $e.minY, 3))
    }
    if ($Report.unsupported.Count -gt 0) {
        Write-Host "  未转换    : $($Report.unsupported -join '、')" -ForegroundColor Yellow
    }
    foreach ($w in $Report.warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
    Write-Host "  耗时      : $($Report.durationMs) ms"
    Write-Host ''
}

$report = $null
try {
    $report = Convert-CadPdfToDxf -Path $Path -Output $Output -Page $Page -Scale $Scale `
        -Layer $Layer -BezierSegments $BezierSegments -IncludeFill:$IncludeFill

    if ($AsJson) {
        $report | ConvertTo-Json -Depth 10
    }
    else {
        Write-CadPdfReport -Report $report
    }

    switch ($report.status) {
        'ok' { exit 0 }
        'parsed' { exit 0 }
        'empty' { exit 3 }
        default { exit 1 }
    }
}
catch {
    $msg = $_.Exception.Message
    if ($AsJson) {
        [ordered]@{
            status     = 'failed'
            source     = $Path
            output     = $Output
            error      = $msg
            durationMs = 0
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Host "PDF → DXF  failed" -ForegroundColor Red
        Write-Host "  $msg" -ForegroundColor Red
        if ($msg -match '扫描件|矢量内容流') {
            Write-Host '  提示：这份 PDF 很可能是扫描件。先做 OCR 与线稿矢量化，再喂给本工具。' -ForegroundColor Yellow
        }
    }
    exit 1
}
