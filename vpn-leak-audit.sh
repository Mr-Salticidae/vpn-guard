#!/usr/bin/env bash
#
#   vpn-leak-audit.sh  —  VPN 出口一致性 / 泄露自查（macOS / Linux 版）
#   用途：使用 VPN 访问受地区限制的海外平台前，一键检查真实身份是否泄露、
#         以及浏览器指纹（时区/语言）是否与出口 IP 所在国一致。
#   用法：bash ./vpn-leak-audit.sh   （或 chmod +x 后直接 ./vpn-leak-audit.sh）
#   只读检查，不修改任何系统设置。依赖：bash 3.2+、curl（macOS/主流发行版自带）。
#
#   Windows 用户请使用同目录下的 vpn-leak-audit.ps1。

# ---- 输出样式 ----
if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_CYAN=''; C_GRAY=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi
line()  { printf '%s%s%s\n' "$C_GRAY" '------------------------------------------------------------' "$C_RESET"; }
dline() { printf '%s%s%s\n' "$C_GRAY" '============================================================' "$C_RESET"; }
ok()    { printf '  %s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
warn()  { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
bad()   { printf '  %s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$1"; }
info()  { printf '  %s%s%s\n' "$C_GRAY" "$1" "$C_RESET"; }
head_() { printf '%s%s%s\n' "$C_CYAN" "$1" "$C_RESET"; }

# 把 "+0800" / "-0430" 格式的偏移转成秒
zone_to_seconds() {
    local z=$1 sign hh mm
    sign=${z:0:1}; hh=${z:1:2}; mm=${z:3:2}
    local s=$((10#$hh * 3600 + 10#$mm * 60))
    [ "$sign" = "-" ] && s=$((-s))
    echo "$s"
}
fmt_utc() { printf 'UTC%+d:00' "$(( $1 / 3600 ))"; }

echo ""
head_ " VPN 出口一致性 / 泄露自查 "
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
dline

# ---------- 0. 代理客户端与流量接管方式 ----------
head_ "0) 代理客户端与流量接管方式"
known='clash|mihomo|verge|v2ray|xray|sing-box|singbox|ss-local|sslocal|shadowsocks|hysteria|tuic|trojan|naive|juicity|wireguard|openvpn'
procs=$(ps -Ao comm= 2>/dev/null | sed 's|.*/||' | grep -Ei "$known" | sort -u | tr '\n' ' ')
if [ -n "$procs" ]; then
    info "客户端进程 : $procs"
else
    info "未识别出已知代理客户端进程（Clash/V2Ray/Xray/sing-box/SS/WireGuard/OpenVPN……不影响后续检查）"
fi

# 对外路由走哪块网卡（用真实公网地址查路由，能识别 0/1 分裂路由和策略路由）
route_if=""
case "$(uname)" in
    Darwin) route_if=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}') ;;
    Linux)  route_if=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | awk '{print $2}') ;;
esac
# 系统代理是否开启
sysproxy=""
case "$(uname)" in
    Darwin)
        if scutil --proxy 2>/dev/null | grep -qE '(HTTPEnable|HTTPSEnable|SOCKSEnable) : 1'; then sysproxy=1; fi ;;
    Linux)
        if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]; then
            sysproxy=1
        elif command -v gsettings >/dev/null 2>&1 && [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" = "'manual'" ]; then
            sysproxy=1
        fi ;;
esac

TAKEOVER="none"
case "$route_if" in
    utun*|tun*|tap*|wg*|Meta*|meta*|mihomo*|sing*)
        TAKEOVER="tun"
        ok "TUN 模式（对外路由走 $route_if）—— 全局流量（含 UDP/WebRTC）均被接管" ;;
    *)
        if [ -n "$sysproxy" ]; then
            TAKEOVER="sysproxy"
            warn "系统代理模式 —— 浏览器流量走代理；不支持代理的应用与 UDP/WebRTC 可能绕行直连"
            info "建议：开启客户端的 TUN/增强模式（Clash Verge: TUN 模式；v2rayN: 启用 Tun；sing-box: tun 入站）"
        else
            warn "未检测到 TUN 路由或系统代理 —— 若你在用浏览器插件级代理或仅本地端口，只有明确配置了代理的应用被接管"
        fi ;;
esac
line

# ---------- 1. 公网 IPv4 + 地理位置 + 代理标记 ----------
head_ "1) 公网出口 IP 与地理位置"
# ip-api 的 line 格式按 fields 顺序逐行返回，无需 JSON 解析器
resp=$(curl -fsS --max-time 15 \
  "http://ip-api.com/line/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting" 2>/dev/null)
ip_status=""; ip_country=""; ip_cc=""; ip_city=""; ip_tz=""; ip_offset=""; ip_isp=""; ip_query=""; ip_proxy=""; ip_hosting=""
if [ -n "$resp" ]; then
    # 注意：ip-api 的 line 格式按其固定字段顺序返回（query 在最后），与请求参数顺序无关
    { read -r ip_status; read -r ip_country; read -r ip_cc; read -r ip_city; read -r ip_tz
      read -r ip_offset; read -r ip_isp; read -r ip_proxy; read -r ip_hosting; read -r ip_query; } <<EOF
