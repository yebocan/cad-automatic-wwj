<#
    CadCommon.ps1 — cad-automatic-wwj 公共库
    ────────────────────────────────────────────────────────────────
    所有脚本都 dot-source 这个文件。它只提供函数，不做任何动作。

    包含：
      · 路径解析链（accoreconsole / acad.exe / COM ProgID）
      · scr 脚本生成（GBK 编码 —— 中文路径的命门）
      · accoreconsole 执行器（超时 / 输出解码 / 结构化返回）
      · DXF 独立校验与实体读取（不依赖任何第三方库）
      · 进程登记表与三道闸清理（绝不按名字批量杀进程）
      · 图纸体检（实体统计 / 图层 / 范围）
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════
#  常量
# ══════════════════════════════════════════════════════════════════

$script:CadSkillName    = 'cad-automatic-wwj'
$script:CadStateDir     = Join-Path ([IO.Path]::GetTempPath()) 'cad-automatic-wwj'
$script:CadRegistryFile = Join-Path $script:CadStateDir 'owned-cad.json'
$script:CadConfigFile   = Join-Path $script:CadStateDir 'config.json'

# 实测：accoreconsole 的 stdout 是 UTF-16LE，scr 必须是 ANSI/GBK。
$script:CadScrEncoding  = [System.Text.Encoding]::GetEncoding(936)
$script:CadOutEncoding  = [System.Text.Encoding]::Unicode

# ★ DXF 编码与 scr 编码是两回事，别混用 ★
#   scr/lsp 必须 GBK(936)，但 DXF 从 R2007(AC1021) 起一律 UTF-8，
#   与文件头里的 $DWGCODEPAGE=ANSI_936 无关 —— 那只是 DWG 侧遗留元数据。
#   实测：all-entities.dxf 头写 ANSI_936，但 MTEXT 的「多行文字」用 UTF-8
#   解码正确、用 GBK 解码成「澶氳鏂囧瓧」。所以 DXF 读取走 UTF-8。
$script:CadDxfEncoding  = New-Object System.Text.UTF8Encoding($false)

# accoreconsole 退出码（实测 + Autodesk 文档）
$script:CadExitCodes = @{
    0   = 'success'
    1   = 'generic-failure'
    2   = 'bad-arguments'
    3   = 'drawing-not-found'
    4   = 'drawing-locked'
    5   = 'script-not-found'
    6   = 'script-failed'
    76  = 'error-status-76'
}

function Initialize-CadState {
    if (-not (Test-Path -LiteralPath $script:CadStateDir)) {
        New-Item -ItemType Directory -Path $script:CadStateDir -Force | Out-Null
    }
}

# ══════════════════════════════════════════════════════════════════
#  配置读写
# ══════════════════════════════════════════════════════════════════

function Get-CadConfig {
    Initialize-CadState
    if (Test-Path -LiteralPath $script:CadConfigFile) {
        try {
            $raw = Get-Content -LiteralPath $script:CadConfigFile -Raw -Encoding UTF8
            if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
        } catch { }
    }
    return [pscustomobject]@{
        accoreconsole = $null
        acadExe       = $null
        comProgId     = $null
        product       = $null
        configuredAt  = $null
    }
}

function Set-CadConfig {
    param(
        [string]$AccoreConsole,
        [string]$AcadExe,
        [string]$ComProgId
    )
    Initialize-CadState
    $cfg = Get-CadConfig
    if ($AccoreConsole) { $cfg.accoreconsole = $AccoreConsole }
    if ($AcadExe)       { $cfg.acadExe       = $AcadExe }
    if ($ComProgId)     { $cfg.comProgId     = $ComProgId }
    $cfg.configuredAt = (Get-Date).ToString('o')
    $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CadConfigFile -Encoding UTF8
    return $cfg
}

# ══════════════════════════════════════════════════════════════════
#  路径解析链
#  优先级：显式参数 → 环境变量 → 配置文件 → 常见安装位置 → PATH
#  不读注册表扫全盘（COM ProgID 例外，那是唯一可靠来源）。
# ══════════════════════════════════════════════════════════════════

function Get-CadCandidateRoots {
    # 常见安装根 + 本机已确认的 F:\CAD。换机器靠这个链兜底。
    return @(
        'C:\Program Files\Autodesk',
        'C:\Program Files (x86)\Autodesk',
        'D:\Program Files\Autodesk',
        'D:\Autodesk',
        'E:\Autodesk',
        'F:\Autodesk',
        'F:\CAD',
        'D:\CAD',
        'E:\CAD',
        'C:\CAD',
        'C:\Program Files\ZWSOFT',
        'C:\Program Files\Gstarsoft'
    )
}

function Find-CadExecutable {
    <#
      按 5 级优先级定位 CAD 可执行文件：
        1) 显式参数
        2) 环境变量（CAD_ACCORECONSOLE / CAD_ACAD）
        3) 配置文件
        4) 常见安装目录扫描
        5) PATH

      ★ 注意配置槽位的映射 ★
      配置里只有两个槽：accoreconsole 与 acadExe。
      早先的写法是「名字里含 accoreconsole 就用槽 A，否则用槽 B」，
      这会让随便一个不认识的名字（比如 foo.exe）也命中 acadExe，
      返回一个完全不相干的路径。现在改成显式映射：只认这两个名字，
      其它名字跳过配置与环境变量两级，直接去扫盘和 PATH。
    #>
    param(
        [Parameter(Mandatory)][string]$ExeName,
        [string]$Explicit
    )

    # 1) 显式参数
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) {
            return [pscustomobject]@{ path = (Resolve-Path -LiteralPath $Explicit).Path; source = 'explicit' }
        }
        throw "指定的 $ExeName 不存在: $Explicit"
    }

    # 显式映射：exe 名 → (环境变量名, 配置槽名)
    $leaf = [IO.Path]::GetFileName($ExeName).ToLowerInvariant()
    $envName = $null
    $cfgSlot = $null
    switch ($leaf) {
        'accoreconsole.exe' { $envName = 'CAD_ACCORECONSOLE'; $cfgSlot = 'accoreconsole' }
        'acad.exe' { $envName = 'CAD_ACAD'; $cfgSlot = 'acadExe' }
    }

    # 2) 环境变量
    if ($envName) {
        $fromEnv = [Environment]::GetEnvironmentVariable($envName)
        if ($fromEnv -and (Test-Path -LiteralPath $fromEnv -PathType Leaf)) {
            return [pscustomobject]@{ path = (Resolve-Path -LiteralPath $fromEnv).Path; source = "env:$envName" }
        }
    }

    # 3) 配置文件
    if ($cfgSlot) {
        $cfg = Get-CadConfig
        $fromCfg = $cfg.$cfgSlot
        if ($fromCfg -and (Test-Path -LiteralPath $fromCfg -PathType Leaf)) {
            return [pscustomobject]@{ path = (Resolve-Path -LiteralPath $fromCfg).Path; source = 'config' }
        }
    }

    # 4) 常见安装位置（深度 3，够覆盖 "...\AutoCAD 2018\accoreconsole.exe"）
    foreach ($root in (Get-CadCandidateRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter $ExeName -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) {
            return [pscustomobject]@{ path = $hit.FullName; source = "scan:$root" }
        }
    }

    # 5) PATH
    $onPath = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($onPath) {
        return [pscustomobject]@{ path = $onPath.Source; source = 'path' }
    }

    return $null
}

