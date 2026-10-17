# 排错手册

按症状查。每条都写清「现象 → 根因 → 修法」。这些都是实际踩出来的，不是猜的。

---

## 一、编码类（本 skill 最大的坑）

### 1.1 LISP 报「参数类型错误: stringp nil」，报错位置指向文件头

**现象**：`(load "xxx.lsp")` 之后立刻报错，位置在文件第 1 行或注释行附近。文件本身在编辑器里看起来完全正常。

**根因**：**lsp 文件不是 GBK**。

accoreconsole（AutoCAD 2018）读 `.lsp` 时按系统代码页 936 解释字节。如果文件是 UTF-8：

- 中文注释的 UTF-8 字节被当 GBK 逐字节解释 → 出现乱码字节
- 某些 UTF-8 字节对恰好落在 GBK 的「双字节第二字节」位置上，会把后面的 `"` 或 `)` 吞掉
- 于是 LISP 读到的字符串没有闭合引号 → 解析出 `nil` → `stringp nil` 失败
- 报错位置永远指向文件头部（因为整段被当成一个畸形的表达式）

UTF-8 **带不带 BOM 都一样**会坏。BOM 只是额外多三个坏字节。

**修法**：写 lsp 一律走 `Write-CadLsp`，它固定 GBK + CRLF + 无 BOM。

```powershell
# 对
. .\CadCommon.ps1
Write-CadLsp -Path "$work\cadcore.lsp" -Body ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8))

# 错 —— 直接把 UTF-8 原件 load 进去
# (load "D:/skill/scripts/cadcore.lsp")
```

skill 目录里的 `cadcore.lsp` 是 **UTF-8 无 BOM 的源文件**（为了让 git / 编辑器正常处理）。**绝不能**直接 load 它，必须先转 GBK 副本到工作目录。`Invoke-CadDraw.ps1` / `Invoke-CadInspect.ps1` / `Export-CadToDxf.ps1` 都做了这一步。

**为什么不用 `.NET` 一次转完再对比**：GBK 编码不是一一映射到 Unicode 的，反斜杠、引号在 GBK 里是单字节（ASCII 兼容），所以 `Write-CadLsp` 可以直接用 `[Text.Encoding]::GetEncoding(936)`。

---

### 1.2 DXF 里的中文读出来是「澶氳鏂囧瓧」

**现象**：`Invoke-CadInspect` 读 MTEXT 得到 `澶氳鏂囧瓧\n绗簩琛?`，但同一张图在 AutoCAD 里显示正常，stdout 回执里的中文也对。

**根因**：**DXF 文件体是 UTF-8，不是 GBK。**

这是与 `.lsp` 完全相反的一套规则：

| 文件 | 编码 |
|---|---|
| `.lsp` / `.scr` | **GBK (936)** |
| `.dxf`（AC1032 / AutoCAD 2018） | **UTF-8** |

`澶氳鏂囧瓧` 是典型的「UTF-8 字节被当 GBK 读」的产物。

DXF 头里的 `$DWGCODEPAGE = ANSI_936` **是 DWG 侧遗留的元数据，不决定文件体编码**。别被它骗了。

**修法**：`Read-CadDxfPairs` 已经是「严格 UTF-8 解码，失败回落 GBK」，返回值带 `encoding` 字段（`utf-8` / `gbk`）。

```powershell
$pairs = Read-CadDxfPairs -Path $dxf
$pairs.encoding   # 'utf-8' 或 'gbk'
```

写自己的 DXF 读取代码时照这个来：

```powershell
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)   # throwOnInvalidBytes
try {
    $text = $utf8Strict.GetString([IO.File]::ReadAllBytes($path))
} catch {
    $text = [Text.Encoding]::GetEncoding(936).GetString([IO.File]::ReadAllBytes($path))
}
```

**验证方法**：这是 AC1032 的判据 ——

```powershell
$b = [IO.File]::ReadAllBytes($dxf)
$t = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($b)
($t.ToCharArray() | Where-Object { $_ -eq [char]0xFFFD }).Count   # 应为 0
```

---

### 1.3 scr 文件里的中文命令变成乱码

`.scr` 也是 GBK。`Write-CadScr` 已经处理好。手写 scr 一定不要用 VS Code 的「UTF-8 保存」。

