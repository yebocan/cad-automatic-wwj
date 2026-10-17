---
name: cad-automatic-wwj
description: 用本机 AutoCAD（accoreconsole 无界面命令行 / COM 自动化）从 JSON 描述生成真实 DWG 图纸并回读验证：画线圆弧多段线齿轮螺栓孔阵列、建图层、加标注填充块、导出 DXF（R12–2018）与 PDF、把 PDF 矢量路径转回 DXF、预检图片能不能照抄、体检已有图纸、出问题时自动诊断修复。中文不乱码、产物经过结构校验而不只看文件存在，结论分五档、证据分四级、可出 manifest 复现比对。附集成自检 / 单元测试 / 场景测试三套套件。零 Python 依赖。
---

# CAD Automatic WWJ

把用户的绘图需求变成「真实 DWG 文件 + 可回读的几何证据」：脚本把 JSON 图纸描述编译成 AutoLISP，交给 AutoCAD 官方的 `accoreconsole.exe` 无界面执行，再用独立的 DXF/PDF/DWG 结构校验器验证产物。本 skill 指导流程与判断标准，执行由本目录内的脚本完成。

**零依赖**：不需要 Python、不需要 pip、不需要装任何第三方库。全部是 PowerShell 脚本 + 一份 AutoLISP 库，AutoCAD 2018 及以上自带运行时。只需要本机装了 AutoCAD（能在 `F:\CAD\AutoCAD 2018\` 这类位置找到 `accoreconsole.exe`）。

## 按用户请求选择入口

- **"画个图 / 生成图纸 / 按这个尺寸画"**：走出图层，用 [scripts/Invoke-CadDraw.ps1](scripts/Invoke-CadDraw.ps1)。喂一份 JSON 描述（格式见 [references/spec.md](references/spec.md)），拿回 DWG/DXF/PDF。
- **"这张图里有什么 / 有几个圆 / 什么图层 / 尺寸多大"**：走出图体检层，用 [scripts/Invoke-CadInspect.ps1](scripts/Invoke-CadInspect.ps1)。DXF 直接解析，DWG 先转 DXF 再解析。**不要只按文件大小猜内容。**
- **"转成 DXF / 要 R12 给老机器用"**：用 [scripts/Export-CadToDxf.ps1](scripts/Export-CadToDxf.ps1)。导完会核对文件里实际的 `$ACADVER`，不符会写 warning 而不是假装成功。
- **"导成 PDF / 打印 / 出图给客户"**：用 [scripts/Invoke-CadPlot.ps1](scripts/Invoke-CadPlot.ps1)。产物会过 `%PDF` 头 + `%%EOF` + 页数三重校验。
- **"画是画出来了但有毛病 / 文件 0 字节 / 打不开"**：走出图修复层，用 [scripts/Invoke-CadRepair.ps1](scripts/Invoke-CadRepair.ps1)。先 `-DryRun` 看诊断，再决定修不修。
- **"要看见 AutoCAD 窗口 / 交互操作 / 已经有图开着"**：走 COM 通道，用 [scripts/Invoke-CadCom.ps1](scripts/Invoke-CadCom.ps1)。它驱动真正运行着的 `acad.exe`，约 25 秒起一次，比 accoreconsole 慢一个量级，只在需要界面时才用。
- **"装在哪 / 换台机器怎么用 / 找不到 accoreconsole"**：读 [references/install.md](references/install.md)。**路径不写死，靠解析链找。**
- **"试一下能不能用 / 演示 / 证明它真的能画"**：跑下面「三套测试套件」里的命令。**别用「窗口弹出来了」当证据。**

### 找不到 `accoreconsole.exe` 怎么办

所有脚本共用同一套路径解析链（[scripts/CadCommon.ps1](scripts/CadCommon.ps1) 的 `Resolve-CadAccoreConsole`）。优先级：

1. 显式参数 `-AccoreConsole`（**测试注入假 accoreconsole 时用这个，不要改环境变量**）
2. 环境变量 `CAD_ACCORECONSOLE`
3. 配置文件 `%TEMP%\cad-automatic-wwj\config.json`
4. 常见安装位置扫描（`C:\Program Files\Autodesk`、`D:\CAD`、`E:\CAD`、`F:\CAD` 等，先找带年份的目录名，再找 `accoreconsole.exe`）
5. `PATH`

**不读注册表、不扫全盘。** 返回值是 `{path, source}` 对象而不是字符串——`source` 告诉你它是从哪一级找到的，排查时先看这个。**注意所有脚本里都要取 `.path`，直接把对象当路径传是早期版本的一个真 bug。**

推荐一次写配置，以后所有脚本都不用再传：

```powershell
& "<skill>\scripts\Set-CadPath.ps1" -Auto          # 自动扫盘并写配置
& "<skill>\scripts\Set-CadPath.ps1" -Show          # 看当前解析到的路径与来源
& "<skill>\scripts\Set-CadPath.ps1" -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe"
```

## 出图层

```powershell
& "<skill>\scripts\Invoke-CadDraw.ps1" -SpecFile "drawing.json" -OutputDir "D:\out" -AsJson
```

参数：`-SpecFile` 或 `-SpecJson`（二选一，必填）、`-OutputDir`、`-Dwg`（覆盖 spec 里的存盘路径）、`-DryRun`（只编译不执行）、`-KeepArtifacts`、`-AsJson`、`-TimeoutSeconds`（默认 180）、`-AccoreConsole`。

一份最小可用的 spec：

```json
{
  "name": "flange-plate",
  "layers": [
    { "name": "GEO", "color": 7 },
    { "name": "HOLE", "color": 1 },
    { "name": "DIM", "color": 3 }
  ],
  "entities": [
    { "type": "rect", "p1": [0, 0], "p2": [200, 120], "layer": "GEO" },
    { "type": "boltpattern", "c": [100, 60], "r": 45, "count": 6, "layer": "HOLE" },
    { "type": "dimlinear", "p1": [0, 0], "p2": [200, 0], "layer": "DIM" }
  ],
  "save": { "dwg": "flange.dwg", "dxf": true, "pdf": "A4" }
}
```

21 种实体类型、每种的确切字段名、坐标与角度约定见 [references/spec.md](references/spec.md)。**字段名必须完全一致**：`arc` 用 `c/r/start/end`，`text` 用 `at/value/height`，`hatch` 用 `pattern/scale/seed`——写成 `h`/`w`/`at` 之类的同义词会被拒或取默认值。

输出 JSON 的字段分三组，**不要只看第一个**：

| 组 | 字段 | 说明 |
|---|---|---|
| 结论 | `status` / `error` | `status` ∈ `ok` / `partial` / `failed` / `dry-run`。**`partial` 是有产物但不完整，不能当成功用。** |
| 执行证据 | `exitCode` / `exitName` / `timedOut` / `markers` | `exitName` ∈ `success` / `drawing-not-found` / `timeout` / `crash` / `other`；`markers` 是 LISP 用 `@@名字=值@@` 回吐的实测值（`COUNT`、`TYPESTAT`、`EXTENTS`、每个实体的 `handle`） |
| 产物证据 | `artifacts[]` / `checks[]` / `warnings[]` | `checks` 里每项是 `{name, pass, detail}`——**判定字段是 `pass` 不是 `passed`**，这是调用方最容易写错的地方 |

判定规则（七条，任一不满足就不算成功）：

1. `timedOut=true` → `failed`
2. `exitCode` 不是 0（尤其 **76 = 找不到输入图纸**）→ `failed`
3. 没见到 `@@DONE@@` marker → `partial`（说明 LISP 中途被吞了，后面可能还有半截没画）
4. 有实体编译失败（`checks` 里「JSON 编译成功（m/n）」不 pass）→ `partial`。**这是本节最重要的一条**：一张图里 5 个孔坏 3 个，剩下的 2 个照样能画出来看着挺正常，但装不上。
5. DWG 头不是 `AC10xx` 或小于 2KB → `partial`
6. DXF 缺 `ENTITIES` 段或 `EOF` → `partial`
7. PDF 缺 `%PDF-` 头、缺 `%%EOF`、或 0 页 → `partial`

**进程正常退出不等于图纸画对了。** accoreconsole 在 LISP 报错后仍然返回 0，它把错误写在 stdout 里继续跑下一条命令。

### 为什么中文不乱码

这是本 skill 最容易踩、也最难自己发现的坑，写在最前面：

> **`.scr` 与 `.lsp` 文件必须用 GBK(936) 写盘，不能用 UTF-8。**

accoreconsole 按系统 ANSI 代码页（中文 Windows = 936）读取脚本文件。用 UTF-8 写的中文注释会变成乱码字节序列，其中某些字节恰好是 `"` 或 `)`，于是 LISP 解析器提前结束了字符串或括号，报出 `; 错误: 参数类型错误: stringp nil`——**报错位置指向文件头，和真正的原因毫无关系**。加不加 UTF-8 BOM 都一样。

