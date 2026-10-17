#════════════════════════════════════════════════════════════════════
#  CadEvidence.ps1 — 证据分级 · 结论五态 · 清单复现 · 单位与图层校验
#────────────────────────────────────────────────────────────────────
#  这个模块解决一个具体问题：**「画成功了」这句话本身不可信**。
#
#  LISP 会打 @@DONE@@，但 @@DONE@@ 只证明脚本跑到了最后一行，
#  不证明 DWG 里有你要的东西。DXF 实体数对得上，也不证明单位是毫米
#  —— 一条 0→100 的线，在 INSUNITS=4 下是 100 毫米，在 INSUNITS=6 下是
#  100 米。同一条线，同一个文件，工件报废。
#
#  所以每一条结论都必须带上「这条我是怎么知道的」：
#
#    known      直接观测到的字节或结构事实
#               例：DWG 文件头是 AC1032、DXF 的 ENTITIES 段有 12 个实体、
#                   文件 SHA-256 是 3f2a…
#    scaled     经过一次换算的事实，换算参数本身可查
#               例：INSUNITS=4 所以数值单位是毫米；
#                   EXTMAX−EXTMIN = 180×100 对应 A4 上约 1:2
#    inferred   基于合理性的推断，没有直接证据
#               例：实体数与声明一致，推测都画出来了；
#                   用户说「这块板」，推测 180×100 是合理的
#    unreadable 该看的地方读不到
#               例：DWG 存在但 acdbmgd 没装、PDF 存在但解析器拒读、
#                   产物路径不存在
#
#  四级证据汇总成五态结论，规则写在 Get-CadDisposition 里。
#════════════════════════════════════════════════════════════════════

Set-StrictMode -Version Latest

$script:CadEvidenceLevels   = @('known', 'scaled', 'inferred', 'unreadable')
$script:CadDispositions     = @('pass', 'pass_with_warnings', 'needs_review', 'blocked', 'fail')

# 单位表（INSUNITS 码 ↔ 名 ↔ 毫米换算因子）以及 Get-CadUnitName / Get-CadUnitCode
# 已在 CadCommon.ps1 定义 —— 因为 CadCompiler.ps1 生成 (cadunits N) 时也要用，
# 而编译器不该为了一个查表去依赖整个证据模块。这里只留一句指引，别重复定义。

#════════════════════════════════════════════════════════════════════
#  证据记录
#════════════════════════════════════════════════════════════════════

function New-CadEvidence {
    <#
      建一条证据。每条都必须能回答三个问题：
        这是在说什么（message）
        凭什么这么说（level + source）
        具体数字是什么（value，可空）

      Supports 是单独的一维：不是所有证据都在支持「产物合格」这个结论。
        unreadable 级证据本身是「不知道」，既不能支持也不能推翻，
        所以它 Supports=$false —— 但它的 level 依然会把结论拉到
        needs_review，因为「不知道」不等于「没问题」。
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('known', 'scaled', 'inferred', 'unreadable')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        $Value = $null,
        # 证据来源：文件名 / 函数名 / 命令名，便于顺藤摸瓜
        [string]$Source = '',
        [bool]$Supports = $true
    )

    return [pscustomobject][ordered]@{
        kind     = $Kind
        level    = $Level
        message  = $Message
        value    = $Value
        source   = $Source
        supports = $Supports
    }
}

function Get-CadEvidenceWorst {
    <#
      一组证据里最差的一级。空集返回 unreadable ——
      「一条证据都没有」比「有一条可疑证据」更糟，不能当成合格。
    #>
    param($Evidence)

    $list = @($Evidence | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return 'unreadable' }

    $worst = 0
    foreach ($e in $list) {
        $idx = [array]::IndexOf($script:CadEvidenceLevels, [string]$e.level)
        if ($idx -lt 0) { $idx = $script:CadEvidenceLevels.Count - 1 }
        if ($idx -gt $worst) { $worst = $idx }
    }
    return $script:CadEvidenceLevels[$worst]
}

