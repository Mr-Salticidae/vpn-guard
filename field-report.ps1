# field-report.ps1 — 环境对照报告（给非技术协作者用的一键流程）
#
# 用途：请朋友/同事帮忙做一次环境对照时，让他双击 `一键体检.cmd` 即可，
#       全程不需要懂命令行。产出一个**已脱敏**的文本报告，由他自己决定发不发。
#
# 设计取舍：
#   1. 只读。不改任何系统设置，不装任何东西，不需要管理员权限。
#   2. 默认脱敏。完整出口 IP / IPv6 / DNS 地址 / 代理凭据 / 机器名 / 路径一律不进报告。
#   3. 绝不自动发送。脚本把报告全文打在屏幕上让他先看，发不发是他的决定。
#   4. 详细自查输出另存本地，明确告诉他「这份不用发」—— 那份里有完整 IP。
#
# Windows PowerShell 5.1 兼容：不用三元 / ?? / ?. / && / ||。

$ErrorActionPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'vpn-guard 环境对照'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Rule { Write-Host ('-' * 62) -ForegroundColor DarkGray }

Write-Host ''
Say '  vpn-guard · 环境对照体检' 'Cyan'
Rule
Say '  这个脚本会做两件事：'
Say '    1) 检查你当前的网络环境（只读，不改任何设置、不装任何东西）'
Say '    2) 问你几个关于账号的问题'
Say ''
Say '  然后生成一份**已经脱敏**的报告放到桌面。'
Say '  报告里不会有你的完整 IP、DNS、密码或任何路径 —— 生成后会全文打给你看，' 'Yellow'
Say '  发不发给对方，由你自己决定。脚本不会自动发送任何东西。' 'Yellow'
Rule
Write-Host ''

$who = Read-Host '  先起个代号，用来区分不同人的报告（比如 小王，直接回车用 A）'
if (-not $who) { $who = 'A' }
$who = ($who -replace '[\\/:*?"<>|]', '_').Trim()

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = $env:USERPROFILE }
$report = Join-Path $desktop ("vpn-guard对照报告_{0}.txt" -f $who)
$detail = Join-Path $desktop ("vpn-guard详细结果_{0}_本地留存.txt" -f $who)

# ---------- 1. 跑自查 ----------
Write-Host ''
Say '  [1/3] 正在检查网络环境，大约 20 秒，请稍等……' 'Cyan'

$audit = Join-Path $PSScriptRoot 'vpn-leak-audit.ps1'
if (-not (Test-Path $audit)) {
    Say ''
    Say '  ✗ 找不到 vpn-leak-audit.ps1。' 'Red'
    Say '    请确认你把整个文件夹解压出来了，而不是只拷了一个文件。' 'Red'
    return
}

# 跳过链路测速：它要下载约 20MB，而且跟本次要对照的东西无关。
# DNS 主动实测保留 —— 它是真实信号。
$raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $audit -NoSpeedTest -Export $report 2>&1
Set-Content -Path $detail -Value ($raw -join "`r`n") -Encoding UTF8

if (-not (Test-Path $report)) {
    Say ''
    Say '  ✗ 没能生成报告。可能是当前完全没联网。' 'Red'
    Say ('    详细信息已存到：{0}' -f $detail) 'Gray'
    return
}
Say '  ✓ 网络环境检查完成' 'Green'

# ---------- 2. 问卷 ----------
Write-Host ''
Say '  [2/3] 下面 9 个问题，跟账号有关。' 'Cyan'
Say '        这部分脚本测不出来，但它比网络环境更能说明问题，所以别跳过。'
Say '        不确定的直接回车，会记成「不清楚」。'
Write-Host ''

$qs = @(
    @{ K = '被封过吗(次数)';    Q = '你的账号被封过吗？封过几次？' }
    @{ K = '最近一次被封时间';  Q = '最近一次是什么时候？（大概月份就行）' }
    @{ K = '账号来源';          Q = '账号是怎么来的？自己注册 / 别人给的 / 买的 / 多人合租' }
    @{ K = '账号大概注册年份';  Q = '大概哪一年注册的？' }
    @{ K = '注册用邮箱';        Q = '注册用的邮箱，是你长期在用的那个，还是为了注册临时建的？' }
    @{ K = '是否与他人共用';    Q = '这个账号有没有和别人一起用？' }
    @{ K = '是否绑过支付方式';  Q = '绑过银行卡/支付方式吗？哪个国家的？' }
    @{ K = '客户端节点策略';    Q = '你的代理客户端里，是固定选一个节点，还是用「自动选择 / 负载均衡」？' }
    @{ K = '多久换一次节点';    Q = '大概多久换一次节点？' }
)

$answers = @{}
$i = 1
foreach ($q in $qs) {
    $a = Read-Host ('  {0}. {1}' -f $i, $q.Q)
    if (-not $a) { $a = '不清楚' }
    $answers[$q.K] = ($a -replace '[\r\n]', ' ').Trim()
    $i++
}

# 把答案写回报告里的占位符
$lines = Get-Content $report -Encoding UTF8
$out = @()
foreach ($l in $lines) {
    $replaced = $false
    foreach ($k in $answers.Keys) {
        if ($l -like ("{0}*: __待填__*" -f $k)) {
            $out += ('{0}: {1}' -f ($l -split ':')[0], $answers[$k])
            $replaced = $true
            break
        }
    }
    if (-not $replaced) { $out += $l }
}
Set-Content -Path $report -Value ($out -join "`r`n") -Encoding UTF8

# ---------- 3. 全文展示 + 交给用户决定 ----------
Write-Host ''
Say '  [3/3] 报告已生成。下面是它的**全部内容** —— 请先看一遍：' 'Cyan'
Rule
Get-Content $report -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor White }
Rule
Write-Host ''
Say '  以上就是全部内容，没有别的东西。' 'Green'
Say ('  文件位置：{0}' -f $report) 'Cyan'
Write-Host ''
Say '  确认没问题的话，把这个文件发给请你帮忙的人就可以了。' 'Yellow'
Say '  如果你觉得其中某一行不方便透露，用记事本打开删掉那一行再发 —— 不影响对照。' 'Yellow'
Write-Host ''
Say ('  另外还有一份详细结果存在：{0}' -f $detail) 'DarkGray'
Say '  那份里有完整 IP 等信息，**是给你自己看的，不用发**。' 'DarkGray'
Write-Host ''

$open = Read-Host '  现在打开文件所在的文件夹吗？(直接回车=打开, n=不用)'
if ($open -ne 'n' -and $open -ne 'N') {
    Start-Process explorer.exe ('/select,"{0}"' -f $report)
}
Write-Host ''
Say '  完成，感谢帮忙。' 'Cyan'
