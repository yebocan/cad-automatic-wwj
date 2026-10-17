# 协议与实现细节

这份文件讲「为什么这么实现」，以及各层之间的接口契约。要给 skill 加新能力时先读这里。

---

## 1. 整体架构

```
                 ┌──────────────────────────────┐
                 │  规格 JSON（spec.md）        │
                 └──────────────┬───────────────┘
                                │ CadCompiler.ps1
                                ▼
                 ┌──────────────────────────────┐
                 │  绘图 LISP（GBK）            │
                 │  (load cadcore.lsp) + 逐实体 │
                 └──────────────┬───────────────┘
                                │ + scr 包装（GBK）
                                ▼
                 ┌──────────────────────────────┐
                 │  script.scr                  │
                 └──────────────┬───────────────┘
                                │ accoreconsole /i <dwg> /s <scr>
                                ▼
                 ┌──────────────────────────────┐
                 │  stdout（UTF-16LE）          │
                 │  @@NAME=value@@ 回执          │
                 └──────────────┬───────────────┘
                                │ Get-CadConsoleDiagnostics + 独立校验
                                ▼
                 ┌──────────────────────────────┐
                 │  报告 JSON                   │
                 └──────────────────────────────┘
```

核心设计原则：**脚本的自述不算证据，独立核验产物才算。**

具体体现在 `Invoke-CadDraw` 的 `checks` 数组：不看 stdout 说成功就完事，而是去检查 DWG 字节数 > 2000、DXF 的 ENTITIES 段存在、PDF 头是 `%PDF`。

---

## 2. 分层职责

### 2.1 `CadCommon.ps1` — 基础设施（约 1030 行，27 个函数）

| 函数 | 职责 |
|---|---|
| `Find-CadExecutable` | 按 5 级优先级找可执行文件，返回 `{path, source}` |
| `Resolve-CadAccoreConsole` | 上者的特化，**返回对象不是字符串**（调用方要取 `.path`） |
| `Get-CadConfig` / `Save-CadConfig` | 配置读写 |
| `Initialize-CadState` | 一次性准备好配置/临时目录/登记表 |
| `Write-CadScr` / `Write-CadLsp` | **GBK + CRLF + 无 BOM** 写文件 |
| `ConvertTo-CadPath` | 反斜杠 → 正斜杠 |
| `Invoke-CadCoreConsole` | 执行器：起进程、收 stdout、超时、解析退出码 |
| `Get-CadConsoleDiagnostics` | 从 stdout 抓 `@@NAME=value@@`、LISP 错误、消息框、找不到文件 |
| `Get-CadMarker` | 从结果里取单个标记 |
| `Read-CadDxfPairs` / `Test-CadDxfFile` / `Get-CadDxfEntities` | DXF 解析（UTF-8 优先，回落 GBK） |
| `ConvertTo-CadDouble` | 安全数字转换，**非法返回 `$null` 不是 0** |
| `Get-CadDrawingInfo` | 图纸体检入口 |
| `Get-CadRegistry` / `Save-CadRegistry` / `Register-OwnedCadProcess` / `Unregister-OwnedCadProcess` / `Get-CadOwnedProcesses` / `Stop-OwnedCadProcess` / `Clear-StaleCadEntries` | 进程登记表 + owner 校验 |

**关键契约**：

```powershell
Resolve-CadAccoreConsole -Explicit 'F:\CAD\AutoCAD 2018\accoreconsole.exe'
# → @{ path = 'F:\CAD\AutoCAD 2018\accoreconsole.exe'; source = 'explicit' }

Invoke-CadCoreConsole -Script $scr -InputDwg $dwg -WorkingDirectory $wd -TimeoutSeconds 180
# → @{
#     exe, exeSource, script, inputDwg, workingDir,
#     exitCode, exitName, timedOut, durationMs,
#     stdoutFile, stderrFile, stdoutTail, stderrTail,
#     lispError, lispErrorLines, markers, messageBoxes, drawingNotFound, pid
#   }
```

`exitName` 取值：`success` / `drawing-not-found` / `crash` / `timeout` / `other`。

### 2.2 `CadCompiler.ps1` — 编译器

```powershell
Compile-CadSpec -Spec $spec -CoreLspPath $core
# → @{ lisp; entityCount; layers; entities; warnings }
```