function Get-CadEvidenceByLevel {
    param($Evidence, [string]$Level)
    return @($Evidence | Where-Object { $_ -and [string]$_.level -eq $Level })
}

#════════════════════════════════════════════════════════════════════
#  五态结论
#════════════════════════════════════════════════════════════════════
#  为什么不是「成功 / 失败」两个值：
#
#    pass               有直接证据证明产物合格，可以直接交付
#    pass_with_warnings 画出来了，但有需要人看一眼的地方（未知线型、
#                       未声明图层、DXF 实体数多于声明）
#    needs_review       有推断级或读不到级的证据 —— 产物可能是对的，
#                       但没人真正证明它对。这是最容易出事的一档：
#                       以前它被写成 pass，用户以为验过了。
#    blocked            出图前就发现必然失败（spec 有错），一个实体没画
#    fail               真的失败了，或者产物缺失/结构损坏
#
#  优先级 blocked > fail > needs_review > pass_with_warnings > pass。

function Get-CadDisposition {
    <#
      把检查结果、证据、警告、错误合成一个结论。
      Checks 里每项的判定字段名是 pass（不是 passed）。
    #>
    param(
        $Checks,
        $Evidence,
        $Warnings,
        [string]$Error,
        [string]$BlockedReason,
        $Artifacts
    )

    $checkList = @($Checks | Where-Object { $null -ne $_ })
    $failed = @($checkList | Where-Object { $_.pass -ne $true })
    $warningList = @($Warnings | Where-Object { $_ })

    # 产物是否存在：用来区分「半途失败」和「压根没开始」
    $artifactList = @($Artifacts | Where-Object { $null -ne $_ })
    $existsCount = @($artifactList | Where-Object { $_.PSObject.Properties['exists'] -and $_.exists }).Count

    if ($BlockedReason) { return 'blocked' }

    if ($Error -and $failed.Count -gt 0 -and $existsCount -eq 0) {
        # 一个产物都没有 + 有失败断言 = 真失败，不是「带警告通过」
        return 'fail'
    }

    if ($failed.Count -gt 0) { return 'fail' }

    $worst = Get-CadEvidenceWorst -Evidence $Evidence
    if ($worst -eq 'inferred' -or $worst -eq 'unreadable') { return 'needs_review' }

    if ($warningList.Count -gt 0) { return 'pass_with_warnings' }

    return 'pass'
}

function Get-CadDispositionAdvice {
    param([Parameter(Mandatory)][string]$Disposition)
    switch ($Disposition) {
        'pass'               { '有直接证据证明产物合格，可以直接交付。' }
        'pass_with_warnings' { '产物已生成，但报告里有需要人看一眼的地方（线型回落、图层补建、实体数差异等），建议扫一遍 warnings。' }
        'needs_review'       { '产物可能是对的，但没有证据证明它是对的（例如单位读不到、只有推断级证据）。请开图核对关键尺寸后再用。' }
        'blocked'            { '出图前就发现 spec 有必然失败的问题，一个实体都没画。按 errors 改完再跑。' }
        'fail'               { '执行或产物校验失败。先看 error 与 checks 里未通过的项，再考虑跑 Invoke-CadRepair.ps1。' }
        default              { "未知结论 '$Disposition'。" }
    }
}

#════════════════════════════════════════════════════════════════════
#  清单（manifest）与复现
#════════════════════════════════════════════════════════════════════
#  出图这类任务的复现性靠三样东西钉住：
#    spec 的 SHA-256   —— 输入没变
#    cadcore.lsp 的 SHA-256 —— 代码没变
#    每个产物的 SHA-256 —— 输出没变
#  三者任一变了，就说明两次运行不是同一件事，比较结论没有意义。
#  时间戳不进比对（它每次都变），否则清单永远「不一致」。

function Get-CadSha256 {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
        return $null
    }
}