function Resolve-CadAccoreConsole {
    param([string]$Explicit)
    $r = Find-CadExecutable -ExeName 'accoreconsole.exe' -Explicit $Explicit
    if (-not $r) {
        throw @"
找不到 accoreconsole.exe。
请任选一种方式指定：
  1) 传参：      -AccoreConsole "D:\path\accoreconsole.exe"
  2) 环境变量：  `$env:CAD_ACCORECONSOLE = "D:\path\accoreconsole.exe"
  3) 写配置：    & "$PSScriptRoot\Set-CadPath.ps1" -AccoreConsole "D:\path\accoreconsole.exe"
accoreconsole.exe 随 AutoCAD 2013+ 安装，位置通常为 <AutoCAD 安装目录>\accoreconsole.exe。
"@
    }
    return $r
}

function Resolve-CadAcadExe {
    param([string]$Explicit)
    return (Find-CadExecutable -ExeName 'acad.exe' -Explicit $Explicit)
}

function Resolve-CadComProgId {
    <#
      实测关键点：本机 AutoCAD 2018 只注册了 AutoCAD.Application.22，
      裸的 AutoCAD.Application 没有 CurVer，直接 New-Object 会失败。
      所以必须枚举 HKLM:\SOFTWARE\Classes\AutoCAD.Application.*，挑最高版本。
    #>
    param([string]$Explicit)

    if ($Explicit) { return [pscustomobject]@{ progId = $Explicit; source = 'explicit' } }

    $cfg = Get-CadConfig
    if ($cfg.comProgId) {
        return [pscustomobject]@{ progId = $cfg.comProgId; source = 'config' }
    }

    $found = @()
    foreach ($hive in @('HKLM:\SOFTWARE\Classes', 'HKCU:\SOFTWARE\Classes')) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^AutoCAD\.Application\.(\d+)$' } |
            ForEach-Object {
                $ver = [int]$Matches[1]
                $found += [pscustomobject]@{ progId = $_.PSChildName; version = $ver }
            }
    }

    if ($found.Count -eq 0) { return $null }

    $best = $found | Sort-Object version -Descending | Select-Object -First 1
    return [pscustomobject]@{ progId = $best.progId; source = 'registry'; version = $best.version }
}

# ══════════════════════════════════════════════════════════════════
#  scr 脚本生成  ★ 中文路径的命门 ★
#
#  实测结论（本机 AutoCAD 2018 / accoreconsole O.49.0.0）：
#    · scr 用 ASCII 写 → accoreconsole 把中文路径读成 "cad?? ??"
#      → (load ...) 报 "文件加载已取消"，SAVEAS 报 "无效文件名"。
#    · scr 用 GBK(936) 写 → 中文路径正常，LOAD 与 SAVEAS 都成功。
#  所以本函数一律按 GBK 落盘，不接受 UTF-8 / ASCII。
# ══════════════════════════════════════════════════════════════════

function Write-CadScr {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Lines
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # 统一 CRLF：accoreconsole 对纯 LF 的 scr 也能读，但 CRLF 最稳。
    $text = ($Lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, $script:CadScrEncoding)
    return $Path
}

function Write-CadLsp {
    <#
      写 LISP 源文件。

      **必须用 GBK(936)**：AutoCAD 2018 的 LISP 读取器按系统 ANSI 代码页解析
      源文件，不认 UTF-8（有没有 BOM 都一样）。用 UTF-8 写的中文注释会被解成
      乱码字节，其中某些字节恰好是引号或括号，于是 LISP 在完全无关的位置报
      「参数类型错误: stringp nil」——报错位置指向文件头，真正的原因在编码。
      实测：UTF-8 版 load 直接失败，GBK 版一次通过。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # 统一 CRLF 再按 GBK 落盘
    $normalized = (($Body -replace "`r`n", "`n") -replace "`n", "`r`n")
    [System.IO.File]::WriteAllText($Path, $normalized, $script:CadScrEncoding)
    return $Path
}

function ConvertTo-CadPath {
    <#
      AutoCAD LISP 里反斜杠是转义符，路径必须用正斜杠。
    #>
    param([Parameter(Mandatory)][string]$Path)
    return ([IO.Path]::GetFullPath($Path)) -replace '\\', '/'
}

# ══════════════════════════════════════════════════════════════════
#  执行器
# ══════════════════════════════════════════════════════════════════

function Get-CadProcessTree {
    <#
      返回以 $RootId 为根的进程子树（父在前、子在后的 BFS 顺序）。
      杀进程时要从后往前，否则杀了父进程后子进程的 ParentProcessId 会变成
      已失效的值，再也追不到。

      为什么要自己走一遍：accoreconsole 的 cmd 包装器 / .NET 宿主 / 插件
      都可能再派生一层，Stop-Process 只作用于单个 PID。
    #>
    param([Parameter(Mandatory)][int]$RootId)

    $ordered = [Collections.Generic.List[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootId)
    $seen = @{}

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        $ordered.Add($cur)

        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$cur" -ErrorAction SilentlyContinue)
        foreach ($c in $children) {
            if (-not $seen.ContainsKey([int]$c.ProcessId)) { $queue.Enqueue([int]$c.ProcessId) }
        }
    }
    return $ordered.ToArray()
}

function Invoke-CadCoreConsole {
    <#
      跑一次 accoreconsole。返回结构化结果，不抛异常（错误进字段）。

      实测要点：
        · /i 指定的 dwg 必须真实存在，否则 exit 76 + 弹 "找不到指定的图形文件"
        · /s 脚本末尾必须 _.QUIT，否则进程不退出 → 只能靠超时收尾
        · SAVEAS 到已存在的文件会停在 "此名称的图形已存在" → 必须先删
    #>
    param(
        [string]$AccoreConsole,
        [string]$Script,
        [string]$InputDwg,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 300,
        [switch]$ReadOnly,
        [string]$LogFile,
        [string[]]$ExtraArgs
    )

    $exe = Resolve-CadAccoreConsole -Explicit $AccoreConsole
    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
        throw "scr 脚本不存在: $Script"
    }
    if ($InputDwg -and -not (Test-Path -LiteralPath $InputDwg -PathType Leaf)) {
        throw "输入图纸不存在: $InputDwg"
    }
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Script }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $outFile = Join-Path $script:CadStateDir "accore_stdout_$stamp.txt"
    $errFile = Join-Path $script:CadStateDir "accore_stderr_$stamp.txt"
    Initialize-CadState

    $argList = @()
    if ($InputDwg) { $argList += @('/i', ('"' + (Resolve-Path -LiteralPath $InputDwg).Path + '"')) }
    $argList += @('/s', ('"' + (Resolve-Path -LiteralPath $Script).Path + '"'))
    if ($ReadOnly) { $argList += '/readonly' }
    if ($ExtraArgs) { $argList += $ExtraArgs }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null
    $proc = $null
    $registered = $false

    try {
        $proc = Start-Process -FilePath $exe.path -ArgumentList $argList `
            -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $registered = Register-OwnedCadProcess -Process $proc -Kind 'accoreconsole' -Source $exe.path

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            # ★ 只 Kill 父进程会留孤儿 ★
            #   实测：mock 的 cmd 包装器派生 pwsh 后，$proc.Kill() 只杀掉 cmd.exe，
            #   里面的 pwsh 还在 Start-Sleep 3600 —— 登记表认为进程已清，PID 却还活着，
            #   下一轮测试就撞上「端口/文件被占」的怪事。
            #   真 accoreconsole 同理：它加载 .NET 后会派生 AppDomain/子进程，
            #   超时那种「卡在对话框」的场景正是最容易留孤儿的时候。
            #   所以：先抓整棵子树，再从叶子往根杀。
            $tree = Get-CadProcessTree -RootId $proc.Id
            foreach ($childId in ($tree | Select-Object -Skip 1)) {
                try { Stop-Process -Id $childId -Force -ErrorAction Stop } catch { }
            }
            try { $proc.Kill() } catch { }
            Start-Sleep -Milliseconds 300
            # 兜底再确认一次：子树里还有活的就再杀一轮
            foreach ($childId in $tree) {
                $alive = Get-Process -Id $childId -ErrorAction SilentlyContinue
                if ($alive) { try { Stop-Process -Id $childId -Force -ErrorAction Stop } catch { } }
            }
        } else {
            $exitCode = $proc.ExitCode
        }
    } catch {
        throw "启动 accoreconsole 失败: $($_.Exception.Message)"
    } finally {
        $sw.Stop()
    }

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $outFile) {
        try { $stdout = Get-Content -LiteralPath $outFile -Raw -Encoding Unicode } catch { $stdout = '' }
    }
    if (Test-Path -LiteralPath $errFile) {
        try { $stderr = Get-Content -LiteralPath $errFile -Raw -Encoding Unicode } catch { $stderr = '' }
    }
    if ($null -eq $stdout) { $stdout = '' }
    if ($null -eq $stderr) { $stderr = '' }

    $parsed = Get-CadConsoleDiagnostics -Text $stdout

    # 日志落到用户指定位置（默认不写进 skill 安装目录）
    if ($LogFile) {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $stdout | Set-Content -LiteralPath $LogFile -Encoding UTF8
    }

    if ($registered -and $proc -and $proc.HasExited) {
        Unregister-OwnedCadProcess -ProcessId $proc.Id
    }

    return [pscustomobject]@{
        exe            = $exe.path
        exeSource      = $exe.source
        script         = (Resolve-Path -LiteralPath $Script).Path
        inputDwg       = if ($InputDwg) { (Resolve-Path -LiteralPath $InputDwg).Path } else { $null }
        workingDir     = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        exitCode       = $exitCode
        exitName       = if ($null -ne $exitCode -and $script:CadExitCodes.ContainsKey([int]$exitCode)) {
                             $script:CadExitCodes[[int]$exitCode]
                         } elseif ($null -ne $exitCode) { "unknown-$exitCode" } else { 'timeout' }
        timedOut       = $timedOut
        durationMs     = [int]$sw.ElapsedMilliseconds
        stdoutFile     = $outFile
        stderrFile     = $errFile
        stdoutTail     = (Get-CadTail -Text $stdout -Lines 40)
        stderrTail     = (Get-CadTail -Text $stderr -Lines 20)
        lispError      = $parsed.lispError
        lispErrorLines = $parsed.lispErrorLines
        markers        = $parsed.markers
        messageBoxes   = $parsed.messageBoxes
        drawingNotFound= $parsed.drawingNotFound
        pid            = if ($proc) { $proc.Id } else { $null }
    }
}

