<#
  vpn-leak-audit.ps1  —  VPN 出口一致性 / 泄露自查   (vpn-guard v1.0.1)
  用途：使用 VPN 访问受地区限制的海外平台前，一键检查真实身份是否泄露、
        以及浏览器指纹（时区/语言）是否与出口 IP 所在国一致。
  覆盖范围：绝大多数项目是系统级的，浏览器与桌面应用/CLI 同样适用。
        第 2 项专测「不认系统代理的程序」（Claude/Codex 桌面版与 CLI、Electron 主进程）的真实出口，
        第 7 项 WebRTC 仅适用于浏览器。
  用法：右键“用 PowerShell 运行”，或在终端执行  powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1
        加 -NoDnsLeak   可跳过联网的 DNS 泄露主动实测（默认开启，走 bash.ws）。
        加 -NoSpeedTest 可跳过链路质量实测（默认开启，约 20MB 流量）。
  只读检查，不修改任何系统设置。
#>

param([switch]$NoDnsLeak, [switch]$NoSpeedTest)

$ErrorActionPreference = 'SilentlyContinue'
function Line($c='-'){ Write-Host ($c * 60) -ForegroundColor DarkGray }
function Ok($m){ Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }

# ==== 出口归属判定：消费级运营商 ASN 名单 ====================================
# 只存号码，不存机构名 —— 机构名由上面那行 "ISP :" 打印，重复存一份只多一处腐坏点。
# 号码集合与 auto-select-node.ps1 顶部那张表同源，由 verify-unix.sh 机械比对。
# 名单漏掉一条的后果只是少一句「住宅」的好消息（降级为「未识别」），
# 不可能变成误报安全 —— 这是本文件敢内联一份副本、而不依赖任何外部库文件的全部理由。
# 两条会「告警」的判据（hosting=true / 32 位 ASN）完全不读这张表。
# 维护约束：BEGIN/END 之间除 ASN 号外不得出现任何数字。
# ASN-TABLE-BEGIN
$ResiAsnRaw = @'
3462 4780 9924 17421 24158
4760 9269 9304 4515 9908 17444
4609
4713 2516 17676 2527 2518 4685 2497 9605 9824 17511 18126 7679 138384
4766 9318 3786 17858 9644
3758 9506 4657 4773
4788
9930 17552 45758
7713 23693
9299 4775
45899 7552 18403
55836 24560 9829 55577 17488
4134 4837 9808 4808
7922 7018 701 6167 20115 11427 22773 21928 209 5650 6128
812 577 852
2856 5607 5089 13285 12576 13037 206067
3320 3209 6805 8422
3215 12322 15557
3269 12874
3352 6739
1136
6830
3301
1221 7474 4739
4771
'@
# ASN-TABLE-END
$ResiAsn = @{}
foreach ($a in ($ResiAsnRaw -split '[^0-9]+')) { if ($a) { $ResiAsn[$a] = $true } }
# 同目录 residential-asn.txt（可选，与 auto-select-node.ps1 读同一个文件、同一条正则）。
# 缺失 = 只用内置名单，功能不减；单独拷走本文件的用户不会踩到任何坑。
# $PSScriptRoot 在被 dot-source 时为空，必须先判空再 Join-Path ——
# 顶部的 SilentlyContinue 会把 Test-Path '' 的报错吃掉，只能靠显式守卫。
$ResiFile = ''
if ($PSScriptRoot) { $ResiFile = Join-Path $PSScriptRoot 'residential-asn.txt' }
if ($ResiFile -and (Test-Path $ResiFile)) {
    foreach ($l in @(Get-Content $ResiFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*(?:AS)?(\d+)\s*(?:#\s*(.*?))?\s*$') { $ResiAsn[$Matches[1]] = $true }
    }
}

# DNS 泄露主动实测：对随机子域发起真实解析，回查哪些解析器应答（含归属国/ASN）。
# 用 bash.ws（dnsleaktest.com 官方 CLI 同源）的免费 API，无需自建权威 DNS。
function Invoke-DnsLeakTest($exitCc, $exitName) {
    $id = try { (Invoke-RestMethod -Uri "https://bash.ws/id" -TimeoutSec 8) } catch { $null }
    if (-not $id) { Warn "bash.ws 不可达 —— 跳过 DNS 主动实测"; return }
    $id = "$id".Trim()
    # 触发解析：必须发起“连接”而非仅解析 —— fake-ip 下真实递归查询在连接时才由客户端发出。
    # 优先用 Windows 自带 curl.exe（可后台并发，等价 bash 版）；否则回退 Invoke-WebRequest。
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        1..6 | ForEach-Object {
            Start-Process -FilePath curl.exe -NoNewWindow `
                -ArgumentList @("-fsS","--max-time","4","http://$_.$id.bash.ws") | Out-Null
        }
        Start-Sleep -Seconds 4
    } else {
        1..6 | ForEach-Object {
            try { Invoke-WebRequest -Uri "http://$_.$id.bash.ws" -TimeoutSec 4 -UseBasicParsing | Out-Null } catch {}
        }
    }
    $res = try { Invoke-RestMethod -Uri "https://bash.ws/dnsleak/test/$id`?json" -TimeoutSec 10 } catch { $null }
    if (-not $res) { Warn "未取到 bash.ws 结果 —— 跳过"; return }
    if (-not $exitCc) {
        $ipEntry = $res | Where-Object { $_.type -eq 'ip' } | Select-Object -First 1
        if ($ipEntry) { $exitCc = $ipEntry.country; $exitName = $ipEntry.country_name }
    }
    $upExit = ("$exitCc").ToUpper()
    $dns = @($res | Where-Object { $_.type -eq 'dns' })
    $mismatch = 0
    foreach ($d in $dns) {
        $rcc = ("$($d.country)").ToUpper()
        if ($upExit -and $rcc -and $rcc -ne $upExit) {
            $mismatch++
            Bad ("解析器 {0}（{1} / {2}）不在出口国 {3} —— DNS 正泄露到此解析器" -f $d.ip, $d.country_name, $d.asn, $exitName)
        } else {
            Info ("解析器 {0}（{1} / {2}）" -f $d.ip, $d.country_name, $d.asn)
        }
    }
    if ($dns.Count -eq 0) {
        Warn "未观察到实际解析器（可能全部命中缓存或被完全隧道）——可稍后重试确认"
    } elseif ($mismatch -eq 0) {
        Ok ("全部解析器都在出口国 {0} —— DNS 未泄露" -f $exitName)
    } else {
        Bad ("共 {0}/{1} 个解析器不在出口国 —— 你查询的域名正暴露给上述解析器（多为真实 ISP）" -f $mismatch, $dns.Count)
        Info "修复：客户端启用 fake-ip + 远端解析（让 DNS 走隧道在出口解析），并确认没有应用绕过隧道直连本地 DNS。"
    }
}

Write-Host ""
Write-Host " VPN 出口一致性 / 泄露自查 " -ForegroundColor Cyan
Write-Host (" 时间: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Line '='

# ---------- 0. 代理客户端与流量接管方式 ----------
Write-Host "0) 代理客户端与流量接管方式" -ForegroundColor Cyan
$knownPat = 'clash|mihomo|verge|v2ray|xray|sing-?box|ss-local|sslocal|shadowsocks|hysteria|tuic|trojan|naive|juicity|wireguard|openvpn'
$procs = Get-Process | Where-Object { $_.ProcessName -match $knownPat } | Select-Object -ExpandProperty ProcessName -Unique
if ($procs) { Info ("客户端进程 : {0}" -f ($procs -join ', ')) }
else { Info "未识别出已知代理客户端进程（Clash/V2Ray/Xray/sing-box/SS/WireGuard/OpenVPN……不影响后续检查）" }

$tunPat = 'tun|tap|wintun|wireguard|meta|mihomo|sing-?box'
$upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
$tunAdapters = @($upAdapters | Where-Object { $_.Name -match $tunPat -or $_.InterfaceDescription -match $tunPat })
$routeIf = $null
try { $routeIf = (Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction Stop).InterfaceAlias | Select-Object -First 1 } catch {}
$reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$TakeoverMode = 'none'
# $TunRouted：严格版 —— 只有「TUN 网卡存在且对外路由确实走它」才为真。
# 下面那个 elseif 里 $TakeoverMode 同样会变成 'tun'（网卡在，但路由没走它），
# 第 2 项的出口轮换判定绝不能用那个宽松值，否则会把真泄露读成轮换。
$TunRouted = $false
if ($tunAdapters.Count -gt 0 -and $routeIf -and ($tunAdapters.Name -contains $routeIf)) {
    $TakeoverMode = 'tun'
    $TunRouted = $true
    Ok ("TUN 模式（{0}）—— 全局流量（含 UDP/WebRTC）均被接管" -f $routeIf)
} elseif ($tunAdapters.Count -gt 0) {
    $TakeoverMode = 'tun'
    Warn ("检测到 TUN 网卡（{0}），但对外路由走 {1} —— TUN 可能未完全接管，请在客户端确认" -f $tunAdapters[0].Name, $routeIf)
} elseif ($reg.ProxyEnable -eq 1) {
    $TakeoverMode = 'sysproxy'
    Warn ("系统代理模式（{0}）—— 浏览器流量走代理；不支持代理的应用与 UDP/WebRTC 可能绕行直连" -f $reg.ProxyServer)
    Info "建议：开启客户端的 TUN/虚拟网卡模式（Clash Verge: TUN 模式；v2rayN: 启用 Tun；sing-box: tun 入站）"
} elseif ($reg.AutoConfigURL) {
    $TakeoverMode = 'sysproxy'
    Warn ("PAC 代理模式（{0}）—— 命中规则的浏览器流量走代理；其余应用与 UDP/WebRTC 直连" -f $reg.AutoConfigURL)
} else {
    Warn "未检测到 TUN 网卡或系统代理 —— 若你在用浏览器插件级代理（如 SwitchyOmega）或仅本地端口，只有明确配置了代理的应用被接管"
}
Line

# ---------- 1. 公网 IPv4 + 地理位置 + 代理标记 ----------
Write-Host "1) 公网出口 IP 与地理位置" -ForegroundColor Cyan
$ipapi = $null
try { $ipapi = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,as,query,proxy,hosting" -TimeoutSec 15 } catch {}
if ($ipapi -and $ipapi.status -eq 'success') {
    Info ("出口 IP   : {0}" -f $ipapi.query)
    Info ("位置      : {0} / {1} ({2})" -f $ipapi.city, $ipapi.country, $ipapi.countryCode)
    Info ("ISP       : {0}" -f $ipapi.isp)
    Info ("IP 时区   : {0} (UTC{1:+0;-0}:00)" -f $ipapi.timezone, ($ipapi.offset/3600))
    if ($ipapi.proxy)   { Warn "该 IP 被标记为 proxy —— 部分平台会据此拦截" } else { Ok "未被标记为 proxy" }
    # EXIT-CLASS-BEGIN  （verify-classifier.sh 按此标记抽取本块做跨语言比对，别删）
    # ---- 出口归属（住宅/消费级 vs 机房/主机商）----
    # 旧版仅凭 ip-api 的 hosting=false 就写「读起来像住宅/普通 ISP」，2026-08-19 实测是错的：
    # AS131939 IPS INC / AS131642 Pittqiao / AS209642 Mejiro 三家小主机商 hosting 全是 false。
    # 现在三态，且「未识别」是默认值：判据不足时只说不知道，绝不说安全。
    # 注：$exitAsnNum 与第 3 项的 $exitAsn（形如 "AS14061" 的字符串，用于 v4/v6 同 ASN 比对）
    #     是两个不同的东西，别「统一」它们 —— 会破掉 IPv6 误报防护。
    #     用 [long] 不用 [int]：ASN 空间到 4294967295，[int] 会溢出且被顶部的 SilentlyContinue 静默吃掉。
    $exitAsnNum = 0
    if ("$($ipapi.as)" -match '^\s*AS(\d+)') { $exitAsnNum = [long]$Matches[1] }
    $ExitResiHit = ($exitAsnNum -gt 0 -and $ResiAsn.ContainsKey([string]$exitAsnNum))
    if ($ipapi.hosting) {
        Warn ("出口归属  : 机房/主机商 —— ip-api 直接标记为 hosting（{0}）。高风控平台常拦截机房 IP" -f $(if ($ipapi.as) { $ipapi.as } else { '未知 ASN' }))
        if ($ExitResiHit) { Info "该 ASN 同时在消费级运营商名单里 —— 多半落在该运营商自营的 IDC 段，仍按机房看待。" }
    } elseif ($exitAsnNum -le 0) {
        Info "出口归属  : 未识别 —— ip-api 没返回 AS 号，无判据。不能据此认为出口安全。"
    } elseif ($ExitResiHit) {
        Ok ("出口归属  : 住宅/消费级 —— AS{0} 在已知消费级运营商名单中" -f $exitAsnNum)
    } elseif ($exitAsnNum -ge 65536) {
        Warn ("出口归属  : 推断为机房/主机商 —— AS{0} 是 32 位 ASN（2014 年后才发放；家宽运营商都在那之前就拿到了号段）" -f $exitAsnNum)
        Info "ip-api 的 hosting=false 只代表它库里没这条记录，不代表这是住宅 IP。"
        Info ("若你确认 AS{0} 是当地家宽运营商，把它写进同目录 residential-asn.txt（每行一条 AS 号）即可。" -f $exitAsnNum)
    } else {
        Info ("出口归属  : 未识别 —— AS{0} 既不在消费级运营商名单中，ip-api 也未标记为机房。" -f $exitAsnNum)
        Info "「未识别」只表示没认出来：既不等于机房，也不等于住宅。别据此判定安全。"
    }
    # EXIT-CLASS-END
} else {
    Bad "无法获取公网 IP（ip-api 不可达）——检查 VPN 是否在线"
}
Line

# ---------- 2. 桌面应用 / CLI 出口（不认系统代理的程序）----------
Write-Host "2) 桌面应用 / CLI 出口（Claude、Codex、Electron 主进程……）" -ForegroundColor Cyan
Info "浏览器和 .NET 会自动读系统代理；但 Node / Rust / Go 写的 CLI 与 Electron 的 Node 主进程不读，"
Info "只认 HTTP_PROXY / HTTPS_PROXY 环境变量。下面用「强制不走代理的 curl」模拟这类程序实测真实出口。"

$envProxyLines = @()
foreach ($n in 'HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','NO_PROXY') {
    $v = [Environment]::GetEnvironmentVariable($n,'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n,'User') }
    if ($v) { $envProxyLines += "$n=$v" }
}
if ($envProxyLines) { Info ("代理环境变量 : {0}" -f ($envProxyLines -join '; ')) }
else { Info "代理环境变量 : 未设置 —— 这类程序不会主动走代理，只能靠 TUN 兜底" }

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Warn "未找到 curl.exe（Windows 10 1803+ 自带）—— 跳过桌面应用出口实测"
} elseif (-not ($ipapi -and $ipapi.status -eq 'success')) {
    Warn "上一项未取到浏览器侧出口 IP —— 无从对比，跳过"
} else {
    # --noproxy "*" 让 curl 忽略一切代理设置（含环境变量），精确复刻「完全不认代理的程序」的行为。
    # curl.exe 本来就不读 Windows 的 WinINET 注册表代理，这一点与 Node/Electron 主进程一致。
    # 加 as 字段：与本项原有请求同一次调用，零额外配额，用于把「出口轮换」与「真泄露」区分开。
    $bareRaw = & curl.exe -s --max-time 12 --noproxy "*" "http://ip-api.com/json/?fields=status,query,country,countryCode,isp,as" 2>$null
    $bare = try { "$bareRaw" | ConvertFrom-Json } catch { $null }
    if (-not $bare -or $bare.status -ne 'success') {
        Warn "实测请求失败 —— 若确实完全不通，说明这类程序在当前环境根本连不上网（也是一种信号）"
    } elseif ($bare.query -eq $ipapi.query) {
        if ($TakeoverMode -eq 'none') {
            Bad ("出口 {0} 与浏览器一致，但当前没有任何接管 —— 两者都是直连，真实 IP 全程暴露" -f $bare.query)
        } else {
            Ok ("出口 {0} 与浏览器一致 —— 不认代理的程序也被隧道接管，Claude/Codex 等不会泄露" -f $bare.query)
        }
    } else {
        # 出口轮换 vs 真泄露。TUN 模式下 curl --noproxy 同样走隧道（--noproxy 只关代理设置，
        # 不改路由），两次观测落在同一出口池的不同成员上就会 IP 不同 —— 那不是泄露。
        # 判据与第 3 项对 IPv6 用的完全一致：同 ASN 时以 ASN 为准。
        # 只在 $TunRouted 为真时才敢这么判：系统代理 / PAC / 无接管时 curl 本来就是直连，
        # 两条路本就不同，此时 IP 不同就是真泄露，必须保持红色。
        $bareAsn = ''
        if ($bare.as -and ("$($bare.as)" -match '^\s*AS(\d+)')) { $bareAsn = $Matches[1] }
        $exitAsnCmp = ''
        if ($ipapi.as -and ("$($ipapi.as)" -match '^\s*AS(\d+)')) { $exitAsnCmp = $Matches[1] }
      if ($TunRouted -and $bareAsn -and $exitAsnCmp -and $bareAsn -eq $exitAsnCmp) {
        Warn ("出口在轮换：浏览器侧 {0}、不认代理的程序侧 {1}，两者同属 AS{2} —— 同一出口池的不同成员，不是泄露" -f `
              $ipapi.query, $bare.query, $exitAsnCmp)
        Info "当前节点背后是负载均衡 / 多出口池：出口被大量账号共享（平台按 IP 聚类做关联判定），"
        Info "且会话 IP 会中途跳变 —— Claude / ChatGPT 这类平台会把它当成异常信号。"
        Info "另注意：第 3、4、5、8 项都是对「第 1 项那一瞬的出口」的快照 —— 出口会变，就说明那些结论只对那一次成立。"
        Info "修复：在客户端里选一个固定节点，别用「自动选择 / 负载均衡 / fallback」策略组。"
      } else {
        Bad ("不认代理的程序直连出口 {0}（{1} / {2}），与浏览器出口 {3}（{4}）不一致 —— 真实 IP 正在泄露！" -f `
             $bare.query, $bare.country, $bare.isp, $ipapi.query, $ipapi.country)
        Info "受影响：Codex CLI、Claude Code CLI、Claude/ChatGPT 桌面版的 Node 主进程、各类自动更新与遥测。"
        Info "修复 A（推荐，一劳永逸）：开客户端的 TUN 模式，全局接管所有程序。"
        Info "修复 B（按应用）：用 app-vpn.ps1 启动它们（进程级注入 HTTPS_PROXY + TZ，不改任何系统设置）。"
        if ($envProxyLines) {
            Info "注：你已设了代理环境变量 —— 认这些变量的程序（多数 Node/Rust CLI）不受影响，不认的仍在泄露。"
        }
      }
    }
}
Line

# ---------- 3. IPv6 泄露面 ----------
Write-Host "3) IPv6 泄露面" -ForegroundColor Cyan
$v6 = $null
try { $v6 = Invoke-RestMethod -Uri "https://api64.ipify.org?format=json" -TimeoutSec 8 } catch {}
if ($v6 -and $v6.ip -match ':') {
    # 关键：有公网 IPv6 不等于泄露。归属与出口一致 = IPv6 也走隧道（出口的 v6）；
    # 只有归属你的真实 ISP（与出口国不一致）才是绕过 VPN 的真泄露。
    $v6info = try { Invoke-RestMethod -Uri ("http://ip-api.com/json/{0}?fields=status,countryCode,country,as" -f $v6.ip) -TimeoutSec 8 } catch { $null }
    $exitCc = if ($ipapi -and $ipapi.status -eq 'success') { $ipapi.countryCode } else { "" }
    # "AS14061 DigitalOcean, LLC" → "AS14061"。刻意保留 "AS" 前缀，只用于 v4/v6 同 ASN 比对；
    # 与第 1 项的 $exitAsnNum（纯数字 long）不是一回事，别合并，会破掉下面的 IPv6 误报防护。
    $exitAsn = if ($ipapi -and $ipapi.status -eq 'success' -and $ipapi.as) { ("$($ipapi.as)".Trim() -split '\s+')[0] } else { "" }
    $v6Asn   = if ($v6info -and $v6info.as) { ("$($v6info.as)".Trim() -split '\s+')[0] } else { "" }
    if ($v6info -and $v6info.status -eq 'success' -and $exitCc -and $v6info.countryCode -eq $exitCc) {
        Ok ("公网 IPv6: {0}（{1} / {2}）—— 与出口国一致，IPv6 也走隧道，未泄露" -f $v6.ip, $v6info.country, $v6info.as)
    } elseif ($v6info -and $v6info.status -eq 'success' -and $exitAsn -and $v6Asn -eq $exitAsn) {
        # 国家对不上但 ASN 相同：这是出口节点自己的 IPv6，只是 ip-api 对同一台机器的 v4/v6
        # 地理定位不一致（DigitalOcean / Vultr 等云厂商常见）。只比国家会在这里误报成"泄露"。
        Ok ("公网 IPv6: {0}（{1}）—— 与出口同属 {2}，是出口节点自己的 IPv6，未泄露" -f $v6.ip, $v6info.as, $exitAsn)
        Info ("注：ip-api 把该 IPv6 定位在 {0}、把出口 IPv4 定位在 {1} —— 同 ASN 时以 ASN 为准，避免误报。" -f $v6info.country, $ipapi.country)
    } elseif ($v6info -and $v6info.status -eq 'success' -and $exitCc) {
        Bad ("公网 IPv6: {0} 归属 {1}（{2}），与出口 {3}（{4}）既不同国也不同 ASN —— IPv6 绕过 VPN 暴露真实位置！" -f `
             $v6.ip, $v6info.country, $v6info.as, $ipapi.country, $(if ($ipapi.as) { $ipapi.as } else { '未知 ASN' }))
        Info "修复：关闭物理网卡的 IPv6，或让 VPN(TUN) 接管 IPv6 隧道。"
    } else {
        Warn ("存在公网 IPv6: {0}，但无法查询其归属以判定是否泄露" -f $v6.ip)
        Info "若该 IPv6 不属于你的 VPN 出口，请关闭网卡 IPv6 或让 VPN 接管 IPv6。"
    }
} else {
    Ok "无公网 IPv6 出口（泄露面已收窄）"
}
Line

# ---------- 4. 时区一致性（头号指纹破绽）----------
Write-Host "4) 时区一致性（浏览器 vs 出口 IP）" -ForegroundColor Cyan
$sysOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds
$sysId = [System.TimeZoneInfo]::Local.Id
Info ("系统时区   : {0} (UTC{1:+0;-0}:00)  —— 浏览器 JS 会据此报时区" -f $sysId, ($sysOffset/3600))
if ($ipapi -and $ipapi.status -eq 'success') {
    Info ("IP 端时区  : {0} (UTC{1:+0;-0}:00)" -f $ipapi.timezone, ($ipapi.offset/3600))
    if ([math]::Abs($sysOffset - $ipapi.offset) -lt 1) {
        Ok "时区一致 —— 浏览器时区与出口 IP 匹配"
    } else {
        $diff = ($ipapi.offset - $sysOffset)/3600
        Bad ("时区不一致，差 {0:+0;-0} 小时 —— 这是平台判定'你在用 VPN'的头号依据" -f $diff)
        Info ("修复（浏览器）  ：browse-vpn.ps1 —— 自动切到出口国时区，关闭浏览器后还原")
        Info ("修复（桌面/CLI）：app-vpn.ps1 <应用> —— Node 类程序进程级注入 TZ；")
        Info ("                  Electron GUI 不认 TZ，需加 -SystemTz 临时切系统时区")
    }
}
Line

# ---------- 5. 语言/locale 一致性 ----------
Write-Host "5) 语言 / locale 一致性" -ForegroundColor Cyan
$sysLang = (Get-Culture).Name
Info ("系统区域    : {0}" -f $sysLang)
if ($ipapi -and $ipapi.countryCode) {
    if ($sysLang -match 'CN' -and $ipapi.countryCode -ne 'CN') {
        Warn ("浏览器默认语言可能是中文，而出口在 {0} —— 次级指纹信号" -f $ipapi.country)
        Info "修复：用 browse-vpn.ps1 以 --lang 覆盖浏览器语言；桌面应用/CLI 用 app-vpn.ps1 注入 LANG（均不改系统）。"
    } else {
        Ok "无明显 locale 矛盾"
    }
}
Line

# ---------- 6. DNS 解析路径 ----------
Write-Host "6) DNS 解析路径（是否漏到本地 ISP）" -ForegroundColor Cyan
$dns = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses.Count -gt 0 }
foreach ($d in $dns) {
    $servers = $d.ServerAddresses -join ', '
    if ($servers -match '^198\.18\.' -or $servers -match '^198\.19\.') {
        Ok ("{0}: {1}  (fake-ip 隧道解析 — Clash/Mihomo/sing-box/Xray fakedns 特征)" -f $d.InterfaceAlias, $servers)
    } elseif ($servers -match '^(10\.|172\.|192\.168\.|127\.)') {
        Info ("{0}: {1}  (内网/本地)" -f $d.InterfaceAlias, $servers)
    } else {
        Warn ("{0}: {1}  (公网解析器——若目标域名走 DIRECT 规则，DNS 查询会暴露给此解析器)" -f $d.InterfaceAlias, $servers)
    }
}
if ($TakeoverMode -eq 'sysproxy') {
    Info "当前为系统代理模式：浏览器把域名交给代理远端解析，本地 DNS 主要影响直连/不走代理的应用。"
}
Info "提示：确认 Chrome 已关闭“安全 DNS(DoH)”，否则浏览器会绕过 VPN 自行解析。"
if (-not $NoDnsLeak) {
    Write-Host ""
    Info "主动实测（触发真实解析，看解析器归属国 · 联网 bash.ws，约 10s；-NoDnsLeak 可跳过）……"
    $exitCc = if ($ipapi -and $ipapi.status -eq 'success') { $ipapi.countryCode } else { "" }
    $exitName = if ($ipapi -and $ipapi.status -eq 'success') { $ipapi.country } else { "" }
    Invoke-DnsLeakTest $exitCc $exitName
} else {
    Info "已跳过 DNS 主动实测（-NoDnsLeak）。上面仅为本地 DNS 配置的静态判断。"
}
Line

# ---------- 7. WebRTC 泄露（主动检测，需真实浏览器）----------
Write-Host "7) WebRTC 泄露面（主动检测 · 仅浏览器）" -ForegroundColor Cyan
Info "WebRTC 是浏览器 API，需在真实浏览器里发 STUN 才能实测，命令行只读检查覆盖不到。"
Info "本项只关乎浏览器（含 Electron 内嵌页面）；纯 CLI 工具不用 WebRTC，不受影响。"
$rtcPage = Join-Path $PSScriptRoot "webrtc-leak-test.html"
if (Test-Path $rtcPage) {
    $Chrome = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($Chrome) { Ok "检测页已就绪：webrtc-leak-test.html（已找到 Chrome）" }
    else { Warn "检测页已就绪：webrtc-leak-test.html（未找到 Chrome，请用任意浏览器打开）" }
    Info "实测（推荐，在真实隧道内跑）：browse-vpn.ps1 -WebRTC"
    Info "或直接双击 webrtc-leak-test.html —— 会自动对比 WebRTC 公网 IP 与出口 IP 并给出判定。"
} else {
    Warn "未找到 webrtc-leak-test.html —— 请从仓库获取该检测页。"
}
Line

# ---------- 8. 链路质量（够不够用；与泄露无关）----------
Write-Host "8) 链路质量（够不够用 · 与泄露无关）" -ForegroundColor Cyan
Info "ping 在这里没有意义：fake-ip 下所有域名都解析到 198.18.x.x、ICMP 由本机应答，"
Info "节点挂了 ping 也照样秒通。只能实测走代理的 TLS 握手与实际吞吐。"
if ($NoSpeedTest) {
    Info "已跳过链路质量实测（-NoSpeedTest）。"
} elseif (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Warn "未找到 curl.exe（Windows 10 1803+ 自带）—— 跳过链路质量实测"
} else {
    $pxArgs = @(); $skipReason = $null
    switch ($TakeoverMode) {
        'tun' { Info "经 TUN 隧道实测" }
        'sysproxy' {
            if ($reg.ProxyServer) {
                # ProxyServer 可能是 "host:port"，也可能是 "http=h:p;https=h:p"
                $px = "$($reg.ProxyServer)".Trim()
                if     ($px -match '(?:^|;)\s*https?=([^;]+)') { $px = $Matches[1] }
                elseif ($px -match ';')                        { $px = ($px -split ';')[0] }
                if ($px -notmatch '://') { $px = "http://$px" }
                $pxArgs = @('-x', $px)
                Info ("经系统代理 {0} 实测" -f $px)
            } elseif ($reg.AutoConfigURL) {
                $skipReason = "PAC 模式下无法确定该测速站走代理还是直连 —— 跳过（测了也失真）"
            }
        }
        default { Info "未检测到接管 —— 下面测的是当前默认出口（可能是直连）" }
    }
    if ($skipReason) {
        Warn $skipReason
    } else {
        Info "实测中（Cloudflare 测速点，约 20MB / 最多 8 秒；-NoSpeedTest 可跳过）……"
        $raw = & curl.exe @pxArgs -s -o NUL -w "%{time_appconnect} %{speed_download} %{http_code}" `
                 --connect-timeout 10 -m 8 "https://speed.cloudflare.com/__down?bytes=20971520" 2>$null
        $f = "$raw".Trim() -split '\s+'
        if ($f.Count -lt 3 -or $f[2] -notmatch '^2\d\d$') {
            Warn ("测速点不可达或被拒（HTTP {0}）—— 跳过链路质量判定" -f $(if ($f.Count -ge 3) { $f[2] } else { '无响应' }))
            Info "这本身也是个信号：若其它检查都正常却连不上测速点，多半是当前节点不稳。"
        } else {
            $tls = [double]$f[0]
            $mbps = [math]::Round(([double]$f[1]) * 8 / 1e6, 1)
            # TLS 握手：最能反映节点是否在排队。网页点击的"卡顿感"主要来自这里。
            if     ($tls -le 0.5) { Ok   ("TLS 握手 {0:N2}s —— 节点响应快" -f $tls) }
            elseif ($tls -le 2.0) { Warn ("TLS 握手 {0:N2}s —— 偏慢，网页点击会有可感延迟" -f $tls) }
            else                  { Bad  ("TLS 握手 {0:N2}s —— 节点在排队/拥塞，每次新连接都要干等这么久" -f $tls) }
            # 吞吐：直接对齐"能不能看视频"
            if     ($mbps -lt 1.5) { Bad  ("下行 {0} Mbps —— 不够 360p，基本没法看视频" -f $mbps) }
            elseif ($mbps -lt 3)   { Bad  ("下行 {0} Mbps —— 只够 360~480p，720p 必卡" -f $mbps) }
            elseif ($mbps -lt 6)   { Warn ("下行 {0} Mbps —— 720p 可用，1080p 会缓冲" -f $mbps) }
            else                   { Ok   ("下行 {0} Mbps —— 1080p 流畅" -f $mbps) }
            Info "参考：480p≈1.5 / 720p≈3 / 1080p≈6 Mbps"
            if ($tls -gt 2.0 -or $mbps -lt 3) {
                Info "建议：换节点，别照客户端面板的延迟数字挑 —— 那只测一次握手往返，不反映带宽，"
                Info "      低延迟节点完全可能是低带宽节点。换完重跑本项对比。"
            }
        }
    }
}
Line '='
Write-Host " 自查完成。红色=需处理，黄色=注意，绿色=通过。" -ForegroundColor Cyan
Write-Host ""