function New-CadManifest {
    <#
      产出一份可存盘、可比对的清单。
      $SpecFile / $SpecSha256 故意不加 [string] 类型标注 ——
      加了以后收到空值会被强制成 ''，清单里就分不出「没有 spec」和「空路径」。
    #>
    param(
        $SpecFile,
        $Spec,
        [string]$DrawingName,
        $Artifacts,
        $Evidence,
        [string]$Disposition,
        $AccoreConsole,
        $AccoreConsoleSource,
        $AccoreConsoleVersion,
        [string]$CadCorePath,
        $Units,
        $UnitsCode,
        $Extents,
        $EntityCount,
        $Layers,
        $SpecSha256
    )

    $artList = @()
    foreach ($a in @($Artifacts | Where-Object { $null -ne $_ })) {
        $p = [string]$a.path
        $exists = $false
        $bytes = $null
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
            $exists = $true
            $bytes = (Get-Item -LiteralPath $p).Length
        }
        $artList += [pscustomobject][ordered]@{
            kind   = [string]$a.kind
            path   = $p
            exists = $exists
            bytes  = $bytes
            sha256 = if ($exists) { Get-CadSha256 -Path $p } else { $null }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        tool          = 'cad-automatic-wwj'
        toolVersion   = '1.1.0'
        timestamp     = (Get-Date).ToString('o')
        drawing       = $DrawingName
        specFile      = if ($SpecFile) { [string]$SpecFile } else { $null }
        # ★ 必须自己算哈希，不能只依赖调用方传 ★
        # Invoke-CadDraw 只传 $SpecFile（真实路径），不传 $SpecSha256；
        # cadcore.lsp 的路径也不在调用方的参数里。如果这里只读传入值，
        # 清单里这两个字段永远为空，"同一份 spec 是否复现出同一张图"
        # 这个核心问题就没法回答 —— 而它是 manifest 存在的全部理由。
        # 文件读不到时给 $null 并让 Compare-CadManifest 判差异，
        # 不给假值：假哈希会让 identical=true 变成谎言。
        specSha256    = if ($SpecSha256) { [string]$SpecSha256 }
                        elseif ($SpecFile -and (Test-Path -LiteralPath ([string]$SpecFile) -PathType Leaf)) { Get-CadSha256 -Path ([string]$SpecFile) }
                        else { $null }
        cadCoreSha256 = if ($CadCorePath) { Get-CadSha256 -Path $CadCorePath }
                        elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'cadcore.lsp') -PathType Leaf) {
                            Get-CadSha256 -Path (Join-Path $PSScriptRoot 'cadcore.lsp')
                        } else { $null }
        accoreConsole = [pscustomobject][ordered]@{
            path    = if ($AccoreConsole) { [string]$AccoreConsole } else { $null }
            source  = if ($AccoreConsoleSource) { [string]$AccoreConsoleSource } else { $null }
            version = if ($AccoreConsoleVersion) { [string]$AccoreConsoleVersion } else { $null }
        }
        units         = [pscustomobject][ordered]@{
            name = if ($Units) { [string]$Units } else { $null }
            code = $UnitsCode
        }
        entityCount   = $EntityCount
        layers        = @($Layers | Where-Object { $_ })
        extents       = $Extents
        artifacts     = $artList
        disposition   = $Disposition
        evidence      = @($Evidence | Where-Object { $null -ne $_ })
    }
}

function Write-CadManifest {
    <#
      落盘。清单写不出去不该让一次成功的出图失败 —— 所以这里不抛，
      返回写成功的路径或 $null，由调用方决定要不要记 warning。
    #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $json = $Manifest | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $Path
    } catch {
        return $null
    }
}

