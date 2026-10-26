# CadOcr.ps1 — 位图文字识别（Windows.Media.Ocr，零第三方依赖）
# ══════════════════════════════════════════════════════════════════
#
#  定位：CadVectorize.ps1 只管几何，文字会被当成小墨点丢掉。这个模块补
#  「图里的字是什么」。
#
#  ★ 为什么用 Windows.Media.Ocr 而不是 Tesseract ★
#    本技能铁律是零 Python / 零第三方依赖。Windows 10+ 自带 OCR 引擎，
#    PowerShell 5.1 通过 WinRT 就能调，不需要装任何东西。代价是它只有
#    系统已安装的语言包（本机实测 zh-Hans-CN + en-US）。
#
#  ★ 实测能力边界（必须诚实告诉调用方）★
#    合成图（Arial 40px 白底黑字）→ 能识别，但有字符级误差：
#      "KM1 QF1 M1 HELLO 123"  →  "KMI QFI M 1 HELLO 1 2"
#      （I/1 混淆、空格切错 —— OCR 引擎的通病，不是本模块的 bug）
#    2456×3260 的真实工程图扫描件 → 几乎识别不出来（全页 2x 二值化后
#      只有 1 行乱码）。原因：图里字高只有 14–22px，且是 CAD 制图的
#      细笔画，低于 OCR 引擎可靠工作的下限。
#    所以：**OCR 结果一律是 inferred 级证据，必须人工核对**，绝不能
#    当尺寸依据。识别不出来时返回空数组 + 原因，不编造。
#
#  ★ 依赖 ★
#    System.Runtime.WindowsRuntime（.NET Framework 自带，无需安装）
#    Windows.Media.Ocr（Windows 10 起自带）
#    缺任一条件时 Test-CadOcrAvailable 返回 available=false，调用方
#    走「只给文字区域、不给文字内容」的降级路径，不报错。

# ══════════════════════════════════════════════════════════════════
#  一、可用性探测
# ══════════════════════════════════════════════════════════════════

# ★ 反射句柄缓存必须先声明 ★
#   Set-StrictMode -Version Latest 下，读取「从未赋值过」的变量会直接抛
#   「无法检索变量，因为尚未设置该变量」——注意这不是 $null 判断能救的，
#   错误发生在读的那一刻，$null -ne $script:X 本身就炸。
#   所以这里先显式置 $null，后面才敢用 `if ($null -ne ...)` 做缓存命中判断。
$script:CadOcrAsTask = $null

