<#
    Invoke-CadRenderPreview.ps1 — DXF 预览渲染 CLI（不开 CAD）
    ══════════════════════════════════════════════════════════════════

    用法：
      Invoke-CadRenderPreview.ps1 -Dxf <dxf路径> [-Page A4|A3|A2|A1]
          [-Orientation landscape|portrait] [-MarginMm 10] [-Dpi 300]
          [-OutputDir <目录>] [-NoPng] [-NoPdf] [-AsJson]

    做什么：
      读 ASCII DXF → 结构审计（段配对/EOF/实体可解析性）→
      实体/图层计数 → 按固定页幅渲染 PNG（System.Drawing）+ PDF（矢量）。

    退出码：0 = pass / pass_with_warnings；3 = blocked（结构错误）；1 = 异常。

    人读面板示例：
      status pass_with_warnings | entities 25 | blocks 0
      page A3 landscape 420x297mm dpi 300
      artifacts: png=...pdf=...
#>

param(
    [Parameter(Mandatory)][string]$Dxf,
    [string]$OutputDir,
    [ValidateSet('A4', 'A3', 'A2', 'A1')][string]$Page = 'A4',
    [ValidateSet('landscape', 'portrait')][string]$Orientation = 'landscape',
    [double]$MarginMm = 10.0,
    [int]$Dpi = 300,
    [switch]$NoPng,
    [switch]$NoPdf,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadEvidence.ps1')
. (Join-Path $scriptDir 'CadRender.ps1')

try {
    $renderArgs = @{
        Dxf         = $Dxf
        Page        = $Page
        Orientation = $Orientation
        MarginMm    = $MarginMm
        Dpi         = $Dpi
    }
    if ($PSBoundParameters.ContainsKey('OutputDir')) { $renderArgs.OutputDir = $OutputDir }
    if ($NoPng) { $renderArgs.NoPng = $true }
    if ($NoPdf) { $renderArgs.NoPdf = $true }

    $r = Invoke-CadDxfPreviewRender @renderArgs

    if ($AsJson) {
        $r | ConvertTo-Json -Depth 6
    } else {
        Write-Host ''
        Write-Host "═══ DXF 预览渲染 ═══" -ForegroundColor Cyan
        Write-Host ("  status    : {0}" -f $r.status)
        Write-Host ("  dxf       : {0}" -f $r.dxf)
        if ($r.version) { Write-Host ("  version   : {0} (编码 {1})" -f $r.version, $r.encoding) }
        Write-Host ("  entities  : {0}  blocks: {1}" -f $r.entityTotal, $r.blockTotal)
        if ($r.audit_errors.Count -gt 0) {
            Write-Host "  audit_errors:" -ForegroundColor Red
            foreach ($e in $r.audit_errors) { Write-Host ("    - {0}" -f $e) -ForegroundColor Red }
        }
        if ($r.audit_fixes.Count -gt 0) {
            Write-Host "  audit_fixes:" -ForegroundColor Yellow
            foreach ($f in $r.audit_fixes) { Write-Host ("    - {0}" -f $f) -ForegroundColor Yellow }
        }
        $ecText = ($r.entity_counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        if ($ecText) { Write-Host ("  by-type   : {0}" -f $ecText) }
        $lcText = ($r.layer_counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        if ($lcText) { Write-Host ("  by-layer  : {0}" -f $lcText) }
        if ($r.page_mm.Count -eq 2) {
            Write-Host ("  page      : {0} {1}  {2}x{3}mm  dpi {4}" -f $Page, $Orientation, $r.page_mm[0], $r.page_mm[1], $r.dpi)
        }
        foreach ($a in $r.artifacts) {
            Write-Host ("  artifact  : {0}  {1} bytes" -f $a.path, $a.bytes)
        }
        if ($r.warnings.Count -gt 0) {
            Write-Host "  warnings:" -ForegroundColor Yellow
            foreach ($w in $r.warnings) { Write-Host ("    - {0}" -f $w) -ForegroundColor Yellow }
        }
        Write-Host ("  耗时       : {0} ms" -f $r.durationMs)
        Write-Host ''
    }
    exit [int]$r.exitCode
} catch {
    if ($AsJson) {
        [pscustomobject][ordered]@{
            tool = 'Invoke-CadRenderPreview/1.0'; status = 'failed'
            dxf = $Dxf; error = $_.Exception.Message
        } | ConvertTo-Json -Depth 3
    } else {
        Write-Host "渲染预览失败: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