`Write-CadScr` / `Write-CadLsp` 已强制 GBK + CRLF。**不要绕开它们用 `Set-Content` 自己写。**

反过来，**DXF 文件体是 UTF-8**（AC1032 起），`$DWGCODEPAGE=ANSI_936` 只是 DWG 侧的遗留元数据、不决定 DXF 编码。`Read-CadDxfPairs` 走严格 UTF-8 解码、失败才回落 GBK，并在返回值的 `encoding` 字段里告诉你实际用了哪个。两套编码不能混。

### 日志

accoreconsole 的日志写 `%TEMP%\cad-automatic-wwj\accore_stdout_<时间戳>.txt`，**不写进 skill 安装目录**。用 `-KeepArtifacts` 保留中间产物（`.lsp`/`.scr`）。

注意 stdout 是 **UTF-16LE**，中文界面（「命令:」「; 错误:」）。读的时候要用 `-Encoding Unicode`。stderr 反而是 UTF-8——两者编码不同，混着读会得到一个空字符串，然后你会以为是脚本没输出。

## 出图体检层

```powershell
& "<skill>\scripts\Invoke-CadInspect.ps1" -Path "drawing.dwg" -Entities -AsJson
```

参数：`-Path`（必填，`.dxf` 或 `.dwg`）、`-Entities`（是否返回实体明细）、`-Limit`（默认 200）、`-AsJson`、`-TimeoutSeconds`、`-AccoreConsole`。

