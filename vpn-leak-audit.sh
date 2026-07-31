#!/usr/bin/env bash
#
#   vpn-leak-audit.sh  —  VPN 出口一致性 / 泄露自查（macOS / Linux 版）   vpn-guard v1.0.0
#   用途：使用 VPN 访问受地区限制的海外平台前，一键检查真实身份是否泄露、
#         以及浏览器指纹（时区/语言）是否与出口 IP 所在国一致。
#   覆盖范围：绝大多数项目是系统级的，浏览器与桌面应用/CLI 同样适用。
#         第 2 项专测「不认系统代理的程序」（Claude/Codex 桌面版与 CLI、Electron 主进程）的真实出口，
#         第 7 项 WebRTC 仅适用于浏览器。
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
SPEED_TEST=1
for a in "$@"; do
    case "$a" in
        --no-dns-leak) DNS_LEAK=0 ;;
        --no-speed-test) SPEED_TEST=0 ;;
        -h|--help)
            echo "用法: ./vpn-leak-audit.sh [--no-dns-leak] [--no-speed-test]"
            echo "  --no-dns-leak    跳过联网的 DNS 泄露主动实测（默认开启，走 bash.ws）"
            echo "  --no-speed-test  跳过链路质量实测（默认开启，约 20MB 流量）"
            exit 0 ;;
        *) echo "未知参数: $a（可用 --no-dns-leak / --no-speed-test）" >&2; exit 1 ;;
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
  "http://ip-api.com/line/?fields=status,country,countryCode,city,timezone,offset,isp,as,query,proxy,hosting" 2>/dev/null)
ip_status=""; ip_country=""; ip_cc=""; ip_city=""; ip_tz=""; ip_offset=""; ip_isp=""; ip_as=""
ip_query=""; ip_proxy=""; ip_hosting=""
if [ -n "$resp" ]; then
    # 注意：ip-api 的 line 格式按其固定字段顺序返回（query 在最后），与请求参数顺序无关。
    # as 排在 isp 之后、proxy 之前 —— 顺序错一位后面全串，改字段时务必先实测确认。
    { read -r ip_status; read -r ip_country; read -r ip_cc; read -r ip_city; read -r ip_tz
      read -r ip_offset; read -r ip_isp; read -r ip_as; read -r ip_proxy; read -r ip_hosting
      read -r ip_query; } <<EOF
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

# ---------- 2. 桌面应用 / CLI 出口（不认系统代理的程序）----------
head_ "2) 桌面应用 / CLI 出口（Claude、Codex、Electron 主进程……）"
info "Chrome 会自动读系统代理；但 Node / Rust / Go 写的 CLI 与 Electron 的 Node 主进程不读，"
info "只认 HTTP_PROXY / HTTPS_PROXY 环境变量。下面用「强制不走代理的 curl」模拟这类程序实测真实出口。"

env_proxy=""
for n in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy NO_PROXY no_proxy; do
    # bash 3.2 没有 ${!n} 间接展开，只能 eval；先赋空值以免 set -u / shellcheck 误报
    v=""; eval "v=\${$n:-}"
    [ -n "$v" ] && env_proxy="${env_proxy:+$env_proxy; }$n=$v"
done
if [ -n "$env_proxy" ]; then info "代理环境变量 : $env_proxy"
else info "代理环境变量 : 未设置 —— 这类程序不会主动走代理，只能靠 TUN 兜底"; fi

if [ "$ip_status" != "success" ]; then
    warn "上一项未取到浏览器侧出口 IP —— 无从对比，跳过"
else
    # --noproxy '*' 让 curl 忽略一切代理设置（含环境变量），精确复刻「完全不认代理的程序」的行为
    bare=$(curl -fsS --max-time 12 --noproxy '*' \
      "http://ip-api.com/line/?fields=status,country,countryCode,isp,query" 2>/dev/null)
    b_status=""; b_country=""; b_cc=""; b_isp=""; b_query=""
    if [ -n "$bare" ]; then
        # shellcheck disable=SC2034
        { read -r b_status; read -r b_country; read -r b_cc; read -r b_isp; read -r b_query; } <<EOF
$bare
EOF
    fi
    if [ "$b_status" != "success" ]; then
        warn "实测请求失败 —— 若确实完全不通，说明这类程序在当前环境根本连不上网（也是一种信号）"
    elif [ "$b_query" = "$ip_query" ]; then
        if [ "$TAKEOVER" = "none" ]; then
            bad "出口 $b_query 与浏览器一致，但当前没有任何接管 —— 两者都是直连，真实 IP 全程暴露"
        else
            ok "出口 $b_query 与浏览器一致 —— 不认代理的程序也被隧道接管，Claude/Codex 等不会泄露"
        fi
    else
        bad "不认代理的程序直连出口 $b_query（$b_country / $b_isp），与浏览器出口 $ip_query（$ip_country）不一致 —— 真实 IP 正在泄露！"
        info "受影响：Codex CLI、Claude Code CLI、Claude/ChatGPT 桌面版的 Node 主进程、各类自动更新与遥测。"
        info "修复 A（推荐，一劳永逸）：开客户端的 TUN 模式，全局接管所有程序。"
        info "修复 B（按应用）：用 ./app-vpn.sh 启动它们（进程级注入 HTTPS_PROXY + TZ，不改任何系统设置）。"
        [ -n "$env_proxy" ] && info "注：你已设了代理环境变量 —— 认这些变量的程序（多数 Node/Rust CLI）不受影响，不认的仍在泄露。"
    fi
