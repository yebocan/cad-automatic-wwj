# 图纸规格 JSON（Spec）完整参考

`Invoke-CadDraw.ps1 -SpecFile xxx.json` 吃一个 JSON，编译成 LISP 再交给 accoreconsole 执行。
本文件是这个 JSON 的完整字段表 —— **字段名必须一字不差**，编译器不做模糊匹配（少数同义写法已在下文用「同义」标出）。

改完 JSON 不用碰 LISP。想加新实体类型才需要动 `cadcore.lsp` + `CadCompiler.ps1`。

---

## 1. 顶层结构

```json
{
  "name": "flange-plate",
  "units": "mm",
  "layers": [ ... ],
  "blocks": [ ... ],
  "entities": [ ... ],
  "save": { ... },
  "zoom": true
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 否 | 只用于日志/报告，不写进图纸 |
| `units` | string | 否 | **会真的生效**：合法值会生成 `(cadunits <code>)` 在出图前 `setvar "INSUNITS"`。合法值见下表；不写或写错只记 warning 不挡路 |
| `layers` | array | 否 | 图层声明。**实体引用了但没声明的图层会自动补建**（颜色 7）并记 warning |
| `blocks` | array | 否 | 块定义 |
| `views` | array | 否 | **多视图模式开关**：非空即进入多视图模式，一份 spec 拆成多张图。结构见下方「多视图 `views[]`」 |
| `entities` | array | * | 实体列表，按数组顺序依次创建。**多视图模式下可以省**（共享实体为空时），前提是至少有一个视图带了本地实体；两者都空仍然报错 |
| `save` | object | 否 | 存盘/导出。不写就只画不存（适合 `-DryRun` 之外的快速验证）。多视图模式下按视图克隆，文件名前插 `<vid>-` |
| `constraints` | object | 否 | 出图前的约束校验，见第 8 节 |
| `zoom` | bool | 否 | 默认 `true`。画完执行 `c:ZOOMEXT` |

`entities` 缺失或为空数组都不会崩，只是画出空图（`entityCount=0`）。

### 多视图 `views[]`

```json
{
  "name": "bracket",
  "views": [
    { "id": "front", "name": "主视图" },
    { "id": "top",   "name": "俯视图" }
  ],
  "entities": [
    { "type": "circle", "c": [0,0], "r": 10, "view_id": "front" },
    { "type": "rect",   "p1": [0,0], "p2": [30,20] },
    { "type": "point",  "at": [0,0] }
  ],
  "save": { "dwg": "bracket.dwg", "dxf": true }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `views[].id` | string | **必填** | 视图标识。**不区分大小写地查重**——`front` 与 `FRONT` 同时出现报错 |
| `views[].name` | string | 否 | 显示名，进报告与 manifest |

拆分规则（`Get-CadSpecViewSpecs`）：

- `view_id` 指向视图 X 的实体 → 只进 X 的子 spec；
- **无 `view_id` 的实体 → 进所有视图**（共享实体）；
- 全局 `units` / `layers` / `blocks` / `zoom` / `calibration` 照搬进每个子 spec；
- `save` 逐视图克隆，文件名前插 `<vid>-`（`bracket.dwg` → `front-bracket.dwg` / `top-bracket.dwg`；绝对路径保留目录只改文件名）；
- 子 spec `name` = `<原名>-<vid>`。

校验规则（`Test-CadSpec`，出错即 `blocked`）：

1. `views[].id` 缺失或重复 → 报错（错误信息带 `views[i]` 定位）；
2. 实体 `view_id` 引用了不存在的视图 → 报错；
3. `constraints.required_view_ids` 引用了不存在的视图 → 报错；
4. `entities` 与 `views` **都**为空 → 报错（原规则不变）；`entities` 空但 `views` 非空 → 放行；
5. 视图内实体本身字段错误 → 报错带 `views[i](vid).entities[j]` 定位。

执行（`Invoke-CadDraw`）：无 `views[]` 行为与以前完全一样；有 `views[]` 时逐视图出图、逐视图独立 manifest，聚合报告顶层 `status`/`disposition` 取所有视图的**最差档**，`entityCount` 求和，视图级 warning 前缀 `[视图 <id>]`，并带 `multiView: true` 与 `views[]` 明细（每视图 `{id, status, disposition, entityCount, artifacts, manifest, report}`）。单个视图 `blocked`（如校验错误）不拖累其他视图执行，但顶层结论如实反映（exit 4）。

### `units` 合法值

| 写法 | INSUNITS | 含义 |
|---|---|---|
| `unitless` | `0` | 无单位 |
| `in` / `英寸` | `1` | 英寸 |
| `ft` / `英尺` | `2` | 英尺 |
| `mm` / `毫米` / `公厘` | `4` | 毫米 |
| `cm` / `厘米` | `5` | 厘米 |
| `m` / `米` / `公尺` | `6` | 米 |

不写 `units` 不生成 `cadunits` 调用（保持图纸原样），记 warning「spec 未声明 units」；写错只记 warning 并列出可用值。

---

## 2. `layers[]`

```json
{ "name": "HOLE", "color": 1, "ltype": "DASHED" }
```

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `name` | string | **必填** | 图层名。已存在则只更新颜色/线型 |
| `color` | int | `7` | AutoCAD 颜色号 1–255。**越界或非整数会回落 7 并记 warning**，不会崩 |
| `ltype` | string | `""` | 线型名。`""` 表示不动。`DASHED`/`CENTER`/`HIDDEN` 等需已加载 |
| `ltypeScale` | double | — | 保留字段，当前未下发 |

> 编译器内部固定调用 `(c:LAYER name color ltype)` 三个实参 —— LISP 没有默认值，缺一个就报「参数太少」。
>
> **线型不存在会让 `-LAYER` 悬停到超时**：AutoCAD 只打一行「未找到线型」，然后继续等输入。`c:LAYER` 会先 `(tblsearch "LTYPE" ltype)` 查一下，查不到就退回 `CONTINUOUS`，并在回执里打 `@@LTYPE_MISSING.<图层>=<你写的线型>@@`，报告里变成一条 warning。

---

## 3. `entities[]` — 通用字段

每个实体都有：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `type` | string | **必填** | 见下表 |
| `layer` | string | 顶层默认图层（`0`） | 非 `0`/非空时切 `CLAYER` |
| `comment` | string | — | 只回显到 LISP 注释，便于调试 |
| `id` | string | — | 实体唯一标识。**多视图模式下必须全局唯一**，任何视图重复都报错 |
| `view_id` | string | — | **多视图模式专用**：指向 `views[]` 里某项的 `id`。指向的实体只画进那个视图；**不写 `view_id` 的实体是共享实体，画进所有视图** |

点（point）的写法有三种，处处通用：

```json
[10, 20]              // 数组
"10,20"               // 字符串
{ "x": 10, "y": 20 }  // 对象
```

---

## 4. 各实体类型的字段表

### 4.1 `line`

```json
{ "type": "line", "p1": [0,0], "p2": [100,50], "layer": "GEO" }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `p1` | ✔ | 起点 |
| `p2` | ✔ | 终点 |

通道：`(cadcmd (list "_.LINE" p1 p2 ""))`

---

### 4.2 `polyline`

```json
{ "type": "polyline", "points": [[0,0],[50,30],[100,0]], "closed": false }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `points` | ✔ | — | ≥2 个点 |
| `closed` | 否 | `false` | `true` 时末尾发 `_C` 闭合 |

通道：`(cadcmd (list "_.PLINE" p1 p2 ... <closed? "_C"> ""))`

---

### 4.3 `circle`

```json
{ "type": "circle", "c": [60,60], "r": 20 }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `c` | ✔ | 圆心 |
| `r` 或 `radius` | ✔ | 半径，必须 > 0 |

---

### 4.4 `arc`

```json
{ "type": "arc", "c": [100,60], "r": 50, "start": 0, "end": 180 }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `c` | ✔ | 圆心 |
| `r` 或 `radius` | ✔ | 半径 |
| `start` 或 `startAngle` | ✔ | 起始角，**度** |
| `end` 或 `endAngle` | ✔ | 终止角，**度**，逆时针 |

角度是度不是弧度。LISP 侧内部转弧度。

通道：`(c:ARC cx cy r startDeg endDeg)` —— 走 LISP 而非命令，因为 `_.ARC` 的提示序列在不同版本里不一致。

---

### 4.5 `rect`

```json
{ "type": "rect", "p1": [0,0], "p2": [200,120] }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `p1` | ✔ | 对角点 1 |
| `p2` | ✔ | 对角点 2 |

通道：`(cadcmd (list "_.RECTANG" p1 p2))`

---

### 4.6 `ellipse`

```json
{ "type": "ellipse", "at": [0,0], "rx": 30, "ry": 15, "rotation": 0 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` 或 `c` | ✔ | — | 中心 |
| `rx` 或 `r` | ✔ | — | 长轴半径 |
| `ry` | ✔ | — | 短轴半径 |
| `rotation` | 否 | `0` | 旋转角（度） |

---

### 4.7 `point`

```json
{ "type": "point", "at": [10,10] }
```

| 字段 | 必填 |
|---|---|
| `at` 或 `c` | ✔ |

注意 `PDMODE`/`PDSIZE` 决定点是否可见。默认 `PDMODE=0` 画出来的点看不见，但 DXF 里有 POINT 实体。

---

### 4.8 `spline`

```json
{ "type": "spline", "points": [[0,0],[10,10],[20,0],[30,10]] }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `points` | ✔ | ≥3 个控制点 |

通道：`(cadcmd (list "_.SPLINE" p1 p2 ... "" "" ""))` —— 三个空串分别结束「下一点」「起点切向」「终点切向」。

---

### 4.9 `polygon`

```json
{ "type": "polygon", "at": [0,0], "r": 50, "sides": 6 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` 或 `c` | ✔ | — | 中心 |
| `r` | ✔ | — | 外接圆半径 |
| `sides` | 否 | `6` | 边数，3–1024 |

---

### 4.10 `gear`

```json
{ "type": "gear", "at": [0,0], "r": 50, "teeth": 20 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` 或 `c` | ✔ | — | 中心 |
| `r` | ✔ | — | 分度圆半径 |
| `teeth` | 否 | `20` | 齿数 |

齿轮是「近似」的：用 LWPOLYLINE 逐齿画梯形，不是真正的渐开线。要精确齿形请导出 DXF 后用专业插件。

---

### 4.11 `centerline`

```json
{ "type": "centerline", "at": [100,60], "len": 150 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` 或 `c` | ✔ | — | 中心 |
| `len` 或 `length` | 否 | `100` | 总长 |

画一条水平 + 一条垂直的点划线十字（用当前图层）。

---

### 4.12 `boltpattern`

```json
{ "type": "boltpattern", "at": [100,60], "r": 40, "count": 6, "holeR": 8 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` 或 `c` | ✔ | — | 分布圆中心 |
| `r` | ✔ | — | 分布圆半径 |
| `count` | 否 | `6` | 螺栓孔个数 |
| `holeR` | 否 | `r/8` | 每个孔半径 |

一次画出 `count` 个圆 + 分布圆虚线。

---

### 4.13 `text`

```json
{ "type": "text", "at": [10,128], "height": 6, "value": "图纸 A-01", "rotation": 0, "align": "BL" }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` | ✔ | — | 插入点 |
| `value` | ✔ | — | 文本内容，支持中文 |
| `height` | 否 | `2.5` | 字高 |
| `rotation` | 否 | `0` | 旋转角（度） |
| `align` | 否 | `BL` | 对齐方式：`L`/`C`/`R`/`BL`/`BC`/`BR`/`ML`/`MC`/`MR`/`TL`/`TC`/`TR` |

通道：`(cadcmd (list "_.TEXT" "_J" align at height rot value))`

> 中文能正确写入，因为 lsp 文件本身按 GBK 落盘（AutoCAD 2018 内部代码页 936）。

---

### 4.14 `mtext`

```json
{ "type": "mtext", "at": [10,110], "width": 80, "height": 4, "value": "多行文字\n第二行" }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `at` | ✔ | — | 左上角插入点 |
| `value` | ✔ | — | 内容，`\n` 换行 |
| `width` | 否 | `100` | 行宽（自动换行宽度） |
| `height` | 否 | `10` | 字高 |

**通道是 `entmake`，不是命令。** 因为 `_.MTEXT` 会弹「多行文字编辑器」对话框，accoreconsole 无 UI 会永远悬在那里。

entmake 组码：`(0."MTEXT")(100."AcDbEntity")(8.layer)(100."AcDbMText")(10.x,y,0)(40.h)(41.w)(71.1)(72.5)(1.txt)(7.style)(50.0)`

---

### 4.15 `dimlinear`

```json
{ "type": "dimlinear", "p1": [0,0], "p2": [200,0], "textAt": [100,-20] }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `p1` | ✔ | 延伸线 1 原点 |
| `p2` | ✔ | 延伸线 2 原点 |
| `textAt` 或 `text` | ✔ | 标注文字位置（决定标注线在哪） |

水平/垂直自动判断（`p1`/`p2` 谁的角度更接近 0 或 90）。

通道：`entmake` + `(50 . 0.0)` + `AcDbRotatedDimension` 尾。**这三个都不能少**，缺一个 entmake 就静默返回 nil。

---

### 4.16 `dimaligned`

```json
{ "type": "dimaligned", "p1": [0,0], "p2": [100,50], "textAt": [50,25] }
```

字段同上。

通道：`entmake` + `(50 . <真实角度弧度>)`，**绝对不加 `(52 . ...)`，绝对不加 `AcDbRotatedDimension` 尾**。

> 这是本 skill 踩过最深的坑之一，四个变体实测：
> - `50 + 52 + 无尾` → **nil**（画不出来）
> - `仅 50` → **ok** ✅
> - `无 50 无 52` → ok（但斜线标注会歪）
> - `50 + RotatedDimension 尾` → **nil**

---

### 4.17 `dimradius`

```json
{ "type": "dimradius", "c": [60,60], "r": 20, "textAt": [75,75] }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `c` | ✔ | 圆心 |
| `r` | ✔ | 半径（用于找目标圆） |
| `edge` 或 `textAt` | 否 | 标注文字位置；缺省取圆心与边缘中点 |

实现细节：`c:DIMRAD` 会用 `(ssget "_X" '((0 . "CIRCLE")))` 按「圆心 ±0.5 + 半径」找到那个圆的 ename 再传给 `entmake`。

> 曾经直接把边缘点当选择对象传，accoreconsole 回 `*无效选择* 需要单个对象` + `; 错误: 函数已取消`，**把后续所有命令一起吞掉**（看起来像「画了一半就停」）。所以这里必须先精确选中。

---

### 4.18 `hatch`

```json
{ "type": "hatch", "pattern": "ANSI31", "scale": 2, "at": [100,30] }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `pattern` | 否 | `ANSI31` | 图案名，需已加载 |
| `scale` | 否 | `1` | 图案比例 |
| `at` 或 `seed` | ✔ | — | 内部种子点 |

实现在 `c:HATCH` 里先 `setvar HPNAME/HPSCALE/HPANG`，再 `(cadcmd (list "_.-HATCH" seedPoint ""))` —— **不要 `_S`**。

> 又一个坑：原写法用 `_S`（Select objects）+ 点坐标，命令不报错但 **hatch 根本没创建**，而 `(entlast)` 返回的是上一个实体，于是回执里的 handle 与上一个实体相同 —— 证据行看着像成功。修法：创建后 `(ssget "_X" '((0 . "HATCH")))` 数一遍并校验实体类型，不成立就回 `FAILED-no-hatch-created`。

---

### 4.19 `solid`

```json
{ "type": "solid", "points": [[0,0],[10,0],[10,10],[0,10]] }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `points` | ✔ | 恰好 3 或 4 个点 |

注意 `_.SOLID` 的顶点顺序是「Z」字（1-2-4-3），不是顺时针。

---

### 4.20 `block`

```json
{ "type": "block", "name": "BOLT-M8", "at": [120,60], "scaleX": 1, "scaleY": 1, "rotation": 0 }
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `name` | ✔ | — | 块名，必须在顶层 `blocks[]` 里定义过 |
| `at` | ✔ | — | 插入点 |
| `scaleX` / `scaleY` | 否 | `1` | 缩放 |
| `rotation` | 否 | `0` | 旋转角（度） |

通道：`(c:INSERTBLOCK name x y sx sy rot)` —— 六个实参一个都不能少。

---

### 4.21 `erase`

```json
{ "type": "erase", "entityType": "HATCH" }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `entityType` | ✔ | 要删除的实体类型名（DXF 名，如 `HATCH`/`POINT`） |
| `layer` | 否 | 只删该图层上的 |

删除类操作用它。要清整个图层用 `c:DELLAYER`（命令行）。

---

## 5. `blocks[]`

```json
{
  "blocks": [
    {
      "name": "BOLT-M8",
      "base": [0,0],
      "entities": [
        { "type": "circle", "c": [0,0], "r": 4 },
        { "type": "circle", "c": [0,0], "r": 7 }
      ]
    }
  ]
}
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `name` | ✔ | — | 块名 |
| `base` | 否 | `[0,0]` | 基点 |
| `entities` | ✔ | — | 块内实体，语法与顶层 `entities` 完全相同 |

块定义用 `c:BEGBLOCK` / `c:ENDBLOCK` 一对，**不是**把 `(command "_.-BLOCK" ...)` 包住画图命令。

原因是 `-BLOCK` 给完基点和名字就进「选择对象:」，**不会**进入「后续实体自动入块」状态，后面那条画图命令的坐标会被当成「选择点」吃掉 → `*无效选择*` → 整张图卡到超时。`(princ "\n")` 也救不了（princ 只往 stdout 打字，不往命令输入队列送回车）。

正确流程：

1. `c:BEGBLOCK` 记下进块前的 `(entlast)`；
2. 块内实体正常画到模型空间；
3. `c:ENDBLOCK` 用 `(entnext)` 从记下的那个之后走到尾，全部 `ssadd` 进选择集；
4. `(cadcmd (list "_.-BLOCK" name (list x y) ss ""))` 一次性把选择集喂进去；
5. 用 `(tblobjname "BLOCK" name)` + `entnext` 数一遍块内实体数，确认真的成了。

---

## 6. `save{}`

```json
"save": {
  "dwg": "out/plan.dwg",
  "version": "2018",
  "dxf": true,
  "dxfVersion": "2013",
  "pdf": "A3",
  "pdfSize": null
}
```

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `dwg` | string | — | 目标 DWG 路径。相对路径相对 `-OutputDir` |
| `version` | string | `2018` | **DWG 保存格式**，白名单：`R14`/`2000`/`2004`/`2007`/`2010`/`2013`/`2018`。非法值会 warning 并回落 `2018` |
| `dxf` | bool 或 string | — | `true` → 与 `dwg` 同名换 `.dxf`；给字符串 → 用该路径 |
| `dxfVersion` | string | `2018` | **DXF 导出格式**，白名单：`R12`/`2000`/`2004`/`2007`/`2010`/`2013`/`2018` |
| `pdf` | string | — | 图纸尺寸名，给值即出 PDF（如 `"A3"`/`"A4"`/`"A2"`） |
| `pdfSize` | string | `A3` | `pdf` 为 `true` 时的尺寸 |

### `version` 与 `dxfVersion` 为什么分开

它们是两条完全独立的通道，而且机制差别很大：

- **DWG**：`SAVEAS` 的提示序列是「**格式在前、文件名在后**」：
  ```
  当前文件格式: AutoCAD 2018 图形
  输入文件格式 [R14(LT98&LT97)/2000(LT2000)/.../2018(LT2018)/标准(S)/dxf(DXF)/样板(T)] <2018>: 2013
  输入文件名: out.dwg
  ```
  只认白名单关键字。给 `"16"` 或 `"2013年"` 会回「无效的选项关键字」并把后续命令一起吞掉。

- **DXF**：`DXFOUT` 的**第二个参数是小数精度，不是版本**。
  `(c:SAVEDXF "p" "12")` / `"13"` / `"16"` 导出的**版本行全是 AC1032**，只有文件大小略微变化（精度差异），这是本 skill 里最有迷惑性的假象。真正的版本开关藏在精度提示的选项里：
  ```
  输入精度的小数位数 (0 到 16) 或 [二进制(B)/选择对象(O)/预览(P)/版本(V)] <16>:
  ```
  于是正确序列是：文件名 → `_V` → 版本名 → 精度 → 二进制。
  实测（用文件头 `AC10xx` 校验，不是看提示回显）：

  | 版本名 | 文件头 | 大小参考 |
  |---|---|---|
  | `R12` | `AC1009` | 7,783 字节 |
  | `2000` | `AC1015` | 214,619 字节 |
  | `2004` | `AC1018` | — |
  | `2007` | `AC1021` | — |
  | `2010` | `AC1024` | — |
  | `2013` | `AC1027` | 125,759 字节 |
  | `2018` | `AC1032` | 默认，不切换 |

  短写 `c:SAVEDXF "p" "16"` 时，`"16"` 会被当成**版本名** `16` 而不走 `_V` 分支之外…… 别这么写。第三个参数才是精度。

---

## 7. 完整示例

```json
{
  "name": "flange-plate",
  "units": "mm",
  "constraints": { "maxEntities": 20, "requiredLayers": ["GEO", "HOLE", "DIM"] },
  "layers": [
    { "name": "GEO",    "color": 7 },
    { "name": "HOLE",   "color": 1 },
    { "name": "CENTER", "color": 8, "ltype": "CENTER" },
    { "name": "DIM",    "color": 3 },
    { "name": "TXT",    "color": 2 }
  ],
  "entities": [
    { "type": "rect", "p1": [0,0], "p2": [200,120], "layer": "GEO" },
    { "type": "circle", "c": [100,60], "r": 45, "layer": "GEO" },
    { "type": "boltpattern", "at": [100,60], "r": 30, "count": 6, "holeR": 5, "layer": "HOLE" },
    { "type": "centerline", "at": [100,60], "len": 130, "layer": "CENTER" },
    { "type": "text", "at": [10,128], "height": 6, "value": "法兰盘 FL-200", "layer": "TXT" },
    { "type": "dimradius", "c": [100,60], "r": 45, "textAt": [150,110], "layer": "DIM" }
  ],
  "save": { "dwg": "flange.dwg", "dxf": true, "pdf": "A4" }
}
```

跑：

```powershell
.\Invoke-CadDraw.ps1 -SpecFile flange.json -OutputDir .\out -AsJson
```

期望报告里：

```json
{
  "status": "ok",
  "entityCount": 6,
  "exitCode": 0,
  "timedOut": false,
  "artifacts": { "dwg": "...", "dxf": "...", "pdf": "..." },
  "checks": [ { "name": "DWG 落地", "pass": true, "detail": "33072 字节" }, ... ]
}
```

> 注意 `entityCount` 是 **JSON 里声明的实体数**。实际 DXF 里的实体数会更多 —— 块定义、填充边界、标注的组成件都会产生额外实体。所以 `checks` 里"DWG 实体数与 JSON 一致"永远不会成立，编译器只做一个「差额警告」。

---

## 8. `constraints{}` — 出图前约束

```json
"constraints": {
  "maxEntities": 50,
  "minEntities": 1,
  "maxLayers": 8,
  "requiredLayers": ["GEO", "HOLE", "DIM"],
  "units": "mm"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `maxEntities` | int | 声明实体数超过它就报错（防 spec 写飞） |
| `minEntities` | int | 少于它就报错 |
| `maxLayers` | int | 图层数超过它就报错 |
| `requiredLayers` | array | 这些图层必须在 `layers[]` 里声明过 |
| `units` | string | 顶层没写 `units` 时用这个兜 |

**约束冲突是必然失败类错误**，`Test-CadSpec.ps1` 会在启动 AutoCAD 之前就报出来，`Invoke-CadDraw.ps1` 的 `checks` 里也会体现（编译失败数 > 0 时该 check 不通过）。

### 出图前预检会抓的必然失败

| 症状 | 报错 |
|---|---|
| 半径/宽度为负或 0 | `半径必须大于 0` / `宽度为 0` |
| 坐标绝对值超 ±10⁷ | `坐标超出 ±10000000`（多半是单位或小数点写错） |
| `polyline` 只有 1 个点 | `至少需要 2 个点` |
| 点是平铺数字数组 | `是平铺的数字数组，应该是 @(@(x,y),...)` |
| 未知 `type` | 报错文本列出全部 21 种合法取值 |
| 重复 `id` | 点名重复的 id |
| 重复图层 | 点名重复的图层名 |

### 只记 warning 不挡路的四类

未声明图层（编译器会自动补建）、缺 `units`、非法 `units`、`dxfVersion` 非法值 —— 都会给出回落值，不阻止出图。