报告字段：`{status, path, format, valid, entityCount, entityTypes, layers, extents, blockCount, sections, version, entities, warnings, error, durationMs}`。

- 格式字段是 **`format`**（值 `dxf` / `dwg`），不是 `source`。
- `Get-CadDxfEntities` 直接返回**数组**，不是 `{entities:[...]}` 包一层。
- 实体每项 `{type, layer, handle, x, y, z, text, radius}`——`handle` 是 AutoCAD 的实体句柄，可以用来交叉核对「LISP 说创建成功」和「文件里真的有这个实体」。

DWG 路径要先把 DWG 转成 DXF 再解析（用 accoreconsole 开图 → `c:SAVEDXF` → 临时目录 → 解析 → 删除）。这条路径实测 3.7 秒，如果跑到 120 秒超时，说明 `.scr` 末尾缺 `_N`，卡在「是否保存对 xxx 的修改？」上——见 troubleshooting。

### 结论分级与证据链

`run-test.ps1 -Test evidence` 与 [scripts/CadEvidence.ps1](scripts/CadEvidence.ps1) 提供两件事：

**证据分级**——每条结论都要说清自己是「量到的」还是「猜的」：

| 级 | 含义 | 例子 |
|---|---|---|
| `known` | 直接读到的硬事实 | DXF 里 `$INSUNITS=4`、DWG 头是 `AC1032`、实体数 13 |
| `scaled` | 读到锚点后换算出来的 | 按 INSUNITS=4 把 100 换算成 100mm、按比例尺反推 |
| `inferred` | 有依据但没直读到 | 图层里有 HATCH 就推断有填充区 |
| `unreadable` | 想读但读不到 | 文件打不开、变量不存在、段被截断 |

**五态结论**（`Get-CadDisposition`，优先级从高到低，取命中的最高档）：

| 结论 | 触发条件 | 给用户的建议 |
|---|---|---|
| `blocked` | 有 `BlockedReason`（出图前就发现必然失败，一个实体都没画） | 按 errors 改完再跑 |
| `fail` | 有 error | 看 error 字段 |
| `needs_review` | 只有 `unreadable` / `inferred` 级证据 | 产物可能是对的，但没有证据证明它是对的；请开图核对关键尺寸 |
| `pass_with_warnings` | 有 warning | 可以用，但看一眼 warning |
| `pass` | 全部 `known` 级 | 放心用 |

⚠️ **产物存在与否不改变结论档位**——`error` + 有半成品仍然只是 `fail`，不会升级成 `blocked`。产物在不在只影响调用方能不能救回半成品。

**清单复现**（`New-CadManifest` / `Write-CadManifest` / `Compare-CadManifest`）回答「这两次跑出来的是不是同一张图」。只比稳定的字段：`specSha256`、`cadCoreSha256`、`units.code`、`entityCount`、`artifacts[].sha256`（按 `kind` 对齐）。**不比** `timestamp`、路径、`disposition`。两个哈希是 `New-CadManifest` 自己从 `$SpecFile` 与 `cadcore.lsp` 现算的——传不传都会算，读不到就给 `$null` 让比对判差异，**绝不填假哈希**（假哈希会让 `identical=true` 变成谎言）。

## 导出与打印层

```powershell
& "<skill>\scripts\Export-CadToDxf.ps1" -Path "drawing.dwg" -Version R12 -AsJson
& "<skill>\scripts\Invoke-CadPlot.ps1"  -Path "drawing.dwg" -PaperSize A3 -Orientation Portrait -AsJson
```

`Export-CadToDxf.ps1`：`-Path`（必填）、`-Output`、`-Version`（`2018`/`2013`/`2010`/`2007`/`2004`/`R12`，默认 2018）、`-AsJson`、`-TimeoutSeconds`、`-AccoreConsole`。报告里除 `version`（你请求的）还有 `actualVersion`（文件里实际的 `$ACADVER`）与 `versionMatch`——**请求和事实分开写**，不一致时 status 落 `partial` 并给 warning。已实测 R12→AC1009、2013→AC1027、2018→AC1032 三者 `versionMatch=true`。

`Invoke-CadPlot.ps1`：`-Path`、`-Output`、`-PaperSize`（`A0`–`A4`/`B`–`E`，默认 A3）、`-Orientation`（`Landscape`/`Portrait`）、`-PlotArea`（`Extents`/`Display`/`Limits`/`Window`）、`-StyleTable`（`monochrome.ctb`/`none`）、`-AsJson`、`-TimeoutSeconds`、`-AccoreConsole`。报告里 `orientation` 与 `plotArea` 会**回显你传入的值**，`pages` 是实际数出来的页数，`valid` 是结构校验结果。`status` 只有 `ok` / `invalid` / `failed` 三种。