fi
line

# ---------- 3. IPv6 泄露面 ----------
head_ "3) IPv6 泄露面"
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
    # "AS14061 DigitalOcean, LLC" → "AS14061"
    exit_asn=${ip_as%% *}; v6_asn=${v6as%% *}
    if [ -n "$up_exit" ] && [ -n "$up_v6cc" ] && [ "$up_v6cc" = "$up_exit" ]; then
        ok "公网 IPv6: $v6（$v6country / $v6as）—— 与出口国一致，IPv6 也走隧道，未泄露"
    elif [ -n "$exit_asn" ] && [ -n "$v6_asn" ] && [ "$v6_asn" = "$exit_asn" ]; then
        # 国家对不上但 ASN 相同：这是出口节点自己的 IPv6，只是 ip-api 对同一台机器的 v4/v6
        # 地理定位不一致（DigitalOcean / Vultr 等云厂商常见）。只比国家会在这里误报成"泄露"。
        ok "公网 IPv6: $v6（$v6as）—— 与出口同属 $exit_asn，是出口节点自己的 IPv6，未泄露"
        info "注：ip-api 把该 IPv6 定位在 $v6country、把出口 IPv4 定位在 $ip_country —— 同 ASN 时以 ASN 为准，避免误报。"
    elif [ -n "$up_v6cc" ]; then
        bad "公网 IPv6: $v6 归属 $v6country（$v6as），与出口 $ip_country（${ip_as:-未知 ASN}）既不同国也不同 ASN —— IPv6 绕过 VPN 暴露真实位置！"
        info "修复：关闭物理网卡的 IPv6，或让 VPN(TUN) 接管 IPv6 隧道。"
    else
        warn "存在公网 IPv6: $v6，但无法查询其归属以判定是否泄露"
        info "若该 IPv6 不属于你的 VPN 出口，请关闭网卡 IPv6 或让 VPN 接管 IPv6。"
    fi
else
    ok "无公网 IPv6 出口（泄露面已收窄）"
fi
line

# ---------- 4. 时区一致性（头号指纹破绽）----------
head_ "4) 时区一致性（浏览器 vs 出口 IP）"
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
        info "修复（浏览器）  ：./browse-vpn.sh —— 用 TZ 让 Chrome 按出口国报时区，不改系统"
        info "修复（桌面/CLI）：./app-vpn.sh <应用> —— 同样用 TZ 进程级注入（Unix 上 GUI 也认 TZ）"
    fi
fi
line

# ---------- 5. 语言/locale 一致性 ----------
head_ "5) 语言 / locale 一致性"
sys_lang=${LANG:-未设置}
info "系统区域    : $sys_lang"
if [ -n "$ip_cc" ] && [ "$ip_status" = "success" ]; then
    if [[ "$sys_lang" == zh_CN* ]] && [ "$ip_cc" != "CN" ]; then
        warn "浏览器默认语言可能是中文，而出口在 $ip_country —— 次级指纹信号"
        info "修复：用 browse-vpn.sh 以 --lang 覆盖浏览器语言；桌面应用/CLI 用 app-vpn.sh 注入 LANG（均不改系统）。"
    else
        ok "无明显 locale 矛盾"
    fi
fi
line

# ---------- 6. DNS 解析路径 ----------
head_ "6) DNS 解析路径（是否漏到本地 ISP）"
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

# ---------- 7. WebRTC 泄露（主动检测，需真实浏览器）----------
head_ "7) WebRTC 泄露面（主动检测 · 仅浏览器）"
info "WebRTC 是浏览器 API，需在真实浏览器里发 STUN 才能实测，命令行只读检查覆盖不到。"
info "本项只关乎浏览器（含 Electron 内嵌页面）；纯 CLI 工具不用 WebRTC，不受影响。"
if [ -f "$AUDIT_DIR/webrtc-leak-test.html" ]; then
    CHROME=$(find_chrome)
    [ -n "$CHROME" ] && ok "检测页已就绪：webrtc-leak-test.html（已找到浏览器）" \
                     || warn "检测页已就绪：webrtc-leak-test.html（未找到 Chrome/Chromium，请用任意浏览器打开）"
    info "实测（推荐，在真实隧道内跑）：./browse-vpn.sh --webrtc"
    info "或直接双击 webrtc-leak-test.html —— 会自动对比 WebRTC 公网 IP 与出口 IP 并给出判定。"