function Get-CadTail {
    param([string]$Text, [int]$Lines = 40)
    if (-not $Text) { return @() }
    $all = $Text -split "\r?\n" | Where-Object { $_.Trim() -ne '' }
    if ($all.Count -le $Lines) { return $all }
    return ($all | Select-Object -Last $Lines)
}

# ══════════════════════════════════════════════════════════════════
#  输出解析
# ══════════════════════════════════════════════════════════════════

function Get-CadConsoleDiagnostics {
    <#
      解析 accoreconsole 的 stdout。三类信号：
        1. LISP 错误行：  "; 错误: ..."  /  "; error: ..."
        2. 标记：         <<<KEY ...>>> / @@KEY=...@@  （脚本自报数据）
        3. 消息框：       ***MessageBox*** ... 请确认 ... >>>Responding:
      注意：accoreconsole 用中文界面时错误前缀是「; 错误:」，英文是「; error:」。
    #>
    param([string]$Text)

    $result = [pscustomobject]@{
        lispError       = $false
        lispErrorLines  = @()
        markers         = @()
        messageBoxes    = @()
        drawingNotFound = $false
    }
    if (-not $Text) { return $result }

    $lines = $Text -split "\r?\n"

    $errLines = @()
    foreach ($ln in $lines) {
        if ($ln -match '^\s*;\s*(错误|error)\s*[:：]') { $errLines += $ln.Trim() }
        if ($ln -match 'MessageBox|Responding:\s*OK|找不到指定的图形文件|Invalid file name|无效文件名') {
            $result.messageBoxes += $ln.Trim()
        }
        if ($ln -match '找不到指定的图形文件|drawing file.*not found') { $result.drawingNotFound = $true }

        # 单行标记：@@NAME=value@@ / @@NAME@@（无值形式，如 @@DONE@@）
        foreach ($m in [regex]::Matches($ln, '@@([A-Za-z0-9_.\-]+)=([^@]*)@@')) {
            $result.markers += [pscustomobject]@{ name = $m.Groups[1].Value; value = $m.Groups[2].Value.Trim() }
        }
        foreach ($m in [regex]::Matches($ln, '@@([A-Za-z0-9_.\-]+)@@')) {
            $result.markers += [pscustomobject]@{ name = $m.Groups[1].Value; value = $true }
        }
        # 块标记：<<<NAME ...>>> ... <<<END>>>
        if ($ln -match '<<<([A-Za-z0-9_.\-]+)(?:\s+([^>]*))?>>>') {
            $result.markers += [pscustomobject]@{
                name  = $Matches[1]
                value = if ($Matches[2]) { $Matches[2].Trim() } else { $true }
            }
        }
    }

    $result.lispError      = ($errLines.Count -gt 0)
    $result.lispErrorLines = $errLines
    return $result
}

