# 命令清单

所有脚本都在 `scripts\` 下，都用 `pwsh` 跑。共同惯例：

- 加 `-AsJson` → 输出单个 JSON 对象（无人类可读输出），适合被程序吃
- 不加 `-AsJson` → 人类可读的对齐文本
- 退出码：`0` = ok / dry-run，`3` = partial，`1` = failed
- 每个要启动 accoreconsole 的脚本都有 `-AccoreConsole` 参数，用来在测试里注入 mock，**不要为此改环境变量**（会污染整个 PowerShell 会话）
- **读实际 JSON 判断通过；进程退出了、文件存在了、窗口弹出来了，都不能单独算测试通过**

**脚本清单**：

| 脚本 | 用途 |
|---|---|
| `Invoke-CadDraw.ps1` | JSON → DWG/DXF/PDF 主入口 |
| `Test-CadSpec.ps1` | 出图前预检（不启动 CAD） |
| `Invoke-CadInspect.ps1` | 体检 DWG/DXF |
| `Export-CadToDxf.ps1` | DWG → DXF 多版本 |
| `Invoke-CadPlot.ps1` | DWG → PDF |
| `Convert-CadPdfToDxf.ps1` | PDF 矢量路径 → DXF |
| `Get-CadImageInfo.ps1` | 图片预检 |
| `Invoke-CadRepair.ps1` | 诊断与自动修复 |
| `Invoke-CadCom.ps1` | COM 通道（需要界面） |
| `Set-CadPath.ps1` | 写/看 accoreconsole 路径 |
| `run-test.ps1` / `run-unit-test.ps1` / `run-scenario-test.ps1` | 三套测试 |

**库文件**（被上面这些 dot-source，不含顶层 `param`）：

| 库 | 职责 |
|---|---|
| `CadCommon.ps1` | 路径解析、编码、scr/lsp 生成、执行器、DXF 解析、进程三道闸 |
| `CadCompiler.ps1` | JSON → LISP |
| `cadcore.lsp` | AutoLISP 侧 55 个 `c:XXX` 命令 |
| `CadEvidence.ps1` | 证据分级、五态结论、manifest、单位与图层校验 |
| `CadSpecCheck.ps1` | 出图前 spec 预检 |
| `CadPdf.ps1` | PDF 内容流解析与 DXF 写出 |
| `CadImage.ps1` | 图片像素与墨迹分析 |
| `CadVectorize.ps1` | 位图 → 矢量几何（连通域拟合，替代 OpenCV Hough） |

⚠️ **所有含中文的 `.ps1` 必须 UTF-8 带 BOM**——PowerShell 5.1 按 ANSI 读无 BOM 文件，中文注释里的 UTF-8 续字节会被当成 GBK 前导字节，吞掉后面的引号/括号，报 ParserError 而行号全指向注释。`edit`/`write` 工具写文件不保证保留 BOM，改过之后必须重新补（`[IO.File]::WriteAllText($p, $txt, (New-Object System.Text.UTF8Encoding($true)))`），且注意别叠加成双 BOM（`EF BB BF EF BB BF`，PS5.1 会把第二个 BOM 字符当正文，块注释直接失效）。

⚠️ **库文件绝不能有顶层 `[CmdletBinding()] param(...)`**。dot-source 带 Mandatory param 的库时 PowerShell 会按强制参数绑定，症状是调用方明明传了 `-Path` 却报「缺少一个或多个必需参数: Path」。

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
.\Set-CadPath.ps1 -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe" -AsJson
```

解析链的返回值是 `{path, source}` 对象**不是字符串**，`source ∈ explicit|env:CAD_ACCORECONSOLE|config|scan:<root>|path`。**所有调用方都要取 `.path`**，直接把对象当路径传是早期版本的一个真 bug。

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
| `-AccoreConsole` | 显式指定 accoreconsole（测试注入 mock 时用） |
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

### 多视图模式（spec 带 `views[]` 时自动启用）

拆分规则与校验规则见 [spec.md](spec.md) 的「多视图 `views[]`」。报告差异：

