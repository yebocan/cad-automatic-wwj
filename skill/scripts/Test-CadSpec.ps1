<#
    Test-CadSpec.ps1 — 出图前静态预检
    ────────────────────────────────────────────────────────────────
    只读 spec，不启动 AutoCAD、不产生任何文件。毫秒级返回。

    为什么值得单独做成一个入口：
      Invoke-CadDraw.ps1 内部也会调同一套检查（默认 -SkipPrecheck 关掉才跳过），
      但那要等 accoreconsole 冷启动。改 spec 的过程中反复试错，更需要一个
      「改一行、判一次」的快回路 —— 尤其是 AI 在生成 spec 的时候，
      它应该先自查一遍再交出去，而不是画完 20 秒再发现半径写成了 -20。

    查什么（详见 references/spec.md）：
      · 结构   type 是否合法、必需字段是否齐全、别名是否写规范
      · 数值   半径 > 0、坐标不溢出 ±1e7、矩形不退化
      · 一致性 图层/块是否重复声明、实体引用的图层是否声明过、id 是否重复
      · 几何   线段零长、样条点不足、完全重叠的重复实体
      · 约束   spec.constraints 里的 expectedUnits / requiredLayers /
               maxWidth / maxHeight / minGap / requireClosed / maxEntities

    用法：
      .\Test-CadSpec.ps1 -SpecFile part.json
      .\Test-CadSpec.ps1 -SpecFile part.json -AsJson
      .\Test-CadSpec.ps1 -SpecJson '{"entities":[{"type":"circle","c":[0,0],"r":10}]}'

    退出码：0 = 通过（可能有 warning）；4 = 有阻断性错误；1 = 读不到 spec
#>

[CmdletBinding()]
param(
    [string]$SpecFile,
    [string]$SpecJson,
    [switch]$AsJson,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCompiler.ps1')
. (Join-Path $scriptDir 'CadSpecCheck.ps1')

$result = [ordered]@{
    status  = 'unknown'
    source  = $null
    ok      = $false
    errors  = @()
    warnings= @()
    evidence= @()
    stats   = $null
    durationMs = $null
}
$started = Get-Date

try {
    if (-not $SpecFile -and -not $SpecJson) {
        throw '必须提供 -SpecFile 或 -SpecJson 之一。'
    }

    $raw = if ($SpecFile) {
        if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) {
            throw "spec 文件不存在: $SpecFile"
        }
        $result.source = (Resolve-Path -LiteralPath $SpecFile).Path
        [IO.File]::ReadAllText($result.source, [Text.Encoding]::UTF8)
    } else {
        $result.source = '<inline>'
        $SpecJson
    }

    try {
        $spec = $raw | ConvertFrom-Json
    } catch {
        throw "spec 不是合法的 JSON：$($_.Exception.Message)"
    }

    $check = Test-CadSpecStrict -Spec $spec
    $result.ok       = [bool]$check.ok
    $result.errors   = @($check.errors)
    $result.warnings = @($check.warnings)
    $result.evidence = @($check.evidence)
    $result.stats    = $check.stats
    $result.status   = if ($check.ok) { 'ok' } else { 'blocked' }
} catch {
    $result.status = 'failed'
    $result.errors = @($_.Exception.Message)
} finally {
    $result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
} elseif (-not $Quiet) {
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  spec 预检  ·  {0}" -f $result.status)
    Write-Host ('═' * 62)
    Write-Host ("  来源    : {0}" -f $result.source)
    if ($result.stats) {
        Write-Host ("  规模    : {0} 实体 / {1} 图层 / {2} 块" -f `
            $result.stats.entityCount, $result.stats.layerCount, $result.stats.blockCount)
    }
    if ($result.errors.Count -gt 0) {
        Write-Host ("  错误    : {0} 条（会阻断出图）" -f $result.errors.Count)
        foreach ($e in $result.errors) { Write-Host ("            ✗ {0}" -f $e) }
    }
    if ($result.warnings.Count -gt 0) {
        Write-Host ("  警告    : {0} 条（不阻断）" -f $result.warnings.Count)
        foreach ($w in $result.warnings) { Write-Host ("            ! {0}" -f $w) }
    }
    if ($result.errors.Count -eq 0 -and $result.warnings.Count -eq 0) {
        Write-Host '  结果    : 没有发现问题，可以直接出图。'
    }
    Write-Host ('═' * 62)
}

if ($result.status -eq 'ok') { exit 0 }
elseif ($result.status -eq 'blocked') { exit 4 }
else { exit 1 }