---

### 1.4 stdout 文件用 `Get-Content` 读出乱码

**根因**：accoreconsole 的 stdout 重定向文件是 **UTF-16LE**。

```powershell
# 对
Get-Content $stdoutFile -Encoding Unicode

# 错
Get-Content $stdoutFile                    # 可能猜错
[IO.File]::ReadAllText($stdoutFile)        # 默认 UTF-8，全乱
```

`Invoke-CadCoreConsole` 内部已经用 `-Encoding Unicode` 读，报告里的 `stdoutTail` 是解码后的字符串。

---

## 二、进程/超时类

### 2.1 进程卡住不退出，直到超时

**原因候选**（按概率排）：

1. **scr 末尾没有 `_.QUIT`** —— accoreconsole 读完 scr 会停在「命令:」等下一行输入，永远不结束。
   修法：scr 最后一行必须是 `_.QUIT`。

2. **卡在「是否保存对 xxx 的修改？」** —— 打开 dwg 改了却没保存就 QUIT。
   修法：`_.QUIT` 后补 `_N`（不保存）。

3. **卡在「此名称的图形已存在，是否替换？」** —— `SAVEAS` 目标已存在。
   修法：`SAVEAS` 之前先 `(if (findfile p) (vl-file-delete p))`。

4. **命令在等一个我们没给的参数**（最常见）。
   典型：`(c:SAVEAS "path")` 只给一个实参 —— LISP 函数声明有 2 个形参，报「参数太少」然后整条链断掉。
   **LISP 函数没有默认值**，形参几个就得给几个。

5. **弹了对话框但 accoreconsole 无 UI**。
   典型：`_.MTEXT` 会弹「多行文字编辑器」。修法：改用 `entmake`。
   另一个：`SAVEAS` 到已存在文件。

**诊断三步**：

```powershell
# 1) 看 stdout 尾部停在哪
Get-Content $report.logDir\stdout.txt -Encoding Unicode | Select-Object -Last 20

# 2) 看有多少个 accoreconsole 还活着
Get-Process accoreconsole -ErrorAction SilentlyContinue |
    Select-Object Id, StartTime, CPU

# 3) 用 -KeepArtifacts 保留工作目录，直接看 scr 最后几行
.\Invoke-CadDraw.ps1 -SpecFile x.json -KeepArtifacts -DryRun
```

---

### 2.2 `_N` 兜底反而制造了一个 `_N.dwg`

**现象**：目录里多出一个名为 `_N.dwg` 的文件，31727 字节。

**根因**：`_N` 是给「是否保存修改？」这个问题准备的答案。但如果前面的命令**没有退出命令状态**，`_N` 会被当成那个命令的下一个参数。

实测事故：`_.SAVEAS` 只给了格式没给文件名 → `SAVEAS` 还在等文件名 → 紧接着的 `_N` 被当成文件名 → 存出 `_N.dwg`。

**修法**：

- `_N` 只能加在**确定已经退出命令状态**的位置（`_.QUIT` 之后）
- 数量不要随手堆。`Invoke-CadInspect` 里 `_.QUIT` 后跟 3 个 `_N` 是安全的（QUIT 之后确实在等 3 次确认），但 `Invoke-CadDraw` 里的 3 个 `_N` 是因为它有更多收尾步骤
- 命令参数宁可多给一个空串 `""` 表示「结束」，也别靠 `_N` 兜

---

### 2.3 `Invoke-CadInspect` 对 DWG 要 122 秒

**根因**：scr 末尾只有 `_.QUIT`，没有 `_N` → 卡在「是否保存对 xxx 的修改？」直到 120 秒超时。

**修法**：`_.QUIT` 后补 `'_N', '_N', '_N'`。修后 **3.7 秒**。

---

### 2.4 杀不掉残留 accoreconsole

**原因**：本 skill 有进程登记表（`%APPDATA%\cad-automatic-wwj\processes.json`），`Stop-OwnedCadProcess` 会校验 owner：

```
ownerCheck 取值：
  ok
  no-registry-entry
  caller-not-owner:entry=26740;caller=39085
  owner-dead
  not-same-name:...
  started_at mismatch: Δ=Ns
  starttime-unreadable
```