function Test-CadOcrAvailable {
    <#
      探测本机 OCR 能不能用。

      返回 @{ available; language; languages[]; maxImageDimension; error }

      ★ 不抛异常 ★
        缺 OCR 不是错误，是「这个功能不可用」。抛异常会让调用方
        （CadVectorize）整个失败，而我们真正想给的是「没有 OCR 也能
        给出文字区域」的降级结果。
    #>
    param(
        [string]$Language = 'zh-Hans-CN'
    )

    $result = [ordered]@{
        available         = $false
        language          = $null
        languages         = @()
        maxImageDimension = 0
        error             = $null
    }

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
    } catch {
        $result.error = "WinRT 类型加载失败（需要 Windows 10+ 与 .NET Framework 4.6+）: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    try {
        $engine = $null
        if ($Language) {
            $lang = New-Object Windows.Globalization.Language $Language
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
        }
        if ($null -eq $engine) {
            # 指定语言没装就退回用户配置里的语言，再不行才放弃
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        }
        if ($null -eq $engine) {
            $result.error = '系统没装任何 OCR 语言包。设置 → 时间和语言 → 语言 → 添加语言（需含「光学字符识别」可选功能）'
            return [pscustomobject]$result
        }

        $langs = New-Object System.Collections.Generic.List[string]
        foreach ($l in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
            $langs.Add([string]$l.LanguageTag)
        }

        $result.available         = $true
        $result.language          = [string]$engine.RecognizerLanguage.LanguageTag
        $result.languages         = $langs.ToArray()
        $result.maxImageDimension = [int][Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    } catch {
        $result.error = "OCR 引擎初始化失败: $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

# ══════════════════════════════════════════════════════════════════
#  二、WinRT 异步等待
# ══════════════════════════════════════════════════════════════════

function Get-CadOcrAwaitHelper {
    <#
      取 System.WindowsRuntimeSystemExtensions.AsTask 的反射句柄。

      ★ 为什么必须反射 ★
        PS 5.1 不能直接 await WinRT 的 IAsyncOperation<T>。官方路子是
        [System.WindowsRuntimeSystemExtensions]::AsTask() 然后 .Wait()，
        但 AsTask 是泛型重载，PS 无法自动推断 T，必须 MakeGenericMethod。
        这个句柄每次调用都重新取一遍太浪费，缓存进 script 作用域。
    #>
    if ($null -ne $script:CadOcrAsTask) { return $script:CadOcrAsTask }

    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $hit = $methods | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

    if ($null -eq $hit) {
        throw '找不到 AsTask(IAsyncOperation<T>) 重载；这台机器的 WinRT 互操作程序集不完整'
    }
    $script:CadOcrAsTask = $hit
    return $hit
}

function Invoke-CadOcrAwait {
    param($Operation, [Type]$ResultType)

    $helper = Get-CadOcrAwaitHelper
    $task = $helper.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    # -1 = 无限等待。OCR 单页最多几秒，不设上限比「等 30 秒就放弃、
    # 结果拿不到还报成功」更安全。
    $task.Wait(-1) | Out-Null
    return $task.Result
}

# ══════════════════════════════════════════════════════════════════
#  三、单张图识别
# ══════════════════════════════════════════════════════════════════

function Invoke-CadOcrImage {
    <#
      对一张图跑 OCR。

      返回 @{ ok; lines[]; text; language; error }
        lines[] 每个 @{ text; x; y; w; h; words[] }
        坐标是**图片像素坐标**，y 向下（与 CadVectorize 的像素口径一致，
        由调用方统一翻 Y）。

      ★ 返回空 lines 不等于失败 ★
        图里没字、字太小、字太糊都会得到 0 行。ok=$true + lines=@()
        表示「引擎跑通了，但这张图没认出字」；ok=$false 才是引擎层面的
        失败（文件读不了、格式不支持）。两者对调用方的含义完全不同：
        前者可以降级到「只标区域」，后者说明 OCR 这条路整条不通。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Language = 'zh-Hans-CN'
    )

    $out = [ordered]@{
        ok       = $false
        lines    = @()
        text     = ''
        language = $null
        error    = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $out.error = "图片不存在: $Path"
        return [pscustomobject]$out
    }

    $probe = Test-CadOcrAvailable -Language $Language
    if (-not $probe.available) {
        $out.error = $probe.error
        return [pscustomobject]$out
    }

    try {
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

        $engine = $null
        if ($Language) {
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language $Language))
        }
        if ($null -eq $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
        $out.language = [string]$engine.RecognizerLanguage.LanguageTag

        $full = (Resolve-Path -LiteralPath $Path).Path
        $file = Invoke-CadOcrAwait ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
        $stream = Invoke-CadOcrAwait ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Invoke-CadOcrAwait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])

        # ★ 必须显式要 Bgra8 ★
        #   不指定格式时 GetSoftwareBitmapAsync() 返回解码器原生格式，
        #   对 JPEG 常是 Bgr24，RecognizeAsync 直接返回 0 行且**不报错**。
        #   这个坑实测踩过：同一张图换 Bgra8 就有结果。
        $bitmap = Invoke-CadOcrAwait (
            $decoder.GetSoftwareBitmapAsync(
                [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
                [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)
        ) ([Windows.Graphics.Imaging.SoftwareBitmap])

        $ocr = Invoke-CadOcrAwait ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

        $lines = New-Object System.Collections.Generic.List[object]
        $sb = New-Object System.Text.StringBuilder
        foreach ($line in $ocr.Lines) {
            $words = New-Object System.Collections.Generic.List[object]
            $minX = [double]::MaxValue; $minY = [double]::MaxValue
            $maxX = [double]::MinValue; $maxY = [double]::MinValue
            foreach ($wd in $line.Words) {
                $r = $wd.BoundingRect
                $words.Add([pscustomobject]@{
                    text = [string]$wd.Text
                    x = [math]::Round($r.X, 1); y = [math]::Round($r.Y, 1)
                    w = [math]::Round($r.Width, 1); h = [math]::Round($r.Height, 1)
                })
                if ($r.X -lt $minX) { $minX = $r.X }
                if ($r.Y -lt $minY) { $minY = $r.Y }
                if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
                if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
            }
            if ($words.Count -eq 0) { continue }

            $lines.Add([pscustomobject]@{
                text  = [string]$line.Text
                x     = [math]::Round($minX, 1); y = [math]::Round($minY, 1)
                w     = [math]::Round($maxX - $minX, 1)
                h     = [math]::Round($maxY - $minY, 1)
                words = $words.ToArray()
            })
            [void]$sb.AppendLine([string]$line.Text)
        }

        $out.ok    = $true
        $out.lines = $lines.ToArray()
        $out.text  = $sb.ToString().TrimEnd()
    } catch {
        $out.error = "OCR 执行失败: $($_.Exception.Message)"
    }

    return [pscustomobject]$out
}

# ══════════════════════════════════════════════════════════════════
#  四、按区域识别（CadVectorize 的主入口）
# ══════════════════════════════════════════════════════════════════

