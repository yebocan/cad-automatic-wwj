[CmdletBinding()]
param(
    [ValidateSet('install', 'update', 'uninstall', 'status')]
    [string]$Action = 'install',

    # 目标平台。默认只装 DSH（本项目的主要使用场景）；
    # 要装到别的客户端必须显式点名，例如 -Target dsh,doubao。
    [ValidateSet('dsh', 'codex', 'doubao', 'doubao-user', 'workbuddy', 'all')]
    [string[]]$Target = @('dsh'),

    # 技能源目录；默认取本脚本同级目录下的 skill\。
    [string]$Source,

    # 只显示会做什么，不实际改动磁盘。
    [switch]$DryRun,

    # 覆盖前把旧版本备份到这个目录（默认 %TEMP%\cad-automatic-wwj-backup\<时间戳>）。
    [string]$BackupDirectory,

    # 卸载/覆盖时不做任何确认（供脚本调用）。
    [switch]$Force
)

# cad-automatic-wwj 安装 / 更新 / 卸载脚本。
#
# 设计约束（按重要性）：
#   1. 默认只装 DSH —— 不默认铺到所有 AI 客户端。要装别的必须显式 -Target。
#   2. 覆盖前先备份 —— 已存在的同名技能会先整目录复制到备份目录，再替换。
#   3. 只动本技能自己的目录 —— 目标目录下的其他技能、用户配置一律不碰。
#   4. 每个目标路径都在本机核实过，不靠猜。
#   5. 装完必须自检 —— 「技能出现在列表里」不等于装好了，
#      要跑 run-test.ps1 看到真实的 accoreconsole 出图才算。
#
# 各平台技能目录（本机实测确认）：
#   dsh         %USERPROFILE%\.dsh\skills                                    DSH 原生技能目录（优先级最高）
#   codex       %USERPROFILE%\.codex\skills                                  Codex；DSH 也会扫描
#   doubao      %USERPROFILE%\Doubao\skills                                  豆包工作电脑版（客户端登记的 local_skill_paths）
#   doubao-user ...\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills
#                                                                           豆包官方用户技能目录
#   workbuddy   %USERPROFILE%\.workbuddy\skills                              WorkBuddy
#
# 用法：
#   .\Install-Skill.ps1 -Action status                 看当前装了哪些平台
#   .\Install-Skill.ps1 -DryRun                        预览 DSH 安装
#   .\Install-Skill.ps1                                装到 DSH
#   .\Install-Skill.ps1 -Target dsh,doubao,workbuddy   装到多个平台
#   .\Install-Skill.ps1 -Action update                 更新（自动备份旧版本）
#   .\Install-Skill.ps1 -Action uninstall              只从 DSH 卸载
#   .\Install-Skill.ps1 -Action uninstall -Target all  从所有平台卸载

$ErrorActionPreference = 'Stop'

$skillName = 'cad-automatic-wwj'

if (-not $Source) {
    $Source = Join-Path $PSScriptRoot 'skill'
}
$Source = [IO.Path]::GetFullPath($Source)

if ($Action -in @('install', 'update')) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "找不到技能源目录: $Source"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md'))) {
        throw "技能源目录里没有 SKILL.md，可能不是技能目录: $Source"
    }
    # 脚本本体缺失时，装进去是个「只会说话不会干活」的空壳技能，必须提前拦住。
    $mustHave = @(
        'scripts\CadCommon.ps1',
        'scripts\CadCompiler.ps1',
        'scripts\cadcore.lsp',
        'scripts\Invoke-CadDraw.ps1',
        'scripts\CadEvidence.ps1',
        'scripts\CadSpecCheck.ps1',
        'scripts\CadPdf.ps1',
        'scripts\CadImage.ps1',
        'scripts\CadVectorize.ps1',
        'scripts\Test-CadSpec.ps1',
        'scripts\Convert-CadPdfToDxf.ps1'
    )
    $missing = @()
    foreach ($rel in $mustHave) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $rel))) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
        throw ("技能源目录缺少关键文件，装上去也用不了：" + ($missing -join ', '))
    }
}

function Get-TargetMap {
    $home_ = $env:USERPROFILE
    $doubaoUserSkills = Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills'

    return [ordered]@{
        'dsh'         = @{ Path = (Join-Path $home_ '.dsh\skills');          Label = 'DSH（原生技能目录）';   Confirmed = $true }
        'codex'       = @{ Path = (Join-Path $home_ '.codex\skills');        Label = 'Codex（DSH 也会扫描）'; Confirmed = $true }
        'doubao'      = @{ Path = (Join-Path $home_ 'Doubao\skills');        Label = '豆包（客户端登记路径）'; Confirmed = $true }
        'doubao-user' = @{ Path = $doubaoUserSkills;                         Label = '豆包（官方用户技能目录）'; Confirmed = $true }
        'workbuddy'   = @{ Path = (Join-Path $home_ '.workbuddy\skills');    Label = 'WorkBuddy';             Confirmed = $true }
    }
}