function Get-CadMarker {
    param($Result, [string]$Name)
    if (-not $Result -or -not $Result.markers) { return $null }
    $hit = @($Result.markers | Where-Object { $_.name -eq $Name })
    if ($hit.Count -eq 0) { return $null }
    return $hit[-1].value
}

# ══════════════════════════════════════════════════════════════════
#  DXF 独立校验与读取
#  自己解析组码，不依赖任何第三方库。用于「不复用绘图结论」的独立证据。
# ══════════════════════════════════════════════════════════════════

function Read-CadDxfPairs {
    <#
      ASCII DXF 是 (组码, 值) 交替的行。返回 {code, value} 数组。
      二进制 DXF（首 22 字节 "AutoCAD Binary DXF"）直接拒绝。

      ★ 编码：DXF 从 R2007(AC1021) 起一律 UTF-8，不看 $DWGCODEPAGE ★
       实测 all-entities.dxf 头里写 ANSI_936，但「多行文字」只有用 UTF-8
       解码才对，用 GBK 会得到「澶氳鏂囧瓧」。所以这里固定 UTF-8，
       与 scr/lsp 的 GBK 需求完全无关（那两个是 AutoCAD 命令行通道的规矩）。
       为兼容极老的 R12/2000 文件（那才是真 ANSI），UTF-8 严格解码失败时
       回落到 GBK，并把实际使用的编码记进返回对象的 encoding 字段。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "DXF 文件不存在: $Path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 4) { throw "DXF 文件过短，不是有效 DXF: $Path" }

    $head = $script:CadScrEncoding.GetString($bytes, 0, [Math]::Min(22, $bytes.Length))
    if ($head -match 'AutoCAD Binary DXF') {
        throw "这是二进制 DXF，本 skill 只解析 ASCII DXF。导出时请用 DXFOUT 的默认 ASCII 模式。"
    }

    $text = $null
    $usedEncoding = 'utf-8'
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strictUtf8.GetString($bytes)
    } catch {
        $text = $script:CadScrEncoding.GetString($bytes)
        $usedEncoding = 'gbk'
    }
    $lines = $text -split "\r?\n"

    $pairs = New-Object System.Collections.Generic.List[object]
    $i = 0
    $malformed = New-Object System.Collections.Generic.List[int]

    while ($i + 1 -lt $lines.Count) {
        $codeRaw = $lines[$i].Trim()
        $valRaw  = $lines[$i + 1]
        if ($codeRaw -eq '') { $i++; continue }

        $code = 0
        if (-not [int]::TryParse($codeRaw, [ref]$code)) {
            $malformed.Add($i + 1) | Out-Null
            $i += 2
            continue
        }
        $pairs.Add([pscustomobject]@{ code = $code; value = $valRaw.TrimEnd(); line = $i + 1 }) | Out-Null
        $i += 2
    }

    return [pscustomobject]@{
        path       = (Resolve-Path -LiteralPath $Path).Path
        pairs      = $pairs
        lineCount  = $lines.Count
        malformedLines = $malformed
        byteLength = $bytes.Length
        encoding   = $usedEncoding
    }
}