`caller-not-owner` 表示「这个进程是别的 PowerShell 会话启动的」—— 这是有意设计的拒绝，防止你误杀别人正在跑的出图任务。

**修法**（按安全性排）：

```powershell
# 1) 让启动它的那个会话自己清理（最安全）
.\Invoke-CadRepair.ps1          # 会 Clear-StaleCadEntries + 结束自己的孤儿进程

# 2) 确认没有活跃任务后，直接杀
Get-Process accoreconsole | Where-Object { $_.StartTime -lt (Get-Date).AddMinutes(-5) } | Stop-Process -Force

# 3) 清登记表（不动进程，只是让登记表变干净）
Remove-Item "$env:APPDATA\cad-automatic-wwj\processes.json" -Force
```

---

## 三、SAVEAS / DXFOUT / PLOT 类

### 3.1 `SAVEAS` 报「无效的选项关键字」，后续命令全被吞

**根因**：`SAVEAS` 的格式参数只认白名单：`R14`/`2000`/`2004`/`2007`/`2010`/`2013`/`2018`/`DWT`/`DXF`/`S`。
传 `"16"`、`"2013年"`、`"autocad2018"` 都会失败，且失败后 AutoCAD 会取消整条命令链。

**提示序列**（格式在前、文件名在后 —— 顺序别搞反）：

```
命令: _.SAVEAS
当前文件格式: AutoCAD 2018 图形
输入文件格式 [R14(LT98&LT97)/2000(LT2000)/2004(LT2004)/2007(LT2007)/2010(LT2010)/2013(LT2013)/2018(LT2018)/标准(S)/dxf(DXF)/样板(T)] <2018>: 2018
输入文件名: D:/out/plan.dwg
```

**修法**：`c:SAVEAS` 现在有两个必填实参：

```lisp
(c:SAVEAS "D:/out/plan.dwg" "2018")
```

传整数 `2` 报 `参数类型错误: stringp 2` —— 必须传字符串。

---

### 3.2 DXF 导出的版本怎么设都不变（永远 AC1032）

**这是本 skill 里最有迷惑性的 bug。**

**现象**：

```powershell
(c:SAVEDXF "out.dxf" "12")   # → 120684 字节，版本 AC1032
(c:SAVEDXF "out.dxf" "13")   # → 120718 字节，版本 AC1032
(c:SAVEDXF "out.dxf" "16")   # → 120775 字节，版本 AC1032
```

文件大小确实变了（容易让人以为成功了），但版本行全是 `AC1032`。

**根因**：**`DXFOUT` 的第二个参数是「小数精度」，不是版本。**

版本开关藏在精度提示的选项里：

```
命令: _.DXFOUT
输入文件名: D:/out/plan.dxf
输入精度的小数位数 (0 到 16) 或 [二进制(B)/选择对象(O)/预览(P)/版本(V)] <16>: _
```

正确序列：**文件名 → `_V` → 版本名 → 精度 → 二进制**。

**修法**（`c:SAVEDXF` 已改成三参数）：

```lisp
(c:SAVEDXF "D:/out/plan.dxf" "2013" "16")   ; 版本 + 精度
```

实现里 `2018` 走捷径（不切 `_V`，少两步输入），其它版本走 `(list "_.DXFOUT" path "_V" ver prec)`。

**实测对应表**（用文件头 `AC10xx` 校验，不是看提示回显）：

| 版本名 | 文件头 | 大小参考 |
|---|---|---|
| `R12` | `AC1009` | 7,783 字节 |
| `2000` | `AC1015` | 214,619 字节 |
| `2004` | `AC1018` | — |
| `2007` | `AC1021` | — |
| `2010` | `AC1024` | — |
| `2013` | `AC1027` | 125,759 字节 |
| `2018` | `AC1032` | 默认 |

校验方法：

```powershell
$b = [IO.File]::ReadAllBytes($dxf)
$t = [Text.Encoding]::UTF8.GetString($b)
$i = $t.IndexOf('AC10')
$t.Substring($i, 6)     # 'AC1009' / 'AC1015' / ...
```

---

### 3.3 accoreconsole 里 `PDFOUT` / `EXPORTPDF` 都说「未知命令」

**根因**：accoreconsole **没有** `EXPORTPDF`/`PDF`/`PDFOUT` 命令。这些是完整 AutoCAD 的。