## PDF 矢量路径转 DXF

```powershell
& "<skill>\scripts\Convert-CadPdfToDxf.ps1" -Path "drawing.pdf" -Output "out.dxf" -AsJson
```

参数：`-Path`（必填）、`-Output`、`-Page`（默认 1）、`-Scale`（默认 1.0，pt→mm 用 `0.352778`）、`-Layer`（默认 `PDF_STROKE`）、`-BezierSegments`（默认 8）、`-IncludeFill`、`-AsJson`。**纯本地解析，不启动任何进程，所以没有 `-TimeoutSeconds`。**

支持 `m/l/c/v/y/re/h` 路径算子、`S/s/f/F/f*/B/B*/b/b*/n` 上色算子、`q/Q/cm/w` 图形状态，FlateDecode 与 AsciiHex 过滤器。产物是 R12（AC1009）DXF：两点出 `LINE`，多点亮式 `POLYLINE`（`66=1` + VERTEX + SEQEND）。

三条实现铁律（都踩过，源码里有注释）：

1. **`switch` 必须加 `-CaseSensitive`**。不加的话 `'q'` 分支压栈、`'Q'` 分支又弹栈，`cm` 变换被静默清掉——症状是坐标原样透传、缩放丢失、位置偏移，**没有任何报错**。
2. **CTM 快照要连 `lineWidth` 一起存**，`q/Q` 只恢复矩阵不够。
3. **`Get-CadPdfStreams` 在没找到流时返回 `$null`**，取 `.Count` 会抛「在此对象上找不到属性 Count」而报错位置指向 `return` 行。一律先 `@(...)` 包一层。

位图 PDF（只含 DCTDecode XObject）会明确报「没找到可解析的矢量内容流，这多半是扫描件，需要先 OCR/矢量化」，exit 1——**不猜、不画一个空图交差**。

## 图片预检

```powershell
& "<skill>\scripts\Get-CadImageInfo.ps1" -Path "photo.png" -AsJson
```

[CadImage.ps1](scripts/CadImage.ps1) 提供四个层次，别混用：

| 函数 | 回答什么 | 关键字段 |
|---|---|---|
| `Get-CadImageInfo` | 这是什么图 | `format` `width` `height` `dpiX` `pixelFormat` `valid` `reason` |
| `Get-CadImageInk` | 图里有多少墨、偏在哪 | `inkRatio` `inkPixels` `meanLuma` `contrast` `bounds` `emptyBorder` `darkIsInk` |
| `Test-CadImageUsable` | 能不能拿它照抄 | `ok` `issues[]` `advice`（**没有 `warnings` 字段**） |
| `Get-CadImageAscii` | 让纯文本模型也「看」到形状 | 字符画 |

`darkIsInk` 会自动判断：平均亮度 < 110 时按「亮的是墨」处理，否则 AutoCAD 黑底截图会被算成满墨，包围盒直接等于整张图。默认门槛是 200×200px、墨迹 0.2%–85%、对比度 ≥ 12——**这些不是物理定律，是「值得停下来问用户」的门槛**。

⚠️ **逐像素循环里绝不调 `Get-CadImageLuma`**：实测 400×260（10 万像素）从 130ms 涨到 2700ms，慢 20 倍。循环内部只做算术。

### 图片 → 矢量几何（视觉矢量化）

```powershell
# 一条命令：图片 → DXF + 几何 JSON（evidence 全带上）
& "<skill>\scripts\Get-CadImageInfo.ps1" -Path "photo.png" -Action vectorize -Output "out.dxf" -Scale 0.1 -AsJson

# 或 dot-source 后分步调（要更细的控制时）
& "<skill>\scripts\CadVectorize.ps1"
$geo = Find-CadImageGeometry -Path "photo.png" -MinBlobArea 40
$conv = Convert-CadImageGeometryToSpec -Geometry $geo -Scale 0.1
$dxf = Write-CadImageDxf -Geometry $geo -Output "out.dxf" -Scale 0.1
```

[CadVectorize.ps1](scripts/CadVectorize.ps1) 用「连通域 + 拟合」替代 OpenCV 的 Hough 变换（本机无 Python；Hough 要 O(墨点数×角度数) 投票，1600×1200 在 PowerShell 里要几十秒，实测连通域路线 300×300 只要 0.5 秒）。管线四步：墨迹掩码（自动判断深底/浅底）→ 8 邻域 BFS 连通域 → 逐域判定 → 像素坐标翻 Y 轴转图纸坐标。三个判据都是**线宽无关**的：圆用最大径向偏差/平均半径 ≤ 0.15（圆≈0.05、正方形≈0.41，一眼分开）+ 36 个 10° 扇区覆盖 ≥30 个（防把 270° 圆弧当整圆）；线用细长度 `sqrt(λmax/λmin)` ≥ 4（PCA 主成分端点）；其余给 Andrew 单调链凸包（诚实的最小外框，不假装知道内凹形状）。

