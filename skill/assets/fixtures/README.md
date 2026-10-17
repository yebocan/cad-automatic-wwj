# fixtures — 故意做坏的样张

这里放的是**故意有问题**的小文件，用来验证诊断链路，不要拿去当模板。

| 文件 | 症状 | 应该被谁发现 |
|---|---|---|
| `broken-line.json` | `line` 缺 `p2` | 编译器 → `warnings` 点名缺字段，该实体跳过，其余照画 |
| `unknown-type.json` | `type` 是 `spiral` | 编译器 → 抛出可用类型全表 |
| `bad-color.json` | 图层 `color: "red"` | 编译器 → 类型不匹配，回落默认色 |
| `empty-dwg.dwg` | 0 字节 | `Test-CadDwgFile` → `valid=false`，`Invoke-CadRepair` R09 命中 |
| `not-a-dwg.dwg` | 纯文本冒充 DWG | `Test-CadDwgFile` → 头不是 `ACxxxx` |
| `truncated.pdf` | 有 `%PDF-` 头但没有 `%%EOF` | `Test-CadPdfFile` → `valid=false` |
| `bad-encoding.scr` | UTF-8 写的中文 scr | 参考 `troubleshooting.md` 第 1 节，复现「参数类型错误: stringp nil」 |

生成这些坏文件的脚本：`skill/scripts/run-unit-test.ps1` 的第 16 节会在临时目录里现场造一份等价物，
所以这里不必把二进制坏文件也提交进仓库 —— 上面标 `dwg`/`pdf` 的只是说明症状，
真正的生成逻辑在测试里。

用它们做手工验证：

```powershell
pwsh -File skill/scripts/Invoke-CadDraw.ps1 -SpecFile skill/assets/fixtures/broken-line.json -AsJson
pwsh -File skill/scripts/Invoke-CadDraw.ps1 -SpecFile skill/assets/fixtures/unknown-type.json -AsJson
```