```json
{
  "status": "ok",
  "disposition": "pass",
  "multiView": true,
  "entityCount": 4,
  "warnings": ["[视图 front] …"],
  "views": [
    {
      "id": "front",
      "name": "主视图",
      "status": "dry-run",
      "disposition": "needs_review",
      "entityCount": 3,
      "artifacts": { "dwg": "...\\front-bracket.dwg", "dxf": "..." },
      "manifest": "...\\manifest-front.json",
      "error": null,
      "report": { /* 该视图的完整单视图报告 */ }
    }
  ]
}
```

- 顶层 `status` / `disposition` 取所有视图的**最差档**（fail > blocked > needs_review > pass_with_warnings > pass）
- `entityCount` 是各视图之和
- 视图级 warning 前缀 `[视图 <id>]`
- 某视图 `blocked`（校验失败等）时其余视图照常执行，顶层如实 `blocked`、exit 4

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
| `-AccoreConsole` | 显式指定 accoreconsole（DWG 分支要用） |

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
| `-AccoreConsole` | — | 显式指定 accoreconsole |

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
  "actualVersion": "AC1009",
  "versionMatch": true,
  "warnings": [],
  "error": null,
  "durationMs": 4102
}
```

`versionMatch=false` 时 `status` 降为 `partial`，并 warning「版本未按请求生效：请求 X（ACxxxx），实际 ACxxxx」——**不假装成功**。

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
| `-PlotArea` | `Extents` | `Extents` / `Limits` / `Display` / `Window` |
| `-StyleTable` | `monochrome.ctb` | 打印样式表；`none` 表示不用 |
| `-AccoreConsole` | — | 显式指定 accoreconsole（测试注入 mock 时用） |

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
  "pages": 1,
  "valid": true,
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
.\Invoke-CadCom.ps1 -Action <Info|Draw|Open|Export|Quit|PaperSpace>
                    [-SpecFile <json>] [-Path <dwg>] [-Output <pdf>]
                    [-PaperSize <尺寸>] [-StyleTable <monochrome.ctb|none>]
                    [-LayoutName <CAD_PS>] [-Visible] [-KeepOpen] [-AsJson]
                    [-TimeoutSeconds <int=180>]
```

| Action | 说明 |
|---|---|
| `Info` | 连接 COM，报版本/文档数/当前文档 |
| `Draw` | 用 spec 通过 COM 画（`ModelSpace.AddLine` 等 API，不走命令行） |
| `Open` | 打开图纸 |
| `Export` | 导出 PDF |
| `Quit` | 退出 AutoCAD |
| `PaperSpace` | 图纸空间/布局出 PDF：模型空间画 spec → 建/复用 `-LayoutName` 布局 → 图纸空间画标题框+标题+视口 → `PlotToFile` |

| 参数 | 说明 |
|---|---|
| `-Visible` | 显示 AutoCAD 窗口（默认 `Visible=$false`，后台跑） |
| `-KeepOpen` | 执行完不 `Quit`（默认会 Quit 并 `ReleaseComObject`） |
| `-LayoutName` | `PaperSpace` 动作的目标布局名，默认 `CAD_PS`；已存在则复用 |

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

**报告字段**：

```json
{
  "status": "ok",
  "action": "Info",
  "progId": "AutoCAD.Application.22",
  "version": "22.0s (LMS Tech)",
  "documents": 1,
  "activeDoc": "Drawing1.dwg",
  "entityCount": 0,
  "output": null,
  "bytes": 0,
  "warnings": [],
  "error": null,
  "durationMs": 25130
}
```

**`CopyObjects` 在 PowerShell 里跑不通**（这是拿对象级 API 复制实体的常规做法）：`object[]`、反射 `InvokeMember`、`VariantWrapper` 包装三种姿势都回「对象数组无效」，同文档内调用回「Value does not fall within the expected range」。根因是 PowerShell 的 COM 编组不支持 `VT_ARRAY|VT_DISPATCH`，Python 侧靠 `pythoncom` 显式构造才成立。要复制实体请走命令行 `COPYCLIP`/`WBLOCK`，或在 accoreconsole 里用选择集重建。

**图纸空间同理走不通（accoreconsole 侧）**：accoreconsole 没有布局引擎——`layoutlist` 不存在、`-LAYOUT` 命令不存在、`setvar "CTAB" "Layout1"` 被拒、`tblnext "LAYOUT"` 返 `none`、`ssget "_X" '((410 . "Model"))'` 返 nil。**要操作布局只能用 COM 通道的 `-Action PaperSpace`**，且内部必须走 `$layout.Block`（`$doc.PaperSpace` 集合经管道包装会退化 `Object[]`，`AddXxx` 报「不包含此方法」），点参数必须 `ConvertTo-CadComPoint` 单对象封送。