**诚实边界（写进源码注释，不是免责声明，是能力声明）**：

- 这是视觉矢量化不是语义理解：文字会被当成小墨点丢掉、齿轮变成一坨闭合多边形。产物是「候选几何」+ 证据分级（circle/line 是 `known`，polygons 是 `inferred` 需人工确认），**最终 spec 仍要人确认后再画**——从位图反推精确几何一定要确认，半径差 0.3mm 屏幕上一样、装到机器上就装不进。
- 只输出 circle / line / polyline 三类，hatch/block/spline/gear 不猜——猜错比不猜更糟。
- **Y 轴必须翻**：像素 y 向下增、图纸 y 向上增，不翻则上下颠倒且不报错。
- `-Scale` 不给就按 1:1 并 warning「没有物理比例」；知道图里某条线实际长度时传 `-KnownWidth` 换算。

## 出图前 spec 预检

```powershell
& "<skill>\scripts\Test-CadSpec.ps1" -SpecFile "drawing.json" -AsJson
```

在启动 accoreconsole **之前**就把「注定失败」的 spec 拦下来。会抓：负半径、`rect` 宽或高为 0（RECTANG 会退化成一条线）、坐标超出 ±10⁷（多半是单位或小数点写错）、`polyline` 只有 1 个点、点是平铺数字数组、重复 `id`、重复图层、`constraints` 冲突（`maxEntities` 等）。**合法的 warning 不会挡路**：未声明图层（编译器会补建）、缺 `units`、非法 `units`、`dxfVersion` 非法值都只记 warning 并给出回落值。

## 出图修复层

```powershell
& "<skill>\scripts\Invoke-CadRepair.ps1" -SpecFile "drawing.json" -DryRun -AsJson   # 先诊断
& "<skill>\scripts\Invoke-CadRepair.ps1" -SpecFile "drawing.json" -AsJson           # 再修
& "<skill>\scripts\Invoke-CadRepair.ps1" -Path "broken.dwg" -AsJson                 # 修已存在的产物
```

参数：`-SpecFile` 或 `-Path`（二选一）、`-DryRun`、`-AsJson`、`-TimeoutSeconds`。报告 `{status, mode, target, findings[], fixed, remaining, error, durationMs}`，`mode` ∈ `dry-run` / `repair`，`status` ∈ `healthy` / `repaired` / `issues` / `failed`。

14 条规则（`findings[].id`）：

| 组 | 规则 |
|---|---|
| 环境 | `R01` accoreconsole 定位不到（扫盘重新定位并写回配置）、`R02` `SECURELOAD` 未关导致 LISP 拒载、`R03` 环境变量指向失效路径（只报告，建议用 `Set-CadPath`） |
| 编码 | `R04` cadcore.lsp 是 UTF-8 而非 GBK、`R05` scr 是 UTF-8、`R06` lsp 里有 BOM |
| 文件 | `R07` SAVEAS 目标已存在会卡死（删目标）、`R08` 目标目录不存在（建目录）、`R09` DWG 是 0 字节或小于 2KB、`R10` DXF 缺 `ENTITIES` |
| 进程 | `R11` 上次遗留的 acad/accoreconsole（按登记表清理）、`R12` 超时未退出 |
| 结构 | `R13` cadcore.lsp 括号不平衡（**只报告具体行号，不自动改**——自动改 LISP 括号比不修更危险）、`R14` JSON 引用了未声明图层（编译器已自动补建，这里只报告） |

**五个必须停止的条件**：同一个目标修过 3 次仍不过、修复后产物比修复前更小、`R13` 括号不平衡（改错会破坏整个 LISP 库）、目标文件不在本次任务产物目录里、`DryRun` 模式下任何写操作。

## COM 通道（需要界面时才用）

```powershell
& "<skill>\scripts\Invoke-CadCom.ps1" -Action Info -AsJson
& "<skill>\scripts\Invoke-CadCom.ps1" -Action Draw -SpecFile "drawing.json" -Visible -AsJson
& "<skill>\scripts\Invoke-CadCom.ps1" -Action Export -Path "drawing.dwg" -Output "out.dxf" -AsJson
& "<skill>\scripts\Invoke-CadCom.ps1" -Action Quit -AsJson
```

参数：`-Action`（`Info`/`Draw`/`Open`/`Export`/`Quit`）、`-SpecFile`、`-Path`、`-Output`、`-PaperSize`、`-StyleTable`、`-Visible`、`-KeepOpen`、`-AsJson`、`-TimeoutSeconds`。

ProgID 解析顺序：`-ComProgId` → `CAD_COM_PROGID` → 配置 → `AutoCAD.Application.22`（本机实测只有这个，**没有 `CurVer`、也没有 `.22.0`**）→ `AutoCAD.Application`。

**关键约束**：

