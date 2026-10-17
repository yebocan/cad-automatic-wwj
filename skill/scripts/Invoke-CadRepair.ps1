<#
    Invoke-CadRepair.ps1 — 出图失败后自动诊断并修复
    ────────────────────────────────────────────────────────────────
    设计原则：不猜。每一条修复规则都必须有可观测的证据支持，
    修完必须重新验证，验证不过就如实报告「修不了」并给出下一步。

    内置规则（按顺序跑，命中即修，修完继续跑下一条）：

      环境类
      R01  accoreconsole 定位不到         → 扫盘重新定位，写回配置
      R02  SECURELOAD 未关导致 LISP 拒载 → 在 scr 里补 (setvar "SECURELOAD" 0)
      R03  环境变量 CAD_ACCORECONSOLE 指向失效路径 → 报告并建议 Set-CadPath

      编码类（本 skill 最常见的坑）
      R04  cadcore.lsp 是 UTF-8 而非 GBK  → 重新以 GBK 落盘
      R05  scr 是 UTF-8 而非 GBK          → 重新以 GBK 落盘
      R06  lsp 里含 BOM                   → 剥掉 BOM 重写

      图纸类
      R07  SAVEAS 目标已存在导致卡死      → 删目标文件
      R08  目标目录不存在                 → 建目录
      R09  DWG 产物为 0 字节或 <2KB       → 判定为写入失败，重跑一次
      R10  DXF 结构不完整（缺 ENTITIES）  → 判定为导出失败，重导

      进程类
      R11  上次遗留的 acad/accoreconsole  → 按登记表清理
      R12  超时未退出                     → 强杀并报告

      脚本类
      R13  cadcore.lsp 括号不平衡         → 报告具体行号，不自动改（改错更危险）
      R14  JSON 里引用了未声明图层        → 自动补建（编译器已做，这里只报告）

    用法：
      .\Invoke-CadRepair.ps1 -SpecFile drawing.json
      .\Invoke-CadRepair.ps1 -SpecFile drawing.json -DryRun     # 只诊断不修
      .\Invoke-CadRepair.ps1 -Path drawing.dwg                  # 修已有产物
      .\Invoke-CadRepair.ps1 -SpecFile drawing.json -AsJson
#>

[CmdletBinding()]
param(
    [string]$SpecFile,
    [string]$Path,
    [switch]$DryRun,
    [switch]$AsJson,
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'CadCommon.ps1')
. (Join-Path $scriptDir 'CadCompiler.ps1')

$findings = New-Object System.Collections.Generic.List[object]
$report = [ordered]@{
    status     = 'unknown'
    # mode 与开关同名（-DryRun → 'dry-run'），便于调用方用同一个词判断，不用记别名
    mode       = $(if ($DryRun) { 'dry-run' } else { 'repair' })
    target     = $null
    findings   = @()
    fixed      = 0
    remaining  = 0
    error      = $null
    durationMs = $null
}
$started = Get-Date

function Add-Finding {
    param(
        [string]$Id, [string]$Severity, [string]$Title,
        [string]$Detail, [string]$Fix, [bool]$Repairable = $false
    )
    $findings.Add([pscustomobject]@{
            id         = $Id
            severity   = $Severity
            title      = $Title
            detail     = $Detail
            fix        = $Fix
            repairable = $Repairable
            repaired   = $false
            note       = $null
        })
}

function Test-GbkFile {
    <#
      判断文件是否真的是 GBK。
      思路：按 GBK 解码再按 GBK 编回，字节完全一致 → 是 GBK。
      这是必要条件不是充分条件，但配合下面的 BOM / UTF-8 检测足够用。
    #>
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -eq 0) { return $null }

    # BOM 检测
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # 严格 UTF-8 检测：能按 UTF-8 解码且含多字节序列 → 很可能是 UTF-8
    $isUtf8 = $false
    try {
        $strict = New-Object Text.UTF8Encoding($false, $true)
        $null = $strict.GetString($bytes)
        # 能严格解码；再看是否有 >127 的字节（纯 ASCII 两者都成立）
        $isUtf8 = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    } catch {
        $isUtf8 = $false
    }

    $gbk = [Text.Encoding]::GetEncoding(936)
    $gbkRoundTrip = $false
    try {
        $txt = $gbk.GetString($bytes)
        $back = $gbk.GetBytes($txt)
        $gbkRoundTrip = ($back.Length -eq $bytes.Length)
    } catch { }

    return [pscustomobject]@{
        hasBom       = $hasBom
        looksUtf8    = $isUtf8
        gbkRoundTrip = $gbkRoundTrip
        length       = $bytes.Length
    }
}