**修法**：只能走 `-PLOT` + `DWG To PDF.pc3` 设备。

---

### 3.4 `-PLOT` 提示错位，吐一串「未知命令"M"」

**根因**：`-PLOT` 的提示序列是**严格固定的 15 步**。多给一个或少给一个，后面的输入就全错位到别的提示上。错位后 AutoCAD 会把 `_M`（本来是给「图纸单位」的回答）当成命令名，于是刷屏「未知命令"M"」，**而且不报错、正常退出**（exit 0）—— 看起来像成功。

15 步（顺序不能变）：

```
1  详细配置?      _Y
2  布局名         Model
3  输出设备       DWG To PDF.pc3
4  图纸尺寸       <尺寸全名，如 "ISO A3 (420.00 x 297.00 毫米)">
5  图纸单位       _M(毫米) / _I(英寸)
6  图形方向       _L(横向) / _P(纵向)
7  上下颠倒       _N
8  打印区域       _E(范围) / _D(显示) / _L(图形界限) / _W(窗口)
9  打印比例       _F(布满)
10 打印偏移       _C(居中)
11 按样式打印     _Y
12 打印样式表     monochrome.ctb / ""
13 打印线宽       _Y
14 先打印到文件?  _Y
15 文件名         D:/out/plan.pdf
```

**修法**：`c:PLOTPDF` 已按这 15 步写好。改它的时候**逐行数**，不要「感觉差不多」。

图纸尺寸必须用**全名**，不是 `A3`。`cadpaper` 函数做映射：

```
A3 → "ISO A3 (420.00 x 297.00 毫米)"
A4 → "ISO A4 (297.00 x 210.00 毫米)"
```

---

### 3.5 `c:SAVEAS` 报「参数太少」

LISP 函数声明了几个形参就得给几个。`(c:SAVEAS "path")` 缺第二个。

查某个 `c:XXX` 要几个参数：

```powershell
Select-String -Path .\cadcore.lsp -Pattern '^\(defun (c:\w+) \(([^)]*)\)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value + ' → ' + $_.Matches[0].Groups[2].Value }
```

---

## 四、绘图实体类

### 4.1 `hatch` 回执看起来成功，但图上没填充

**现象**：回执 `@@HATCH=pat=ANSI31 scale=2 handle=29F@@`，但**下一个实体的 handle 也是 29F** —— 同一个 handle 出现在两个回执里，说明 hatch 根本没创建，`(entlast)` 返回的还是上一个实体。

**根因**：`_S`（Select objects）后面必须跟选择集或对象，给点坐标无效。

```lisp
;; 错 —— 命令不报错但什么也没画
(cadcmd (list "_.-HATCH" "_P" pat scale "0" "_S" (list px py) "" ""))
```

**修法**（实测 hatchCount 0→1，handle 为新值）：

```lisp
(setvar "HPNAME" pat)
(setvar "HPSCALE" scale)
(setvar "HPANG" 0.0)
(cadcmd (list "_.-HATCH" (list px py) ""))
```

创建后必须 `(ssget "_X" '((0 . "HATCH")))` 数一遍并校验 `(cdr (assoc 0 (entget e)))` 是 `"HATCH"`，否则回 `FAILED-no-hatch-created`。

> **通用教训：创建类命令不能只信 `(entlast)`。** 命令静默失败时 `entlast` 返回的是上一个实体，会骗你。

---

### 4.2 `dimaligned` 画不出来（entmake 静默返回 nil）

**根因**：`(52 . ...)` 组码，或 `AcDbRotatedDimension` 尾，任何一个都会让 `dimaligned` 的 entmake 静默失败。

四个变体实测：

| 写法 | 结果 |
|---|---|
| `50 + 52 + 无 Rotated 尾` | **nil** |
| `仅 50` | **ok** ✅ |
| `无 50 无 52` | ok（但斜线标注会歪） |
| `50 + RotatedDimension 尾` | **nil** |

**修法**：

- `c:DIMLIN`（正交标注）：要 `(50 . 0.0)` **+** `AcDbRotatedDimension` 尾
- `c:DIMALIGN`（对齐标注）：要 `(50 . <真实角度弧度>)`，**绝不加 `52`，绝不加 Rotated 尾**

