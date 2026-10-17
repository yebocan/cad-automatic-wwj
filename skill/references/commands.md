# 命令清单

所有脚本都在 `scripts\` 下，都用 `pwsh` 跑。共同惯例：

- 加 `-AsJson` → 输出单个 JSON 对象（无人类可读输出），适合被程序吃
- 不加 `-AsJson` → 人类可读的对齐文本
- 退出码：`0` = ok / dry-run，`3` = partial，`1` = failed

---

## 1. `Set-CadPath.ps1` — 配置路径

```powershell
.\Set-CadPath.ps1 [-AccoreConsole <path>] [-AcadExe <path>] [-ComProgId <id>]
                  [-Auto] [-Show] [-Clear] [-AsJson]
```

| 参数 | 说明 |
|---|---|
| `-AccoreConsole` | 显式指定 accoreconsole.exe |
| `-AcadExe` | 显式指定 acad.exe（COM 通道用） |
| `-ComProgId` | 显式指定 COM ProgID，如 `AutoCAD.Application.22` |
| `-Auto` | 自动探测并写入配置 |
| `-Show` | 只显示当前配置与生效来源，不写 |
| `-Clear` | 删除配置文件 |
| `-AsJson` | JSON 输出 |

```powershell
.\Set-CadPath.ps1 -Auto -Show
.\Set-CadPath.ps1 -Clear
```

---

## 2. `Invoke-CadDraw.ps1` — 出图（主入口）

```powershell
.\Invoke-CadDraw.ps1 [-SpecFile <json>] [-SpecJson <string>] [-OutputDir <dir>]
                     [-Dwg <path>] [-DryRun] [-KeepArtifacts] [-AsJson]
                     [-TimeoutSeconds <int=180>]
```

| 参数 | 说明 |
|---|---|
| `-SpecFile` | JSON 规格文件路径 |
| `-SpecJson` | 直接给 JSON 字符串（与 `-SpecFile` 二选一，`-SpecJson` 优先） |
| `-OutputDir` | 工作/产物目录。默认在 `%TEMP%` 下建 |
| `-Dwg` | 覆盖 spec 里的 `save.dwg` |
| `-DryRun` | 只编译 + 生成 LISP/scr，不执行 accoreconsole。用于检查 spec 是否合法 |
| `-KeepArtifacts` | 保留工作目录（里面的 `.lsp`/`.scr` 是排错关键） |
| `-TimeoutSeconds` | 单次 accoreconsole 超时，默认 180 |

**报告字段**：

```json
{
  "status": "ok",                  // ok | partial | failed | dry-run
  "drawing": "D:\\...\\plan.dwg",
  "entityCount": 12,               // JSON 声明数
  "layers": ["GEO","HOLE","DIM","TXT"],
  "artifacts": { "dwg": "...", "dxf": "...", "pdf": "..." },
  "checks": [ { "name": "DWG 落地", "pass": true, "detail": "37484 字节" } ],
  "warnings": [],
  "error": null,
  "logDir": "C:\\Users\\...\\work_20261017_...",
  "durationMs": 4398,
  "exitCode": 0,
  "exitName": "success",
  "timedOut": false,
  "markers": { "CADCORE": "loaded", "SETUP": "ok", "COUNT": "25", "DONE": "" }
}
```

- `checks[].pass` 是 **`pass`** 不是 `passed`
- `markers` 是从 stdout 里抓的 `@@NAME=value@@` / `@@NAME@@` 回执
- `exitName` 是 accoreconsole 退出码的语义名：`success` / `drawing-not-found` / `crash` / `timeout` / `other`

```powershell
# 标准用法
.\Invoke-CadDraw.ps1 -SpecFile .\flange.json -OutputDir .\out -AsJson

# 只编译不画
.\Invoke-CadDraw.ps1 -SpecFile .\flange.json -DryRun

# 内联 JSON
.\Invoke-CadDraw.ps1 -SpecJson '{"entities":[{"type":"circle","c":[0,0],"r":10}]}' -OutputDir .\out
```

---

## 3. `Invoke-CadInspect.ps1` — 图纸体检

```powershell
.\Invoke-CadInspect.ps1 -Path <dwg|dxf> [-Entities] [-Limit <int=200>] [-AsJson]
                        [-TimeoutSeconds <int=120>]