function Test-CadDxfFile {
    <#
      独立校验 DXF 结构。返回的每一项都是「结构事实」，不代表图形内容正确。
        与「绘图成功」是两件事，别混着说。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $r = [ordered]@{
        path            = $null
        valid           = $false
        reason          = $null
        byteLength      = 0
        pairs           = 0
        sections        = @()
        sectionCount    = 0
        hasEntities     = $false
        entityCount     = 0
        entityTypes     = @{}
        layers          = @()
        blockCount      = 0
        eofSeen         = $false
        sectionBalance  = 0
        malformedLines  = 0
        extents         = $null
        version         = $null
    }

    try {
        $doc = Read-CadDxfPairs -Path $Path
    } catch {
        $r.reason = $_.Exception.Message
        return [pscustomobject]$r
    }

    $r.path           = $doc.path
    $r.byteLength     = $doc.byteLength
    $r.pairs          = $doc.pairs.Count
    $r.malformedLines = $doc.malformedLines.Count

    $pairs = $doc.pairs
    $secs = New-Object System.Collections.Generic.List[string]
    $inEntities = $false
    $entityTypes = @{}
    $layers = New-Object System.Collections.Generic.List[string]
    $balance = 0
    $eof = $false
    $blockCount = 0
    $inBlocks = $false

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]

        if ($p.code -eq 0 -and $p.value -eq 'SECTION') {
            $balance++
            $name = ''
            if ($i + 1 -lt $pairs.Count -and $pairs[$i+1].code -eq 2) { $name = $pairs[$i+1].value }
            if ($name) { $secs.Add($name) | Out-Null }
            if ($name -eq 'ENTITIES') { $inEntities = $true }
            if ($name -eq 'BLOCKS')   { $inBlocks   = $true }
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'ENDSEC') {
            $balance--
            $inEntities = $false
            $inBlocks   = $false
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'EOF') { $eof = $true; continue }

        if ($p.code -eq 9 -and $p.value -eq '$ACADVER') {
            if ($i + 1 -lt $pairs.Count -and $pairs[$i+1].code -eq 1) { $r.version = $pairs[$i+1].value }
        }

        if ($inEntities -and $p.code -eq 0) {
            $t = $p.value
            if ($t) {
                if ($entityTypes.ContainsKey($t)) { $entityTypes[$t]++ } else { $entityTypes[$t] = 1 }
            }
        }
        if ($inEntities -and $p.code -eq 8) {
            if ($p.value -and -not $layers.Contains($p.value)) { $layers.Add($p.value) | Out-Null }
        }
        if ($inBlocks -and $p.code -eq 0 -and $p.value -eq 'BLOCK') { $blockCount++ }
    }

    $r.sections       = $secs.ToArray()
    $r.sectionCount   = $secs.Count
    $r.hasEntities    = ($secs -contains 'ENTITIES')
    $r.entityCount    = ($entityTypes.Values | Measure-Object -Sum).Sum
    if ($null -eq $r.entityCount) { $r.entityCount = 0 }
    $r.entityTypes    = $entityTypes
    $r.layers         = $layers.ToArray()
    $r.blockCount     = $blockCount
    $r.eofSeen        = $eof
    $r.sectionBalance = $balance

    # 判定：结构完整才算 valid。这是「文件结构合法」，不是「图形画对了」。
    if ($r.malformedLines -gt 0) {
        $r.reason = "有 $($r.malformedLines) 行组码不是整数"
    } elseif (-not $eof) {
        $r.reason = '缺少 EOF 记录（文件被截断）'
    } elseif ($balance -ne 0) {
        $r.reason = "SECTION/ENDSEC 不配对，差值 $balance"
    } elseif (-not $r.hasEntities) {
        $r.reason = '缺少 ENTITIES 段'
    } elseif ($r.sectionCount -lt 2) {
        $r.reason = "段数只有 $($r.sectionCount)，DXF 至少要有 HEADER 与 ENTITIES"
    } else {
        $r.valid  = $true
        $r.reason = 'ok'
    }

    return [pscustomobject]$r
}

function Get-CadDxfEntities {
    <#
      从 ASCII DXF 的 ENTITIES 段读出实体清单。
      只提取通用字段：type / layer / handle / 首个点(10,20,30)。
      够做「画了几条线、在哪个图层、坐标是多少」这类证据。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Limit = 500
    )

    $doc = Read-CadDxfPairs -Path $Path
    $pairs = $doc.pairs
    $out = New-Object System.Collections.Generic.List[object]
    $inEntities = $false
    $cur = $null

    function New-Entity {
        return [pscustomobject]@{
            type   = $null
            layer  = $null
            handle = $null
            x      = $null
            y      = $null
            z      = $null
            text   = $null
            radius = $null
        }
    }

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]

        if ($p.code -eq 0 -and $p.value -eq 'SECTION') {
            $name = ''
            if ($i + 1 -lt $pairs.Count -and $pairs[$i+1].code -eq 2) { $name = $pairs[$i+1].value }
            if ($name -eq 'ENTITIES') { $inEntities = $true }
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'ENDSEC') { $inEntities = $false; continue }

        if ($inEntities -and $p.code -eq 0) {
            if ($cur) { $out.Add($cur) | Out-Null; if ($out.Count -ge $Limit) { break } }
            $cur = New-Entity
            $cur.type = $p.value
            continue
        }
        if (-not $inEntities -or -not $cur) { continue }

        switch ($p.code) {
            8  { if (-not $cur.layer)  { $cur.layer  = $p.value } }
            5  { if (-not $cur.handle) { $cur.handle = $p.value } }
            10 { if ($null -eq $cur.x) { $cur.x = ConvertTo-CadDouble $p.value } }
            20 { if ($null -eq $cur.y) { $cur.y = ConvertTo-CadDouble $p.value } }
            30 { if ($null -eq $cur.z) { $cur.z = ConvertTo-CadDouble $p.value } }
            40 { if ($null -eq $cur.radius) { $cur.radius = ConvertTo-CadDouble $p.value } }
            1  { if ($null -eq $cur.text -and $cur.type -in @('TEXT','MTEXT','ATTRIB')) { $cur.text = $p.value } }
        }
    }
    if ($cur -and $out.Count -lt $Limit) { $out.Add($cur) | Out-Null }

    return $out.ToArray()
}