---

### 4.3 `dimradius` 之后「函数已取消」，后续全不画

**现象**：画完一部分就停，stdout 有 `*无效选择* 需要单个对象` + `; 错误: 函数已取消`。

**根因**：`c:DIMRAD` 把边缘点当选择对象传给了需要 ename 的位置。

**修法**：先精确找到那个圆：

```lisp
(setq ss (ssget "_X" (list '(0 . "CIRCLE")
                           (cons 10 (list cx cy 0))
                           (cons 40 r))))
```

用圆心 ±0.5 容差 + 半径匹配。找到 ename 再传。

---

### 4.4 `mtext` 卡住（不报错、不返回，直到超时）

**根因**：`_.MTEXT` 会弹「多行文字编辑器」对话框。accoreconsole 没有 UI，对话框永远等不到人点。

**修法**：改用 `entmake`：

```lisp
(entmake (list '(0 . "MTEXT") '(100 . "AcDbEntity") (cons 8 layer)
               '(100 . "AcDbMText")
               (cons 10 (list x y 0)) (cons 40 h) (cons 41 w)
               '(71 . 1) '(72 . 5) (cons 1 txt) '(7 . style) '(50 . 0.0)))
```

`(71 . 1)` 是附着点，`(72 . 5)` 是绘制方向（by style）。

---

### 4.5 动态块的 hatch 数量对不上 / DXF 实体数比 JSON 多

**这是正常的，不是 bug。**

块定义（`BLOCK`/`ENDBLK`）、填充边界、标注的组成件（`DIMENSION` 会额外产生 `LINE`/`SOLID`/`MTEXT` 等）都会让 DXF 里的实体计数大于 JSON 里声明的实体数。

`Invoke-CadDraw` 报告里的 `entityCount` 是 **JSON 声明数**，`checks` 里对 DXF 实体数只做「差额警告」，不判失败。

如果想知道真实实体数，用 `Invoke-CadInspect -Path <产物> -Entities`。

---

### 4.6 中文写进图里变成 `???`

**根因**：`TEXTSTYLE` 用的字体不支持中文，或者 `lsp` 文件本身不是 GBK（见 1.1）。

**排查**：

```powershell
# 1) 先确认 lsp 是 GBK
$b = [IO.File]::ReadAllBytes("$work\cadcore.lsp")
(New-Object System.Text.UTF8Encoding($false,$true)).GetString($b)   # 应该抛异常
[Text.Encoding]::GetEncoding(936).GetString($b).Contains('多行文字')  # True

# 2) 再确认字体
# 用 entmake 时把 (7 . style) 指向一个用 gbcbig.shx 或宋体的样式
```

`c:SETUP` 里默认建了一个能用中文的文字样式。

---

## 五、PowerShell 类

### 5.1 `[System.Object[]] 不包含名为 'op_Addition' 的方法`

**根因**：PowerShell 里**逗号优先级高于 `+`**。

```powershell
# 错 —— 被解析成 ($xy[0] + ($w, ($xy[1] + $h)))
@($xy[0] + [double]$w, $xy[1] + [double]$h)
```

**修法**：先算进变量再组数组。

```powershell
$x1 = $xy[0] + [double]$w
$y1 = $xy[1] + [double]$h
@($x1, $y1)
```

---

### 5.2 `@() | ConvertTo-Json` 返回 `$null`，写文件变空操作

**现象**：清空进程登记表，但文件内容不变。

**根因**：PowerShell 7 里空数组管道给 `ConvertTo-Json` 返回 `$null`；而 `$null | Set-Content` **根本不创建/清空文件**（静默跳过）。

**修法**：

```powershell
$json = if ($arr.Count -eq 0) { '[]' } else { $arr | ConvertTo-Json -Depth 5 }
Set-Content -Path $p -Value $json -Encoding UTF8
```

---

### 5.3 `在此对象上找不到属性"xxx"`

`Set-StrictMode -Version Latest` 下读不存在的属性会抛异常。用 `$obj.PSObject.Properties.Name` 先检查：

```powershell
if ($obj.PSObject.Properties.Name -contains 'orientation') { $obj.orientation }
```