1. 冷启动 `New-Object -ComObject "AutoCAD.Application.22"` 约 **25 秒**，别把默认超时设成 10 秒然后报「启动失败」。
2. 一律 `Visible = $false` 起，除非用户要看。`-Visible` 才会显示窗口。
3. 用完必须 `Quit()` + `[Runtime.InteropServices.Marshal]::ReleaseComObject()`，否则 `acad.exe` 会留在后台。已实测：正确释放后无残留进程。
4. **COM 通道慢一个数量级**。批量出图一律用 accoreconsole，COM 只在「必须看见窗口」或「已有 cad 进程在跑」时才用。

## 已知缺陷与硬性约束

**`SAVEAS` 到已存在的文件会卡死。** accoreconsole 弹「此名称的图形已存在」，无界面下没人应答，进程挂到超时。所以 `c:SAVEAS` 在存盘前先 `vl-file-delete`。**任何新增的存盘类命令都要照做。**

**`SAVEAS` 的版本参数必须是字符串。** 传整数 2 报 `; 错误: 参数类型错误: stringp 2`；传非法关键字（如 `"2013"` 之外的任意串）报 `无效的选项关键字`，而且**会把后续命令一起吞掉**，导致 `_.QUIT` 也执行不到。所以版本号做了白名单。

**`_.QUIT` 后面必须跟 `_N`，但不能乱堆。** 少了 `_N` 会卡在「是否保存修改」；堆多了（比如 3 个）在某次实测里 `_N` 被当成了前一条命令的文件名，生成了一个叫 `_N.dwg` 的文件。**只加在确定已退出命令状态的位置，数量不多于需要应答的提示数。**

**`-HATCH` 的 `_S` 后面必须跟选择集或对象，给点坐标无效。** 这是本 skill 最阴的 bug：`(list "_.-HATCH" "_P" pat scale "0" "_S" (list px py) "" "")` 看起来合理，实际不创建任何填充，而且 `(entlast)` 返回的是**上一个实体**——于是 `@@HATCH=...handle=29F@@` 和 `@@DIMRAD=...handle=29F@@` 拿到同一个 handle，证据字符串看着像成功。正确做法是先 `setvar` 设 `HPNAME`/`HPSCALE`/`HPANG`，然后 `(cadcmd (list "_.-HATCH" (list px py) ""))`，**不要 `_S`**。修完还要 `ssget "_X" '((0 . "HATCH"))'` 数一遍确认真的创建了。**教训：创建类命令不能只信 `(entlast)`。**

**`c:DIMALIGN` 不能带 `52` 组码。** 四个变体实测：`50+52+无Rotated尾`→nil、`仅50`→ok、`无50无52`→ok、`50+RotatedDimension尾`→nil。已只保留 `50`。

**`DIMRAD` 传边缘点当选择对象会吞掉后续命令。** 原来直接把边缘点传给标注命令，accoreconsole 回 `*无效选择* 需要单个对象` + `; 错误: 函数已取消`，然后**后面所有命令都不执行了**。现在改成用 `ssget "_X" '((0 . "CIRCLE"))'` 按圆心（±0.5）+ 半径找到 ename 再传。

**LISP 没有可选参数。** `c:LAYER` 声明了 `(name color ltype)`，少传一个就是运行时「参数太少」。所有 LISP 入口的必需参数数量见 [references/commands.md](references/commands.md)，PowerShell 侧永远补齐。

**`-BLOCK` 不是「开着让后面实体自动入块」。** 直觉写法 `(command "_.-BLOCK" name pt)` 之后紧跟着画图，`-BLOCK` 给完基点+名字就进「选择对象:」，把后面的坐标当选择点吃掉，冒出 `*无效选择*` + `需要点或窗口(W)/…/单个(SI)`，然后整张图卡到超时。`(princ "\n")` 救不了——**princ 只往 stdout 打字，不往命令输入队列送回车**。正确做法：先画到模型空间 → 进块前记 `(entlast)` → 出块后 `(entnext)` 走到尾全 `ssadd` 进选择集 → `(command "_.-BLOCK" name pt ss "")` 一次性喂进去 → 用 `(tblobjname "BLOCK" name)` + `entnext` 数一遍确认真的成了。实现在 `cadcore.lsp` 的 `c:BEGBLOCK` / `c:ENDBLOCK` / `cadblkcnt`，编译器只会生成这三个调用。

**不存在的线型会让 `-LAYER` 悬停。** `_.-LAYER _L NO_SUCH_LTYPE` 时 AutoCAD 只打一行「未找到线型」，然后**继续等下一个输入**，而此时已经没有输入了 → 卡到超时，日志只剩 `; 错误: 函数已取消`。`c:LAYER` 先 `(tblsearch "LTYPE" ltype)` 查一遍，查不到退回 `CONTINUOUS`，并打 `@@LTYPE_MISSING.<图层>=<线型>@@`，报告里变成一条 warning。

**图层颜色必须是 1–255 的整数。** 用户写 `"red"`、`"#FF0000"`、`300`、`0` 都常见。原来直接 `[int]` 强转，StrictMode 下抛异常**把整张图带崩**——图层是基础设施，坏一个值不该让所有实体停工。现在非整数或越界一律回落 7 并记 warning。