`Compile-CadEntity -Entity -Index -DefaultLayer` 是单实体编译，返回 LISP 片段。

**错误处理契约**：编译错误**不抛异常**，记进 `warnings` 并跳过该实体。这样「一个坏实体不会让整张图不画」。

```powershell
# 典型 warning
# entities[1] 编译失败：entities[1](bad-type) 未知 type: 'bad-type'（支持：line/...）
```

`Get-CadField -Object -Name -Default` 是 StrictMode 下取可选字段的唯一正确方式 —— 直接 `$obj.foo` 在字段缺失时会抛。

### 2.3 `cadcore.lsp` — LISP 运行时（51 个 `c:XXX`）

按功能分组：

| 组 | 函数 |
|---|---|
| 初始化 | `c:SETUP` `c:LAYER` |
| 基本图元 | `c:LINE` `c:PLINE` `c:CIRCLE` `c:ARC` `c:RECT` `c:ELLIPSE` `c:POINT` `c:SPLINE` |
| 文字 | `c:TEXT` `c:TEXTC` `c:MTEXT` |
| 标注 | `c:DIMLIN` `c:DIMALIGN` `c:DIMRAD` |
| 填充 | `c:HATCH` `c:SOLID` |
| 编辑 | `c:MOVEALL` `c:COPYLAST` `c:ROTATEALL` `c:SCALEALL` `c:MIRRORALL` `c:ARRAYRECT` `c:OFFSET` `c:FILLET` `c:EXPLODEALL` |
| 选择/删除 | `c:SSBYTYPE` `c:DELTYPE` `c:DELLAYER` |
| 块 | `c:MAKEBLOCK` `c:INSERTBLOCK` |
| 查询 | `c:COUNT` `c:TYPESTAT` `c:LAYERLIST` `c:EXTENTS` `c:ENTLIST` `c:GETVAR` `c:SUMMARY` `c:AREA` |
| 存盘/输出 | `c:SAVEAS` `c:SAVEDXF` `c:PLOTPDF` |
| 维护 | `c:PURGEALL` `c:AUDIT` `c:ZOOMEXT` `c:REGENALL` |
| 机械件 | `c:GEAR` `c:POLYGON` `c:CENTERLINE` `c:BOLTPATTERN` |

**LISP 函数必须给全部实参。** 没有默认值。

查签名：

```powershell
Select-String -Path .\cadcore.lsp -Pattern '^\(defun (c:\w+) \(([^)]*)\)' |
    ForEach-Object { "$($_.Matches[0].Groups[1].Value)($($_.Matches[0].Groups[2].Value))" }
```

### 2.4 三个辅助函数

```lisp
(cadcmd lst)         ; 把 lst 传给 (command ...) 并逐项打印，便于调试
(cadsay name value)  ; 输出 @@name=value@@
(cadnum x)           ; 数字转字符串；仅当原值有小数点时才剥尾零
```

`cadnum` 曾经无条件剥尾零，导致整数 100 变成 `"1"` —— 回执里的证据字符串骗人。现在只在 `"1.0"` 这种形态下剥。

---

## 3. 编码协议（最容易出错的地方）

| 文件 | 编码 | 理由 |
|---|---|---|
| `.lsp` | **GBK (936)** | accoreconsole 按系统代码页解释源码 |
| `.scr` | **GBK (936)** | 同上 |
| `.dxf`（AC1032） | **UTF-8 无 BOM** | 文件体规范 |
| stdout 重定向文件 | **UTF-16LE** | accoreconsole 自己决定 |
| 配置文件 | UTF-8 | 我们自己读写 |
| `cadcore.lsp` 源文件（在 skill 目录） | UTF-8 无 BOM | 给 git/编辑器用 |

**跨层传递时的铁律**：从 skill 目录读 UTF-8 → `Write-CadLsp` 转 GBK 写到工作目录 → 只 load 工作目录的副本。

```powershell
$coreSrc = [IO.File]::ReadAllText($scriptDir\cadcore.lsp, [Text.Encoding]::UTF8)
Write-CadLsp -Path $work\cadcore.lsp -Body $coreSrc
# LISP 里 load 的是 $work\cadcore.lsp
```