# 判断目标目录里已有的同名技能是否真的属于本项目 —— 只认 SKILL.md 的 name 字段。
function Test-IsOurSkill {
    param([string]$Dir)
    $skillMd = Join-Path $Dir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) { return $false }
    try {
        $head = Get-Content -LiteralPath $skillMd -TotalCount 12 -Encoding UTF8
        foreach ($line in $head) {
            if ($line -match "^\s*name:\s*['""]?([A-Za-z0-9._-]+)") {
                return ($Matches[1] -eq $skillName)
            }
        }
    }
    catch { }
    return $false
}

# 从 SKILL.md 里读 description 的第一句，用来在覆盖前提示「旧版本是什么」。
function Get-SkillDescription {
    param([string]$Dir)
    $skillMd = Join-Path $Dir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) { return $null }
    try {
        $txt = Get-Content -LiteralPath $skillMd -Raw -Encoding UTF8
        if ($txt -match '(?m)^\s*description:\s*(.+)$') { return $Matches[1].Trim().Trim('"', "'") }
    }
    catch { }
    return $null
}

function Get-DirStamp {
    param([string]$Dir)
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue)
    $total = 0
    foreach ($f in $files) { $total += $f.Length }
    return [pscustomobject]@{ files = $files.Count; bytes = $total }
}

$map = Get-TargetMap

# 展开 all
$keys = @()
foreach ($t in $Target) {
    if ($t -eq 'all') { $keys += $map.Keys } else { $keys += $t }
}
$keys = @($keys | Select-Object -Unique)

if (-not $BackupDirectory) {
    $BackupDirectory = Join-Path ([IO.Path]::GetTempPath()) ("cad-automatic-wwj-backup\" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

Write-Host ''
Write-Host "技能:     $skillName"
Write-Host "动作:     $Action"
if ($Action -in @('install', 'update')) { Write-Host "源目录:   $Source" }
Write-Host "目标平台: $($keys -join ', ')"
if ($Action -in @('install', 'update')) { Write-Host "备份目录: $BackupDirectory" }
Write-Host ''

$results = @()

foreach ($k in $keys) {
    $parentDir = $map[$k].Path
    $dest = Join-Path $parentDir $skillName
    $parentExists = Test-Path -LiteralPath $parentDir
    $exists = Test-Path -LiteralPath $dest
    $isOurs = if ($exists) { Test-IsOurSkill -Dir $dest } else { $false }

    # ---------------- status：只看不写 ----------------
    if ($Action -eq 'status') {
        $state = 'not-installed'
        $files = 0
        if ($exists) {
            if ($isOurs) { $state = 'installed' } else { $state = 'occupied-by-other' }
            $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count
        }
        Write-Host ("  [{0,-16}] {1,-12} {2}" -f $state, $k, $dest)
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            state = $state; files = $files; isOurSkill = $isOurs
        }
        continue
    }

    # ---------------- uninstall ----------------
    if ($Action -eq 'uninstall') {
        if (-not $exists) {
            Write-Host ("  [跳过] {0,-12} 未安装: {1}" -f $k, $dest)
            $results += [pscustomobject]@{ target = $k; destination = $dest; action = 'uninstall'; skipped = $true; removed = $false }
            continue
        }
        if (-not $isOurs) {
            Write-Host ("  [拒绝] {0,-12} {1} 里的 SKILL.md 不是 {2}，不删除。" -f $k, $dest, $skillName)
            $results += [pscustomobject]@{ target = $k; destination = $dest; action = 'uninstall'; refused = $true; removed = $false; reason = 'not our skill' }
            continue
        }
        if ($DryRun) {
            Write-Host ("  [试运行] 将删除 {0}" -f $dest)
            $results += [pscustomobject]@{ target = $k; destination = $dest; action = 'uninstall'; removed = $false; dryRun = $true }
            continue
        }
        # 卸载只删技能目录本身，绝不动父目录里的其他技能。
        Remove-Item -LiteralPath $dest -Recurse -Force
        $stillThere = Test-Path -LiteralPath $dest
        Write-Host ("  [完成] {0,-12} 已删除 {1}" -f $k, $dest)
        $results += [pscustomobject]@{ target = $k; destination = $dest; action = 'uninstall'; removed = (-not $stillThere) }
        continue
    }

    # ---------------- install / update ----------------
    if ($exists -and -not $isOurs) {
        Write-Host ("  [拒绝] {0,-12} {1} 已存在，但 SKILL.md 里的 name 不是 {2}。" -f $k, $dest, $skillName)
        Write-Host ("         为免覆盖别人的技能，本脚本不动它。请先自行确认或删除该目录。")
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            installed = $false; refused = $true; reason = 'occupied by a different skill'
        }
        continue
    }

    if ($Action -eq 'update' -and -not $exists) {
        Write-Host ("  [提示] {0,-12} 未安装过，本次按首次安装处理。" -f $k)
    }

    if ($DryRun) {
        $verb = if ($exists) { '覆盖（会先备份）' } else { '首次安装' }
        Write-Host ("  [试运行] {0,-12} {1} -> {2}" -f $k, $verb, $dest)
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $exists; installed = $false; dryRun = $true
        }
        continue
    }

    $backupPath = $null
    try {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null

        if ($exists) {
            # 覆盖前先整目录备份 —— 这是旧版本缺的关键一步。
            $old = Get-DirStamp -Dir $dest
            $oldDesc = Get-SkillDescription -Dir $dest
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupPath = Join-Path $BackupDirectory ($k + '_' + $stamp)
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            Copy-Item -LiteralPath $dest -Destination $backupPath -Recurse -Force
            Write-Host ("  [备份] {0,-12} 旧版本 {1} 个文件 -> {2}" -f $k, $old.files, $backupPath)
            if ($oldDesc) { Write-Host ("         旧版本描述: " + $oldDesc) }
            Remove-Item -LiteralPath $dest -Recurse -Force
        }

        Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force

        # 注意：不要写成 @(Get-ChildItem ... | Measure-Object).Count
        # —— Measure-Object 返回的是「一个统计对象」，包进 @() 后 Count 恒为 1，
        #    会误报「更新 1 个文件」。用 .Count 直接数数组。
        $fileCount = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
        $ok = Test-IsOurSkill -Dir $dest

        $verb = if ($exists) { '更新' } else { '安装' }
        Write-Host ("  [完成] {0,-12} {1} {2} 个文件 -> {3}" -f $k, $verb, $fileCount, $dest)
        if (-not $ok) { Write-Host ("  [警告] 安装后 SKILL.md 校验未通过，请检查源目录。") }

        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $exists; installed = $ok
            files = $fileCount; backupPath = $backupPath; verified = $ok
        }
    }
    catch {
        Write-Host ("  [失败] {0,-12} {1}" -f $k, $_.Exception.Message)
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $exists
            installed = $false; backupPath = $backupPath; error = $_.Exception.Message
        }
    }
}