在 accoreconsole 里筛模型空间实体用 `((67 . 0))`（410 组码不可用）：

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
| `R01-accoreconsole-missing` | 定位不到 accoreconsole 或路径已失效 | 重扫并更新配置 |
| `R02-secureload` | `SECURELOAD` 未关，LISP 会被拦 | 报告（在 scr 里已强制置 0） |
| `R03-env-var-stale` | `CAD_ACCORECONSOLE` 指向不存在的文件 | 报告 |
| `R04-cadcore-utf8` | `cadcore.lsp` 是 UTF-8 | 转 GBK |
| `R05-scr-utf8` | 生成的 `.scr` 是 UTF-8 | 转 GBK |
| `R06-lsp-bom` | `cadcore.lsp` 带 BOM | 去掉 |
| `R07-saveas-exists` | SAVEAS 目标已存在会卡住 | 先删再存 |
| `R08-output-dir-missing` | 目标目录不存在 | 建目录 |
| `R09-zero-byte-dwg` | DWG 0 字节或 < 2KB | 删除 |
| `R10-dxf-no-entities` | DXF 缺 ENTITIES 段 | 报告 |
| `R11-orphan-process` | 有本 skill 启动但未退出的 accoreconsole | **只报告不杀** |
| `R12-timeout-not-exited` | 上次跑到超时没退出 | 清理 |
| `R13-paren-imbalance` | LISP 括号不平衡 | 只报告不改 |
| `R14-undeclared-layer` | spec 引用了未声明的图层 | 只报告（编译器已补建） |

**R11 为什么只报告不杀**：登记表只记录本 skill 自己启动、且 owner PID 对得上的进程。别人的、对不上的，一律不碰——宁可漏一个孤儿，也不能误杀用户正在用的图。

```powershell
.\Invoke-CadRepair.ps1 -SpecFile .\flange.json -DryRun -AsJson
.\Invoke-CadRepair.ps1 -SpecFile .\flange.json
```

`status` 取值：`ok`（没发现问题）/ `repaired` / `dry-run` / `failed`。`mode` 取值：`repair` / `dry-run`。

---

## 8. `Test-CadSpec.ps1` — 出图前预检

```powershell
.\Test-CadSpec.ps1 [-SpecFile <json>] [-SpecJson <string>] [-AsJson]
```

**不启动 AutoCAD**，纯本地校验。用来在花 4 秒跑图之前先发现「注定失败」的 spec。

会抓的**必然失败**：

| 症状 | 报错 |
|---|---|
| 半径/宽度为负或 0 | `半径必须大于 0` / `宽度为 0` |
| 坐标绝对值超 ±10⁷ | `坐标超出 ±10000000`（多半是单位或小数点写错） |
| `polyline` 只有 1 个点 | `至少需要 2 个点` |
| 点是平铺数字数组 | `是平铺的数字数组，应该是 @(@(x,y),...)` |
| 未知 `type` | 报错文本列出全部合法取值 |
| 重复 `id` | 点名重复的 id |
| 重复图层 | 点名重复的图层名 |
| `constraints` 冲突 | `maxEntities` 等超限 |
| 多视图：`views[].id` 缺失/重复 | `视图 id 'X' 重复（views[i] 与 views[j]）`（不区分大小写） |
| 多视图：`view_id` 引用未知视图 | `entities[i] 的 view_id='X' 没有对应的 views[] 条目` |
| 多视图：`required_view_ids` 未知 | `constraints.required_view_ids 里的视图 'X' 没有在 views[] 里定义` |
| 多视图：视图内实体缺字段 | `views[i](vid).entities[j](type) 缺少必需字段 …` |

`entities` 与 `views` 都为空仍然报错；`entities` 空但 `views` 非空放行（每个视图至少要有共享或本地实体才有东西画）。

**只记 warning 不挡路**：未声明图层（编译器会自动补建）、缺 `units`、非法 `units`、非法 `dxfVersion`、**视图内实体引用未声明图层**（同样自动补建，错误信息带 `views[i]` 定位）。

