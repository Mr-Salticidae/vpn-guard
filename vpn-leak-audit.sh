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

# ---- 参数 ----
DNS_LEAK=1
for a in "$@"; do
    case "$a" in
        --no-dns-leak) DNS_LEAK=0 ;;
        -h|--help) echo "用法: ./vpn-leak-audit.sh [--no-dns-leak]"; echo "  --no-dns-leak  跳过联网的 DNS 泄露主动实测（默认开启，走 bash.ws）"; exit 0 ;;
        *) echo "未知参数: $a（可用 --no-dns-leak）" >&2; exit 1 ;;
    esac
done

AUDIT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---- DNS 泄露主动实测：对随机子域发起真实解析，回查是哪些解析器应答（含归属国/ASN）----
# 用 bash.ws（dnsleaktest.com 官方 CLI 同源）的免费 API，无需自建权威 DNS。
dns_leak_test() {
    local exit_cc="$1" exit_name="$2" id json rows i
    id=$(curl -fsS --max-time 8 "https://bash.ws/id" 2>/dev/null)
    if [ -z "$id" ]; then warn "bash.ws 不可达 —— 跳过 DNS 主动实测"; return; fi
    # 触发解析：curl 走 getaddrinfo，最贴近应用实际行为（子域无 HTTP 服务，连接失败无妨，解析已发生）
    for i in 1 2 3 4 5 6; do curl -fsS --max-time 4 "http://$i.$id.bash.ws" >/dev/null 2>&1 & done
    wait
    json=$(curl -fsS --max-time 10 "https://bash.ws/dnsleak/test/$id?json" 2>/dev/null)
    if [ -z "$json" ]; then warn "未取到 bash.ws 结果 —— 跳过"; return; fi
    rows=$(printf '%s' "$json" | sed 's/},{/}\n{/g')
    # 出口国兜底：ip-api 若失败，用 bash.ws 自己回报的公网 IP 归属
    if [ -z "$exit_cc" ]; then
        exit_cc=$(printf '%s' "$rows"  | grep '"type":"ip"' | head -1 | sed -E 's/.*"country":"([^"]*)".*/\1/')
        exit_name=$(printf '%s' "$rows"| grep '"type":"ip"' | head -1 | sed -E 's/.*"country_name":"([^"]*)".*/\1/')
    fi
    local up_exit; up_exit=$(printf '%s' "$exit_cc" | tr '[:lower:]' '[:upper:]')
    local dns_count=0 mismatch=0
    while IFS= read -r obj; do
        case "$obj" in *'"type":"dns"'*) ;; *) continue ;; esac
        local rip rcc rname rasn
        rip=$(printf '%s'   "$obj" | sed -E 's/.*"ip":"([^"]*)".*/\1/')
        rcc=$(printf '%s'   "$obj" | sed -E 's/.*"country":"([^"]*)".*/\1/' | tr '[:lower:]' '[:upper:]')
        rname=$(printf '%s' "$obj" | sed -E 's/.*"country_name":"([^"]*)".*/\1/')
        rasn=$(printf '%s'  "$obj" | sed -E 's/.*"asn":"([^"]*)".*/\1/')
        dns_count=$((dns_count + 1))
        if [ -n "$up_exit" ] && [ -n "$rcc" ] && [ "$rcc" != "$up_exit" ]; then
            mismatch=$((mismatch + 1))
            bad "解析器 $rip（$rname / $rasn）不在出口国 $exit_name —— DNS 正泄露到此解析器"
        else
            info "解析器 $rip（$rname / $rasn）"
        fi
    done <<EOF