function Compare-CadManifest {
    <#
      比对两份清单，回答「这两次运行是不是同一件事」。
      只比那些「应该稳定」的字段：
        specSha256 / cadCoreSha256 / units.code / entityCount /
        artifacts[].sha256（按 kind 对齐）
      不比：timestamp、路径、disposition（结论会因环境变化而不同，
      而我们要判断的是产物本身是否一致）。
    #>
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )

    $diffs = New-Object System.Collections.Generic.List[object]
    function Add-Diff([string]$field, $b, $a) {
        if ([string]$b -cne [string]$a) {
            $diffs.Add([pscustomobject][ordered]@{ field = $field; before = $b; after = $a }) | Out-Null
        }
    }

    Add-Diff 'specSha256'    $Before.specSha256    $After.specSha256
    Add-Diff 'cadCoreSha256' $Before.cadCoreSha256 $After.cadCoreSha256
    Add-Diff 'units.code'    $Before.units.code    $After.units.code
    Add-Diff 'entityCount'   $Before.entityCount   $After.entityCount

    # 产物按 kind 对齐比 sha256：路径变了不算差异（换个目录跑同一次出图很常见）
    $bKind = @{}
    foreach ($a in @($Before.artifacts)) { if ($a.kind) { $bKind[[string]$a.kind] = $a.sha256 } }
    foreach ($a in @($After.artifacts)) {
        if (-not $a.kind) { continue }
        $k = [string]$a.kind
        $bHash = if ($bKind.ContainsKey($k)) { $bKind[$k] } else { $null }
        Add-Diff "artifacts[$k].sha256" $bHash $a.sha256
    }
    foreach ($k in $bKind.Keys) {
        if (-not (@($After.artifacts) | Where-Object { [string]$_.kind -eq $k })) {
            Add-Diff "artifacts[$k].sha256" $bKind[$k] $null
        }
    }

    return [pscustomobject][ordered]@{
        identical = ($diffs.Count -eq 0)
        diffCount = $diffs.Count
        diffs     = $diffs.ToArray()
    }
}

#════════════════════════════════════════════════════════════════════
#  单位（INSUNITS）校验
#════════════════════════════════════════════════════════════════════

function Get-CadDxfHeaderVar {
    <#
      从 DXF 的 HEADER 段读一个系统变量。用法：
        Get-CadDxfHeaderVar -Path x.dxf -Name '$INSUNITS'
      返回原始字符串值；变量不存在返回 $null。

      DXF HEADER 的结构是：9 / $VARNAME 后跟一对或多对 (组码, 值)。
      不同变量的组码不同（$INSUNITS 是 70，$ACADVER 是 1，$EXTMIN 是 10/20/30），
      所以不能硬编码某一组码 —— 取变量名之后**紧跟的第一对**即可，
      因为 HEADER 里的每个变量都以 9 开头分隔。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $doc = Read-CadDxfPairs -Path $Path
    $pairs = $doc.pairs
    $target = $Name.Trim()
    if (-not $target.StartsWith('$')) { $target = '$' + $target }

    for ($i = 0; $i -lt $pairs.Count; $i++) {
        if ($pairs[$i].code -eq 9 -and $pairs[$i].value -eq $target) {
            if ($i + 1 -lt $pairs.Count) { return $pairs[$i + 1].value }
            return $null
        }
    }
    return $null
}

