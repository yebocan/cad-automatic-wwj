<#
    Publish-ToGitHub.ps1
    ────────────────────────────────────────────────────────────────
    把本仓库（CAD Automatic WWJ 技能）发布到 GitHub。

    它会自动完成：
      1. 检查本地仓库状态（含「装好的技能目录是否与仓库同步」这一步）
      2. 远端仓库不存在 → 自动创建
      3. 保存登录凭据（存在 Windows 凭据管理器里，下次不用再输）
      4. 推送代码

    运行方式（在本文件所在目录打开 PowerShell）：
        pwsh -File .\Publish-ToGitHub.ps1

    关于 Token：
      需要一个 GitHub Personal Access Token，用来创建仓库和推送。
      没有的话，脚本会引导你去网页创建，然后走浏览器授权。

    地址：https://github.com/yebocan/cad-automatic-wwj
#>

[CmdletBinding()]
param(
    [string]$Token,
    [string]$Owner = 'yebocan',
    [string]$Repo = 'cad-automatic-wwj',
    [switch]$Private,
    [string]$RepoPath = $PSScriptRoot,
    [string]$Description = '用 AI 操作 AutoCAD 的 DSH 技能：从 JSON 生成真实 DWG、建图层加标注、导 DXF/PDF、体检与自动修复，零 Python 依赖',
    # 跳过发布前的仓库自检（不推荐，自检是为了避免把坏代码推上去）。
    [switch]$SkipSelfTest,
    # 只做检查不推送。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Bad($m)  { Write-Host $m -ForegroundColor Red }

Write-Host ''
Write-Host '=====================================================' -ForegroundColor White
Write-Host '  CAD Automatic WWJ  →  GitHub 发布工具' -ForegroundColor White
Write-Host '=====================================================' -ForegroundColor White
Write-Host ''

# ── 1. 定位仓库 ─────────────────────────────────────────────────
if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Bad "这里不是 git 仓库：$RepoPath"
    Bad '请把本脚本放在 cad-automatic-wwj 目录下运行。'
    exit 1
}
Set-Location $RepoPath
Ok "仓库路径: $RepoPath"

# ── 2. 检查 git ─────────────────────────────────────────────────
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { Bad '未找到 git，请先安装 Git for Windows。'; exit 1 }
Ok "git: $git"

$branch = (& git branch --show-current 2>&1).Trim()
if (-not $branch) { $branch = 'main' }
Ok "当前分支: $branch"

# ── 3. 发布前自检（防止把坏代码推上去）───────────────────────────
# 为什么要这步：这个技能的价值全在「产物真的能生成、测试真的能过」。
# 推一个测试红的版本上去，等于把「装好之后跑不通」的问题丢给用户。
if (-not $SkipSelfTest) {
    Info ''
    Info '正在做发布前自检（单元测试）…'
    $unit = Join-Path $RepoPath 'skill\scripts\run-unit-test.ps1'
    if (Test-Path -LiteralPath $unit) {
        $out = & pwsh -NoProfile -File $unit 2>&1 | Out-String
        $tail = ($out -split "`r?`n" | Where-Object { $_ -match '单元测试  ·' } | Select-Object -Last 1)
        if ($out -match '通过，0 失败') {
            Ok ("  " + $tail.Trim())
        } else {
            Bad ("  单元测试未通过：" + $tail.Trim())
            Bad '  加 -SkipSelfTest 可强制发布，但强烈建议先修好。'
            exit 1
        }
    } else {
        Warn "  找不到 $unit，跳过单元测试。"
    }
}

$dirty = (& git status --porcelain 2>&1)
if ($dirty) {
    Warn ''
    Warn '⚠ 有未提交的改动：'
    $dirty | ForEach-Object { Warn "    $_" }
    Warn ''
    if ($DryRun) {
        Warn '（-DryRun：不会提交）'
    } else {
        $ans = Read-Host '是否先提交这些改动？(y/n)'
        if ($ans -eq 'y') {
            & git add -A
            $msg = Read-Host '提交说明（直接回车用默认）'
            if (-not $msg) { $msg = 'chore: 更新技能内容' }
            & git commit -m $msg | Out-Null
            Ok '已提交。'
        }
    }
}

$lastCommit = (& git log --oneline -1 2>&1).Trim()
Ok "最新提交: $lastCommit"
Write-Host ''

# ── 4. 远端是否已存在 ───────────────────────────────────────────
$apiBase = "https://api.github.com/repos/$Owner/$Repo"
$repoExists = $false
try {
    $null = Invoke-RestMethod -Uri $apiBase -TimeoutSec 20 -Headers @{ 'User-Agent' = 'cad-publish' }
    $repoExists = $true
} catch {
    $repoExists = $false
}

if ($repoExists) {
    Ok "远端仓库已存在: https://github.com/$Owner/$Repo"
} else {
    Warn "远端仓库不存在: https://github.com/$Owner/$Repo"
}