`run-unit-test.ps1` 第 2 分区专门测这条：UTF-8 无 BOM 被识别、GBK 不被误判、`Write-CadLsp` 往返一致、不含 BOM、使用 CRLF。

---

## 4. 回执协议

LISP 侧输出两种形态：

```
@@NAME=value@@    有值
@@NAME@@          无值（纯信号）
```

`Get-CadConsoleDiagnostics` 用两条正则分别匹配（**只匹配有值分支会漏掉 `@@DONE@@`**）：

```powershell
'@@([A-Za-z0-9_.\-]+)=([^@]*)@@'   # 有值
'@@([A-Za-z0-9_.\-]+)@@'           # 无值
```

实际样本：

```
@@CADCORE=loaded@@
@@SETUP=ok@@
@@LAYER=GEO@@
@@E0=line|27D@@
@@ARC=c=100,60 r=30 0->180 handle=281@@
@@DIMLIN=p1=0,0 p2=200,0 handle=296@@
@@DIMALIGN=FAILED-entmake-nil@@
@@HATCH=pat=ANSI31 scale=2 handle=29F@@
@@COUNT=25@@
@@SAVEAS=ok=<path> size=36718@@
@@SAVEDXF=ok=<path> ver=2013 size=125759@@
@@PLOTPDF=ok=<path> paper=ISO A3 (420.00 x 297.00 毫米) size=91684@@
@@DONE@@
```

**两条判读铁律**：

1. `FAILED-` 前缀是失败，`ok=` 才是成功
2. **同一个 handle 出现在两个回执里 → 后者没创建**（`entlast` 在命令静默失败时返回上一个实体）

---

## 5. 退出码协议

### 我们的脚本

| 码 | `status` | 含义 |
|---|---|---|
| `0` | `ok` / `dry-run` | 成功 |
| `3` | `partial` | 部分产物落地 |
| `1` | `failed` | 失败 |

### accoreconsole

| 码 | `exitName` | 判据 |
|---|---|---|
| `0` | `success` | — |
| `76` | `drawing-not-found` | `/i` 指向的 dwg 不存在；stdout 有「找不到指定的图形文件」 |
| — | `timeout` | 我们主动 kill（`timedOut=true`） |
| 其它 | `crash` / `other` | 见 stdout 尾部 |

---

## 6. 进程安全协议

本 skill 会启动 `accoreconsole.exe` 子进程。为了防止误杀用户自己的 AutoCAD，有一套登记表：

```json
[
  {
    "pid": 12345,
    "kind": "accoreconsole",
    "source": "Invoke-CadDraw",
    "owner_pid": 6789,
    "started_at": "2026-10-17T14:28:24.1234567+08:00"
  }
]
```

`Stop-OwnedCadProcess -ProcessId 12345 -OwnerPid 6789` 的拒绝条件（返回 `refused` 对象，不抛异常）：

| `ownerCheck` | 含义 |
|---|---|
| `ok` | 可以杀 |
| `no-registry-entry` | 这个 pid 没登记过 —— 不是我们启动的 |
| `caller-not-owner:entry=26740;caller=39085` | 登记的是别人启动的 |
| `owner-dead` | 启动它的进程已经不在了 |
| `not-same-name:...` | pid 被复用了，现在跑的不是 accoreconsole |
| `started_at mismatch: Δ=Ns` | pid 复用，启动时间差太多 |
| `starttime-unreadable` | 读不到 StartTime，保守拒绝 |

这是**有意设计的拒绝**，不是 bug。

`run-test.ps1` 收尾时也只统计 `StartTime -ge $runStartedAt` 的进程 —— 用户本来就开着的实例不算失败。

---

## 7. 命令通道选择：`cadcmd` vs `entmake` vs `(c:XXX)`

| 实体 | 通道 | 理由 |
|---|---|---|
| `line` `rect` `polyline` `circle` `spline` `solid` `text` | `cadcmd` | 命令稳定，提示序列固定 |
| `arc` `ellipse` `point` `polygon` `gear` `boltpattern` `centerline` | `(c:XXX)` | 命令提示跨版本不一致，包成函数更可控 |
| `dimlinear` `dimaligned` `dimradius` | `entmake` | 命令要选择对象，accoreconsole 里容易「无效选择」吞后续命令 |
| `mtext` | `entmake` | **命令会弹对话框，无 UI 就永远悬住** |
| `hatch` | `cadcmd` + `setvar` | 见 troubleshooting 4.1 |
| `block` | `(c:INSERTBLOCK)` | 六实参一次给全 |