function Get-CadDrawingUnits {
    <#
      读一张 DXF 的单位。返回 {code, name, unitToMm, source, evidence}。

      ★ 为什么这比「实体数对不对」重要 ★
        一个 100×60 的矩形，在 INSUNITS=4(毫米) 下是 100mm×60mm 的垫片；
        在 INSUNITS=6(米) 下是 100m×60m 的地块。DXF 字节几乎一样，
        实体数完全一样，肉眼在屏幕上看到的比例也一样。
        唯一能区分它们的就是 $INSUNITS —— 而它是由「当初画图时谁设的」
        决定的，不是在图纸上能看出来的。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $code = -1
    $raw = $null
    $source = 'none'
    try {
        $raw = Get-CadDxfHeaderVar -Path $Path -Name '$INSUNITS'
        if ($null -ne $raw) {
            $parsed = 0
            if ([int]::TryParse(([string]$raw).Trim(), [ref]$parsed)) {
                $code = $parsed
                $source = 'dxf-header'
            }
        }
    } catch {
        $code = -1
        $source = 'unreadable:' + $_.Exception.Message
    }

    $name = if ($code -ge 0) { Get-CadUnitName -Code $code } else { $null }
    $toMm = if ($name -and $script:CadUnitToMm.ContainsKey($name)) { $script:CadUnitToMm[$name] } else { $null }

    $ev = if ($code -lt 0) {
        New-CadEvidence -Kind 'units' -Level 'unreadable' `
            -Message "无法从 DXF 读出 `$INSUNITS（$source），物理尺寸不明" `
            -Source 'Get-CadDrawingUnits' -Supports $false
    } else {
        New-CadEvidence -Kind 'units' -Level 'scaled' `
            -Message "DXF 声明 `$INSUNITS=$code（$name），数值单位已按此换算" `
            -Value $code -Source 'dxf-header'
    }

    [pscustomobject][ordered]@{
        code     = $code
        name     = $name
        unitToMm = $toMm
        raw      = $raw
        source   = $source
        evidence = $ev
    }
}

function Test-CadUnits {
    <#
      校验图纸单位是否与期望一致。返回 {match, actual, expected, evidence}。

      match 有三种结果，必须区分（不能用 true/false 两个值糊过去）：
        $true   实际单位 == 期望单位
        $false  实际单位 != 期望单位 → 尺寸会差 1000 倍这种级别
        $null   读不到 / 期望为空 / 有一方是 unitless → 无法判定
      $null 不是失败，是「不知道」，调用方要把它当 needs_review 处理。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )

    $actual = Get-CadDrawingUnits -Path $Path
    $expCode = Get-CadUnitCode -Name $Expected

    $match = $null
    $ev = $null

    if ($expCode -lt 0) {
        $ev = New-CadEvidence -Kind 'units-check' -Level 'unreadable' `
            -Message "期望单位 '$Expected' 无法识别，跳过单位校验" `
            -Source 'Test-CadUnits' -Supports $false
    } elseif ($actual.code -lt 0) {
        $ev = New-CadEvidence -Kind 'units-check' -Level 'unreadable' `
            -Message "读不到图纸单位，无法与期望 '$Expected' 比对" `
            -Source 'Test-CadUnits' -Supports $false
    } elseif ($actual.code -eq 0) {
        $ev = New-CadEvidence -Kind 'units-check' -Level 'inferred' `
            -Message "图纸声明无单位（unitless），无法与期望 '$Expected' 比对物理尺寸" `
            -Source 'Test-CadUnits' -Supports $false
    } elseif ($actual.code -eq $expCode) {
        $match = $true
        $ev = New-CadEvidence -Kind 'units-check' -Level 'known' `
            -Message "单位一致：$($actual.name)（INSUNITS=$($actual.code)）" `
            -Value $actual.code -Source 'Test-CadUnits'
    } else {
        $match = $false
        # 差多少倍要算出来，否则用户不知道后果有多严重
        $aMm = $actual.unitToMm
        $eMm = if ($script:CadUnitToMm.ContainsKey((Get-CadUnitName -Code $expCode))) {
                   $script:CadUnitToMm[(Get-CadUnitName -Code $expCode)]
               } else { $null }
        $ratio = if ($aMm -and $eMm) { [math]::Round($aMm / $eMm, 4) } else { $null }
        $ratioText = if ($ratio) { "，尺寸相差 $ratio 倍" } else { '' }
        $ev = New-CadEvidence -Kind 'units-check' -Level 'known' `
            -Message "单位不一致：图纸是 $($actual.name)（$($actual.code)），期望 $Expected（$expCode）$ratioText" `
            -Value $actual.code -Source 'Test-CadUnits' -Supports $false
    }

    [pscustomobject][ordered]@{
        match    = $match
        actual   = $actual
        expected = $Expected
        expectedCode = $expCode
        evidence = $ev
    }
}