# ---------------- 汇总 ----------------
Write-Host ''
Write-Host '汇总：'
foreach ($r in $results) {
    if ($Action -eq 'status') {
        $mark = switch ($r.state) { 'installed' { '✓' } 'occupied-by-other' { '!' } default { '·' } }
        Write-Host ("  {0} {1,-12} {2}" -f $mark, $r.target, $r.destination)
    }
    elseif ($Action -eq 'uninstall') {
        $mark = if ($r.removed) { '✓' } elseif ($r.refused) { '!' } else { '·' }
        Write-Host ("  {0} {1,-12} {2}" -f $mark, $r.target, $r.destination)
    }
    else {
        $mark = if ($DryRun) { '·' } elseif ($r.installed) { '✓' } else { '✗' }
        Write-Host ("  {0} {1,-12} {2}" -f $mark, $r.target, $r.destination)
        if ($r.backupPath) { Write-Host ("      备份: " + $r.backupPath) }
    }
}

$failed = @($results | Where-Object { $_.PSObject.Properties['installed'] -and $_.installed -eq $false -and -not $_.dryRun })
$refused = @($results | Where-Object { $_.PSObject.Properties['refused'] -and $_.refused })

if ($Action -eq 'status') {
    $installed = @($results | Where-Object { $_.state -eq 'installed' })
    Write-Host ''
    Write-Host ("已安装 {0} / {1} 个平台。" -f $installed.Count, $results.Count)
}
elseif ($Action -eq 'uninstall') {
    $removed = @($results | Where-Object { $_.removed })
    Write-Host ''
    Write-Host ("已卸载 {0} / {1} 个平台。" -f $removed.Count, $results.Count)
}
elseif (-not $DryRun) {
    $okCount = @($results | Where-Object { $_.installed }).Count
    Write-Host ''
    Write-Host ("成功 {0} / {1} 个平台。" -f $okCount, $results.Count)
    if ($okCount -gt 0) {
        $installedDir = Join-Path $map['dsh'].Path $skillName
        Write-Host ''
        Write-Host '下一步（必须做，否则不算装好）：'
        Write-Host '  1) 先确认能定位 accoreconsole：'
        Write-Host ("     & ""{0}\scripts\Set-CadPath.ps1"" -Auto -Show" -f $installedDir)
        Write-Host '  2) 再跑集成自检，看真实出图：'
        Write-Host ("     & ""{0}\scripts\run-test.ps1"" -Test all" -f $installedDir)
        Write-Host '  看到 "集成自检  ·  N / N 通过，0 失败" 才算装好。'
        Write-Host '  技能出现在列表里、AutoCAD 窗口弹出来了，都不算装好。'
    }
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host '有平台安装失败，见上面的错误信息。'
        $results | ConvertTo-Json -Depth 4 -Compress | Write-Output
        exit 1
    }
}

# 机器可读结果，方便脚本调用方解析。
$results | ConvertTo-Json -Depth 4 -Compress | Write-Output
