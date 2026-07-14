<#
  vpn-leak-audit.ps1  —  VPN 出口一致性 / 泄露自查
  用途：使用 VPN 访问受地区限制的海外平台前，一键检查真实身份是否泄露、
        以及浏览器指纹（时区/语言）是否与出口 IP 所在国一致。
  用法：右键“用 PowerShell 运行”，或在终端执行  powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1
  只读检查，不修改任何系统设置。
#>

$ErrorActionPreference = 'SilentlyContinue'
function Line($c='-'){ Write-Host ($c * 60) -ForegroundColor DarkGray }
function Ok($m){ Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }

Write-Host ""
Write-Host " VPN 出口一致性 / 泄露自查 " -ForegroundColor Cyan
Write-Host (" 时间: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Line '='

# ---------- 1. 公网 IPv4 + 地理位置 + 代理标记 ----------
Write-Host "1) 公网出口 IP 与地理位置" -ForegroundColor Cyan
$ipapi = $null
try { $ipapi = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting" -TimeoutSec 15 } catch {}
if ($ipapi -and $ipapi.status -eq 'success') {
    Info ("出口 IP   : {0}" -f $ipapi.query)
    Info ("位置      : {0} / {1} ({2})" -f $ipapi.city, $ipapi.country, $ipapi.countryCode)
    Info ("ISP       : {0}" -f $ipapi.isp)
    Info ("IP 时区   : {0} (UTC{1:+0;-0}:00)" -f $ipapi.timezone, ($ipapi.offset/3600))
    if ($ipapi.proxy)   { Warn "该 IP 被标记为 proxy —— 部分平台会据此拦截" } else { Ok "未被标记为 proxy" }
    if ($ipapi.hosting) { Warn "该 IP 被标记为 hosting/机房 —— 高风控平台常拦截机房 IP" } else { Ok "未被标记为机房 IP（读起来像住宅/普通 ISP）" }
} else {
    Bad "无法获取公网 IP（ip-api 不可达）——检查 VPN 是否在线"
}
Line

# ---------- 2. IPv6 泄露面 ----------
Write-Host "2) IPv6 泄露面" -ForegroundColor Cyan
$v6 = $null
try { $v6 = Invoke-RestMethod -Uri "https://api64.ipify.org?format=json" -TimeoutSec 8 } catch {}
$hasPubV6 = $false
if ($v6 -and $v6.ip -match ':') { $hasPubV6 = $true }
if ($hasPubV6) {
    Warn ("存在公网 IPv6 出口: {0} —— 若 VPN 只隧道 IPv4，IPv6 会绕过 VPN 暴露真实位置" -f $v6.ip)
    Info "建议：关闭以太网适配器的 IPv6，或确认 VPN 已接管 IPv6。"
} else {
    Ok "无公网 IPv6 出口（泄露面已收窄）"
}
Line

# ---------- 3. 时区一致性（头号指纹破绽）----------
Write-Host "3) 时区一致性（浏览器 vs 出口 IP）" -ForegroundColor Cyan
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
        Info ("修复：会话前运行  browse-vpn.ps1（自动切到出口国时区并在关闭浏览器后还原）")
    }
}
Line

# ---------- 4. 语言/locale 一致性 ----------
Write-Host "4) 语言 / locale 一致性" -ForegroundColor Cyan
$sysLang = (Get-Culture).Name
Info ("系统区域    : {0}" -f $sysLang)
if ($ipapi -and $ipapi.countryCode) {
    if ($sysLang -match 'CN' -and $ipapi.countryCode -ne 'CN') {
        Warn ("浏览器默认语言可能是中文，而出口在 {0} —— 次级指纹信号" -f $ipapi.country)
        Info "修复：用 browse-vpn.ps1 以 --lang 覆盖浏览器语言（不改系统）。"
    } else {
        Ok "无明显 locale 矛盾"
    }
}
Line

# ---------- 5. DNS 解析路径 ----------
Write-Host "5) DNS 解析路径（是否漏到本地 ISP）" -ForegroundColor Cyan
$dns = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses.Count -gt 0 }
foreach ($d in $dns) {
    $servers = $d.ServerAddresses -join ', '
    if ($servers -match '^198\.18\.' -or $servers -match '^198\.19\.') {
        Ok ("{0}: {1}  (Clash fake-ip 隧道解析)" -f $d.InterfaceAlias, $servers)
    } elseif ($servers -match '^(10\.|172\.|192\.168\.|127\.)') {
        Info ("{0}: {1}  (内网/本地)" -f $d.InterfaceAlias, $servers)
    } else {
        Warn ("{0}: {1}  (公网解析器——若目标域名走 DIRECT 规则，DNS 查询会暴露给此解析器)" -f $d.InterfaceAlias, $servers)
    }
}
Info "提示：确认 Chrome 已关闭“安全 DNS(DoH)”，否则浏览器会绕过 VPN 自行解析。"
Line '='
Write-Host " 自查完成。红色=需处理，黄色=注意，绿色=通过。" -ForegroundColor Cyan
Write-Host ""