```powershell
.\Test-CadSpec.ps1 -SpecFile .\flange.json -AsJson
```

---

## 9. `Convert-CadPdfToDxf.ps1` — PDF 矢量路径 → DXF

```powershell
.\Convert-CadPdfToDxf.ps1 -Path <pdf> [-Output <dxf>] [-Page <int=1>]
                            [-Scale <double=1.0>] [-Layer <name=PDF_STROKE>]
                            [-BezierSegments <int=8>] [-IncludeFill] [-AsJson]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Path` | **必填** | 源 PDF |
| `-Output` | 同名 `.dxf` | 目标路径 |
| `-Page` | `1` | 解析第几页 |
| `-Scale` | `1.0` | 缩放系数；pt→mm 用 `0.352778` |
| `-Layer` | `PDF_STROKE` | 目标图层 |
| `-BezierSegments` | `8` | 每段三次贝塞尔展平成几段 |
| `-IncludeFill` | — | 连填充路径一起导出 |

**纯本地解析，不启动任何进程，所以没有 `-TimeoutSeconds`。**

**报告字段**：

```json
{
  "status": "ok",
  "source": "...\\plan.pdf",
  "output": "...\\plan.dxf",
  "page": 1,
  "pageCount": 1,
  "pdfVersion": "1.6",
  "streamCount": 3,
  "streamFilter": "FlateDecode",
  "pathCount": 4,
  "strokePaths": 3,
  "fillPaths": 1,
  "exportedPaths": 4,
  "entities": 77,
  "scale": 1.0,
  "bezierSegments": 8,
  "layer": "PDF_STROKE",
  "mediaBox": [0, 0, 842, 595],
  "extents": { "minX": 60.64, "minY": 50, "maxX": 780.28, "maxY": 481.76 },
  "bytes": 5896,
  "unsupported": [],
  "evidence": [],
  "warnings": [],
  "error": null,
  "durationMs": 812
}
```

`status` 取值：`ok` / `parsed`（解析出东西但没到预期）/ `empty`。

支持 `m/l/c/v/y/re/h` 路径算子、`S/s/f/F/f*/B/B*/b/b*/n` 上色算子、`q/Q/cm/w` 图形状态，FlateDecode 与 AsciiHex 过滤器。产物是 R12（AC1009）DXF：两点出 `LINE`，多点亮式 `POLYLINE`（`66=1` + VERTEX + SEQEND）。

**位图 PDF 会明确报错**：只含 DCTDecode XObject 时报「没找到可解析的矢量内容流，这多半是扫描件，需要先 OCR/矢量化」，exit 1。**不猜、不画一个空图交差。**

---

## 9b. `Invoke-CadRenderPreview.ps1` — DXF 预览渲染（不开 CAD）

```powershell
.\Invoke-CadRenderPreview.ps1 -Dxf <dxf> [-OutputDir <dir>] [-Page <A4|A3|A2|A1=A4>]
                              [-Orientation <landscape|portrait> [-MarginMm <double=10>]
                              [-Dpi <int=300>] [-NoPng] [-NoPdf] [-AsJson]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Dxf` | **必填** | ASCII DXF 路径 |
| `-OutputDir` | DXF 同目录 | 产物目录 |
| `-Page` | `A4` | 画布页幅：A4 297×210 / A3 420×297 / A2 594×420 / A1 841×594（mm，横放基准） |
| `-Orientation` | `landscape` | `portrait` 时宽高互换 |
| `-MarginMm` | `10` | 页边距；内容超出画布时按边界收进并记 warning |
| `-Dpi` | `300` | PNG 分辨率（PDF 恒为矢量） |
| `-NoPng` / `-NoPdf` | — | 关掉对应产物 |

**零进程**：不启动 accoreconsole、不碰 COM，纯 PowerShell + System.Drawing。底层在 `CadRender.ps1`：`Get-CadDxfRenderData`（解析+审计）与 `Invoke-CadDxfPreviewRender`（渲染）。

**报告字段**（对齐上游 render_dxf_preview.py 口径）：