function ConvertTo-CadDouble {
    param([string]$s)
    if (-not $s) { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-CadDxfBlockNames {
    <#
      从 ASCII DXF 的 BLOCKS 段读出块定义名（组码 2，紧跟组码 0=BLOCK 的那个）。

      为什么单独一个函数：
        「模型空间里有 INSERT」只能证明引用存在，证明不了块真的建成了 ——
        块定义缺失时 AutoCAD 会造一个匿名空块顶上，INSERT 照样出现。
        只有 BLOCKS 段里出现预期名字，才说明 -BLOCK 真的收下了实体。

      $200、$201 这些是自动布局的匿名块，过滤掉避免噪声。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-CadDxfPairs -Path $Path
    $pairs = $doc.pairs
    $out = New-Object System.Collections.Generic.List[string]
    $inBlocks = $false

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]
        if ($p.code -eq 0 -and $p.value -eq 'SECTION') {
            $name = ''
            if ($i + 1 -lt $pairs.Count -and $pairs[$i + 1].code -eq 2) { $name = $pairs[$i + 1].value }
            $inBlocks = ($name -eq 'BLOCKS')
            continue
        }
        if ($p.code -eq 0 -and $p.value -eq 'ENDSEC') { $inBlocks = $false; continue }
        if (-not $inBlocks) { continue }

        if ($p.code -eq 0 -and $p.value -eq 'BLOCK') {
            # 下一个组码 2 就是块名
            for ($j = $i + 1; $j -lt [Math]::Min($i + 8, $pairs.Count); $j++) {
                if ($pairs[$j].code -eq 2) {
                    $bn = [string]$pairs[$j].value
                    if ($bn -and -not $bn.StartsWith('*')) { $out.Add($bn) | Out-Null }
                    break
                }
                if ($pairs[$j].code -eq 0) { break }
            }
        }
    }
    return $out.ToArray()
}

# ══════════════════════════════════════════════════════════════════
#  进程登记表 + 三道闸清理
#
#  本 skill 绝不按名字批量结束进程。
#  只有「本 skill 自己启动、且登记在案、且 PID+启动时间+进程名全对」的进程才会被结束。
# ══════════════════════════════════════════════════════════════════

function Get-CadRegistry {
    Initialize-CadState
    if (-not (Test-Path -LiteralPath $script:CadRegistryFile)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:CadRegistryFile -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @() }
        $obj = $raw | ConvertFrom-Json
        if ($obj -is [array]) { return $obj }
        return @($obj)
    } catch { return @() }
}

function Save-CadRegistry {
    <#
      ★ 空数组必须显式写成 [] ★
      PowerShell 7 里 `@() | ConvertTo-Json` 返回 $null，
      而 `$null | Set-Content` 根本不会创建/清空文件 ——
      于是「清空登记表」变成静默空操作，旧条目原样留在文件里，
      下次读回来还以为进程没被清理。这是真踩到的 bug。
    #>
    param($Entries)
    Initialize-CadState
    $arr = @($Entries)
    $json = if ($arr.Count -eq 0) { '[]' } else { $arr | ConvertTo-Json -Depth 5 }
    Set-Content -LiteralPath $script:CadRegistryFile -Value $json -Encoding UTF8
}

function Register-OwnedCadProcess {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Source
    )
    Initialize-CadState
    try {
        $startTime = $Process.StartTime
    } catch {
        # 进程已退出时拿不到 StartTime —— 不登记，避免留下无法校验的条目。
        return $false
    }

    $entry = [pscustomobject]@{
        pid        = $Process.Id
        name       = $Process.ProcessName
        started_at = $startTime.ToString('o')
        kind       = $Kind
        source     = $Source
        owner_pid  = $PID
        owner_name = (Get-Process -Id $PID -ErrorAction SilentlyContinue).ProcessName
        created_at = (Get-Date).ToString('o')
    }
    $all = @(Get-CadRegistry)
    $all = @($all | Where-Object { $_.pid -ne $entry.pid })
    $all += $entry
    Save-CadRegistry -Entries $all
    return $true
}

function Unregister-OwnedCadProcess {
    param([int]$ProcessId)
    $all = @(Get-CadRegistry | Where-Object { $_.pid -ne $ProcessId })
    Save-CadRegistry -Entries $all
}