function Invoke-CadOcrRegions {
    <#
      给一组「文字候选区域」逐个裁图放大后识别。

      为什么要裁图放大：整页 OCR 会把 20px 高的字当噪声（引擎有最小
      字高假设）。裁出单行、放大 3–4 倍、补白边，识别率明显提升。
      本机实测：整页 0 行 → 单行裁剪 4x 后能出结果（虽然仍有字符错）。

      参数：
        -ImagePath   原图
        -Regions     @(@{x;y;w;h;id}) 像素坐标
        -Upscale     放大倍数（默认 3）
        -Padding     四周补白像素（默认 8，防笔画贴边被切）
        -MinConfidence  预留（Windows OCR 不暴露置信度，恒为 0）

      返回 @{ available; language; results[]; error }
        results[] 每个 @{ id; x; y; w; h; text; ok; error }，坐标已换算回原图。
    #>
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][object[]]$Regions,
        [string]$Language = 'zh-Hans-CN',
        [int]$Upscale = 3,
        [int]$Padding = 8,
        [string]$WorkDir
    )

    $out = [ordered]@{
        available = $false
        language  = $null
        results   = @()
        error     = $null
    }

    $probe = Test-CadOcrAvailable -Language $Language
    if (-not $probe.available) {
        $out.error = $probe.error
        return [pscustomobject]$out
    }
    $out.available = $true
    $out.language  = $probe.language

    if ($Upscale -lt 1) { $Upscale = 1 }
    if ($Padding -lt 0) { $Padding = 0 }

    Add-Type -AssemblyName System.Drawing

    if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('cad-ocr-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }

    $results = New-Object System.Collections.Generic.List[object]
    $src = $null

    try {
        $src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $ImagePath).Path)
        $imgW = $src.Width
        $imgH = $src.Height

        $idx = 0
        foreach ($r in $Regions) {
            $idx++
            $rid = if ($null -ne $r.id) { [string]$r.id } else { "r$idx" }
            $entry = [ordered]@{
                id = $rid; x = [int]$r.x; y = [int]$r.y; w = [int]$r.w; h = [int]$r.h
                text = ''; ok = $false; error = $null
            }

            # 裁图范围夹到图内，再向外补 Padding
            $x0 = [math]::Max(0, [int]$r.x - $Padding)
            $y0 = [math]::Max(0, [int]$r.y - $Padding)
            $x1 = [math]::Min($imgW, [int]$r.x + [int]$r.w + $Padding)
            $y1 = [math]::Min($imgH, [int]$r.y + [int]$r.h + $Padding)
            $cw = $x1 - $x0; $ch = $y1 - $y0
            if ($cw -lt 2 -or $ch -lt 2) {
                $entry.error = '区域太小，跳过'
                $results.Add([pscustomobject]$entry) | Out-Null
                continue
            }

            $cropPath = Join-Path $WorkDir ("ocr-$rid.png")
            $crop = $null; $big = $null; $g = $null; $g2 = $null
            try {
                # 24bpp + 白底：直接 FromFile 读 JPEG 再 Save 会带上原图
                # 的像素格式，OCR 对非 Bgra8/Bgr24 的输入会静默返回 0 行
                $crop = New-Object System.Drawing.Bitmap($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $g = [System.Drawing.Graphics]::FromImage($crop)
                $g.Clear([System.Drawing.Color]::White)
                $destRect = New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)
                $srcRect = New-Object System.Drawing.Rectangle($x0, $y0, $cw, $ch)
                $g.DrawImage($src, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

                $bw = $cw * $Upscale
                $bh = $ch * $Upscale
                $big = New-Object System.Drawing.Bitmap($bw, $bh, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $g2 = [System.Drawing.Graphics]::FromImage($big)
                $g2.Clear([System.Drawing.Color]::White)
                $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g2.DrawImage($crop, 0, 0, $bw, $bh)
                $big.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                if ($g2) { $g2.Dispose() }
                if ($big) { $big.Dispose() }
                if ($g) { $g.Dispose() }
                if ($crop) { $crop.Dispose() }
            }

            $one = Invoke-CadOcrImage -Path $cropPath -Language $Language
            if ($one.ok) {
                $entry.ok = $true
                # 多行合并：一行区域裁出来偶尔会切成两行，用空格连起来
                $parts = New-Object System.Collections.Generic.List[string]
                foreach ($ln in $one.lines) {
                    if ($ln.text) { $parts.Add([string]$ln.text) }
                }
                $entry.text = ($parts -join ' ').Trim()
            } else {
                $entry.error = $one.error
            }

            $results.Add([pscustomobject]$entry) | Out-Null
        }
    } catch {
        $out.error = "区域 OCR 失败: $($_.Exception.Message)"
    } finally {
        if ($src) { $src.Dispose() }
    }

    $out.results = $results.ToArray()
    return [pscustomobject]$out
}