```json
{
  "tool": "Invoke-CadRenderPreview/1.0",
  "status": "pass_with_warnings",
  "dxf": "...\\all-entities.dxf",
  "sha256": "45b28103…",
  "version": "AC1032",
  "encoding": "utf-8",
  "audit_errors": [],
  "audit_fixes": [],
  "entityTotal": 25,
  "blockTotal": 0,
  "entity_counts": { "CIRCLE": 9, "LINE": 3, "LWPOLYLINE": 4, "MTEXT": 1, "TEXT": 1, "…": "…" },
  "layer_counts": { "GEO": 8, "HOLE": 9, "TXT": 2, "…": "…" },
  "extents": { "minX": 0, "minY": 0, "maxX": 275, "maxY": 120 },
  "page_mm": { "width": 420, "height": 297 },
  "dpi": 300,
  "artifacts": [ { "kind": "png", "path": "...", "bytes": 223920 } ],
  "warnings": ["PDF 预览里 1 处文字含中文/非 Latin-1 字符，已替换为 '?'（基础 14 字体不含中文；PNG 预览不受影响）"],
  "exitCode": 0,
  "durationMs": 1644
}
```

退出码：`0` = pass / pass_with_warnings，`3` = blocked（DXF 结构错误，如缺 ENTITIES 段、缺 EOF），`1` = 异常。

**中文边界**：PDF 用 14 个 PDF 基础字体，不含中文——文字含非 Latin-1 字符时 PNG 照常、PDF 里替换为 `?` 并写 warning。要中文 PDF 走 `Invoke-CadPlot.ps1`。

---

## 10. `Get-CadImageInfo.ps1` — 图片预检

```powershell
.\Get-CadImageInfo.ps1 -Path <图片> [-AsJson]
```

四个函数分工（都在 `CadImage.ps1`，`Get-CadImageInfo.ps1` 是 CLI 包装）：

| 函数 | 回答什么 | 关键字段 |
|---|---|---|
| `Get-CadImageInfo` | 这是什么图 | `format` `width` `height` `dpiX` `pixelFormat` `valid` `reason` |
| `Get-CadImageInk` | 图里有多少墨、偏在哪 | `inkRatio` `inkPixels` `meanLuma` `contrast` `bounds` `emptyBorder` `darkIsInk` |
| `Test-CadImageUsable` | 能不能拿它照抄 | `ok` `issues[]` `advice` |
| `Get-CadImageAscii` | 让纯文本模型也「看」到形状 | 字符画 |

默认门槛（`Test-CadImageUsable`）：200×200px、墨迹 0.2%–85%、对比度 ≥ 12。

`darkIsInk` 自动判断：平均亮度 < 110 时按「亮的是墨」处理——否则 AutoCAD 黑底截图会被算成满墨，包围盒直接等于整张图。

⚠️ **逐像素循环里绝不调 `Get-CadImageLuma`**：实测 400×260（10 万像素）从 130ms 涨到 2700ms，慢 20 倍。

### 图片 → 矢量几何

一条命令版（`Get-CadImageInfo.ps1 -Action vectorize`，推荐）：

```powershell
.\Get-CadImageInfo.ps1 -Path <图片> -Action vectorize -Output <dxf> [-Scale 0.1] [-MinBlobArea 40] [-AsJson]
```

报告 `vectorize` 字段：`{output bytes entities extents circles lines polygons inkCount darkIsInk evidence[] warnings[] specEntities[]}`——`specEntities` 是可直接粘进正式 spec 的实体数组（带 `_src` 证据注记），DXF 已同时落盘。

分步版（`CadVectorize.ps1`，dot-source 库，要更细控制时）：

```powershell
. .\CadVectorize.ps1
$geo  = Find-CadImageGeometry -Path <图片> [-MinBlobArea 40] [-Threshold 200] [-DarkIsInk <bool>]
$conv = Convert-CadImageGeometryToSpec -Geometry $geo [-Scale 0.1] [-KnownWidth <mm>] `
            [-CircleLayer IMAGE_CIRCLE] [-LineLayer IMAGE_LINE] [-PolyLayer IMAGE_POLY] [-MaxPolyPoints 24] [-IncludePolygons]