```

| 参数 | 说明 |
|---|---|
| `-Path` | **必填**。`.dxf` 直接解析；`.dwg` 先转临时 DXF 再解析（约 4 秒） |
| `-Entities` | 在报告里带实体明细列表 |
| `-Limit` | 实体明细上限，默认 200 |

**报告字段**：

```json
{
  "status": "ok",
  "path": "D:\\...\\plan.dwg",
  "format": "dwg",                 // dxf | dwg
  "valid": true,
  "entityCount": 25,
  "entityTypes": { "CIRCLE": 9, "LWPOLYLINE": 4, "LINE": 3, "DIMENSION": 3, ... },
  "layers": ["0","GEO","HOLE","CENTER","DIM","TXT"],
  "extents": { "minX": 0, "minY": -15, "maxX": 275, "maxY": 106.78 },
  "blockCount": 5,
  "sections": ["HEADER","TABLES","BLOCKS","ENTITIES","OBJECTS"],
  "version": "AC1032",
  "entities": [ { "type": "CIRCLE", "layer": "GEO", "handle": "27D", "x": 100, "y": 60, "radius": 30 } ],
  "warnings": [],
  "error": null,
  "durationMs": 3721
}
```

注意格式字段是 **`format`**（`dxf`/`dwg`），不是 `source`。

```powershell
.\Invoke-CadInspect.ps1 -Path .\out\plan.dwg -Entities -AsJson
```

---

## 4. `Export-CadToDxf.ps1` — DWG → DXF

```powershell
.\Export-CadToDxf.ps1 -Path <dwg> [-Output <dxf>] [-Version <版本>] [-AsJson]
                      [-TimeoutSeconds <int=120>]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Path` | **必填** | 源 DWG |
| `-Output` | 同名 `.dxf` | 目标路径 |
| `-Version` | `2018` | 白名单：`2018`/`2013`/`2010`/`2007`/`2004`/`R12` |

**报告字段**：

```json
{
  "status": "ok",
  "source": "...\\plan.dwg",
  "output": "...\\plan.dxf",
  "version": "R12",
  "bytes": 27518,
  "valid": true,
  "entityCount": 21,
  "warnings": [],
  "error": null,
  "durationMs": 4102
}
```

实测版本对应（用文件头 `AC10xx` 校验）：

| `-Version` | 文件头 |
|---|---|
| `R12` | `AC1009` |
| `2004` | `AC1018` |
| `2007` | `AC1021` |
| `2010` | `AC1024` |
| `2013` | `AC1027` |
| `2018` | `AC1032` |

```powershell
.\Export-CadToDxf.ps1 -Path .\out\plan.dwg -Version R12 -AsJson
```

---

## 5. `Invoke-CadPlot.ps1` — 打印 PDF

```powershell
.\Invoke-CadPlot.ps1 -Path <dwg> [-Output <pdf>] [-PaperSize <尺寸>]
                     [-Orientation <Landscape|Portrait>] [-PlotArea <Extents|Limits|Display>]
                     [-AsJson] [-TimeoutSeconds <int=120>]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Path` | **必填** | 源 DWG |
| `-Output` | 同名 `.pdf` | 目标路径 |
| `-PaperSize` | `A3` | `A0`/`A1`/`A2`/`A3`/`A4`/`B`/`C`/`D`/`E` |
| `-Orientation` | `Landscape` | `Landscape` / `Portrait` |
| `-PlotArea` | `Extents` | `Extents` / `Limits` / `Display` |

**报告字段**：

```json
{
  "status": "ok",
  "source": "...\\plan.dwg",
  "output": "...\\plan.pdf",
  "bytes": 88325,
  "paperSize": "A3",
  "orientation": "Portrait",
  "plotArea": "Extents",
  "warnings": [],
  "error": null,
  "durationMs": 5021
}
```

实现走 `-PLOT` + `DWG To PDF.pc3`。**accoreconsole 里没有 `EXPORTPDF`/`PDF` 命令**（实测回「未知命令"PDF"」）。

`-PLOT` 的提示序列是严格固定的 15 步，多一个少一个都会错位到别的提示上（错位后 AutoCAD 会把 `_M` 当成命令名，吐一串「未知命令"M"」且不报错退出）。

```powershell
.\Invoke-CadPlot.ps1 -Path .\out\plan.dwg -PaperSize A2 -Orientation Landscape
```

---

## 6. `Invoke-CadCom.ps1` — COM 通道

```powershell
.\Invoke-CadCom.ps1 -Action <Info|Draw|Open|Export|Quit>
                    [-SpecFile <json>] [-Path <dwg>] [-Output <pdf>]
                    [-PaperSize <尺寸>] [-StyleTable <monochrome.ctb|none>]
                    [-Visible] [-KeepOpen] [-AsJson] [-TimeoutSeconds <int=180>]
