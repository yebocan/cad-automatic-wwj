<#
    Set-CadPath.ps1 — 配置 accoreconsole / acad.exe / COM ProgID 路径
    ────────────────────────────────────────────────────────────────
    写一次，以后所有脚本都不用再传 -AccoreConsole。

    用法：
      & ".\Set-CadPath.ps1" -Auto                 # 自动探测并写入（默认行为）
      & ".\Set-CadPath.ps1" -Show                 # 看当前配置 + 实时探测
      & ".\Set-CadPath.ps1" -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe"
      & ".\Set-CadPath.ps1" -Clear                # 清空配置
#>

[CmdletBinding()]
param(
    [string]$AccoreConsole,
    [string]$AcadExe,
    [string]$ComProgId,
    [switch]$Auto,
    [switch]$Show,
    [switch]$Clear,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CadCommon.ps1')

function Show-Pair($label, $value) {
    Write-Host ("  {0,-16} {1}" -f $label, $value)
}

function Format-Opt($v, $fallback) {
    if ($v) { return $v }
    return $fallback
}

if ($Clear) {
    if (Test-Path -LiteralPath $script:CadConfigFile) {
        Remove-Item -LiteralPath $script:CadConfigFile -Force
        Write-Host '配置已清空。' -ForegroundColor Green
    } else {
        Write-Host '本来就没有配置。'
    }
    return
}

$didWrite = $false

if (-not $Show -and ($Auto -or $AccoreConsole -or $AcadExe -or $ComProgId)) {
    if ($AccoreConsole -or $AcadExe -or $ComProgId) {
        # 手动指定
        Set-CadConfig -AccoreConsole $AccoreConsole -AcadExe $AcadExe -ComProgId $ComProgId | Out-Null
        Write-Host ''
        Write-Host ("配置已写入: " + $script:CadConfigFile) -ForegroundColor Green
        $didWrite = $true
    } else {
        # 自动探测
        Write-Host ''
        Write-Host '正在自动探测…' -ForegroundColor Cyan

        $acc  = Find-CadExecutable -ExeName 'accoreconsole.exe'
        $acad = Find-CadExecutable -ExeName 'acad.exe'
        $com  = Resolve-CadComProgId

        if ($acc)  { Write-Host ("  [找到] accoreconsole  " + $acc.path + "   (" + $acc.source + ")") -ForegroundColor Green }
        else       { Write-Host '  [未找到] accoreconsole.exe' -ForegroundColor Yellow }

        if ($acad) { Write-Host ("  [找到] acad.exe       " + $acad.path + "   (" + $acad.source + ")") -ForegroundColor Green }
        else       { Write-Host '  [未找到] acad.exe' -ForegroundColor Yellow }

        if ($com)  { Write-Host ("  [找到] COM ProgID     " + $com.progId + "   (" + $com.source + ")") -ForegroundColor Green }
        else       { Write-Host '  [未找到] AutoCAD.Application.* 注册项' -ForegroundColor Yellow }

        if ($acc -or $acad -or $com) {
            $a1 = $null; $a2 = $null; $a3 = $null
            if ($acc)  { $a1 = $acc.path }
            if ($acad) { $a2 = $acad.path }
            if ($com)  { $a3 = $com.progId }
            Set-CadConfig -AccoreConsole $a1 -AcadExe $a2 -ComProgId $a3 | Out-Null
            Write-Host ''
            Write-Host ("配置已写入: " + $script:CadConfigFile) -ForegroundColor Green
            $didWrite = $true
        } else {
            Write-Host ''
            Write-Host '什么都没找到。请手动指定：' -ForegroundColor Yellow
            Write-Host '  & ".\Set-CadPath.ps1" -AccoreConsole "D:\...\accoreconsole.exe"' -ForegroundColor Gray
            exit 1
        }
    }
}

if ($AsJson) {
    Get-CadConfig | ConvertTo-Json -Depth 4
    return
}

if ($Show -or -not $didWrite) {
    $cfg = Get-CadConfig
    Write-Host ''
    Write-Host '当前配置：' -ForegroundColor Cyan
    Show-Pair 'accoreconsole' (Format-Opt $cfg.accoreconsole '(未设置)')
    Show-Pair 'acad.exe'      (Format-Opt $cfg.acadExe       '(未设置)')
    Show-Pair 'COM ProgID'    (Format-Opt $cfg.comProgId     '(未设置)')
    Show-Pair '写入时间'       (Format-Opt $cfg.configuredAt  '(从未)')

    Write-Host ''
    Write-Host '实时探测（不依赖配置）：' -ForegroundColor Cyan
    $acc = Find-CadExecutable -ExeName 'accoreconsole.exe'
    if ($acc) { Show-Pair 'accoreconsole' ("$($acc.path)  [$($acc.source)]") }
    else      { Show-Pair 'accoreconsole' '未找到' }
    $com = Resolve-CadComProgId
    if ($com) { Show-Pair 'COM ProgID'    ("$($com.progId)  [$($com.source)]") }
    else      { Show-Pair 'COM ProgID'    '未找到' }
}