不能用 `Test-CadField` —— 它把 `null` 值也当不存在，而有些字段「存在但值为 null」是正常的（如最小 DXF 的 `extents`）。

---

### 5.4 `-like` 里的方括号不是字面量

```powershell
# 错 —— [1] 被当字符集，匹配不到 "entities[1]"
$s -like '*entities[1]*'

# 对 —— 转义
$s -like '*entities`[1`]*'
```

---

### 5.5 `Select-Object -Skip` 收到负数

```powershell
# 错 —— 多匹配时 LineNumber 是数组，$n-4 会报错
$n = (Select-String -Path $f -Pattern 'xxx').LineNumber
Get-Content $f | Select-Object -Skip ($n-4)

# 对
$n = (Select-String -Path $f -Pattern 'xxx' | Select-Object -First 1).LineNumber
```

---

### 5.6 路径里带空格

所有路径都用引号包起来，LISP 里用正斜杠：

```powershell
ConvertTo-CadPath -Path 'D:\deepseek harness gongzuoqu\cad\out.dwg'
# → D:/deepseek harness gongzuoqu/cad/out.dwg
```

`ConvertTo-CadPath` 返回的字符串在 LISP 里用 `(load "D:/a b/c.lsp")` 是安全的 —— LISP 字符串不因空格断裂。

---

### 5.7 `switch` 不加 `-CaseSensitive`，PDF 坐标静默错位

**现象**：`Convert-CadPdfToDxf` 导出的 DXF 坐标范围是 `(372,0)–(6369,3598)`，而 PDF 的 MediaBox 只有 `[0 0 842 595]`。缩放系数像没生效，位置整体偏移，**但没有任何报错**。

**根因**：PowerShell 的 `switch` 默认不区分大小写，而 PDF 的 `q`/`Q` 是一对相反的操作：

- `q` = 压栈保存当前图形状态（CTM、lineWidth）
- `Q` = 弹栈恢复

不加 `-CaseSensitive` 时，`'q'` 分支先把 CTM 压栈，紧接着 `'Q'` 分支的 `if ($stack.Count -gt 1)` 成立又弹栈，恢复成单位矩阵 —— **`cm` 变换被静默清掉**，坐标原样透传。

**修法**：

```powershell
switch -CaseSensitive ($op) {
    'q' { $stack.Push($ctm.Clone()) }
    'Q' { if ($stack.Count -gt 0) { $ctm = $stack.Pop() } }
}
```

顺带：CTM 快照要连 `lineWidth` 一起存，`q/Q` 只恢复矩阵不够。

**「范围落在 MediaBox 内」是集成测试里的 CTM 哨兵**，专门抓这个 bug。

---

### 5.8 「在此对象上找不到属性 Count」，报错指向 `return` 行

**现象**：`Get-CadPdfInfo` 对一个流都没有的 PDF 抛异常，报错位置指向函数末尾的 `return [pscustomobject]@{`，完全看不出是上面为空。

**根因**：`Get-CadPdfStreams` 在没找到流时返回 **`$null`**（不是空数组），而 `streamCount = $streams.Count` 在 `$null` 上取 Count 抛异常。

**修法**：一律先 `@(...)` 包一层，并把 `$contentStreams = @()` 的初始化移到 foreach 之前。

```powershell
$streams = @(Get-CadPdfStreams -Bytes $bytes)
$contentStreams = @()
```

---

### 5.9 DXF 解析出 0 对，`(0,SECTION)` 被吃

**现象**：自己生成的 DXF 用 `Read-CadDxfPairs` 读出来只有 1 对甚至 0 对，TABLES 段（图层声明、线型表）全丢。

**根因**：文件带 **UTF-8 BOM**。`[IO.File]::WriteAllText(path, str, [Text.Encoding]::UTF8)` 会写 BOM，解码后首行是 `\uFEFF0`，`Trim()` 剥不掉 → `int::TryParse` 失败 → `i += 2` 跳两行 → `(0,SECTION)` 连同值一起被吃。报错只出现在第 1 行、看不出因果。

**修法**：写端用 `New-Object System.Text.UTF8Encoding($false)`，读端已加防御：

```powershell
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
```

---

### 5.10 函数名撞内置别名，报错位置指向调用行

**现象**：自己写的函数 `Rp` / `ReadPoint`，调用时报「无法处理命令，因为缺少一个或多个必需参数: Name」，位置指向**调用那一行**，完全不提函数定义。

**根因**：**`rp` 是内置别名 `Remove-ItemProperty`**。函数名撞别名时，`Rp 'A'` 被当成 cmdlet 调用。

**修法**：给函数取名避开单字母/短名别名（`h`=Get-History、`rp`=Remove-ItemProperty 等）。

**教训**：先在最小复现里排除「函数名撞别名」，再怀疑业务逻辑 —— 本 skill 为这个走了 20+ 个探针。

---

### 5.11 `@($list)` 对 `List[object]` 抛「Argument types do not match」

**现象**：`$x = @($someList)` 报参数类型不匹配，位置指向调用方那一行。

**根因**：PowerShell 7.6.7 的已知行为。`List[int]` / `ArrayList` / `object[]` / 普通数组都正常，连空 `List[object]` 也 FAIL。

**修法**：所有跨函数返回的 `List[object]` 一律 `.ToArray()`。

---

### 5.12 `$hash.PSObject.Properties['x']` 恒返回 `$null`

**现象**：`Get-CadField` 对 `[ordered]@{}` 哈希表输入永远返回默认值，像是字段不存在。

**根因**：`$hash.PSObject.Properties['name']` 只有对 **PSCustomObject** 才有效，对哈希表恒 `$null`。

**修法**：函数开头加字典分支。

```powershell
if ($Object -is [System.Collections.IDictionary]) {
    if (-not $Object.Contains($Name)) { return $Default }
    ...
}
```

---

### 5.13 库文件有顶层 `param`，调用方报「缺少必需参数」

**现象**：dot-source 了 `CadCommon.ps1`，调用 `Get-CadXxx -Path 'x'` 却报「缺少一个或多个必需参数: Path」，位置指向调用行。

**根因**：库文件顶部有 `[CmdletBinding()] param(...)`，dot-source 时 PowerShell 按强制参数绑定。

**修法**：库文件不放顶层 param。判断方法：

```powershell
$ast = [Parser]::ParseFile($path, [ref]$null, [ref]$null)
$ast.ParamBlock   # 非 $null 就说明有
```

---

### 5.14 `try/catch` 不能写在对象字面量里

```powershell
# 错 —— ParserError「语句块或类型定义中缺少右大括号」
$out += [pscustomobject]@{ meas = try { ... } catch { ... } }

# 对 —— 先算进变量
$meas = try { ... } catch { ... }
$out += [pscustomobject]@{ meas = $meas }
```

---

### 5.15 `-replace` 的展开被解析成额外参数

```powershell
# 错 —— 「找不到 WriteAllText 的参数计数为 4 的重载」
[IO.File]::WriteAllText($p, $str -replace 'T:', $d, [Text.Encoding]::GetEncoding(936))

# 错 —— 「无法将参数 culture 转换为类型 ""」
$str.Replace(@'...'@ -replace "`r`n","`n", @'...'@ -replace "`r`n","`n")

# 对 —— 先赋给变量
$norm = $old -replace "`r`n","`n"
$new  = $norm.Replace($a, $b)
```

---

## 六、证据/报告类

### 6.1 回执看着像成功，实际失败

本 skill 的所有回执都是 `@@NAME=value@@` 格式，两条铁律：

1. **同一个 handle 出现在两个回执里 = 后者没创建**（`entlast` 骗人）
2. **`FAILED-` 前缀是失败**，`ok=` 才是成功。别只看有没有 `@@XXX@@`

```powershell
$m = Get-CadMarker -Result $run -Name 'HATCH'
if ($m -like 'FAILED*') { ... }
```

### 6.2 `checks` 里字段名是 `pass` 不是 `passed`

```powershell
$report.checks | Where-Object { -not $_.pass }
```

### 6.3 `markers` 是数组不是哈希

`Get-CadConsoleDiagnostics` 返回的 `markers` 是 `@{name=...; value=...}` 的**数组**（因为要保序、允许重名）。转成哈希：

```powershell
$hash = [ordered]@{}
foreach ($mk in @($run.markers)) { $hash[[string]$mk.name] = $mk.value }
```

### 6.4 图纸尺寸读出来是 `(0,0)`

**现象**：`Get-CadExtentSize` 对一张明显有内容的图返回 `width=0 height=0`。

**根因**：读 `$EXTMAX` 的 while 循环停止条件只写了 `-ne 9`。`$EXTMAX` 后面紧跟的是 `0=ENDSEC`，循环跨过段界一路读到 ENTITIES 段的 `10/20/30`，**把实体坐标覆盖成 `$EXTMAX` 的值**。如果那张图的第一个实体恰好在原点，结果就是 `(0,0)`。`$EXTMIN` 侥幸正确因为它后面紧跟 `$EXTMAX`（code 9）挡住了。

**修法**：停止条件同时拦 code 9 与 code 0。

```powershell
while ($j -lt $pairs.Count -and $pairs[$j].code -ne 9 -and $pairs[$j].code -ne 0) { ... }
```

### 6.5 `manifest` 里 `specSha256` / `cadCoreSha256` 永远是空的

**根因**：`New-CadManifest` 原来只读传入值，而调用方只传 `$SpecFile` 不传 `$SpecSha256`，cadcore.lsp 路径也不在参数里 → 两个字段永远为空，「同一份 spec 是否复现出同一张图」这个核心问题无法回答。

**修法**：`New-CadManifest` 自己现算 —— `specSha256` 从 `$SpecFile` 算，`cadCoreSha256` 缺省回落 `Join-Path $PSScriptRoot 'cadcore.lsp'`。文件读不到给 `$null` 让比对判差异，**不给假值**。

### 6.6 「图层声明了但空」被判成「图层不存在」

**根因**：`Test-CadRequiredLayers` 原来只从实体的 8 组码反推图层（`Get-CadDxfEntities` 只读 ENTITIES 段），拿不到 TABLES 里的 LAYER 声明。

**修法**：用 `Get-CadDxfLayerNames` 读 TABLES 段的声明，匹配顺序改为 `byLayer → declaredLower → missing`，结果分 `present`/`empty`/`missing` 三类。

### 6.7 `Compare-CadManifest` 报「找不到与参数名称 'Path' 匹配的参数」

**根因**：它吃的是**两个清单对象**（`-Before` / `-After`），不是文件路径。

**修法**：先把落盘的 JSON 读回来再比 —— 顺带验了「写出去的能被读回来」这最后一环。

```powershell
$back = (Get-Content -Raw .\manifest.json) | ConvertFrom-Json
$diff = Compare-CadManifest -Before $back -After $man
# $diff.identical / $diff.diffCount / $diff.diffs[]（元素是 {field, before, after}）
```

返回字段是 `diffs` **不是 `differences`**。

### 6.8 结论档位与预期不符

**产物存在与否不改变结论档位**。`error` + 有半成品仍然只是 `fail`，不会升级成 `blocked`；`blocked` **只在 `$BlockedReason` 非空时**返回。产物在不在只影响调用方能否救回半成品。

五态优先级：`blocked` > `fail` > `needs_review` > `pass_with_warnings` > `pass`。

### 6.9 单位读不到

`Get-CadDrawingUnits -Path <dxf>` 返回 `units` `unitToMm` `evidence`，**不是 `toMm`**。「mm / 毫米 / furlong 认不认」属于 `Get-CadUnitCode -Name`（认不出返回 **-1**，`unitless` → 0），不是 `Get-CadDrawingUnits -Units`（那个参数不存在）。

---

## 七、什么时候该看工作目录

加 `-KeepArtifacts` 后，报告里的 `logDir` 就是工作目录，里面有：

| 文件 | 看什么 |
|---|---|
| `drawing.lsp` | 编译器生成的 LISP —— spec 有没有被正确翻译 |
| `drawing.scr` | 实际喂给 accoreconsole 的脚本 —— 检查末尾有没有 `_.QUIT`、`_N` |
| `cadcore.lsp` | GBK 副本 —— 用来确认编码转换成功 |
| `stdout.txt` | accoreconsole 全部输出（UTF-16LE）—— **最有用的一个** |
| `stderr.txt` | 通常为空 |
| `spec.json` | 回填过路径的 spec |

**排错第一件事永远是看 `stdout.txt` 的最后 30 行。** 它告诉你命令停在哪个提示上。