**accoreconsole 的 stdout 是 UTF-16LE，`/ ?` 会挂起，`/i` 指向不存在的 dwg 是 exit 76 + 弹出「找不到指定的图形文件」。**

**`DXFOUT` 的第二个参数是小数精度，不是版本。** 传 `"12"`/`"13"`/`"16"` 导出的文件全是 `AC1032`（只是精度差异导致字节数 120684/120718/120775 略有不同）。改版本要用 `SAVEAS` 的格式选项，且格式在文件名**之前**：

```
输入文件格式 [R14(LT98&LT97)/2000(LT2000)/2004(LT2004)/2007(LT2007)/2010(LT2010)/2013(LT2013)/2018(LT2018)/标准(S)/dxf(DXF)/样板(T)] <2018>:
```

## 三套测试套件

| 用户想看什么 | 命令 | 验收重点 |
|---|---|---|
| 真机能不能画、产物对不对 | `run-test.ps1 -Test all` | 13 个实体全部落盘、块定义与块插入都成立、DWG/DXF/PDF 三结构校验通过、DXF 回读实体数与 JSON 声明交叉核对、中文未乱码、退出码 0、无残留进程、五态结论优先级、manifest 自比对与差异检出、PDF 矢量路径转 DXF 落在 MediaBox 内（**65 项**） |
| 逻辑对不对（完全不装 AutoCAD） | `run-unit-test.ps1` | 路径解析、GBK 写盘、JSON 编译、图层颜色回落、块构建器写法、DXF 解析（含 BOM 与 UTF-8/GBK 双解码）、PDF/DWG 结构校验、进程登记表六种拒绝条件、证据分级与五态结论、清单复现、单位与必需图层三分类、出图前预检、编译器接入 units、位图矢量化管线八函数与 Y 轴翻转（**265 项**） |
| 出错时判断准不准 | `run-scenario-test.ps1` | 假 accoreconsole 制造九种「看起来成功」的假象，要求脚本自己戳破（mock **11** / offline **15** / real **3**） |

```powershell
& "<skill>\scripts\run-test.ps1"          -Test all -OutputDirectory "D:\some\writable\dir"
& "<skill>\scripts\run-unit-test.ps1"                                        # 秒级，不需要 AutoCAD
& "<skill>\scripts\run-scenario-test.ps1" -Mode mock                         # 假 accoreconsole
& "<skill>\scripts\run-scenario-test.ps1" -Mode offline                      # 不启动任何进程
& "<skill>\scripts\run-scenario-test.ps1" -Mode real                         # 真机
```

`-Test` 可取 `all`（默认）、`draw`、`inspect`、`export`、`plot`、`repair`、`evidence`、`pdf2dxf`。加 `-KeepArtifacts` 保留中间产物。加 `-SkipCrossCheck` 跳过 DXF 回读交叉核对。单独跑 `-Test export` / `-Test plot` 时脚本会依次尝试 `draw\integration-draw.dwg` → `mini\integration-mini.dwg` → 现画一张 mini，**不会因为「没先跑 draw」就失败**。

`run-scenario-test.ps1` 的 `-Scenario` 可用 `all`（默认）或具体场景名，`-ListScenarios` 列出全部 14 个。`-Mode` 三选一：

- **`real`** 真跑 accoreconsole。慢，但验证的是真机行为。
- **`mock`** 用 [scripts/mock/fake-accoreconsole.cmd](scripts/mock/fake-accoreconsole.cmd) 冒充。它不猜产物路径，而是**读调用方真正生成的 `.scr` 和 `.lsp`**，从中抠出 `c:SAVEAS`/`c:SAVEDXF`/`c:PLOTPDF` 的目标路径再往那儿写产物——所以改脚本时 mock 不用跟着改。`MOCK_SCENARIO` 环境变量控制十种场景：`normal` / `lisp-error` / `not-found` / `no-done` / `no-artifact` / `same-handle` / `dialog` / `hang` / `bad-dxf` / `bad-pdf`。
- **`offline`** 完全不执行进程，只验编译、参数校验、单位与图层分类、清单比对、PDF 矢量解析、图片预检、图片矢量化（连通域拟合管线）。

**判定标准**