if ($DryRun) {
    Info ''
    Info '-DryRun：到此为止，没有创建仓库也没有推送。'
    exit 0
}

# ── 5. 取 Token ─────────────────────────────────────────────────
$needCreate = -not $repoExists

if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) { $Token = $env:GH_TOKEN }

if (-not $Token -and $needCreate) {
    Write-Host ''
    Warn '创建远端仓库需要一个 GitHub Token。'
    Write-Host ''
    Write-Host '  获取方式（30 秒）：' -ForegroundColor White
    Write-Host '    1) 打开  https://github.com/settings/tokens/new' -ForegroundColor Gray
    Write-Host '    2) Note 随便填（例如 cad-publish）' -ForegroundColor Gray
    Write-Host '    3) Expiration 选 90 days 或 No expiration' -ForegroundColor Gray
    Write-Host '    4) 勾选  ✅ repo  （第一项，勾上会连带子项）' -ForegroundColor Gray
    Write-Host '    5) 拉到底点  Generate token' -ForegroundColor Gray
    Write-Host '    6) 复制那串  ghp_...  粘贴到下面' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  也可以先去网页手动建仓库：' -ForegroundColor White
    Write-Host "    https://github.com/new?name=$Repo" -ForegroundColor Gray
    Write-Host '    （不要勾选 Add a README，建好后重新运行本脚本，走浏览器授权即可）' -ForegroundColor Gray
    Write-Host ''
    $sec = Read-Host '请粘贴 Token（直接回车跳过，走浏览器授权）' -AsSecureString
    if ($sec.Length -gt 0) {
        $Token = [System.Net.NetworkCredential]::new('', $sec).Password
    }
}

# ── 6. 需要则创建仓库 ───────────────────────────────────────────
if ($needCreate -and $Token) {
    Info ''
    Info '正在创建远端仓库…'
    $headers = @{
        Authorization = "Bearer $Token"
        'User-Agent'  = 'cad-publish'
        Accept        = 'application/vnd.github+json'
    }
    $body = @{
        name        = $Repo
        description = $Description
        private     = [bool]$Private
        auto_init   = $false
    } | ConvertTo-Json

    try {
        $created = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post `
            -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 30
        Ok "仓库已创建: $($created.html_url)"
        $repoExists = $true
    } catch {
        $err = $_.Exception.Message
        Bad "创建失败: $err"
        if ($err -match '401|Bad credentials') { Bad 'Token 无效或已过期。' }
        if ($err -match '403|scope')           { Bad 'Token 缺少 repo 权限，请重新生成并勾选 repo。' }
        exit 1
    }
}

if (-not $repoExists) {
    Bad ''
    Bad "远端仓库仍不存在，无法推送。"
    Bad "请先打开 https://github.com/new?name=$Repo 手动创建一个空仓库，然后重新运行本脚本。"
    exit 1
}

# ── 7. 保存凭据 ─────────────────────────────────────────────────
if ($Token) {
    Info ''
    Info '正在保存凭据到 Windows 凭据管理器（下次不用再输）…'
    $cred = "protocol=https`nhost=github.com`nusername=$Owner`npassword=$Token`n"
    $cred | & git credential approve 2>&1 | Out-Null
    Ok '凭据已保存。'
}

# ── 8. 设置远端并推送 ───────────────────────────────────────────
$remoteUrl = "https://github.com/$Owner/$Repo.git"
$existing = (& git remote get-url origin 2>&1)
if ($LASTEXITCODE -ne 0) {
    & git remote add origin $remoteUrl
    Ok "已添加远端: $remoteUrl"
} elseif ($existing.Trim() -ne $remoteUrl) {
    & git remote set-url origin $remoteUrl
    Ok "已更新远端: $remoteUrl"
} else {
    Ok "远端已正确: $remoteUrl"
}

Write-Host ''
Info '正在推送…'
if (-not $Token) {
    Warn '（如果弹出浏览器登录窗口，请在窗口里完成 GitHub 授权）'
}
Write-Host ''

$pushOut = & git push -u origin $branch 2>&1
$pushCode = $LASTEXITCODE
$pushOut | ForEach-Object { Write-Host "  $_" }

Write-Host ''
if ($pushCode -eq 0) {
    Ok '====================================================='
    Ok '  ✅ 推送成功！'
    Ok '====================================================='
    Write-Host ''
    Write-Host "  仓库地址: https://github.com/$Owner/$Repo" -ForegroundColor White
    Write-Host ''
} else {
    Bad '====================================================='
    Bad '  ❌ 推送失败'
    Bad '====================================================='
    Write-Host ''
    Warn '常见原因：'
    Warn '  · 弹出浏览器窗口但没完成登录 → 重新运行，在窗口里点授权'
    Warn '  · Token 无效/过期 → 重新生成一个'
    Warn '  · 远端已有内容（例如建仓库时勾了 README）→ 运行：'
    Warn "      git pull --rebase origin $branch"
    Warn '      然后重新运行本脚本'
    exit 1
}