function Get-CadOwnedProcesses {
    <#
      只读枚举：登记表里的 PID 现在还活着、且身份对得上的那些。
      不结束任何进程。
    #>
    $rows = @()
    foreach ($e in (Get-CadRegistry)) {
        $p = Get-Process -Id $e.pid -ErrorAction SilentlyContinue
        $alive = $false
        $match = $false
        if ($p) {
            $alive = $true
            try {
                $st = $p.StartTime
                $reg = [datetime]::Parse($e.started_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $match = ([Math]::Abs(($st - $reg).TotalSeconds) -le 2) -and ($p.ProcessName -eq $e.name)
            } catch { $match = $false }
        }
        $rows += [pscustomobject]@{
            pid = $e.pid; name = $e.name; kind = $e.kind
            registered_at = $e.created_at; alive = $alive; identityMatch = $match
        }
    }
    return $rows
}

function Stop-OwnedCadProcess {
    <#
      结束一个「本 skill 自己启动的」CAD 进程。三道闸全过才动手：
        闸1  PID 在登记表里
        闸2  调用方 -OwnerPid 与登记条目的 owner_pid 一致，且 owner 进程仍存活
        闸3  进程名对得上，且启动时间与登记值相差 ≤ 2 秒
      任何一闸不过 → 返回 refused + 原因，不做任何操作。
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [int]$OwnerPid = $PID,
        [switch]$Force
    )

    $result = [pscustomobject]@{
        pid = $ProcessId; stopped = $false; refused = $false
        ownerCheck = 'ok'; method = $null; reason = $null
    }

    $entry = @(Get-CadRegistry | Where-Object { $_.pid -eq $ProcessId })
    if ($entry.Count -eq 0) {
        $result.refused = $true
        $result.ownerCheck = 'no-registry-entry'
        $result.reason = '该 PID 不在本 skill 的登记表里，不是本 skill 启动的进程，拒绝结束。'
        return $result
    }
    $entry = $entry[0]

    if ($entry.owner_pid -ne $OwnerPid) {
        $result.refused = $true
        $result.ownerCheck = "caller-not-owner:entry=$($entry.owner_pid);caller=$OwnerPid"
        $result.reason = '调用方不是登记条目里的 owner，拒绝结束。'
        return $result
    }
    $owner = Get-Process -Id $entry.owner_pid -ErrorAction SilentlyContinue
    if (-not $owner) {
        $result.refused = $true
        $result.ownerCheck = 'owner-dead'
        $result.reason = '登记条目里的 owner 进程已不存在，拒绝结束（可能是 PID 复用）。'
        return $result
    }

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Unregister-OwnedCadProcess -ProcessId $ProcessId
        $result.stopped = $true
        $result.method = 'already-exited'
        $result.reason = '进程已自行退出，登记条目已清理。'
        return $result
    }

    if ($proc.ProcessName -ne $entry.name) {
        $result.refused = $true
        $result.ownerCheck = "not-same-name:$($proc.ProcessName)≠$($entry.name)"
        $result.reason = '进程名与登记值不符（PID 可能已被复用），拒绝结束。'
        return $result
    }

    try {
        $reg = [datetime]::Parse($entry.started_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $delta = [Math]::Abs(($proc.StartTime - $reg).TotalSeconds)
        if ($delta -gt 2) {
            $result.refused = $true
            $result.ownerCheck = "started_at mismatch: Δ=$([Math]::Round($delta,1))s"
            $result.reason = '启动时间与登记值相差超过 2 秒（PID 复用），拒绝结束。'
            return $result
        }
    } catch {
        $result.refused = $true
        $result.ownerCheck = 'starttime-unreadable'
        $result.reason = "读不到进程启动时间：$($_.Exception.Message)"
        return $result
    }

    # 清理顺序：先试优雅关闭窗口，再对单个 PID 强杀。
    $method = 'close-main-window'
    try {
        if ($proc.MainWindowHandle -ne 0 -and $proc.CloseMainWindow()) {
            if ($proc.WaitForExit(5000)) {
                $method = 'close-main-window'
                Unregister-OwnedCadProcess -ProcessId $ProcessId
                $result.stopped = $true; $result.method = $method
                return $result
            }
        }
    } catch { }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        $method = 'stop-process-single-pid'
        Unregister-OwnedCadProcess -ProcessId $ProcessId
        $result.stopped = $true
        $result.method = $method
    } catch {
        $result.reason = "结束失败：$($_.Exception.Message)"
    }
    return $result
}

function Clear-StaleCadEntries {
    <#
      清理登记表里的死条目。跳过「owner 进程还活着」的条目 —— 交给那个 owner 自己收尾。
    #>
    $kept = @()
    $dropped = @()
    foreach ($e in (Get-CadRegistry)) {
        $owner = Get-Process -Id $e.owner_pid -ErrorAction SilentlyContinue
        $proc  = Get-Process -Id $e.pid -ErrorAction SilentlyContinue
        if (-not $proc -and -not $owner) { $dropped += $e.pid }
        elseif (-not $proc) { $dropped += $e.pid }   # 进程已退出，条目无用
        else { $kept += $e }
    }
    Save-CadRegistry -Entries $kept
    return [pscustomobject]@{ kept = $kept.Count; dropped = $dropped }
}

# ══════════════════════════════════════════════════════════════════
#  图纸体检
# ══════════════════════════════════════════════════════════════════

function Get-CadDrawingInfo {
    <#
      读一张图纸的「可验证事实」：实体数、图层、类型分布、范围、块数。
      两条通道：
        · DXF 通道（首选，纯离线）：自己解析，不依赖 CAD 进程
        · LISP 通道（需要 accoreconsole）：对 DWG 直接取，靠 accoreconsole 执行
      本函数只做 DXF 通道；DWG 请先用 Export-CadToDxf 转 DXF。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -ne '.dxf') {
        throw "Get-CadDrawingInfo 只读 ASCII DXF。DWG 请先转 DXF（Export-CadToDxf），或用 Invoke-CadInspect 走 accoreconsole 通道。"
    }

    $check = Test-CadDxfFile -Path $Path
    $ents  = Get-CadDxfEntities -Path $Path -Limit 5000

    $xs = @($ents | Where-Object { $null -ne $_.x } | ForEach-Object { $_.x })
    $ys = @($ents | Where-Object { $null -ne $_.y } | ForEach-Object { $_.y })

    $extents = $null
    if ($xs.Count -gt 0 -and $ys.Count -gt 0) {
        $extents = [pscustomobject]@{
            minX = ($xs | Measure-Object -Minimum).Minimum
            maxX = ($xs | Measure-Object -Maximum).Maximum
            minY = ($ys | Measure-Object -Minimum).Minimum
            maxY = ($ys | Measure-Object -Maximum).Maximum
            width  = [Math]::Round((($xs | Measure-Object -Maximum).Maximum - ($xs | Measure-Object -Minimum).Minimum), 6)
            height = [Math]::Round((($ys | Measure-Object -Maximum).Maximum - ($ys | Measure-Object -Minimum).Minimum), 6)
        }
    }

    $byType = @{}
    foreach ($e in $ents) {
        if (-not $e.type) { continue }
        if ($byType.ContainsKey($e.type)) { $byType[$e.type]++ } else { $byType[$e.type] = 1 }
    }
    # 哈希表对调用方不友好（JSON 里成对象、渲染时要 .type/.count 都没有）。
    # 统一成 [{type,count}] 有序数组，按数量降序。
    $typeList = @($byType.GetEnumerator() |
        Sort-Object -Property Value -Descending |
        ForEach-Object { [pscustomobject]@{ type = $_.Key; count = $_.Value } })

    $layers = @($ents | Where-Object { $_.layer } | Select-Object -ExpandProperty layer -Unique)

    return [pscustomobject]@{
        path           = (Resolve-Path -LiteralPath $Path).Path
        dxfValid       = $check.valid
        dxfReason      = $check.reason
        version        = $check.version
        byteLength     = $check.byteLength
        entityCount    = $check.entityCount
        entitiesRead   = $ents.Count
        entityTypes    = $typeList
        layers         = $layers
        blockCount     = $check.blockCount
        extents        = $extents
        sectionCount   = $check.sectionCount
        sections       = $check.sections
        eofSeen        = $check.eofSeen
        malformedLines = $check.malformedLines
    }
}


