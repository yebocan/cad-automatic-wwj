<#
    fake-accoreconsole.ps1 — 冒充 accoreconsole.exe 的测试替身
    ────────────────────────────────────────────────────────────────
    目的：验证「本 skill 对 accoreconsole 输出的解析」和「产物校验逻辑」，
    不依赖真的装了 AutoCAD。

    ★ 为什么要做成 cmd 包一层 ★
    Start-Process 直接跑 .ps1 会另开窗口或落到错误的宿主；
    更关键的是：真 accoreconsole 的 stdout 是 UTF-16LE，
    我们用 [Console]::OpenStandardOutput() 直接写字节才能精确复刻这一点。
    在 pwsh 脚本里这么写，经 cmd 转发后确实是 UTF-16LE（已实测字节 228,78 = 0x4EE4）。

    ★ 它怎么知道该写哪些产物文件 ★
    不去猜路径，而是**读调用方真正生成的脚本**：
      1. 从 /s 参数拿到 .scr 路径，按 GBK 读
      2. 从 scr 里 (load "...") 拿到 drawing.lsp 路径
      3. 从 drawing.lsp 里 grep (c:SAVEAS "p" "ver") / (c:SAVEDXF "p" "ver" "prec") / (c:PLOTPDF "p" "size")
      4. 往那些路径写产物
    这样 mock 的行为跟着「被测量的代码」走，改脚本时 mock 不用跟着改。

    场景（环境变量 MOCK_SCENARIO）：
      normal      全部成功 —— 吐全部 marker + 写 dwg/dxf/pdf
      lisp-error  吐 "; 错误:" 行（验证错误识别）
      not-found   exit 76 + 「找不到指定的图形文件」（验证 exitName）
      no-done     写产物但不吐 @@DONE@@（验证「必须见到 DONE」）
      no-artifact 吐全部 marker 但一个文件都不写（★ 验证「不信自述」★）
      same-handle 两个实体回同一 handle（★ 验证 hatch 那类"假成功" ★）
      dialog      吐 MessageBox 行（验证对话框拦截）
      hang        永不退出（验证超时闸；配合很短的 -TimeoutSeconds）
      bad-dxf     写一个结构残缺的 DXF（验证 DXF 独立校验）
      bad-pdf     写一个不是 %PDF 的文件（验证 PDF 头校验）
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Raw([string]$Text) {
    $bytes = [Text.Encoding]::Unicode.GetBytes($Text)
    $s = [Console]::OpenStandardOutput()
    $s.Write($bytes, 0, $bytes.Length)
    $s.Flush()
}

function Line([string]$Text) { Write-Raw ($Text + "`r`n") }

function Get-ArgValue([string[]]$Argv, [string]$Name) {
    # ★ 形参不能叫 $Args —— 那是 PowerShell 自动变量，赋值/读取都会失真 ★
    for ($i = 0; $i -lt $Argv.Count - 1; $i++) {
        if ($Argv[$i] -ieq $Name) { return $Argv[$i + 1].Trim('"') }
    }
    return $null
}

# 从 LISP 里抠出某个 c:XXX 调用的第一个字符串实参（也就是输出路径）
function Get-LispTargetPath([string]$Lisp, [string]$Fn) {
    $m = [regex]::Match($Lisp, '\(c:' + [regex]::Escape($Fn) + '\s+"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

$scenario = $env:MOCK_SCENARIO
if (-not $scenario) { $scenario = 'normal' }

$gbk = [Text.Encoding]::GetEncoding(936)

# ── 解析参数 ─────────────────────────────────────────────────────
$scrPath = Get-ArgValue $Rest '/s'
$dwgIn = Get-ArgValue $Rest '/i'

Line '正在初始化...'
Line '命令:'

# 找不到图纸文件 —— 真 accoreconsole 是 exit 76
if ($scenario -eq 'not-found' -or ($dwgIn -and -not (Test-Path -LiteralPath $dwgIn))) {
    Line "System.Exception: 找不到指定的图形文件。"
    Line '   在 Autodesk.AutoCAD.ApplicationServices....'
    Write-Raw "*MessageBox* 找不到指定的图形文件 >>>Responding: `r`n"
    exit 76
}

if ($scenario -eq 'hang') {
    # 让调用方用很短的 -TimeoutSeconds 打中。
    #
    # ★ 上限不能给太大，且父进程死了要自己退 ★
    #   原来写 Start-Sleep 3600，一旦测试框架漏杀（比如只杀了 cmd 包装器），
    #   这个进程会在后台躺一小时，占着文件句柄让下一轮测试莫名其妙地失败。
    #   现在：最多 600 秒，且每 500ms 检查一次父进程还在不在 —— 父进程没了就退出，
    #   这样即使 kill 逻辑有漏，孤儿也会在 0.5 秒内自清。
    $myPid = $PID
    $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$myPid").ParentProcessId
    $deadline = (Get-Date).AddSeconds(600)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($parentId) {
            $p = Get-Process -Id $parentId -ErrorAction SilentlyContinue
            if (-not $p) { exit 0 }
        }
    }
    exit 0
}

if (-not $scrPath -or -not (Test-Path -LiteralPath $scrPath)) {
    Line '错误: 没有 /s 脚本'
    exit 1
}

# ── 读 scr → 找 drawing.lsp → 读 lisp 找产物路径 ─────────────────
$scr = $gbk.GetString([IO.File]::ReadAllBytes($scrPath))
$lspPath = $null
$m = [regex]::Match($scr, '\(load\s+"([^"]+)"\)')
if ($m.Success) { $lspPath = $m.Groups[1].Value }

$lsp = ''
if ($lspPath -and (Test-Path -LiteralPath $lspPath)) {
    $lsp = $gbk.GetString([IO.File]::ReadAllBytes($lspPath))
    Line '@@CADCORE=loaded@@'
}

$dwgOut = Get-LispTargetPath $lsp 'SAVEAS'
$dxfOut = Get-LispTargetPath $lsp 'SAVEDXF'
$pdfOut = Get-LispTargetPath $lsp 'PLOTPDF'

# ── 场景：LISP 报错 ──────────────────────────────────────────────
if ($scenario -eq 'lisp-error') {
    Line '命令:'
    Line '; 错误: 参数类型错误: stringp nil'
    Line '; 错误: 函数已取消'
    exit 0
}

# ── 写产物 ───────────────────────────────────────────────────────
$writer = {
    param($Path, [string]$Content, [int]$PadTo = 0)
    if (-not $Path) { return $false }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # SAVEAS 到已存在文件会卡住 —— 真 AutoCAD 的行为，这里也先删
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    [IO.File]::WriteAllBytes($Path, $bytes)
    if ($PadTo -gt $bytes.Length) {
        # 用 0 填充到指定大小，用来骗过 ">2000 字节" 这类体量检查
        $pad = New-Object byte[] ($PadTo - $bytes.Length)
        $fs = [IO.File]::Open($Path + '.tmp', [IO.FileMode]::Create)
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Write($pad, 0, $pad.Length) } finally { $fs.Dispose() }
        Move-Item -LiteralPath ($Path + '.tmp') -Destination $Path -Force
    }
    return $true
}