try {
    Initialize-CadState | Out-Null

    # ── 确定修复目标 ────────────────────────────────────────────
    $specObj = $null
    if ($SpecFile) {
        if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { throw "规格文件不存在: $SpecFile" }
        $specObj = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SpecFile).Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $report.target = "spec: $SpecFile"
    } elseif ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件不存在: $Path" }
        $report.target = "file: $Path"
    } else {
        throw '需要 -SpecFile（修出图流程）或 -Path（修已有产物）'
    }

    # ══════════════════════════════════════════════════════════════
    #  R01 / R03  环境：accoreconsole 定位
    # ══════════════════════════════════════════════════════════════
    $accoreInfo = $null
    try { $accoreInfo = Resolve-CadAccoreConsole } catch { }
    if (-not $accoreInfo -or -not $accoreInfo.path) {
        Add-Finding -Id 'R01' -Severity 'blocker' `
            -Title 'accoreconsole.exe 定位不到' `
            -Detail '配置、环境变量 CAD_ACCORECONSOLE、PATH、常见安装路径扫描全部失败。' `
            -Fix '运行 Set-CadPath -Auto 重新自动定位，或用 -AccoreConsole 显式指定路径' -Repairable $false
    } elseif (-not (Test-Path -LiteralPath $accoreInfo.path -PathType Leaf)) {
        Add-Finding -Id 'R01' -Severity 'blocker' `
            -Title 'accoreconsole.exe 路径失效' `
            -Detail "配置里记录的是 '$($accoreInfo.path)'，但文件已不存在（来源: $($accoreInfo.source)）。" `
            -Fix '运行 Set-CadPath -Auto 重新定位' -Repairable $true
        if (-not $DryRun) {
            try {
                $fresh = Find-CadExecutable -ExeName 'accoreconsole.exe'
                if ($fresh -and $fresh.path -and (Test-Path -LiteralPath $fresh.path)) {
                    Set-CadConfig -AccoreConsole $fresh.path | Out-Null
                    $findings[$findings.Count - 1].repaired = $true
                    $findings[$findings.Count - 1].note = "已重新定位到 $($fresh.path)"
                }
            } catch {
                $findings[$findings.Count - 1].note = "自动重定位失败: $($_.Exception.Message)"
            }
        }
    } else {
        $envVal = $env:CAD_ACCORECONSOLE
        if ($envVal -and -not (Test-Path -LiteralPath $envVal)) {
            Add-Finding -Id 'R03' -Severity 'warning' `
                -Title '环境变量 CAD_ACCORECONSOLE 指向失效路径' `
                -Detail "`$env:CAD_ACCORECONSOLE = '$envVal'，该路径不存在。当前实际使用 '$($accoreInfo.path)'（来源 $($accoreInfo.source)）。" `
                -Fix '清除或修正该环境变量，避免其他脚本误用' -Repairable $false
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  R11  进程：遗留的 acad / accoreconsole
    # ══════════════════════════════════════════════════════════════
    $owned = @(Get-CadOwnedProcesses)
    $stale = @($owned | Where-Object { -not $_.alive })
    if ($stale.Count -gt 0 -and -not $DryRun) { Clear-StaleCadEntries | Out-Null }

    $liveOwned = @(Get-CadOwnedProcesses | Where-Object { $_.alive })
    if ($liveOwned.Count -gt 0) {
        Add-Finding -Id 'R11' -Severity 'warning' `
            -Title "有 $($liveOwned.Count) 个本 skill 启动的 CAD 进程仍在运行" `
            -Detail (($liveOwned | ForEach-Object { "PID $($_.pid) ($($_.kind)) 启动于 $($_.started)" }) -join '; ') `
            -Fix '用 Stop-OwnedCadProcess 清理，或直接 Invoke-CadRepair -Fix 自动清理' -Repairable $true
        if (-not $DryRun) {
            $killed = 0
            foreach ($p in $liveOwned) {
                try {
                    if (Stop-OwnedCadProcess -ProcessId $p.pid -Force) { $killed++ }
                } catch { }
            }
            if ($killed -gt 0) {
                $findings[$findings.Count - 1].repaired = $true
                $findings[$findings.Count - 1].note = "已清理 $killed 个进程"
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  R04 / R05 / R06  编码
    #
    #  ★ 这里有一个容易搞反的点 ★
    #    skill 目录里的 cadcore.lsp **源文件必须保持 UTF-8** ——
    #    它是给人读的、要给 git diff 看的、编辑器默认也是 UTF-8。
    #    真正要求 GBK 的是**运行时工作目录里的副本**，由 Write-CadLsp
    #    在每次执行前转码。所以这里不能把源文件改成 GBK，
    #    只检查源文件有没有 BOM（BOM 会让 Load 报错，与编码无关）。
    # ══════════════════════════════════════════════════════════════
    $corePath = Join-Path $scriptDir 'cadcore.lsp'
    if (Test-Path -LiteralPath $corePath) {
        $info = Test-GbkFile -FilePath $corePath
        if ($info -and $info.hasBom) {
            Add-Finding -Id 'R06' -Severity 'blocker' `
                -Title 'cadcore.lsp 含 UTF-8 BOM' `
                -Detail 'BOM 会被 LISP 读成三个字节，导致第一个表达式解析失败，报错位置指向文件头。源文件本身应为「UTF-8 无 BOM」。' `
                -Fix '剥掉 BOM（保持 UTF-8 无 BOM）' -Repairable $true
            if (-not $DryRun) {
                try {
                    $txt = [IO.File]::ReadAllText($corePath, [Text.Encoding]::UTF8)
                    [IO.File]::WriteAllText($corePath, $txt, (New-Object Text.UTF8Encoding $false))
                    $findings[$findings.Count - 1].repaired = $true
                    $findings[$findings.Count - 1].note = '已剥 BOM，保持 UTF-8 无 BOM'
                } catch {
                    $findings[$findings.Count - 1].note = "修复失败: $($_.Exception.Message)"
                }
            }
        }
    } else {
        Add-Finding -Id 'R00' -Severity 'blocker' `
            -Title 'cadcore.lsp 缺失' `
            -Detail "找不到 $corePath —— skill 安装不完整。" `
            -Fix '重新安装 skill（运行 Install-Skill.ps1）' -Repairable $false
    }

    # R05：检查遗留的临时工作目录里的 GBK 副本。
    # 每次 Invoke-CadDraw 都在 CadStateDir 下建 draw-xxxx 临时目录，
    # 正常结束时会被删掉；残留说明上次异常中断，里面的副本可能过期。
    if ($script:CadStateDir -and (Test-Path -LiteralPath $script:CadStateDir)) {
        $staleDirs = @(Get-ChildItem -LiteralPath $script:CadStateDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(draw|plot|inspect|export|repair)-' })
        if ($staleDirs.Count -gt 0) {
            Add-Finding -Id 'R05' -Severity 'info' `
                -Title "有 $($staleDirs.Count) 个遗留的临时工作目录" `
                -Detail (($staleDirs | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ') `
                -Fix '上次运行异常中断留下的，可安全删除' -Repairable $true
            if (-not $DryRun) {
                $n = 0
                foreach ($d in $staleDirs) {
                    try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; $n++ } catch { }
                }
                if ($n -gt 0) {
                    $findings[$findings.Count - 1].repaired = $true
                    $findings[$findings.Count - 1].note = "已清理 $n 个"
                }
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  R13  cadcore.lsp 括号平衡
    # ══════════════════════════════════════════════════════════════
    if (Test-Path -LiteralPath $corePath) {
        $txt = [IO.File]::ReadAllText($corePath, [Text.Encoding]::GetEncoding(936))
        $depth = 0
        $inStr = $false
        $lineNo = 1
        $firstUnbalanced = $null
        for ($i = 0; $i -lt $txt.Length; $i++) {
            $ch = $txt[$i]
            if ($ch -eq "`n") { $lineNo++; continue }
            if ($inStr) {
                if ($ch -eq '\') { $i++; continue }
                if ($ch -eq '"') { $inStr = $false }
                continue
            }
            if ($ch -eq ';') {
                while ($i -lt $txt.Length -and $txt[$i] -ne "`n") { $i++ }
                $lineNo++
                continue
            }
            if ($ch -eq '"') { $inStr = $true; continue }
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') {
                $depth--
                if ($depth -lt 0 -and $null -eq $firstUnbalanced) { $firstUnbalanced = $lineNo }
            }
        }
        if ($depth -ne 0 -or $null -ne $firstUnbalanced) {
            $extra = ''
            if ($null -ne $firstUnbalanced) { $extra = "，第 $firstUnbalanced 行出现多余的右括号" }
            Add-Finding -Id 'R13' -Severity 'blocker' `
                -Title 'cadcore.lsp 括号不平衡' `
                -Detail "扫描结束深度 = $depth（应为 0）$extra。LISP 会报「多余的右括号」或「输入中含有多余的右括号」，且报错位置常指向文件头。" `
                -Fix '人工检查对应行。自动改括号风险太高，本脚本只定位不修改。' -Repairable $false
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  R14  JSON 图层声明（编译器已自动补建，这里只报告）
    # ══════════════════════════════════════════════════════════════
    if ($specObj) {
        $declared = @{}
        foreach ($l in @(Get-CadField $specObj 'layers' @())) {
            $n = [string](Get-CadField $l 'name' '')
            if ($n) { $declared[$n.ToUpperInvariant()] = $true }
        }
        $used = @{}
        foreach ($e in @(Get-CadField $specObj 'entities' @())) {
            $n = [string](Get-CadField $e 'layer' '')
            if ($n -and $n -ne '0') { $used[$n.ToUpperInvariant()] = $n }
        }
        $missing = @($used.Keys | Where-Object { -not $declared.ContainsKey($_) } | ForEach-Object { $used[$_] })
        if ($missing.Count -gt 0) {
            Add-Finding -Id 'R14' -Severity 'info' `
                -Title "JSON 里 $($missing.Count) 个图层被实体引用但未在 layers[] 声明" `
                -Detail ("图层: " + ($missing -join ', ') + '。编译器会自动补建（颜色 7），不会导致出图失败，但图层颜色可能不是你要的。') `
                -Fix '在 layers[] 里显式声明这些图层并指定 color' -Repairable $false
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  R07 / R08 / R09 / R10  产物
    # ══════════════════════════════════════════════════════════════
    $probeDwg = $null
    if ($Path) {
        $probeDwg = (Resolve-Path -LiteralPath $Path).Path
    } elseif ($specObj) {
        $save = Get-CadField $specObj 'save' $null
        if ($save) {
            $d = [string](Get-CadField $save 'dwg' '')
            if ($d) {
                if (-not [IO.Path]::IsPathRooted($d)) { $d = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $SpecFile).Path) $d }
                $probeDwg = [IO.Path]::GetFullPath($d)
            }
        }
    }

    if ($probeDwg) {
        $parent = Split-Path -Parent $probeDwg
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            Add-Finding -Id 'R08' -Severity 'warning' `
                -Title '目标目录不存在' `
                -Detail "输出目录 '$parent' 不存在，SAVEAS 会报无效文件名。" `
                -Fix '创建目录' -Repairable $true
            if (-not $DryRun) {
                try {
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                    $findings[$findings.Count - 1].repaired = $true
                    $findings[$findings.Count - 1].note = '目录已创建'
                } catch {
                    $findings[$findings.Count - 1].note = "创建失败: $($_.Exception.Message)"
                }
            }
        }

        if (Test-Path -LiteralPath $probeDwg) {
            $sz = (Get-Item -LiteralPath $probeDwg).Length
            if ($sz -eq 0 -or $sz -lt 2048) {
                Add-Finding -Id 'R09' -Severity 'blocker' `
                    -Title "DWG 产物异常（$sz 字节）" `
                    -Detail '正常 DWG 至少几十 KB。这个大小说明 SAVEAS 只创建了空壳就中断了。' `
                    -Fix '删除后重跑出图' -Repairable $true
                if (-not $DryRun) {
                    try {
                        Remove-Item -LiteralPath $probeDwg -Force
                        $findings[$findings.Count - 1].repaired = $true
                        $findings[$findings.Count - 1].note = '已删除空壳，请重跑 Invoke-CadDraw'
                    } catch {
                        $findings[$findings.Count - 1].note = "删除失败: $($_.Exception.Message)"
                    }
                }
            }

            # DXF 校验
            $dxf = [IO.Path]::ChangeExtension($probeDwg, '.dxf')
            if (Test-Path -LiteralPath $dxf) {
                $check = Test-CadDxfFile -Path $dxf
                if (-not $check.valid) {
                    Add-Finding -Id 'R10' -Severity 'blocker' `
                        -Title 'DXF 结构不完整' `
                        -Detail "缺少段: $($check.missing -join ', ')。原因通常是 SAVEDXF 的版本号写错，或 LISP 在导出前就被取消了。" `
                        -Fix '用 Export-CadToDxf 重新导出' -Repairable $false
                }
            }
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  汇总
    # ══════════════════════════════════════════════════════════════
    $report.findings = $findings.ToArray()
    $report.fixed = @($findings | Where-Object { $_.repaired }).Count
    $report.remaining = @($findings | Where-Object { -not $_.repaired -and $_.severity -ne 'info' }).Count

    if ($findings.Count -eq 0) {
        $report.status = 'healthy'
    } elseif ($report.remaining -eq 0) {
        $report.status = 'repaired'
    } elseif (@($findings | Where-Object { $_.severity -eq 'blocker' -and -not $_.repaired }).Count -gt 0) {
        $report.status = 'blocked'
    } else {
        $report.status = 'issues'
    }
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    $report.findings = $findings.ToArray()
} finally {
    $report.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    $icon = @{
        'healthy'  = '[OK]'
        'repaired' = '[FIXED]'
        'issues'   = '[ISSUES]'
        'blocked'  = '[BLOCKED]'
        'failed'   = '[FAILED]'
    }
    Write-Host ''
    Write-Host ('═' * 62)
    Write-Host ("  出图体检与修复  ·  {0}  {1}" -f $report.status, $icon[$report.status])
    Write-Host ('═' * 62)
    Write-Host ("  目标    : {0}" -f $report.target)
    Write-Host ("  模式    : {0}" -f $report.mode)
    if ($report.findings -and @($report.findings).Count -eq 0) {
        Write-Host '  未发现问题，环境与产物都健康。'
    } else {
        Write-Host ''
        foreach ($f in $report.findings) {
            $mark = if ($f.repaired) { '✓' } elseif ($f.severity -eq 'info') { 'i' } else { '✗' }
            Write-Host ("  {0} [{1}] {2}" -f $mark, $f.id, $f.title)
            Write-Host ("      详情: {0}" -f $f.detail)
            Write-Host ("      建议: {0}" -f $f.fix)
            if ($f.note) { Write-Host ("      结果: {0}" -f $f.note) }
            Write-Host ''
        }
    }
    if ($report.error) { Write-Host ("  错误    : {0}" -f $report.error) }
    Write-Host ("  已修 {0} 项，剩余 {1} 项  ·  {2:N1} 秒" -f $report.fixed, $report.remaining, ($report.durationMs / 1000.0))
    Write-Host ('═' * 62)
}

switch ($report.status) {
    'healthy' { exit 0 }
    'repaired' { exit 0 }
    'issues' { exit 3 }
    default { exit 1 }
}