function Test-CadPdfFile {
    <#
      独立校验 PDF 产物。
      为什么必须做：accoreconsole 的 -PLOT 即使失败，也可能留下一个几 KB 的
      空壳或 0 字节文件；只判 Test-Path 会把「绘图失败」当成功上报。
      这里查三件事，任缺其一都不算有效 PDF：
        1) 头 5 字节是 %PDF-
        2) 尾 1 KB 内出现 %%EOF（文件被截断就没有）
        3) 字节数过下限（A3 空图也有几 KB，低于 MinimumBytes 基本是空壳）
      注意：通过校验只代表「是结构完整的 PDF」，不代表图面内容正确。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinimumBytes = 1024
    )

    $r = [ordered]@{
        path        = $Path
        valid       = $false
        reason      = $null
        byteLength  = 0
        header      = $null
        hasEof      = $false
        pageCount   = 0
        minimumBytes = $MinimumBytes
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $r.reason = '文件不存在'
        return [pscustomobject]$r
    }

    try { $r.byteLength = (Get-Item -LiteralPath $Path).Length } catch {
        $r.reason = "读取文件信息失败: $($_.Exception.Message)"
        return [pscustomobject]$r
    }

    if ($r.byteLength -lt $MinimumBytes) {
        $r.reason = "文件只有 $($r.byteLength) 字节，低于下限 $MinimumBytes（大概率是空壳或写入中断）"
        return [pscustomobject]$r
    }

    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($Path)

        # 1) 头 8 字节
        $head = New-Object byte[] 8
        $n = $fs.Read($head, 0, 8)
        $r.header = if ($n -gt 0) { [Text.Encoding]::ASCII.GetString($head, 0, $n).Trim() } else { '' }
        if (-not $r.header.StartsWith('%PDF-')) {
            $r.reason = "文件头不是 %PDF-（实际是 '$($r.header)'），这不是 PDF"
            return [pscustomobject]$r
        }

        # 2) 尾部 %%EOF
        $tailLen = [int][Math]::Min(1024, $r.byteLength)
        $fs.Seek(-$tailLen, [IO.SeekOrigin]::End) | Out-Null
        $tail = New-Object byte[] $tailLen
        $null = $fs.Read($tail, 0, $tailLen)
        $tailText = [Text.Encoding]::ASCII.GetString($tail)
        $r.hasEof = $tailText.Contains('%%EOF')
        if (-not $r.hasEof) {
            $r.reason = '文件尾没有 %%EOF，PDF 被截断'
            return [pscustomobject]$r
        }

        # 3) 页数（扫描整个文件找 /Type /Page，够用且不依赖第三方库）
        $fs.Seek(0, [IO.SeekOrigin]::Begin) | Out-Null
        $all = New-Object byte[] $r.byteLength
        $read = 0
        while ($read -lt $all.Length) {
            $got = $fs.Read($all, $read, $all.Length - $read)
            if ($got -le 0) { break }
            $read += $got
        }
        $text = [Text.Encoding]::ASCII.GetString($all, 0, $read)
        $r.pageCount = ([regex]::Matches($text, '/Type\s*/Page[^s]')).Count
    } catch {
        $r.reason = "读取 PDF 失败: $($_.Exception.Message)"
        return [pscustomobject]$r
    } finally {
        if ($fs) { $fs.Dispose() }
    }

    if ($r.pageCount -lt 1) {
        $r.reason = 'PDF 里找不到任何页面对象（/Type /Page）'
        return [pscustomobject]$r
    }

    $r.valid = $true
    return [pscustomobject]$r
}


function Test-CadDwgFile {
    <#
      独立校验 DWG 产物。
      为什么不能只看大小：写入中断会留下一个几 KB 的半截 DWG；而 accoreconsole
      在 SAVEAS 失败时也可能留下旧文件或空壳。
      DWG 的真实标识是文件头 'AC10xx'（R12=AC1009 / 2018=AC1032 等），
      与 DXF 的版本号是同一套编号体系，可以互相印证。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinimumBytes = 2000
    )

    $r = [ordered]@{
        path       = $Path
        valid      = $false
        reason     = $null
        byteLength = 0
        header     = $null
        version    = $null
        minimumBytes = $MinimumBytes
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $r.reason = '文件不存在'
        return [pscustomobject]$r
    }

    try { $r.byteLength = (Get-Item -LiteralPath $Path).Length } catch {
        $r.reason = "读取文件信息失败: $($_.Exception.Message)"
        return [pscustomobject]$r
    }

    if ($r.byteLength -lt $MinimumBytes) {
        $r.reason = "文件只有 $($r.byteLength) 字节，低于下限 $MinimumBytes"
        return [pscustomobject]$r
    }

    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 6
            $n = $fs.Read($head, 0, 6)
            $r.header = if ($n -ge 6) { [Text.Encoding]::ASCII.GetString($head, 0, 6) } else { '' }
        } finally { $fs.Dispose() }
    } catch {
        $r.reason = "读取文件头失败: $($_.Exception.Message)"
        return [pscustomobject]$r
    }

    if ($r.header -notmatch '^AC\d{4}$') {
        $r.reason = "文件头不是 AC10xx（实际是 '$($r.header)'），这不是 DWG"
        return [pscustomobject]$r
    }

    $r.version = switch ($r.header) {
        'AC1009' { 'R12' }
        'AC1012' { 'R13' }
        'AC1014' { 'R14' }
        'AC1015' { '2000' }
        'AC1018' { '2004' }
        'AC1021' { '2007' }
        'AC1024' { '2010' }
        'AC1027' { '2013' }
        'AC1032' { '2018' }
        default  { $r.header }
    }

    $r.valid = $true
    return [pscustomobject]$r
}
