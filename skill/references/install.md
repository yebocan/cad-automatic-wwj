# 安装与配置

本 skill 靠 `accoreconsole.exe`（AutoCAD 核心引擎控制台）驱动绘图，不需要打开 AutoCAD 界面，也不需要 COM。
另有 `Invoke-CadCom.ps1` 走 COM 通道（需要装完整 AutoCAD），用于必须用 COM 才能做的事。

---

## 1. 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| Windows | 10 / 11 / Server 2016+ | accoreconsole 只在 Windows 上 |
| PowerShell | **7.0+**（`pwsh`） | Windows PowerShell 5.1 也能跑大部分，但 `ConvertTo-Json` 的空数组行为不同，未做兼容 |
| AutoCAD | **2018 或更高** | 需要 `accoreconsole.exe` |
| 磁盘 | ≥ 200 MB 临时空间 | 每次执行会在 `%TEMP%` 建工作目录 |

**不需要**：
- 不需要 AutoCAD 正在运行
- 不需要许可证激活到「可交互」状态（accoreconsole 用同一套许可，但不需要 GUI 会话）
- 不需要 `.NET SDK`、不需要 VS、不需要装任何 NuGet 包

---

## 2. 定位 accoreconsole

### 2.1 自动探测（推荐）

```powershell
.\Set-CadPath.ps1 -Auto -Show
```

它会：

1. 读环境变量 `CAD_ACCORECONSOLE`
2. 读配置文件（`%APPDATA%\cad-automatic-wwj\config.json`）
3. 扫常见安装根：`C:\Program Files\Autodesk\`、`D:\`、`E:\`、`F:\`、`G:\` 下的 `AutoCAD*` 目录
4. 最后查 `PATH`

输出形如：

```
  accoreconsole.exe  F:\CAD\AutoCAD 2018\accoreconsole.exe   (来源: scan:F:\CAD)
  acad.exe           F:\CAD\AutoCAD 2018\acad.exe            (来源: scan:F:\CAD)
  COM ProgID         AutoCAD.Application.22
```

### 2.2 手工指定

```powershell
# 只指定 accoreconsole
.\Set-CadPath.ps1 -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe"

# 同时指定 acad.exe（COM 通道要用）与 ProgID
.\Set-CadPath.ps1 -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe" `
                  -AcadExe       "F:\CAD\AutoCAD 2018\acad.exe" `
                  -ComProgId     "AutoCAD.Application.22"
```

写入后的配置文件长这样：

```json
{
  "accoreconsole": "F:\\CAD\\AutoCAD 2018\\accoreconsole.exe",
  "acadExe": "F:\\CAD\\AutoCAD 2018\\acad.exe",
  "comProgId": "AutoCAD.Application.22",
  "configuredAt": "2026-10-17T14:29:08.1234567+08:00"
}
```

### 2.3 环境变量（适合 CI）

```powershell
$env:CAD_ACCORECONSOLE = 'F:\CAD\AutoCAD 2018\accoreconsole.exe'
$env:CAD_ACAD          = 'F:\CAD\AutoCAD 2018\acad.exe'
```

优先级：**显式参数 > 环境变量 > 配置文件 > 扫盘 > PATH**。
每一条脚本的报告里都有 `exeSource` 字段告诉你这次实际用了哪一级（`explicit` / `env:CAD_ACCORECONSOLE` / `config` / `scan:F:\CAD` / `path`）。

### 2.4 清空

```powershell
.\Set-CadPath.ps1 -Clear
```

---

## 3. 验证安装

```powershell
# 只看环境，不画图。3 秒内返回。
.\run-test.ps1 -Test draw
```

期望全部 `[PASS]`：

```
── 0. 环境 ───────────────────────────────────────────────────────────────
[PASS] accoreconsole 可定位 — F:\CAD\AutoCAD 2018\accoreconsole.exe（来源 config）
[PASS] cadcore.lsp 存在 — cadcore.lsp
[PASS] cadcore.lsp 源文件无 BOM — bytes=34447
[PASS] 无遗留登记进程 — count=0
...
  集成自检  ·  19 / 19 通过，0 失败
```

全套（出图/体检/导出/打印/修复）：

```powershell
.\run-test.ps1 -Test all      # 约 15 秒
```

离线单测（不需要 AutoCAD，只测纯逻辑）：

```powershell
.\run-unit-test.ps1           # 115 项，约 8 秒
```