```

| Action | 说明 |
|---|---|
| `Info` | 连接 COM，报版本/文档数/当前文档 |
| `Draw` | 用 spec 通过 COM 画（`ModelSpace.AddLine` 等 API，不走命令行） |
| `Open` | 打开图纸 |
| `Export` | 导出 PDF |
| `Quit` | 退出 AutoCAD |

| 参数 | 说明 |
|---|---|
| `-Visible` | 显示 AutoCAD 窗口（默认 `Visible=$false`，后台跑） |
| `-KeepOpen` | 执行完不 `Quit`（默认会 Quit 并 `ReleaseComObject`） |

**什么时候才该用 COM**：

- 需要读/写 AutoCAD 的 `Application` 级对象（`Preferences`、`Documents` 集合）
- 需要 `SendCommand` 之外的低层 API（`ModelSpace.AddCircle` 之类直接构造对象）
- 需要在 `acad.exe` 已经打开的图形上操作

**什么时候不该用**：

- 只是画图 / 导出 → 用 `Invoke-CadDraw.ps1`，比 COM 快 10 倍以上（COM 冷启动约 25 秒）
- 需要确定性的退出码与 stdout 证据 → COM 没有 stdout，只有 COM 异常

```powershell
.\Invoke-CadCom.ps1 -Action Info -AsJson
.\Invoke-CadCom.ps1 -Action Draw -SpecFile .\flange.json -AsJson
```

---

## 7. `Invoke-CadRepair.ps1` — 修复

```powershell
.\Invoke-CadRepair.ps1 [-SpecFile <json>] [-Path <dwg>] [-DryRun] [-AsJson]
                       [-TimeoutSeconds <int=180>]