$dxf  = Write-CadImageDxf -Geometry $geo -Output <dxf> [-Scale 0.1] [-KnownWidth <mm>] [-IncludePolygons]
```

管线：`Get-CadImageMask`（bool[] 掩码 + darkInk 镜像阈值）→ `Get-CadMaskBlobs`（8 邻域 BFS 连通域，pixels=y*w+x 扁平下标）→ 逐域判定：`Get-CadBlobCircleFit`（径向偏差 ≤0.15 + 36 扇区覆盖 ≥30，**线宽无关**双判据）、`Get-CadBlobLineFit`（PCA 细长度 ≥4）、`Get-CadBlobConvexHull`（Andrew 单调链）→ `Find-CadImageGeometry` 汇总。

- `Find-CadImageGeometry` 返回 `{width height darkIsInk inkCount inkRatio bounds circles[] lines[] polygons[] blobs evidence[] warnings[]}`；circles/lines 证据 `known`，polygons 证据 `inferred`（只给最小外框，需人工确认）。
- 产物是 R12 DXF（AC1009，`$INSUNITS=4`），LINE/CIRCLE/POLYLINE 三类实体；`$dxf` 返回 `{output bytes entities scale counts extents warnings}`。
- **Y 轴必须翻**（内部已处理，`height - 1 - y`）；不知道比例时给 `-Scale 1.0` 会 warning「没有物理比例」，知道实长用 `-KnownWidth`。
- 只输出 circle / line / polyline 三类。hatch/block/spline/gear 不猜——猜错比不猜更糟。

---

## 11. 结论分级与清单复现（CadEvidence.ps1）

### 证据分级

| 级 | 含义 | 例子 |
|---|---|---|
| `known` | 直接读到的硬事实 | DXF 里 `$INSUNITS=4`、DWG 头是 `AC1032`、实体数 13 |
| `scaled` | 读到锚点后换算出来的 | 按 INSUNITS=4 把 100 换算成 100mm |
| `inferred` | 有依据但没直读到 | 图层里有 HATCH 就推断有填充区 |
| `unreadable` | 想读但读不到 | 文件打不开、变量不存在、段被截断 |

`New-CadEvidence` 建的集合按 `known < scaled < inferred < unreadable` 取最差的一级。

### 五态结论

`Get-CadDisposition` 的优先级从高到低：

| 结论 | 触发条件 |
|---|---|
| `blocked` | 有 `BlockedReason` |
| `fail` | 有 error |
| `needs_review` | 只有 `unreadable` / `inferred` 级证据 |
| `pass_with_warnings` | 有 warning |
| `pass` | 全部 `known` 级 |

⚠️ **产物存在与否不改变结论档位**——`error` + 有半成品仍然只是 `fail`，不会升级成 `blocked`。

### 单位校验

| 函数 | 参数 | 说明 |
|---|---|---|
| `Get-CadUnitCode` | `-Name` | `mm`/`毫米`/`公厘` → 4；认不出返回 **-1**；`unitless` → 0 |
| `Get-CadDrawingUnits` | `-Path`（一张 DXF） | 返回 `units` `unitToMm` `evidence`，不是 `toMm` |
| `Test-CadUnits` | `-Path -Expected` | 返回 `match` 三值 `$true`/`$false`/`$null`，`$null` = 不知道 |

### 必需图层校验

`Test-CadRequiredLayers` 把结果分成三类，**三者对调用方是不同的诊断**：

- `present` —— 有声明也有实体
- `empty` —— 有声明（TABLES 里读得到）但模型空间没有实体：建了层却漏画
- `missing` —— 连声明都没有

图层名匹配不区分大小写。`Get-CadDxfLayerNames` 负责读 TABLES 段里的声明（`Get-CadDxfEntities` 只读 ENTITIES 段，反推不出声明）。

### 清单复现

`New-CadManifest` / `Write-CadManifest` / `Compare-CadManifest` 回答「这两次跑出来的是不是同一张图」。

只比：`specSha256`、`cadCoreSha256`、`units.code`、`entityCount`、`artifacts[].sha256`（按 `kind` 对齐）。
**不比**：`timestamp`、路径、`disposition`。

`Compare-CadManifest` 吃**两个清单对象**（`-Before` / `-After`），不是文件路径。要先把落盘的 JSON 读回来：

```powershell
$man  = New-CadManifest -SpecFile .\flange.json -EntityCount 12 -Layers @('GEO','HOLE')
Write-CadManifest -Manifest $man -Path .\manifest.json
$back = (Get-Content -Raw .\manifest.json) | ConvertFrom-Json
$diff = Compare-CadManifest -Before $back -After $man
# $diff.identical / $diff.diffCount / $diff.diffs[]（元素是 {field, before, after}）
```

`specSha256` 与 `cadCoreSha256` 是 `New-CadManifest` 自己现算的，传不传都会算；文件读不到给 `$null` 让比对判差异。**绝不填假哈希**——假哈希会让 `identical=true` 变成谎言。

---

## 12. `run-test.ps1` — 集成自检

```powershell
.\run-test.ps1 [-Test <all|draw|inspect|export|plot|repair|evidence|pdf2dxf>]
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
| 1 出图 | 13 | 13 实体（含 1 个块插入）→ DWG+DXF+PDF 三产物、回执、交叉复核、中文未乱码、块定义存在 |
| 2 体检 | 7 | DXF 与 DWG 两条路径各自 status/entityCount/layers/extents |
| 3 导出 | 6 | 2018 与 R12 两个版本，各自落地+结构有效+版本行 |
| 4 打印 | 3 | status / paperSize+orientation / PDF 魔数 |
| 5 修复 | 8 | 造 0 字节 DWG 与遗留目录，验证识别+修复+DryRun 不动手 |
| 6 证据链与清单 | 17 | 五态优先级实测、manifest 写→读回→自比对 identical→改字段检出差异 |
| 7 PDF 矢量→DXF | 13 | 真 PDF 或自造 PDF → 路径数、DXF valid、**范围落在 MediaBox 内**、图层名 |
| 8 收尾 | 2 | 无残留登记进程 / 本轮无残留 accoreconsole |