$resp
EOF
fi
if [ "$ip_status" = "success" ]; then
    info "出口 IP   : $ip_query"
    info "位置      : $ip_city / $ip_country ($ip_cc)"
    info "ISP       : $ip_isp"
    info "IP 时区   : $ip_tz ($(fmt_utc "$ip_offset"))"
    if [ "$ip_proxy" = "true" ];   then warn "该 IP 被标记为 proxy —— 部分平台会据此拦截"; else ok "未被标记为 proxy"; fi
    if [ "$ip_hosting" = "true" ]; then warn "该 IP 被标记为 hosting/机房 —— 高风控平台常拦截机房 IP"; else ok "未被标记为机房 IP（读起来像住宅/普通 ISP）"; fi
else
    bad "无法获取公网 IP（ip-api 不可达）——检查 VPN 是否在线"
fi
line

# ---------- 2. IPv6 泄露面 ----------
head_ "2) IPv6 泄露面"
v6=$(curl -fsS --max-time 8 "https://api64.ipify.org" 2>/dev/null)
if [ -n "$v6" ] && [[ "$v6" == *:* ]]; then
    warn "存在公网 IPv6 出口: $v6 —— 若 VPN 只隧道 IPv4，IPv6 会绕过 VPN 暴露真实位置"
    info "建议：关闭网络接口的 IPv6，或确认 VPN 已接管 IPv6。"
else
    ok "无公网 IPv6 出口（泄露面已收窄）"
fi
line

# ---------- 3. 时区一致性（头号指纹破绽）----------
head_ "3) 时区一致性（浏览器 vs 出口 IP）"
sys_offset=$(zone_to_seconds "$(date +%z)")
if [ -L /etc/localtime ]; then
    sys_tz=$(readlink /etc/localtime | sed 's|.*zoneinfo/||')
else
    sys_tz=$(date +%Z)
fi
[ -z "$sys_tz" ] && sys_tz="(未知)"
info "系统时区   : $sys_tz ($(fmt_utc "$sys_offset"))  —— 浏览器 JS 会据此报时区"
if [ "$ip_status" = "success" ]; then
    info "IP 端时区  : $ip_tz ($(fmt_utc "$ip_offset"))"
    if [ "$sys_offset" -eq "$ip_offset" ]; then
        ok "时区一致 —— 浏览器时区与出口 IP 匹配"
    else
        diff_h=$(( (ip_offset - sys_offset) / 3600 ))
        bad "$(printf "时区不一致，差 %+d 小时 —— 这是平台判定'你在用 VPN'的头号依据" "$diff_h")"
        info "修复：会话前运行  ./browse-vpn.sh（用 TZ 环境变量让 Chrome 按出口国报时区，不改系统）"
    fi
fi
line

# ---------- 4. 语言/locale 一致性 ----------
head_ "4) 语言 / locale 一致性"
sys_lang=${LANG:-未设置}
info "系统区域    : $sys_lang"
if [ -n "$ip_cc" ] && [ "$ip_status" = "success" ]; then
    if [[ "$sys_lang" == zh_CN* ]] && [ "$ip_cc" != "CN" ]; then
        warn "浏览器默认语言可能是中文，而出口在 $ip_country —— 次级指纹信号"
        info "修复：用 browse-vpn.sh 以 --lang 覆盖浏览器语言（不改系统）。"
    else
        ok "无明显 locale 矛盾"
    fi
fi
line

# ---------- 5. DNS 解析路径 ----------
head_ "5) DNS 解析路径（是否漏到本地 ISP）"
dns_servers=""
case "$(uname)" in
    Darwin)
        dns_servers=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u) ;;
    Linux)
        # 只抽取 IPv4 地址样式的 token —— 避免把 "Link 2"/"Link 3" 的链路编号当成 DNS
        if command -v resolvectl >/dev/null 2>&1; then
            dns_servers=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
        fi
        if [ -z "$dns_servers" ] && [ -r /etc/resolv.conf ]; then
            dns_servers=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | sort -u)
        fi ;;
esac
if [ -z "$dns_servers" ]; then
    warn "未能读取 DNS 服务器列表"
else
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        case "$s" in
            198.18.*|198.19.*)
                ok "DNS: $s  (fake-ip 隧道解析 — Clash/Mihomo/sing-box/Xray fakedns 特征)" ;;
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|127.*)
                info "DNS: $s  (内网/本地)" ;;
            *)
                warn "DNS: $s  (公网解析器——若目标域名走 DIRECT 规则，DNS 查询会暴露给此解析器)" ;;
        esac
    done <<EOF
$dns_servers
EOF
fi
if [ "$TAKEOVER" = "sysproxy" ]; then
    info "当前为系统代理模式：浏览器把域名交给代理远端解析，本地 DNS 主要影响直连/不走代理的应用。"
fi
info "提示：确认 Chrome 已关闭「安全 DNS(DoH)」，否则浏览器会绕过 VPN 自行解析。"
dline
head_ " 自查完成。红色=需处理，黄色=注意，绿色=通过。"
echo ""