**选通道的判断标准**：

1. 会不会弹对话框？会 → 必须 `entmake`
2. 要不要选择对象？要 → 优先 `entmake`（accoreconsole 的选择集容易出错）
3. 提示序列跨版本稳定吗？不稳定 → 包 `(c:XXX)`
4. 以上都没有 → `cadcmd` 最直白

---

## 8. 校验协议（为什么不信脚本自述）

`Invoke-CadDraw` 的 `checks` 全部是**独立核验**，不读 stdout 的自述：

| 检查 | 方法 |
|---|---|
| DWG 落地 | `(Get-Item $dwg).Length -gt 2000` |
| DXF 结构有效 | `Test-CadDxfFile` 解析文件体，要求有 `ENTITIES` 段 |
| PDF 落地 | 读前 4 字节是不是 `%PDF` |
| 回执到位 | `Get-CadMarker -Name 'DONE'` 非空 |
| 实体数合理 | DXF 里数出来的实体数与 JSON 声明数做差额比对（差额只 warn） |

`run-test.ps1` 更进一步：出图后用 `Invoke-CadInspect.ps1` **独立打开产物再数一遍**（`-SkipCrossCheck` 可跳过）。这一步能抓住「DWG 写出来了但是空的」这类问题。

---

## 9. 超时闸

两层：

1. **单次执行**：`Invoke-CadCoreConsole -TimeoutSeconds`（默认 180）。到点 `Stop-Process` 并置 `timedOut=true`。
2. **总体预算**：`run-test.ps1` 的 `$script:deadline` + `Assert-Budget($stage, $need)`。每个例程开始前预估自己需要多少秒，不够就跳过并记 fail。

```powershell
Assert-Budget '出图' 60      # 剩余不足 60 秒时直接抛
```

accoreconsole 冷启动 20–60 秒是硬开销，所以预算要留足。

---

## 10. 加新实体类型的步骤

1. **`cadcore.lsp`** 加 `(defun c:NEWTHING (...) ...)`，末尾 `(cadsay "NEWTHING" ...)`
   - 如果命令通道够用，也可以不加 LISP，直接在编译器里 `cadcmd`
2. **`CadCompiler.ps1`** 的 `switch ($type)` 加分支，用 `Get-CadField` 取字段，用 `Format-LispNum`/`Format-LispPoint`/`Format-LispString` 格式化
3. **`run-unit-test.ps1`** 第 5 分区加断言（用 `Test-Entity` 辅助函数）
4. **`run-unit-test.ps1`** 第 13 分区的函数清单数组里加名字
5. **`references/spec.md`** 加字段表
6. 跑 `run-unit-test.ps1`（115 项应全过）和 `run-test.ps1 -Test draw`

第 4 步容易忘 —— 忘了会让「51 个 LISP 函数都存在」这项检查漏掉新函数。

---

## 11. 已知限制

| 限制 | 说明 |
|---|---|
| 只支持 AutoCAD | accoreconsole 是 Autodesk 独有的；不支持 BricsCAD / ZWCAD / DraftSight |
| 只支持 Windows | accoreconsole 无 macOS/Linux 版 |
| 齿轮是近似的 | `c:GEAR` 用 LWPOLYLINE 画梯形齿，不是真渐开线 |
| 不支持动态块参数 | 只能插入静态块 |
| 不支持图层过滤器/布局视口 | 需要 `-PLOT` 之外的复杂配置 |
| `.lsp` 源文件必须 UTF-8 无 BOM | 有 BOM 会被 `Write-CadLsp` 原样带进 GBK 副本（`ReadAllText` 会剥 BOM，所以实际安全，但别依赖这个） |
| 单进程单图 | accoreconsole 一个实例只能开一个 dwg。批量处理要串行开多次进程，或者把所有操作塞进一个 scr |
| COM 通道慢 25 秒 | `New-Object -ComObject "AutoCAD.Application.22"` 冷启动实测约 25 秒，只在必要场景用 |