#════════════════════════════════════════════════════════════════════
#  图层覆盖校验
#════════════════════════════════════════════════════════════════════

function Test-CadRequiredLayers {
    <#
      每个要求的图层是否**真的有实体画在上面**。

      ★ 为什么不能只判断图层存不存在 ★
        新建图层是零成本的：一张空图里可以有 50 个图层，一个实体都没有。
        「图层 GEO 存在」和「几何真的画在 GEO 上」是两件事，
        下游按图层筛几何（CAM 刀路、算量、出图过滤）时只认后者。

      返回 {pass, required, present, missing, empty, evidence}
        present  图层存在
        empty    图层存在但没有任何实体（这是最容易被漏掉的失败）
        missing  图层根本不存在
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Required,
        # 支持两种输入：DXF 路径（自己解析），或已解析的实体数组
        [string]$DxfPath = $null,
        [object[]]$Entities = $null
    )

    $req = @($Required | Where-Object { $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() })
    $out = [ordered]@{
        pass     = $true
        required = $req
        present  = @()
        missing  = @()
        empty    = @()
        evidence = @()
    }
    if ($req.Count -eq 0) {
        $out.evidence = @(New-CadEvidence -Kind 'layers' -Level 'known' `
            -Message '未要求特定图层，跳过图层覆盖校验' -Source 'Test-CadRequiredLayers')
        return [pscustomobject]$out
    }

    $ents = $Entities
    if ($null -eq $ents -and $DxfPath) {
        $ents = @(Get-CadDxfEntities -Path $DxfPath -Limit 100000)
    }
    $ents = @($ents | Where-Object { $null -ne $_ })

    # ★ TABLES 段的 LAYER 声明 ★
    # 只看实体的话，"图层声明了但上面一个实体都没有" 会被当成
    # "图层不存在"。两者对调用方是不同的诊断：前者说明建了层却漏画，
    # 后者说明连层都没建。所以有 DxfPath 时把声明表也读出来。
    $declared = @()
    if ($DxfPath -and (Test-Path -LiteralPath $DxfPath -PathType Leaf)) {
        $declared = @(Get-CadDxfLayerNames -Path $DxfPath)
    }
    $declaredLower = @{}
    foreach ($d in $declared) { if ($d) { $declaredLower[[string]$d.ToLowerInvariant()] = [string]$d } }

    # 图层名在 DXF 里区分大小写，但用户写要求时通常不在意。
    # 这里按不区分大小写匹配，报告里回显**实际**名字。
    $byLayer = @{}
    foreach ($e in $ents) {
        $ln = [string]$e.layer
        if (-not $ln) { continue }
        $k = $ln.ToLowerInvariant()
        if (-not $byLayer.ContainsKey($k)) { $byLayer[$k] = 0 }
        $byLayer[$k]++
    }

    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $empty   = New-Object System.Collections.Generic.List[string]

    foreach ($r in $req) {
        $k = $r.ToLowerInvariant()
        if ($byLayer.ContainsKey($k)) {
            $present.Add($r) | Out-Null
            if ($byLayer[$k] -eq 0) { $empty.Add($r) | Out-Null }
        } elseif ($declaredLower.ContainsKey($k)) {
            # 声明存在、实体数为 0 → 建了层但什么都没画
            $empty.Add($declaredLower[$k]) | Out-Null
        } else {
            $missing.Add($r) | Out-Null
        }
    }

    $out.present = $present.ToArray()
    $out.missing = $missing.ToArray()
    $out.empty   = $empty.ToArray()

    $evList = New-Object System.Collections.Generic.List[object]
    foreach ($r in $req) {
        $k = $r.ToLowerInvariant()
        if ($byLayer.ContainsKey($k) -and $byLayer[$k] -gt 0) {
            $evList.Add((New-CadEvidence -Kind 'layers' -Level 'known' `
                -Message "图层 '$r' 有 $($byLayer[$k]) 个实体" -Value $byLayer[$k] `
                -Source 'Test-CadRequiredLayers')) | Out-Null
        } else {
            $evList.Add((New-CadEvidence -Kind 'layers' -Level 'known' `
                -Message "图层 '$r' 上没有任何实体" -Value 0 `
                -Source 'Test-CadRequiredLayers' -Supports $false)) | Out-Null
        }
    }
    $out.evidence = $evList.ToArray()
    $out.pass = ($missing.Count -eq 0 -and $empty.Count -eq 0)

    return [pscustomobject]$out
}

function Get-CadExtentSize {
    <#
      从 DXF 的 $EXTMIN/$EXTMAX 算出图纸的数值尺寸，并按单位换算成毫米。

      为什么值得单独算：这是**唯一**能在不看图的情况下判断
      「这块板到底是不是 180×100 毫米」的办法。
      实体数对不代表尺寸对；标题栏写着 180 也不代表模型是 180。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$Tolerance = 1e-6
    )

    $minX = Get-CadDxfHeaderVar -Path $Path -Name '$EXTMIN'
    $maxX = Get-CadDxfHeaderVar -Path $Path -Name '$EXTMAX'

    # $EXTMIN 是 10/20/30 三个组码，但 Get-CadDxfHeaderVar 只返回第一对（10=X）。
    # Y/Z 要自己接着往下读，所以这里用 pairs 直接定位。
    $doc = Read-CadDxfPairs -Path $Path
    $pairs = $doc.pairs

    function Read-Point([string]$varName) {
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            if ($pairs[$i].code -eq 9 -and $pairs[$i].value -eq $varName) {
                $x = $null; $y = $null; $z = $null
                $j = $i + 1
                # ★ 停止条件不能只写「遇到下一个 9」★
                # HEADER 里一个变量后面可能直接跟 0=ENDSEC（段结束），
                # 此时 while 会跨过段界一路读到 ENTITIES 段的 10/20/30，
                # 把实体坐标当成 $EXTMIN/$EXTMAX 的值 —— 结果是
                # $EXTMAX 被最后一个实体的坐标覆盖，图纸尺寸算成 0 或任意值。
                # 实测：$EXTMAX=100,60 的图被读成 (0,0)，因为扫到了 LINE 的 (0,0)。
                while ($j -lt $pairs.Count -and $pairs[$j].code -ne 9 -and $pairs[$j].code -ne 0) {
                    switch ($pairs[$j].code) {
                        10 { $x = ConvertTo-CadDouble $pairs[$j].value }
                        20 { $y = ConvertTo-CadDouble $pairs[$j].value }
                        30 { $z = ConvertTo-CadDouble $pairs[$j].value }
                    }
                    $j++
                }
                return [pscustomobject]@{ x = $x; y = $y; z = $z }
            }
        }
        return $null
    }

    $mn = Read-Point '$EXTMIN'
    $mx = Read-Point '$EXTMAX'
    if ($null -eq $mn -or $null -eq $mx) { return $null }
    if ($null -eq $mn.x -or $null -eq $mx.x) { return $null }

    $w = [math]::Round($mx.x - $mn.x, 6)
    $h = [math]::Round($mx.y - $mn.y, 6)

    $units = Get-CadDrawingUnits -Path $Path
    $f = $units.unitToMm
    $wMm = if ($f) { [math]::Round($w * $f, 4) } else { $null }
    $hMm = if ($f) { [math]::Round($h * $f, 4) } else { $null }

    [pscustomobject][ordered]@{
        min       = $mn
        max       = $mx
        width     = $w
        height    = $h
        units     = $units.name
        unitsCode = $units.code
        widthMm   = $wMm
        heightMm  = $hMm
    }
}