- 单元测试：`单元测试 · n / m 通过`，结果写 `%TEMP%\cad-unit-tests\`。
- 集成自检：`集成自检 · n / m 通过`，报告写 `<OutputDirectory>\run_<时间戳>\report.json`。
- 场景测试：`场景测试 · n / m 通过`，报告写 `<OutputDirectory>\run_<时间戳>\report.json`。

**每条场景结果都带 `mode` 字段**（`real` / `mock` / `offline`）——`mock` 模式通过的场景证明了「脚本的判定逻辑正确」，**不能拿去当「真 AutoCAD 上验证过」**。报告末尾会印一句这一轮到底证明了什么、没证明什么。

**读实际 JSON 判断通过；进程退出了、文件存在了、窗口弹出来了，都不能单独算测试通过。**

## 进程安全（最高优先级）

本 skill **绝不按名字批量结束进程**。结束 CAD 进程的唯一入口是 `Stop-OwnedCadProcess`，三道闸全部通过才动手：

| 闸 | 不满足时 |
|---|---|
| PID 必须在登记表里（`%TEMP%\cad-automatic-wwj\owned-processes.json`，只有本 skill 自己启动的才登记） | `refused`，`ownerCheck=no-registry-entry` |
| 调用方传入的 `-OwnerPid` 必须等于登记条目里的 owner，且 owner 进程仍存活 | `refused`，`ownerCheck=caller-not-owner:entry=X;caller=Y` / `owner-dead` |
| 进程名必须与登记值一致，且启动时间与登记值相差不超过 2 秒 | `refused`，`ownerCheck=not-same-name:A≠B` / `started_at mismatch: Δ=Ns` |

**全仓库没有一句 `Get-Process -Name acad | Stop-Process`。**

其他保证：

- 超时杀进程时**先抓整棵子树再从叶子往根杀**（`Get-CadProcessTree`）。实测过：只 `Kill()` 父进程时，cmd 包装器派生的子进程会活下来继续跑，登记表认为已清而 PID 还在——下次测试就撞上「文件被占」的怪事。真正的 accoreconsole 加载 .NET 后同样会派生。
- `Get-CadOwnedProcesses`（枚举）是**只读**的，只记录不结束。
- 脚本检测到已有 accoreconsole / acad 实例时**不阻止、不清理**，只在报告里区分「本轮启动的」与「用户本来就开着的」——判残留只看 `StartTime -ge $runStartedAt` 的进程。
- 启动进程之前先写登记表，所以测试进程被强杀（Ctrl+C，`finally` 不执行）时，也能靠 `Clear-StaleCadEntries` 在下次收尾。
- **授权只看登记表，不看父进程。**

## 给用户画图的常规流程

1. 先确认 accoreconsole 能定位（`Set-CadPath.ps1 -Show`）。定位不到就先解决这个，不要急着写 spec。
2. 把用户需求翻译成 JSON：先定图层，再定几何，最后定标注与存盘。**尺寸、角度、坐标要写具体数字，不要写「大概」「合适」。**
3. 先跑 `Test-CadSpec.ps1` 做预检——它在启动 CAD 之前就把负半径、宽 0、坐标爆表这类必然失败拦下来，比跑 4 秒再失败快得多。
4. `-DryRun` 跑一遍，看编译警告与生成的 LISP。有实体编译失败就先改 spec。
5. 真跑，读 `status` 与 `checks`。`partial` 要看清是哪条断言没过。
6. 用 `Invoke-CadInspect.ps1` 回读产物，把**实际的实体数、图层、包围盒、单位**报给用户作为证据。**不要只说"已生成"。**
7. 需要复现或对比两次结果时写一份 manifest，用 `Compare-CadManifest` 判 identical。
8. 交付时给出文件绝对路径与字节数。需要 DXF/PDF 就顺手导。

## 参考文档

- [references/spec.md](references/spec.md) —— JSON 图纸描述完整 schema：21 种实体的字段、坐标与角度约定、图层规则、单位、存盘选项、`constraints` 约束
- [references/commands.md](references/commands.md) —— 全部脚本的参数、报告字段、退出码；cadcore.lsp 里 51 个 `c:XXX` 函数的必需参数
- [references/protocol.md](references/protocol.md) —— accoreconsole 交互协议：scr 语法、marker 约定、退出码、stdout 编码、DXF 结构
- [references/troubleshooting.md](references/troubleshooting.md) —— 按症状查：中文乱码、卡死、LISP 报错、产物 0 字节、找不到图纸、超时、残留进程
- [references/install.md](references/install.md) —— 各平台安装路径、一键安装、升级校验与验证方法

## 跨智能体使用

本 skill 的执行层是「PowerShell 脚本 + 一份 AutoLISP 库」，不依赖 DSH 专有接口，任何能执行命令行的智能体都能调用。

用户问「怎么装到 DSH / 豆包 / WorkBuddy / Codex」时，读 [references/install.md](references/install.md)，按里面的实际路径安装，**不要凭印象编路径**。装完必须跑 `run-test.ps1` 验证——**技能出现在列表里、AutoCAD 窗口弹出来，都不能算装好。**

移植到其他机器时注意：

- 路径按目标机器实际安装位置传（`-AccoreConsole` 参数），不要照抄本文档里的 `F:\CAD\AutoCAD 2018`。
- 技能目录里带用户名（如 `C:\Users\yebocan\...`），换机器后按实际用户名替换。
- AutoCAD 版本不同时，`c:SAVEAS` 的合法版本关键字与 `accoreconsole` 的退出码可能略有差异；先跑 `run-test.ps1 -Test draw` 确认。
- 只有 AutoCAD（含 `acad.exe`）没有 `accoreconsole.exe` 时，出图层不可用，只能用 `Invoke-CadCom.ps1` 走 COM 通道——慢，但能画。