`-Test all` = **65 项断言，约 20 秒**。

报告写到 `<OutputDirectory>\run_<stamp>\report.json`。

收尾判残留时只统计 `StartTime -ge $runStartedAt` 的 accoreconsole —— 你本来就开着的实例不会被算成失败，会单独打「提示」。

**「范围落在 MediaBox 内」这条是 CTM 哨兵**：`ConvertFrom-CadPdfContent` 丢了 `cm` 矩阵时，坐标会原样透传，典型症状是坐标跑到 372–6369 而 MediaBox 只有 842 宽，且**没有任何报错**。

---

## 13. `run-unit-test.ps1` — 离线单测

```powershell
.\run-unit-test.ps1 [-WorkDirectory <dir>]
```

**不需要 AutoCAD**，只测纯逻辑。**261 项，约 10 秒**。

22 个分区：

| # | 分区 | 内容 |
|---|---|---|
| 1 | 路径解析 | 优先级（显式>环境>配置>扫盘>PATH）与来源标注 |
| 2 | 编码 | GBK/UTF-8 判定、`Write-CadLsp` 写 GBK 无 BOM CRLF |
| 3 | 路径转换 | 反斜杠转正斜杠 |
| 4 | 数值格式化 | `Format-LispNum`/`Format-LispPoint`/`Format-LispString` |
| 5 | 编译器实体 | 21 种类型逐一出 LISP 并核对通道 |
| 6 | 图层处理 | 三实参、自动补建、非法颜色回落、warning |
| 7 | 错误路径 | 缺字段/未知类型/非数值 → warning 不抛 |
| 8 | `Get-CadField` | StrictMode 下安全访问，含哈希表输入 |
| 9 | DXF 解析 | 成对读取、结构校验、编码回落、数字转换、BOM 首对 |
| 10 | 进程登记表 | 写入/清理/owner 校验拒杀 |
| 11 | 括号平衡 | 跳过字符串与注释 |
| 12 | 图纸尺寸名 | `cadpaper` 映射 |
| 13 | LISP 函数存在性 | 55 个 `c:XXX` 齐不齐、块构建器三件套 |
| 14 | 配置文件 | 读写往返 |
| 15 | `Get-CadMarker` | 解析 `@@NAME=value@@` |
| 16 | 产物结构校验 | PDF 三条铁律（头/尾/页数）、DWG 头版本映射 |
| 17 | 证据分级与五态结论 | 四级排序、空集、五态优先级、五种 advice、`Get-CadSha256` |
| 18 | 清单复现 | manifest 字段、落盘 UTF-8 无 BOM、自比对、四类差异检出 |
| 19 | 单位与必需图层 | `Get-CadUnitCode` 中文别名、`Get-CadDrawingUnits`、`Test-CadUnits`、图层三分类、`Get-CadExtentSize` |
| 20 | 出图前 spec 预检 | 负半径/宽 0/坐标爆表/重复 id/constraints/四份官方示例 |
| 21 | 编译器接入 units | `mm`→`(cadunits 4)`、`m`→`(cadunits 6)`、缺/非法 units 的 warning |
| 22 | 位图矢量化 | 四库 BOM 非、darkInk 口径、单元素数组逗号、无 if 表达式传参、8 函数存在、Y 翻转、三类输出、DXF 铁律、双判据阈值 |