```

| 参数 | 说明 |
|---|---|
| `-SpecFile` | 出图用的 spec（用于核对产物是否落地） |
| `-Path` | 直接给目标 dwg |
| `-DryRun` | 只诊断，不动手（报告里 `mode='dry-run'`） |

**报告字段**：

```json
{
  "status": "repaired",            // ok | repaired | dry-run | failed
  "mode": "repair",                // repair | dry-run
  "target": "...\\plan.dwg",
  "findings": [
    {
      "id": "zero-byte-dwg",
      "severity": "blocker",
      "detail": "DWG 存在但 0 字节",
      "repairable": true,
      "repaired": true,
      "action": "已删除"
    }
  ],
  "warnings": [],
  "error": null,
  "durationMs": 312
}
```

会检查并修的：

| id | 触发条件 | 修复动作 |
|---|---|---|
| `zero-byte-dwg` | DWG 存在但 0 字节 | 删除 |
| `stale-work-dir` | `%TEMP%\cad-automatic-wwj\work_*` 遗留 | 删除 |
| `stale-process-entry` | 登记表里有已死进程 | 清理条目 |
| `orphan-accoreconsole` | 有本 skill 启动但未退出的 accoreconsole | 结束（有 owner 校验） |
| `missing-artifact` | spec 声明要 DXF/PDF 但产物不在 | 报告，不自动重跑 |
| `corrupt-dxf` | DXF 结构无效（缺 ENTITIES 段等） | 报告 |

```powershell
.\Invoke-CadRepair.ps1 -SpecFile .\flange.json -DryRun -AsJson
.\Invoke-CadRepair.ps1 -SpecFile .\flange.json
```

---

## 8. `run-test.ps1` — 集成自检

```powershell
.\run-test.ps1 [-Test <all|draw|inspect|export|plot|repair>]
               [-OutputDirectory <dir>] [-AccoreConsole <path>]
               [-TimeoutSeconds <int=900>] [-SkipCrossCheck] [-KeepArtifacts]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Test` | `all` | 跑哪几个例程 |
| `-OutputDirectory` | `%TEMP%\cad-integration-tests` | 产物根 |
| `-SkipCrossCheck` | — | 跳过「出图后独立复核」这一步（省约 4 秒） |
| `-KeepArtifacts` | — | 保留工作目录 |

例程与断言数：

| 例程 | 断言数 | 内容 |
|---|---|---|
| 0 环境 | 4 | accoreconsole 可定位 / cadcore.lsp 存在无 BOM / 无遗留进程 |
| 1 出图 | 12 | 12 实体 → DWG+DXF+PDF 三产物、回执、交叉复核、中文未乱码 |
| 2 体检 | 7 | DXF 与 DWG 两条路径各自 status/entityCount/layers/extents |
| 3 导出 | 6 | 2018 与 R12 两个版本，各自落地+结构有效+版本行 |
| 4 打印 | 3 | status / paperSize+orientation / PDF 魔数 |
| 5 修复 | 8 | 造 0 字节 DWG 与遗留目录，验证识别+修复+DryRun 不动手 |
| 6 收尾 | 2 | 无残留登记进程 / 本轮无残留 accoreconsole |

`-Test all` = **43 项断言，约 15 秒**。

报告写到 `<OutputDirectory>\run_<stamp>\report.json`。

收尾判残留时只统计 `StartTime -ge $runStartedAt` 的 accoreconsole —— 你本来就开着的实例不会被算成失败，会单独打「提示」。

---

## 9. `run-unit-test.ps1` — 离线单测

```powershell
.\run-unit-test.ps1 [-WorkDirectory <dir>]
```

**不需要 AutoCAD**，只测纯逻辑。**115 项，约 8 秒**。

15 个分区：

| # | 分区 | 内容 |
|---|---|---|
| 1 | 路径解析 | 优先级（显式>环境>配置>扫盘>PATH）与来源标注 |
| 2 | 编码 | GBK/UTF-8 判定、`Write-CadLsp` 写 GBK 无 BOM CRLF |
| 3 | 路径转换 | 反斜杠转正斜杠 |
| 4 | 数值格式化 | `Format-LispNum`/`Format-LispPoint`/`Format-LispString` |
| 5 | 编译器实体 | 20 种类型逐一出 LISP 并核对通道 |
| 6 | 图层处理 | 三实参、自动补建、warning |
| 7 | 错误路径 | 缺字段/未知类型/非数值 → warning 不抛 |
| 8 | `Get-CadField` | StrictMode 下安全访问 |
| 9 | DXF 解析 | 成对读取、结构校验、编码回落、数字转换 |
| 10 | 进程登记表 | 写入/清理/owner 校验拒杀 |
| 11 | 括号平衡 | 跳过字符串与注释 |
| 12 | 图纸尺寸名 | `cadpaper` 映射 |
| 13 | LISP 函数存在性 | 51 个 `c:XXX` 齐不齐 |
| 14 | 配置文件 | 读写往返 |
| 15 | `Get-CadMarker` | 解析 `@@NAME=value@@` |

---

## 10. `run-scenario-test.ps1` — 场景测试

```powershell
.\run-scenario-test.ps1 [-Scenario <name|all>] [-Mode <real|mock|offline>]
                        [-OutputDirectory <dir>] [-TimeoutSeconds <int=1200>]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Scenario` | `all` | 场景名或 `all` |
| `-Mode` | `real` | `real` 真跑 AutoCAD / `mock` 用假 accoreconsole / `offline` 完全不执行 |

`mock` 模式：用一个 `fake-accoreconsole.ps1` 冒充 accoreconsole，按预置脚本吐 stdout、写产物、给退出码。用来验证「脚本对 accoreconsole 输出的解析」不依赖真机。

`offline` 模式：只编译、只检查 LISP 文本，不执行任何进程。

---

## 11. 环境变量速查

| 变量 | 作用 |
|---|---|
| `CAD_ACCORECONSOLE` | accoreconsole.exe 路径（优先级高于配置文件） |
| `CAD_ACAD` | acad.exe 路径 |
| `CAD_COM_PROGID` | COM ProgID |
| `CAD_STDOUT_KEEP` | 设 `1` 则保留 stdout 文件（默认保留，设 `0` 关） |

---

## 12. 退出码

| 码 | 含义 |
|---|---|
| `0` | ok（或 dry-run 成功） |
| `1` | failed |
| `3` | partial（产物部分落地，看 `checks` 与 `warnings`） |

accoreconsole 自己的退出码另有一套：

| accoreconsole 码 | `exitName` | 含义 |
|---|---|---|
| `0` | `success` | 正常 |
| `76` | `drawing-not-found` | `/i` 指向的 dwg 不存在 |
| `-1` / 超时 | `timeout` | 被我们的超时闸杀掉 |
| 其它非零 | `crash` / `other` | 见 stdout 尾部 |
