# CAD Automatic WWJ

让 AI 智能体真正操作本机 **AutoCAD** 的技能：把一段 JSON 描述画成**真实的 DWG 图纸**、建图层加标注填充、导 DXF 与 PDF、体检已有图纸、出错自动诊断修复 —— 每一步都用读回的真实字节作证据，不靠「命令执行了」这种自述。

**零 Python 依赖**，不需要 pip，不需要装 ObjectARX / pyautocad / ezdxf。

> 本 README 对应仓库当前代码。文中每条能力都标注了「已实测 / 未实测」，未做的写在[已知限制](#12-已知限制)里，不混在现有能力中。

---

## 1. 项目用途

AI 帮你画图时最常见的困境是「代码写出来了，但图纸在哪、画对没有」——线在不在、图层对不对、文字乱没乱码，全靠人肉打开 AutoCAD 看。本技能把这件事变成命令行可调用、结果可解析的接口：

| 环节 | 做法 | 证据 |
|---|---|---|
| 出图 | 把 JSON 编译成 LISP，交给 `accoreconsole.exe` 无界面执行 | 退出码 + `@@DONE@@` 回执 + `@@COUNT=n@@` 实体数 |
| 校验 | **不信 LISP 自述**，独立校验产物字节 | DWG 头是 `AC10xx` 且 >2KB、DXF 能解析出 ENTITIES、PDF 含 `%PDF-`/`%%EOF`/`/Type/Page` |
| 交叉复核 | 让另一个脚本把刚生成的图**读回来** | 实体类型统计、图层清单、中文文字是否完整 |
| 体检 | 解析 DXF（DWG 先转 DXF）拿到结构事实 | 实体数、类型分布、图层、范围、块数、DXF 版本 |
| 单位与必需图层 | 读 `$INSUNITS` 与 TABLES 里的图层声明 | 毫米换算、图层三分类（有实体/声明但空/根本没建） |
| 导出 | 转 DXF（R12–2018）/ 打印 PDF | 实际生效的版本号（`AC1009`…`AC1032`）与请求值比对 |
| PDF 反读 | 解析 PDF 内容流，把矢量路径写回 DXF | 路径数、坐标范围落在 MediaBox 内、DXF 结构 |
| 图片预检 | 逐像素算墨迹与对比度 | 墨迹占比、包围盒、`darkIsInk` 自动判断 |
| 结论分级 | 每条证据标 `known`/`scaled`/`inferred`/`unreadable` | 五态结论 `blocked`/`fail`/`needs_review`/`pass_with_warnings`/`pass` |
| 复现比对 | 出 manifest，比 spec 与 cadcore 的哈希 | 同一份 spec 是否复现出同一张图 |
| 修复 | 按 14 条规则逐项体检并处理 | 每条规则给出 `{id, title, status, action, detail}` |

## 2. 支持的环境

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Windows 10 / 11 | 依赖 PowerShell 与 .NET |
| PowerShell | Windows PowerShell 5.1 **或** PowerShell 7+ | 两个都测过；脚本不用 7 才有的语法 |
| AutoCAD | 2013 及以上（本项目在 **AutoCAD 2018 / 22.0.49.0.0** 上验证） | 核心通道需要 `accoreconsole.exe`（随 AutoCAD 安装，通常在安装目录根下） |
| .NET | 4.x 或 PowerShell 自带 | 无额外依赖 |
| Python | **不需要** | 整个项目零 Python |
| COM 通道 | 可选 | 需要完整 `acad.exe`；无界面机器上不用它 |

实测环境：Windows 10 + PowerShell 7.6.6 + AutoCAD 2018（`F:\CAD\AutoCAD 2018`）。

## 3. 安装要求

- 磁盘：技能本体约 460 KB（14 个 PowerShell 脚本 + 1 个 LISP + 5 篇参考文档 + 4 份示例）。
- 权限：普通用户即可。安装脚本只往当前用户的技能目录写文件，**不改系统环境变量、不改注册表、不动 PATH**。
- 网络：不需要。安装与运行全程离线。

## 4. 如何安装 Skill

```powershell
cd "D:\deepseek harness gongzuoqu\cad-automatic-wwj"
pwsh -File .\Install-Skill.ps1 -DryRun      # 先看会装到哪，不写任何文件
pwsh -File .\Install-Skill.ps1              # 实际安装（默认只装 DSH）
```

**默认只装 DSH**。要装到别处必须显式指定 `-Target`：

```powershell
pwsh -File .\Install-Skill.ps1 -Target dsh,doubao,workbuddy
```

| `-Target` | 技能目录 |
|---|---|
| `dsh`（默认） | `%USERPROFILE%\.dsh\skills\cad-automatic-wwj\` |
| `codex` | `%USERPROFILE%\.codex\skills\cad-automatic-wwj\` |
| `doubao` | `%USERPROFILE%\Doubao\skills\cad-automatic-wwj\` |
| `doubao-user` | `%LOCALAPPDATA%\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills\cad-automatic-wwj\` |
| `workbuddy` | `%USERPROFILE%\.workbuddy\skills\cad-automatic-wwj\` |

安装脚本的安全行为（都已实测）：

- 目标目录已有**同名但不是本技能**的目录时 → **拒绝覆盖**，并提示「为免覆盖别人的技能，本脚本不动它」。判定依据是 `SKILL.md` frontmatter 里的 `name:` 字段。
- 覆盖本技能旧版本前，先把整个旧目录备份到 `%TEMP%\cad-automatic-wwj-backup\<时间戳>\<平台>_<时间戳>\`，并打印旧版本的描述。
- 装之前就检查关键文件是否齐全（`CadCommon.ps1` / `CadCompiler.ps1` / `cadcore.lsp` / `Invoke-CadDraw.ps1`），缺一个直接拒绝，不装一个「只会说话不会干活」的空壳。
- 安装后回读校验 `SKILL.md` 的 `name:`，校验不过打印 `[警告]`。

其它动作：

```powershell
pwsh -File .\Install-Skill.ps1 -Action status      # 看各平台装没装
pwsh -File .\Install-Skill.ps1 -Action update      # 同 install，语义更明确
pwsh -File .\Install-Skill.ps1 -Action uninstall -Target dsh   # 只删本技能目录
```

`-Action uninstall` 只删技能目录本身，父目录里别人的技能一律不碰；目标不是本技能时拒绝删除。

### 装完必须验证

```powershell
& "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts\run-test.ps1" -Test all
```

看到 `集成自检  ·  65 / 65 通过，0 失败` 才算装好。**技能出现在列表里、AutoCAD 窗口弹出来了，都不能算装好。**

## 5. 如何定位 accoreconsole

所有脚本共用同一套解析链（实现在 `skill/scripts/CadCommon.ps1` 的 `Resolve-CadAccoreConsole`），优先级从高到低：

| 优先级 | 来源 | 写法 |
|---|---|---|
| 1 | 命令行参数 | `-AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe"` |
| 2 | 环境变量 | `$env:CAD_ACCORECONSOLE = "...\accoreconsole.exe"` |
| 3 | **配置文件** | 用下面的 `Set-CadPath.ps1` 写 |
| 4 | 常见安装位置 | `C:\Program Files\Autodesk\AutoCAD *`、`D:\`/`E:\`/`F:\` 下的 `CAD` / `AutoCAD*` / `Autodesk` 目录 |
| 5 | 系统 PATH | PATH 里的 `accoreconsole.exe` |

**只做定点探测，不扫全盘。** 全部找不到时抛错并逐条列出试过哪些来源。返回对象里带 `source` 字段（`explicit` / `env:CAD_ACCORECONSOLE` / `config` / `scan:<根>` / `path`），报告里会显示来源，方便判断「到底用了哪个」。

推荐一次写好配置：

```powershell
$s = "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts\Set-CadPath.ps1"
& $s                    # 自动探测并写入
& $s -Auto -Show        # 探测 + 显示当前配置和实时结果
& $s -AccoreConsole "F:\CAD\AutoCAD 2018\accoreconsole.exe"   # 手动指定
& $s -Clear             # 删掉配置，回到自动探测
```

配置文件位置 `%APPDATA%\cad-automatic-wwj\config.json`（可用环境变量 `CAD_AUTOMATIC_WWJ_CONFIG` 指向别处）。内容形如：

```json
{ "accoreconsole": "F:\\CAD\\AutoCAD 2018\\accoreconsole.exe", "comProgId": "AutoCAD.Application.22", "configuredAt": "2026-10-17T15:18:55" }
```

## 6. 如何画一张图

### 6.1 最小可跑的 spec

```json
{
  "name": "demo",
  "layers": [{ "name": "GEO", "color": 7 }],
  "entities": [
    { "type": "rect",   "layer": "GEO", "p1": [0, 0], "p2": [180, 100] },
    { "type": "circle", "layer": "GEO", "c": [90, 50], "r": 20 }
  ],
  "save": { "dwg": "demo.dwg", "dxf": true, "pdf": "A4" }
}
```

```powershell
& "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts\Invoke-CadDraw.ps1" `
    -SpecFile .\demo.json -OutputDir .\out -AsJson
```

### 6.2 支持的实体类型（21 种，全部实测通过）

| type | 必填字段 | 可选字段 |
|---|---|---|
| `line` | `p1` `p2` | — |
| `polyline` | `points`（≥2） | `closed` |
| `circle` | `c` `r`（或 `radius`） | — |
| `arc` | `c` `r` `start`（或 `startAngle`）`end`（或 `endAngle`） | — |
| `rect` | `p1` `p2` | — |
| `ellipse` | `c` `rx`（或 `r`）`ry` | — |
| `point` | `at`（或 `c`） | — |
| `spline` | `points`（≥3） | — |
| `polygon` | `c` `r` `sides` | — |
| `gear` | `c` `r` `teeth` | — |
| `centerline` | `c` `len`（或 `length`） | — |
| `boltpattern` | `c` `r` `count` | — |
| `text` | `at` `value` | `height`(2.5) `align`(BL) `rotation`(0) |
| `mtext` | `at` `value` | `width`(100) `height`(10) |
| `dimlinear` | `p1` `p2` | `at` |
| `dimaligned` | `p1` `p2` | `at` |
| `dimradius` | `c` `r` | `edge`（或 `at`）`text` `textAt` |
| `hatch` | `pattern` `scale` `at`（或 `seed`） | — |
| `solid` | `points`（≥3，最多 4） | — |
| `block` | `name` `at` | `scaleX`(1) `scaleY`(1) `rotation`(0) |
| `erase` | `entityType`（或 `layer`） | — |

**字段名容易写错的几个**（用错会得到明确的「需要 xxx」报错，不会静默）：

- `text` / `mtext` 的位置是 **`at`**，文字大小是 **`height`**，多行宽度是 **`width`** —— 不是 `x/y/h/w`。
- `arc` 的起止角是 **`start` / `end`**（度数，0 = 正东，逆时针）。
- `centerline` 的长度是 **`len`**；`hatch` 的种子点是 **`at`**。

### 6.3 块定义

```json
{
  "blocks": [
    { "name": "BOLT_M12", "base": [0, 0],
      "entities": [
        { "type": "circle", "c": [0, 0], "r": 6 },
        { "type": "circle", "c": [0, 0], "r": 3 }
      ] }
  ],
  "entities": [
    { "type": "block", "layer": "HOLE", "name": "BOLT_M12", "at": [170, 30], "scaleX": 2, "scaleY": 2, "rotation": 15 }
  ]
}
```

### 6.4 报告怎么读

```json
{
  "status": "ok",
  "drawing": "...\\out\\demo.dwg",
  "entityCount": 2,
  "layers": ["0", "GEO"],
  "artifacts": [{ "kind": "dwg", "path": "...", "exists": true, "bytes": 33072 }],
  "checks": [{ "name": "DWG 结构有效（32.3 KB / 2018）", "pass": true }],
  "warnings": [],
  "exitCode": 0,
  "exitName": "success",
  "timedOut": false,
  "markers": { "SETUP": "ok", "LAYER": "GEO color=7 ltype=BYLAYER", "COUNT": "12", "DONE": "" },
  "durationMs": 4096
}
```

| `status` | 含义 | 退出码 |
|---|---|---|
| `ok` | 全部产物校验通过 | 0 |
| `partial` | 画出来了但有产物缺失或校验未过 | 3 |
| `failed` | 没画出来 | 1 |
| `dry-run` | 只编译不执行 | 0 |

**七条判定规则**（`checks` 里就是按这几条打分的）：

1. accoreconsole 定位成功 —— 否则直接 failed。
2. `cadcore.lsp` 已转码为 GBK —— 原件是 UTF-8，交付前必须转。
3. JSON 编译成功 —— 分母是 spec 里声明的实体数，有失败就不是「全过」。
4. LISP 已生成 —— 文件存在且非空。
5. accoreconsole 退出码 0。
6. LISP 执行到 `@@DONE@@` —— 这是「脚本真的跑完了」的唯一凭据。
7. DWG / DXF / PDF 结构校验分别通过。

### 6.5 为什么中文不乱码

这是本技能最容易翻车的一条，两个编码方向必须分开处理：

| 文件 | 编码 | 原因 |
|---|---|---|
| `.scr`（命令脚本） | **GBK (936)** | accoreconsole 按系统 ANSI 代码页读它 |
| `.lsp`（LISP 源码） | **GBK (936)** | 同上；UTF-8 的中文注释会被解成乱码字节，某些字节恰好是引号/括号 → LISP 报「参数类型错误: stringp nil」，**报错位置指向文件头，真正原因是编码** |
| `.dxf`（导出产物） | **UTF-8** | AC1032（2018）的 DXF 文件体一律 UTF-8；`$DWGCODEPAGE=ANSI_936` 只是 DWG 侧遗留元数据，不决定编码 |

`Read-CadDxfPairs` 用严格 UTF-8 解码，失败才回落 GBK，并在返回值里标 `encoding` 字段说明实际用了哪个。

口诀：**写进去用 GBK，读出来先试 UTF-8。**

### 6.6 日志在哪

`%TEMP%\cad-automatic-wwj\accore_stdout_<时间戳>.txt`（**UTF-16LE**，中文界面），报告里 `logDir` 指向工作目录。stderr 单独一个文件。工作目录默认保留（里面有你这次的 `drawing.lsp` 和 `cadcore.lsp`，出问题可以直接看），加 `-KeepArtifacts` 强制保留。

## 7. 如何体检已有图纸

```powershell
& "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts\Invoke-CadInspect.ps1" `
    -Path .\drawing.dwg -Entities -AsJson
```

- `.dxf` 直接解析（自己写的解析器，不依赖 ezdxf）。
- `.dwg` 先转 DXF（临时目录，读完就删）再解析。

报告字段：`status` / `path` / `format`（`dxf`|`dwg`）/ `valid` / `entityCount` / `entityTypes[]`（`{type, count}`）/ `layers[]` / `extents` / `blockCount` / `sections[]` / `version` / `entities[]`（加 `-Entities` 才有）/ `warnings` / `error` / `durationMs`。

`version` 是 DXF 版本串（`AC1009`=R12 … `AC1032`=2018）。

## 8. 如何导出与打印

```powershell
$s = "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts"

# DXF（R12 / 2000 / 2004 / 2007 / 2010 / 2013 / 2018）
& "$s\Export-CadToDxf.ps1" -Path .\drawing.dwg -Output .\drawing.dxf -Version R12 -AsJson

# PDF
& "$s\Invoke-CadPlot.ps1" -Path .\drawing.dwg -Output .\drawing.pdf `
    -PaperSize A3 -Orientation Portrait -PlotArea Extents -AsJson
```

**版本真的会生效**：`Export-CadToDxf` 的报告里有 `actualVersion` 与 `versionMatch`，实测 R12→`AC1009`、2013→`AC1027`、2018→`AC1032` 三项 `versionMatch=true`。版本没按请求生效时 `status=partial` 并给 warning，不会假装成功。

`Invoke-CadPlot` 报告里有 `pages` / `valid` / `orientation` / `plotArea` 回显，PDF 走 `Test-CadPdfFile` 三重校验（头 `%PDF-`、尾 `%%EOF`、≥1 个 `/Type/Page`）。

### 8.1 出图前先预检

```powershell
& "$s\Test-CadSpec.ps1" -SpecFile .\demo.json -AsJson
```

不启动 AutoCAD，纯本地校验。用来在花 4 秒跑图之前先发现「注定失败」的 spec：负半径、`rect` 宽或高为 0（RECTANG 会退化成一条线）、坐标绝对值超 ±10⁷（多半是单位或小数点写错）、`polyline` 只有 1 个点、点是平铺数字数组、未知 `type`、重复 `id`、重复图层、`constraints` 冲突。

**合法的 warning 不挡路**：未声明图层（编译器会自动补建）、缺 `units`、非法 `units`、`dxfVersion` 非法值都只记 warning 并给出回落值。

### 8.2 结论分级与证据链

每条结论都要说清自己是「量到的」还是「猜的」：

| 级 | 含义 | 例子 |
|---|---|---|
| `known` | 直接读到的硬事实 | DXF 里 `$INSUNITS=4`、DWG 头是 `AC1032`、实体数 13 |
| `scaled` | 读到锚点后换算出来的 | 按 INSUNITS=4 把 100 换算成 100mm |
| `inferred` | 有依据但没直读到 | 图层里有 HATCH 就推断有填充区 |
| `unreadable` | 想读但读不到 | 文件打不开、变量不存在、段被截断 |

五态结论（`Get-CadDisposition`，取命中的最高档）：

| 结论 | 触发条件 |
|---|---|
| `blocked` | 有 `BlockedReason` |
| `fail` | 有 error |
| `needs_review` | 只有 `unreadable` / `inferred` 级证据 |
| `pass_with_warnings` | 有 warning |
| `pass` | 全部 `known` 级 |

⚠️ **产物存在与否不改变结论档位** —— `error` + 有半成品仍然只是 `fail`，不会升级成 `blocked`。产物在不在只影响调用方能不能救回半成品。

**清单复现**（`New-CadManifest` / `Write-CadManifest` / `Compare-CadManifest`）回答「这两次跑出来的是不是同一张图」。只比 `specSha256`、`cadCoreSha256`、`units.code`、`entityCount`、`artifacts[].sha256`；**不比** `timestamp`、路径、`disposition`。两个哈希是 `New-CadManifest` 自己现算的，读不到就给 `$null` 让比对判差异 —— **绝不填假哈希**（假哈希会让 `identical=true` 变成谎言）。

单位校验三个函数别混用：`Get-CadUnitCode -Name`（`mm`/`毫米` → 4，认不出返 -1，`unitless` → 0）、`Get-CadDrawingUnits -Path`（一张 DXF，返 `units` `unitToMm`）、`Test-CadUnits -Path -Expected`（返 `match` 三值，`$null` = 不知道）。

`Test-CadRequiredLayers` 把结果分成三类，**三者对调用方是不同的诊断**：`present`（有声明也有实体）/ `empty`（有声明但模型空间没实体：建了层却漏画）/ `missing`（连声明都没有）。

### 8.3 PDF 矢量路径 → DXF

```powershell
& "$s\Convert-CadPdfToDxf.ps1" -Path .\plan.pdf -Output .\plan.dxf -Scale 0.352778 -AsJson
```

纯本地解析，不启动任何进程，**没有 `-TimeoutSeconds`**。支持 `m/l/c/v/y/re/h` 路径算子、`S/s/f/F/f*/B/B*/b/b*/n` 上色算子、`q/Q/cm/w` 图形状态，FlateDecode 与 AsciiHex 过滤器。产物是 R12（AC1009）DXF：两点出 `LINE`，多点亮式 `POLYLINE`（`66=1` + VERTEX + SEQEND）。

三条实现铁律（源码里有注释）：

1. **`switch` 必须加 `-CaseSensitive`**。不加的话 `'q'` 分支压栈、`'Q'` 分支又弹栈，`cm` 变换被静默清掉 —— 症状是坐标原样透传、缩放丢失、位置偏移，**没有任何报错**。
2. **CTM 快照要连 `lineWidth` 一起存**。
3. **`Get-CadPdfStreams` 在没找到流时返回 `$null`**，取 `.Count` 会抛异常而报错位置指向 `return` 行。一律先 `@(...)` 包一层。

位图 PDF（只含 DCTDecode XObject）会明确报「没找到可解析的矢量内容流，这多半是扫描件，需要先 OCR/矢量化」，exit 1 —— **不猜、不画一个空图交差**。

**「范围落在 MediaBox 内」是 CTM 哨兵**：丢了 `cm` 矩阵时坐标会原样透传，典型症状是坐标跑到 372–6369 而 MediaBox 只有 842 宽。

### 8.4 图片预检

```powershell
& "$s\Get-CadImageInfo.ps1" -Path .\photo.png -AsJson
```

四个函数分工（都在 `CadImage.ps1`）：`Get-CadImageInfo`（这是什么图）、`Get-CadImageInk`（有多少墨、偏在哪）、`Test-CadImageUsable`（能不能照抄，返 `ok`/`issues[]`/`advice`）、`Get-CadImageAscii`（让纯文本模型也「看」到形状）。

`darkIsInk` 自动判断：平均亮度 < 110 时按「亮的是墨」处理 —— 否则 AutoCAD 黑底截图会被算成满墨，包围盒直接等于整张图。

⚠️ **逐像素循环里绝不调 `Get-CadImageLuma`**：实测 400×260（10 万像素）从 130ms 涨到 2700ms，慢 20 倍。

## 9. 如何自动修复

```powershell
& "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts\Invoke-CadRepair.ps1" -SpecFile .\demo.json -DryRun -AsJson
```

先 `-DryRun` 看它想做什么，确认后再去掉。报告 `mode` 字段区分 `dry-run` 与 `repair`。

14 条规则：

| id | 检查项 | 会不会动文件 |
|---|---|---|
| R01 | accoreconsole 定位不到 / 路径失效 | 会（重新探测并写配置） |
| R02 | `SECURELOAD` 未关 | 只报告 |
| R03 | 环境变量指向的文件不存在 | 会（清理失效值） |
| R04 | `cadcore.lsp` 是 UTF-8 而非 GBK | 会（重新转码） |
| R05 | 遗留工作目录 | 会（清理超期的） |
| R06 | `.lsp` 带 BOM | 会（重写） |
| R07 | `SAVEAS` 目标已存在（会卡在「此名称的图形已存在」） | 会（删掉目标） |
| R08 | 目标目录不存在 | 会（创建） |
| R09 | DWG 0 字节或 <2KB | 会（删除残片） |
| R10 | DXF 缺 ENTITIES 段 | 会（删除残片） |
| R11 | 遗留 accoreconsole 进程 | 只报告（见下） |
| R12 | 上次执行超时未退出 | 会（清理登记） |
| R13 | LISP 括号不平衡 | 只报告 |
| R14 | 未声明的图层 | 只报告（编译器已自动补建） |

**R11 为什么只报告**：本技能绝不按名字批量结束进程。只有「本技能自己启动、且登记在案、且 PID+启动时间+进程名全对」的进程才会被结束。你手动开着的 AutoCAD 不在其中。

## 10. 进程安全

三道闸，缺一不可：

1. **启动时登记**：记 `{pid, startTime, name, kind, source}` 到 `%APPDATA%\cad-automatic-wwj\processes.json`。
2. **结束时核验**：PID 存在 **且** 启动时间一致 **且** 进程名一致，三条全对才认。
3. **超时杀树**：先 BFS 走 `Win32_Process.ParentProcessId` 收集整棵进程树，先杀子再杀父，最后兜底复查一遍 —— 只杀父进程会留孤儿（实测 mock 的 cmd 包装器派生 pwsh 后，`Kill()` 只杀 cmd，pwsh 继续跑）。

## 11. 常见错误如何处理

| 现象 | 原因 | 处理 |
|---|---|---|
| `参数类型错误: stringp nil`，报错指向文件头 | LISP 是 UTF-8 写的 | 用 `Write-CadLsp` 重写（GBK），见 6.5 |
| 卡在「此名称的图形已存在」 | `SAVEAS` 目标已存在 | 先 `vl-file-delete`，或跑 `Invoke-CadRepair` |
| `*无效选择*` + `需要点或窗口(W)/…` | 有命令停在「选择对象」并吃掉了后续坐标 | 见 R13 / `troubleshooting.md` 的 -BLOCK 那一节 |
| 进程不退出，只能等超时 | scr 末尾缺 `_.QUIT` | 本技能生成时已加；手写 scr 要自己补 |
| `; 错误: 参数太少` | LISP 没有可选参数，少传一个就报这个 | 对照 `cadcore.lsp` 的 `defun` 参数表补齐 |
| 中文变 `澶氳鏂囧瓧` | DXF 被当 GBK 读了 | 已修（严格 UTF-8 优先）；若手改过 `Read-CadDxfPairs` 要改回来 |
| 打印出来的 PDF 是空的 | 打印范围选错 / 图层全关 | 用 `-PlotArea Extents`，检查图层是否可见 |
| `未知命令 "N"` | `_N` 兜底数量加多了，被上一条命令消费掉了 | 只在确定已退出命令状态的位置加 |
| PDF 转出的 DXF 坐标跑到几千几万 | `switch` 没加 `-CaseSensitive`，`cm` 变换被 `Q` 分支静默清掉 | 改成 `switch -CaseSensitive ($op)` |
| 「在此对象上找不到属性 Count」，报错指向 `return` 行 | `Get-CadPdfStreams` 零流返 `$null`，取 `.Count` 抛异常 | `@(Get-CadPdfStreams -Bytes $bytes)` 包一层 |
| DXF 解析出 0 对、`(0,SECTION)` 被吃 | 文件带 UTF-8 BOM，`Trim()` 剥不掉 `\uFEFF` | `Read-CadDxfPairs` 已加首字符 BOM 剥离 |
| 图纸尺寸读出来是 `(0,0)` | `Get-CadExtentSize` 的 while 只判 code 9，跨段界读进实体坐标 | 停止条件补 `-and $pairs[$j].code -ne 0` |

完整诊断树见 [skill/references/troubleshooting.md](skill/references/troubleshooting.md)。

## 12. 已知限制

- **只测过 AutoCAD 2018**。2013–2025 的接口理论上一致（都是 `accoreconsole` + LISP），但没有逐一验证。低版本可能不认较新的 DXF 版本号。
- **COM 通道不适用于无界面机器**：`acad.exe` 要真的起得来。`Invoke-CadCom.ps1` 有 `-Visible` 但默认不可见，起一次约 25 秒。且 PowerShell 的 COM 编组不支持 `VT_ARRAY|VT_DISPATCH`，`CopyObjects` 跑不通（复制实体请走 `COPYCLIP`/`WBLOCK` 或选择集重建）。
- **accoreconsole 没有布局引擎**：`layoutlist` / `-LAYOUT` / `setvar "CTAB"` / `tblnext "LAYOUT"` / 410 组码全不可用，要操作图纸空间只能走 COM 通道打开 `acad.exe`。
- **DXF 版本控制走 `SAVEAS`**：`DXFOUT` 的第二个参数是精度不是版本（实测传 `"12"/"13"/"16"` 全出 `AC1032`）。
- **不支持天正/中望等第三方对象**：只有 AutoCAD 原生实体能保证被解析。
- **不做批量/多图并行**：一次一个 `accoreconsole` 实例，并发要调用方自己排。
- **不写 `.dwt` 模板**：只从空白图开始画。

## 安全说明

- 安装脚本只写当前用户的技能目录，**不改环境变量、不改注册表、不动 PATH**。
- 出图脚本会对 `SAVEAS` 的目标文件做**删除**操作（否则会卡在覆盖确认）。所以 `-OutputDir` 只指给你愿意被覆盖的目录。
- `Invoke-CadRepair` 的删除动作全部限定在它自己的工作目录与它自己登记过的文件内，不碰你其他图纸。
- **绝不按名字批量结束 `acad.exe` / `accoreconsole.exe`**，只结束自己启动且登记在案的进程。

## 自检与测试

```powershell
$s = "$env:USERPROFILE\.dsh\skills\cad-automatic-wwj\scripts"

# 1) 单元测试（秒级，不需要 AutoCAD）
pwsh -File "$s\run-unit-test.ps1"                       # 240 项

# 2) 集成自检（真出图，约 20 秒）
pwsh -File "$s\run-test.ps1" -Test all                  # 65 项

# 3) 场景测试（三档）
pwsh -File "$s\run-scenario-test.ps1" -Mode offline     # 14 个，纯编译校验
pwsh -File "$s\run-scenario-test.ps1" -Mode mock        # 11 个，坏路径注入
pwsh -File "$s\run-scenario-test.ps1" -Mode real        # 3 个，真机
pwsh -File "$s\run-scenario-test.ps1" -ListScenarios     # 看全部场景
```

当前状态：**240 / 240**、**65 / 65**、**14 / 14**、**11 / 11**、**3 / 3**，全绿。

三档模式回答三个不同的问题：

| 模式 | 数量 | 证明什么 | **不能**证明什么 |
|---|---|---|---|
| `mock` | 11 | 脚本对 accoreconsole 输出的**解析与判定**是对的 | 真机行为 |
| `offline` | 14 | 编译与预检逻辑、编码、PDF/DXF 解析、清单比对 | 任何真机交互 |
| `real` | 3 | 真 accoreconsole 全链路 | 别的机器/别的 AutoCAD 版本 |

`-Mode mock` 用一个假的 `accoreconsole` 注入坏路径（无产物、无 `@@DONE@@`、LISP 报错、图找不到、坏 DXF、坏 PDF、弹对话框、卡死），证明**判定逻辑本身**是有效的。

## 目录结构

```
cad-automatic-wwj/
├─ README.md                      本文件
├─ 使用教程.md                     手把手教程（给第一次用的人）
├─ Install-Skill.ps1              安装 / 更新 / 卸载
├─ Publish-ToGitHub.ps1           发布到 GitHub
├─ LICENSE                        MIT
├─ .gitignore
└─ skill/
   ├─ SKILL.md                    技能主文档（智能体读这个）
   ├─ agents/openai.yaml          展示名与默认提示词
   ├─ assets/
   │  ├─ samples/                 4 份可跑的示例 JSON
   │  └─ fixtures/                故意做坏的样张
   ├─ references/
   │  ├─ spec.md                  JSON schema 全字段说明
   │  ├─ commands.md              cadcore.lsp 的 55 个函数 + 11 个 CLI
   │  ├─ protocol.md              accoreconsole 协议与回执格式
   │  ├─ troubleshooting.md       诊断树
   │  └─ install.md               各平台安装细节
   └─ scripts/
      ├─ CadCommon.ps1            公共库（31 个函数）
      ├─ CadCompiler.ps1          JSON → LISP
      ├─ CadEvidence.ps1          证据分级 / 五态结论 / manifest / 单位与图层
      ├─ CadSpecCheck.ps1         出图前 spec 预检
      ├─ CadPdf.ps1               PDF 内容流解析 → DXF
      ├─ CadImage.ps1             图片像素与墨迹分析
      ├─ cadcore.lsp              LISP 命令库（51 个 c:XXX）
      ├─ Invoke-CadDraw.ps1       出图主入口
      ├─ Invoke-CadInspect.ps1    体检
      ├─ Export-CadToDxf.ps1      导出 DXF
      ├─ Invoke-CadPlot.ps1       打印 PDF
      ├─ Invoke-CadCom.ps1        COM 通道
      ├─ Invoke-CadRepair.ps1     诊断修复
      ├─ Set-CadPath.ps1          配置路径
      ├─ run-unit-test.ps1        单元测试
      ├─ run-test.ps1             集成自检
      ├─ run-scenario-test.ps1    场景测试
      └─ mock/                    假 accoreconsole（测试用）
```

## 技术原理

不用 COM、不用 ObjectARX、不用任何第三方库，只走一条路：

```
JSON spec
  → Test-CadSpec.ps1 出图前预检（负半径 / 宽 0 / 坐标爆表 / 重复 id）
  → CadCompiler.ps1 编译成 LISP 调用序列
  → 写盘（GBK/CRLF）为 drawing.lsp
  → 写盘（GBK/CRLF）为 draw.scr：加载 LISP → 执行 → SAVEAS/DXFOUT/PLOT → QUIT
  → accoreconsole /i blank.dwg /s draw.scr
  → 读 stdout（UTF-16LE）抓 @@KEY=value@@ 回执
  → 独立校验产物字节（DWG 头 / DXF 结构 / PDF 结构）
  → 出 manifest：spec 与 cadcore 的 SHA-256 + 产物哈希，供下次比对
```

选 `accoreconsole` 而不是 COM 的原因：无界面、启动快（约 4 秒 vs 25 秒）、不需要 `acad.exe`、不会被弹窗卡住、进程退出干净。COM 只作为备用通道。

## 跨智能体使用

技能本身是「一篇 `SKILL.md` + 一堆命令行脚本」，任何能跑 PowerShell 的智能体都能用：

- **DSH / Codex / Claude Code**：把 `skill/` 放进对应技能目录，用 `$cad-automatic-wwj` 触发。
- **其他**：直接读 `skill/SKILL.md`，按里面的入口调用脚本即可，不依赖 DSH 特有机制。

## 许可

MIT，见 [LICENSE](LICENSE)。