---

## 14. `run-scenario-test.ps1` — 场景测试

```powershell
.\run-scenario-test.ps1 [-Scenario <name|all>] [-Mode <real|mock|offline>]
                        [-OutputDirectory <dir>] [-TimeoutSeconds <int=1200>]
                        [-ListScenarios]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Scenario` | `all` | 场景名或 `all` |
| `-Mode` | `real` | `real` 真跑 AutoCAD / `mock` 用假 accoreconsole / `offline` 完全不执行 |
| `-ListScenarios` | — | 只列场景名不跑 |

三套模式回答三个不同的问题：

| 模式 | 数量 | 证明什么 | **不能**证明什么 |
|---|---|---|---|
| `mock` | 11 | 脚本对 accoreconsole 输出的**解析与判定**是对的 | 真机行为 |
| `offline` | 15 | 编译与预检逻辑、编码、PDF/DXF 解析、图片预检与矢量化、清单比对 | 任何真机交互 |
| `real` | 3 | 真 accoreconsole 全链路 | 别的机器/别的 AutoCAD 版本 |

`mock` 模式用一个 `mock\fake-accoreconsole.ps1` 冒充 accoreconsole，按预置脚本吐 stdout、写产物、给退出码，含 `no-artifact` / `bad-pdf` / `no-done` / `lisp-error` / `dialog` / `hang` 等场景。`hang` 场景带自保：父进程一死就退，不会留下 `Start-Sleep 3600` 的孤儿。

每个结果都带 `mode` 字段，结尾按 mode 印不同的免责句。

---

## 15. 环境变量速查

| 变量 | 作用 |
|---|---|
| `CAD_ACCORECONSOLE` | accoreconsole.exe 路径（优先级高于配置文件） |
| `CAD_ACAD` | acad.exe 路径 |
| `CAD_COM_PROGID` | COM ProgID |
| `CAD_STDOUT_KEEP` | 设 `1` 则保留 stdout 文件（默认保留，设 `0` 关） |

---

## 16. 退出码

| 码 | 含义 |
|---|---|
| `0` | ok（或 dry-run 成功） |
| `1` | failed |
| `3` | partial（产物部分落地，看 `checks` 与 `warnings`） |

按脚本细看：

| 脚本 | `0` | `3` | `1` |
|---|---|---|---|
| `Invoke-CadDraw` | ok / dry-run | partial | 其它 |
| `Invoke-CadInspect` | ok | — | 其它 |
| `Export-CadToDxf` | ok | — | 其它 |
| `Invoke-CadPlot` | ok | — | 其它 |
| `Convert-CadPdfToDxf` | ok / parsed | empty | 其它 |
| `Invoke-CadCom` | ok / partial | — | 其它 |
| `Invoke-CadRepair` | healthy / repaired | issues | 其它 |
| `Invoke-CadRenderPreview` | pass / pass_with_warnings | —（`3` = blocked：DXF 结构错误） | 其它 |
| `Invoke-CadDraw`（多视图顶层 blocked） | — | — | `4` = blocked（某视图校验失败；其余视图照常执行） |

accoreconsole 自己的退出码另有一套：

| accoreconsole 码 | `exitName` | 含义 |
|---|---|---|
| `0` | `success` | 正常 |
| `76` | `drawing-not-found` | `/i` 指向的 dwg 不存在 |
| `-1` / 超时 | `timeout` | 被我们的超时闸杀掉 |
| 其它非零 | `crash` / `other` | 见 stdout 尾部 |