else
    warn "未找到 webrtc-leak-test.html —— 请从仓库获取该检测页。"
fi
line

# ---------- 8. 链路质量（够不够用；与泄露无关）----------
head_ "8) 链路质量（够不够用 · 与泄露无关）"
info "ping 在这里没有意义：fake-ip 下所有域名都解析到 198.18.x.x、ICMP 由本机应答，"
info "节点挂了 ping 也照样秒通。只能实测走代理的 TLS 握手与实际吞吐。"
if [ "$SPEED_TEST" != "1" ]; then
    info "已跳过链路质量实测（--no-speed-test）。"
else
    speed_px=""; speed_skip=""
    case "$TAKEOVER" in
        tun) info "经 TUN 隧道实测" ;;
        sysproxy)
            # Linux：curl 自己认 http_proxy/https_proxy；macOS 的系统代理 curl 不会自动用，需从 scutil 取
            if [ -n "${https_proxy:-}${HTTPS_PROXY:-}${http_proxy:-}${HTTP_PROXY:-}" ]; then
                info "经环境变量代理实测"
            elif [ "$(uname)" = "Darwin" ]; then
                ph=$(scutil --proxy 2>/dev/null | awk '/HTTPSProxy/{print $3}')
                pp=$(scutil --proxy 2>/dev/null | awk '/HTTPSPort/{print $3}')
                if [ -n "$ph" ] && [ -n "$pp" ]; then
                    speed_px="http://$ph:$pp"
                    info "经系统代理 $speed_px 实测"
                else
                    speed_skip="读不到系统代理地址 —— 跳过（直测会失真）"
                fi
            fi ;;
        *) info "未检测到接管 —— 下面测的是当前默认出口（可能是直连）" ;;
    esac
    if [ -n "$speed_skip" ]; then
        warn "$speed_skip"
    else
        info "实测中（Cloudflare 测速点，约 20MB / 最多 8 秒；--no-speed-test 可跳过）……"
        if [ -n "$speed_px" ]; then
            raw=$(curl -x "$speed_px" -s -o /dev/null -w "%{time_appconnect} %{speed_download} %{http_code}" \
                  --connect-timeout 10 -m 8 "https://speed.cloudflare.com/__down?bytes=20971520" 2>/dev/null)
        else
            raw=$(curl -s -o /dev/null -w "%{time_appconnect} %{speed_download} %{http_code}" \
                  --connect-timeout 10 -m 8 "https://speed.cloudflare.com/__down?bytes=20971520" 2>/dev/null)
        fi
        tls=""; spd=""; code=""
        read -r tls spd code <<EOF
$raw
EOF
        case "$code" in
            2[0-9][0-9]) ;;
            *)
                warn "测速点不可达或被拒（HTTP ${code:-无响应}）—— 跳过链路质量判定"
                info "这本身也是个信号：若其它检查都正常却连不上测速点，多半是当前节点不稳。"
                code="" ;;
        esac
        if [ -n "$code" ]; then
            mbps=$(awk -v s="$spd" 'BEGIN{printf "%.1f", s*8/1000000}')
            tls_s=$(awk -v t="$tls" 'BEGIN{printf "%.2f", t}')
            # TLS 握手：最能反映节点是否在排队。网页点击的"卡顿感"主要来自这里。
            if   awk -v t="$tls" 'BEGIN{exit !(t<=0.5)}'; then ok   "TLS 握手 ${tls_s}s —— 节点响应快"
            elif awk -v t="$tls" 'BEGIN{exit !(t<=2.0)}'; then warn "TLS 握手 ${tls_s}s —— 偏慢，网页点击会有可感延迟"
            else                                               bad  "TLS 握手 ${tls_s}s —— 节点在排队/拥塞，每次新连接都要干等这么久"
            fi
            # 吞吐：直接对齐"能不能看视频"
            if   awk -v m="$mbps" 'BEGIN{exit !(m<1.5)}'; then bad  "下行 ${mbps} Mbps —— 不够 360p，基本没法看视频"
            elif awk -v m="$mbps" 'BEGIN{exit !(m<3)}';   then bad  "下行 ${mbps} Mbps —— 只够 360~480p，720p 必卡"
            elif awk -v m="$mbps" 'BEGIN{exit !(m<6)}';   then warn "下行 ${mbps} Mbps —— 720p 可用，1080p 会缓冲"
            else                                               ok   "下行 ${mbps} Mbps —— 1080p 流畅"
            fi
            info "参考：480p≈1.5 / 720p≈3 / 1080p≈6 Mbps"
            if awk -v t="$tls" -v m="$mbps" 'BEGIN{exit !(t>2.0 || m<3)}'; then
                info "建议：换节点，别照客户端面板的延迟数字挑 —— 那只测一次握手往返，不反映带宽，"
                info "      低延迟节点完全可能是低带宽节点。换完重跑本项对比。"
            fi
        fi
    fi
fi
dline
head_ " 自查完成。红色=需处理，黄色=注意，绿色=通过。"
echo ""