$rows
EOF
    if [ "$dns_count" -eq 0 ]; then
        warn "未观察到实际解析器（可能全部命中缓存或被完全隧道）——可稍后重试确认"
    elif [ "$mismatch" -eq 0 ]; then
        ok "全部解析器都在出口国 $exit_name —— DNS 未泄露"
    else
        bad "共 $mismatch/$dns_count 个解析器不在出口国 —— 你查询的域名正暴露给上述解析器（多为真实 ISP）"
        info "修复：客户端启用 fake-ip + 远端解析（让 DNS 走隧道在出口解析），并确认没有应用绕过隧道直连本地 DNS。"
    fi
}
find_chrome() {
    local c
    case "$(uname)" in
        Darwin) for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                         "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                         "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
                    [ -x "$c" ] && { echo "$c"; return; }; done ;;
        Linux)  for c in google-chrome google-chrome-stable chromium chromium-browser; do
                    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }; done ;;
    esac
}

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
    # 关键：有公网 IPv6 不等于泄露。若它归属与出口一致，说明 IPv6 也走了隧道（是出口的 v6）；
    # 只有当它归属你的真实 ISP（与出口国不一致）时，才是绕过 VPN 的真泄露。
    v6json=$(curl -fsS --max-time 8 "http://ip-api.com/json/$v6?fields=status,countryCode,country,as" 2>/dev/null)
    v6cc=$(printf '%s' "$v6json" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"//;s/"//')
    v6country=$(printf '%s' "$v6json" | grep -o '"country":"[^"]*"' | sed 's/.*"country":"//;s/"//')
    v6as=$(printf '%s' "$v6json" | grep -o '"as":"[^"]*"' | sed 's/.*"as":"//;s/"//')
    up_v6cc=$(printf '%s' "$v6cc" | tr '[:lower:]' '[:upper:]')
    up_exit=$(printf '%s' "$ip_cc" | tr '[:lower:]' '[:upper:]')
    if [ -n "$up_exit" ] && [ -n "$up_v6cc" ] && [ "$up_v6cc" = "$up_exit" ]; then
        ok "公网 IPv6: $v6（$v6country / $v6as）—— 与出口国一致，IPv6 也走隧道，未泄露"
    elif [ -n "$up_v6cc" ]; then
        bad "公网 IPv6: $v6 归属 $v6country（$v6as），与出口国 $ip_country 不一致 —— IPv6 绕过 VPN 暴露真实位置！"
        info "修复：关闭物理网卡的 IPv6，或让 VPN(TUN) 接管 IPv6 隧道。"
    else
        warn "存在公网 IPv6: $v6，但无法查询其归属以判定是否泄露"
        info "若该 IPv6 不属于你的 VPN 出口，请关闭网卡 IPv6 或让 VPN 接管 IPv6。"
    fi
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
if [ "$DNS_LEAK" = "1" ]; then
    echo ""
    info "主动实测（触发真实解析，看解析器归属国 · 联网 bash.ws，约 10s；--no-dns-leak 可跳过）……"
    dns_leak_test "$ip_cc" "$ip_country"
else
    info "已跳过 DNS 主动实测（--no-dns-leak）。上面仅为本地 DNS 配置的静态判断。"
fi
line

# ---------- 6. WebRTC 泄露（主动检测，需真实浏览器）----------
head_ "6) WebRTC 泄露面（主动检测）"
info "WebRTC 是浏览器 API，需在真实浏览器里发 STUN 才能实测，命令行只读检查覆盖不到。"
if [ -f "$AUDIT_DIR/webrtc-leak-test.html" ]; then
    CHROME=$(find_chrome)
    [ -n "$CHROME" ] && ok "检测页已就绪：webrtc-leak-test.html（已找到浏览器）" \
                     || warn "检测页已就绪：webrtc-leak-test.html（未找到 Chrome/Chromium，请用任意浏览器打开）"
    info "实测（推荐，在真实隧道内跑）：./browse-vpn.sh --webrtc"
    info "或直接双击 webrtc-leak-test.html —— 会自动对比 WebRTC 公网 IP 与出口 IP 并给出判定。"
else
    warn "未找到 webrtc-leak-test.html —— 请从仓库获取该检测页。"
fi
dline
head_ " 自查完成。红色=需处理，黄色=注意，绿色=通过。"
echo ""
