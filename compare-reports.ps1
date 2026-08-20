# compare-reports.ps1 — 并排比对两份（或多份）环境对照报告
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\compare-reports.ps1 报告A.txt 报告B.txt
#   powershell -ExecutionPolicy Bypass -File .\compare-reports.ps1 .\reports\*.txt
#
# 报告由 `vpn-leak-audit.ps1 -Export` 或 `一键体检.cmd` 产出。
#
# 为什么要有它：靠肉眼比两份文本，最容易只盯着显眼的「网络环境」差异，
# 而按已确立的结论，真正决定账号存活的是「账号与使用习惯」那一段。
# 所以本工具刻意把两段分开输出，并在结尾按权重给出解读顺序。

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $Paths -or $Paths.Count -lt 2) {
    Write-Host "用法: compare-reports.ps1 <报告1> <报告2> [报告3 ...]" -ForegroundColor Yellow
    Write-Host "      至少要两份才能比对。" -ForegroundColor Yellow
    return
}

$files = @()
foreach ($p in $Paths) { $files += @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue) }
# 保持命令行给出的顺序（不排序）——排序会让列序与用户预期不符；仅去重。
$seen = @{}; $files = @($files | Where-Object { if ($seen[$_.FullName]) { $false } else { $seen[$_.FullName] = $true; $true } })
if ($files.Count -lt 2) {
    Write-Host ("只找到 {0} 份报告，无法比对。" -f $files.Count) -ForegroundColor Red
    return
}

# 解析：`键 : 值`，忽略注释与小节标题
$reports = @()
foreach ($f in $files) {
    $kv = [ordered]@{}
    foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*##') { continue }
        if ($line -match '^([^:#]+?)\s*:\s*(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if ($v -match '^(.*?)\s+#') { $v = $Matches[1].Trim() }   # 去掉行尾提示注释
            if ($k -and $k -ne '生成时间' -and $k -ne '报告格式版本') { $kv[$k] = $v }
        }
    }
    # 代号取自文件名 vpn-guard对照报告_XXX.txt
    $tag = $f.BaseName
    if ($tag -match '报告[_-](.+)$') { $tag = $Matches[1] }
    $reports += [pscustomobject]@{ Tag = $tag; File = $f.Name; KV = $kv }
}

# 「出口基准可信」必须在最前面显示：它为「否」时，下面所有出口相关的值都不代表
# 浏览器实际走的出口（Unix 上系统代理 + curl 读不到代理地址时会出现），整列不可用于对照。
$NET = @('操作系统','流量接管方式','对外路由确实走TUN','出口基准可信',
         '出口国','出口网段','出口 ASN','出口 ISP',
         '出口归属判定','被标记为 proxy','CLI/桌面应用出口','时区差(出口-系统)','系统区域',
         'IPv6','代理环境变量')
$ACC = @('被封过吗(次数)','最近一次被封时间','账号来源','账号大概注册年份','注册用邮箱',
         '是否与他人共用','是否绑过支付方式','客户端节点策略','多久换一次节点')

function Show-Section($title, $keys, $note, $noteColor) {
    Write-Host ''
    Write-Host ("== $title ==") -ForegroundColor Cyan
    Write-Host ("   $note") -ForegroundColor $noteColor
    Write-Host ''
    $wk = 18
    $wv = [Math]::Min(30, [Math]::Max(14, [int]((100 - $wk) / $reports.Count) - 2))
    $hdr = ('{0,-18}' -f '')
    foreach ($r in $reports) {
        $t = $r.Tag; if ($t.Length -gt $wv) { $t = $t.Substring(0, $wv) }
        $hdr += ('{0,-' + $wv + '} ') -f $t
    }
    Write-Host $hdr -ForegroundColor DarkGray
    Write-Host ('-' * $hdr.Length) -ForegroundColor DarkGray

    $diffCount = 0
    foreach ($k in $keys) {
        $vals = @()
        foreach ($r in $reports) {
            $v = $r.KV[$k]
            if (-not $v) { $v = '—' }
            $vals += $v
        }
        $same = (@($vals | Sort-Object -Unique).Count -eq 1)
        if (-not $same) { $diffCount++ }
        $kk = $k; if ($kk.Length -gt 17) { $kk = $kk.Substring(0, 17) }
        $row = ('{0,-18}' -f $kk)
        foreach ($v in $vals) {
            $vv = $v; if ($vv.Length -gt $wv) { $vv = $vv.Substring(0, $wv) }
            $row += ('{0,-' + $wv + '} ') -f $vv
        }
        if ($same) { Write-Host $row -ForegroundColor DarkGray }
        else       { Write-Host $row -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host ("   本段 {0} 项有差异（黄色行）" -f $diffCount) -ForegroundColor Gray
    return $diffCount
}

Write-Host ''
Write-Host ' 环境对照 · 并排比对' -ForegroundColor Cyan
Write-Host ('=' * 62) -ForegroundColor DarkGray
foreach ($r in $reports) { Write-Host ("  {0,-10} <- {1}" -f $r.Tag, $r.File) -ForegroundColor Gray }

$netDiff = Show-Section '一、网络环境（脚本实测）' $NET `
    '这一段差异大不代表问题大 —— 它是权重较低的那几层。' 'DarkGray'
$accDiff = Show-Section '二、账号与使用习惯（人工填写）' $ACC `
    '这一段才是主变量。脚本测不到，但它比上面任何一项都更能决定账号存活。' 'Yellow'

Write-Host ''
Write-Host ('=' * 62) -ForegroundColor DarkGray
Write-Host ' 怎么读这张表' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. 先看第二段。「被封过吗」是结果变量，其余是候选原因。' -ForegroundColor Gray
Write-Host '     如果被封的人和没被封的人在「账号来源 / 注册年份 / 是否共用」上分得开，' -ForegroundColor Gray
Write-Host '     而在第一段上分不开 —— 那就验证了「差异在账号出身，不在 IP 质量」。' -ForegroundColor Gray
Write-Host ''
Write-Host '  2. 第一段里只有两项值得单独看：' -ForegroundColor Gray
Write-Host '     · 出口归属判定 —— 是不是机房段' -ForegroundColor Gray
Write-Host '     · 客户端节点策略（在第二段）—— 自动选择会造成国家跳变' -ForegroundColor Gray
Write-Host ''
if ($accDiff -eq 0 -and $netDiff -gt 0) {
    Write-Host '  ⚠ 注意：账号那一段完全没有差异，网络环境却有。' -ForegroundColor Yellow
    Write-Host '    这种情况下本次对照无法支持「差异在账号出身」的结论 —— 样本不足以区分。' -ForegroundColor Yellow
}
if ($reports.Count -eq 2) {
    Write-Host '  ⚠ 只有两份样本。任何一条差异都可能是巧合，只能当线索，不能当结论。' -ForegroundColor Yellow
}
$untrusted = @($reports | Where-Object { $_.KV['出口基准可信'] -and $_.KV['出口基准可信'] -notlike '是*' })
if ($untrusted.Count -gt 0) {
    Write-Host ('  ⚠ 有 {0} 份报告的「出口基准可信」不是「是」：{1}' -f $untrusted.Count, (($untrusted | ForEach-Object { $_.Tag }) -join ', ')) -ForegroundColor Red
    Write-Host '    这几份里「出口国 / 出口 ASN / 出口 ISP / 时区差」拿到的是他的直连出口，' -ForegroundColor Red
    Write-Host '    不是浏览器实际走的出口 —— 那几行不能用于对照，请让他开 TUN 后重跑。' -ForegroundColor Red
}
Write-Host ''