---

## 4. 把 skill 注册给 DSH / Claude Code 等

skill 目录结构必须是：

```
<skills-root>\cad-automatic-wwj\
    SKILL.md
    agents\openai.yaml
    references\*.md
    scripts\*.ps1
    scripts\cadcore.lsp
    assets\samples\*.json
```

**DSH**：

```powershell
.\Install-Skill.ps1
```

它会把本仓库的 `skill\` 复制到 `%USERPROFILE%\.dsh\skills\cad-automatic-wwj\`。
可以用 `-Destination` 指定别的位置，`-Force` 覆盖已有安装。

**手工安装**：

```powershell
$dst = "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj"
New-Item -ItemType Directory -Path $dst -Force
Copy-Item .\skill\* $dst -Recurse -Force
```

---

## 5. 目录与临时文件

| 路径 | 用途 |
|---|---|
| `%APPDATA%\cad-automatic-wwj\config.json` | 路径配置 |
| `%APPDATA%\cad-automatic-wwj\processes.json` | 进程登记表（防误杀别人的进程） |
| `%TEMP%\cad-automatic-wwj\accore_stdout_<stamp>.txt` | 每次执行的 stdout（**UTF-16LE**） |
| `%TEMP%\cad-automatic-wwj\accore_stderr_<stamp>.txt` | stderr |
| `%TEMP%\cad-automatic-wwj\work_<stamp>_<rand>\` | 单次执行的工作目录（`-KeepArtifacts` 才保留） |
| `%TEMP%\cad-integration-tests\run_<stamp>\` | 集成自检产物与 `report.json` |
| `%TEMP%\cad-unit-tests\` | 单元测试工作目录 |

清理：

```powershell
# 清遗留工作目录（正常执行会自动删，异常退出会留下）
Remove-Item "$env:TEMP\cad-automatic-wwj\work_*" -Recurse -Force -ErrorAction SilentlyContinue
```

---

## 6. 版本对应的 ProgID

如果要用 `Invoke-CadCom.ps1`，ProgID 必须对：

| AutoCAD 版本 | ProgID |
|---|---|
| 2013 | `AutoCAD.Application.19` |
| 2014 | `AutoCAD.Application.19.1` |
| 2015 | `AutoCAD.Application.20` |
| 2016 | `AutoCAD.Application.20.1` |
| 2017 | `AutoCAD.Application.21` |
| **2018** | **`AutoCAD.Application.22`** |
| 2019 | `AutoCAD.Application.23` |
| 2020 | `AutoCAD.Application.23.1` |
| 2021 | `AutoCAD.Application.24` |
| 2022 | `AutoCAD.Application.24.1` |
| 2023 | `AutoCAD.Application.24.2` |
| 2024 | `AutoCAD.Application.24.3` |

查本机实际注册了哪个：

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Classes\AutoCAD.Application.*' |
    Select-Object PSChildName
```

> 本机实测：只有 `AutoCAD.Application.22`，**没有** `AutoCAD.Application`（无版本号）也没有 `CurVer` 别名。
> 所以 `New-Object -ComObject "AutoCAD.Application"` 在本机会失败，必须写 `.22`。

---

## 7. 常见安装问题

### 「输入图纸不存在」+ exit 76

`accoreconsole /i <file>` 指向不存在的 dwg 时会 exit 76 并弹消息框：

```
找不到指定的图形文件 ...
```

脚本已经把这个情况分类成 `drawingNotFound=true`（不是笼统的 exitCode 非零），报告里能直接看出来。

### 首次执行很慢（20–60 秒）

accoreconsole 每次启动都要加载整个 AutoCAD 核心。这是硬开销，跟图纸大小无关。
一个图要连做「出图 → 体检 → 导出 → 打印」，就开 4 次进程 = 4 次冷启动。

优化办法：**在同一个 scr 里串起来**。`run-test.ps1` 就是这么做的（15 秒跑完 5 个例程）。

### 杀毒软件拦截

accoreconsole 会写临时文件、启动子进程，某些国产杀软会拦。加白名单：

```
%TEMP%\cad-automatic-wwj\
F:\CAD\AutoCAD 2018\accoreconsole.exe
```

### 多版本 AutoCAD 并存

配置里只存一份路径。需要切换版本时用 `-AccoreConsole` 显式指定，或改环境变量。**不要**在同一台机器上让两个版本交替用配置文件 —— 容易互相覆盖。