$wroteDwg = $false
$wroteDxf = $false
$wrotePdf = $false

if ($scenario -ne 'no-artifact') {
    if ($dwgOut) {
        $wroteDwg = & $writer $dwgOut 'AC1032mock-dwg-payload' 4000
    }
    if ($dxfOut) {
        if ($scenario -eq 'bad-dxf') {
            $wroteDxf = & $writer $dxfOut "0`nEOF`n"
        } else {
            $body = @(
                '0', 'SECTION', '2', 'HEADER',
                '9', '$ACADVER', '1', 'AC1032',
                '0', 'ENDSEC',
                '0', 'SECTION', '2', 'ENTITIES'
            ) + @('0', 'CIRCLE', '8', 'GEO', '10', '0.0', '20', '0.0', '40', '20.0') +
            @('0', 'ENDSEC', '0', 'EOF')
            $wroteDxf = & $writer $dxfOut ($body -join "`r`n") 3000
        }
    }
    if ($pdfOut) {
        if ($scenario -eq 'bad-pdf') {
            # 头对、体量够，但不是 PDF —— 用来验证「只看文件头」的检查也不够
            $wrotePdf = & $writer $pdfOut 'NOTAPDF-just-text' 2000
        } else {
            # 必须造一个结构完整的 PDF：真 accoreconsole 出的 PDF 有 %PDF 头、
            # 至少一个 /Type /Page、尾部 %%EOF。只写头会被 Test-CadPdfFile 判为截断，
            # 所以填充字节要插在 %%EOF 之前，而不是简单把整个内容 padding 到 2000。
            $head = "%PDF-1.7`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n" +
                    "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj`n" +
                    "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 842 595]>>endobj`n"
            $trailer = "trailer<</Root 1 0 R>>`nstartxref`n0`n%%EOF`n"
            $headBytes = [Text.Encoding]::UTF8.GetBytes($head)
            $tailBytes = [Text.Encoding]::UTF8.GetBytes($trailer)
            $padLen = [Math]::Max(0, 2000 - $headBytes.Length - $tailBytes.Length)
            $pad = New-Object byte[] $padLen
            $dir = Split-Path -Parent $pdfOut
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            if (Test-Path -LiteralPath $pdfOut) { Remove-Item -LiteralPath $pdfOut -Force }
            $fs = [IO.File]::Open($pdfOut, [IO.FileMode]::Create)
            try {
                $fs.Write($headBytes, 0, $headBytes.Length)
                $fs.Write($pad, 0, $pad.Length)
                $fs.Write($tailBytes, 0, $tailBytes.Length)
            } finally { $fs.Dispose() }
            $wrotePdf = $true
        }
    }
}

# ── 吐 marker ────────────────────────────────────────────────────
Line '@@SETUP=ok@@'
Line '@@LAYER=GEO@@'
Line '@@E0=line|mock@@'

if ($scenario -eq 'same-handle') {
    # 两个实体回同一个 handle —— 真 hatch 静默失败时就是这样
    Line '@@HATCH=pat=ANSI31 scale=2 handle=29F@@'
    Line '@@DIMRAD=c=60,60 r=20 handle=29F@@'
} else {
    Line '@@HATCH=pat=ANSI31 scale=2 handle=29F@@'
    Line '@@DIMRAD=c=60,60 r=20 handle=2B1@@'
}

Line '@@COUNT=12@@'

if ($scenario -eq 'dialog') {
    Write-Raw "*MessageBox* 是否替换已有文件？ >>>Responding: `r`n"
}

if ($wroteDwg -and $dwgOut) {
    Line ('@@SAVEAS=ok={0} size={1}@@' -f $dwgOut, (Get-Item -LiteralPath $dwgOut).Length)
}
if ($wroteDxf -and $dxfOut) {
    Line ('@@SAVEDXF=ok={0} ver=2018 size={1}@@' -f $dxfOut, (Get-Item -LiteralPath $dxfOut).Length)
}
if ($wrotePdf -and $pdfOut) {
    Line ('@@PLOTPDF=ok={0} size={1}@@' -f $pdfOut, (Get-Item -LiteralPath $pdfOut).Length)
}

if ($scenario -ne 'no-done') {
    Line '@@DONE@@'
}

Line '命令: _.QUIT'
exit 0
