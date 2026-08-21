#!/usr/bin/env bash
#
#   vpn-leak-audit.sh  —  VPN 出口一致性 / 泄露自查（macOS / Linux 版）   vpn-guard v1.2.0
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

# SYSPROXY-EXTRACT-BEGIN  （verify-classifier.sh 按此标记抽取本块做表驱动回归，别删）
# 纯函数：只读参数 / stdin，不调任何外部状态命令 —— CI 能喂罐头样本离线回归。
# 为什么要有它：curl 不读 macOS 的 scutil、也不读 Linux 的 gsettings，只读 http_proxy
# 等环境变量。第 1 项若不显式 -x，拿到的就是直连出口（=真实 IP），而第 2/3/4/5 项
# 全都拿它当「浏览器侧基准」—— 基准错了，四项会一起给出假的「一致 / 未泄露」。
sysproxy_fmt() {
    local scheme=$1 h=$2 p=$3
    [ -n "$h" ] || return 1
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ ${#p} -le 5 ] || return 1          # 先卡长度，避免 [ 做大整数比较时溢出报错
    [ "$p" -gt 0 ] || return 1           # HTTPEnable:1 配 HTTPPort:0 是真实存在的残留配置
    [ "$p" -le 65535 ] || return 1
    case "$h" in *:*) h="[$h]" ;; esac   # IPv6 字面量要加方括号
    printf '%s://%s:%s\n' "$scheme" "$h" "$p"
}
# 输入：scutil --proxy 的原文（stdin）。输出恰好一行：
#   URL   —— curl -x 可直接用的地址
#   PAC   —— 自动配置，没有静态地址可取
#   空    —— 没开，或开了但配置残缺（缺 host / 端口非法）
# 顺序 HTTP > HTTPS > SOCKS：第 1 项请求的是 http:// 的 URL（ip-api 免费版无 https），
# 浏览器对 http:// 也是先用 Web Proxy(HTTP)。别照 app-vpn.sh 的 HTTPS 优先抄。
# SOCKS 必须给 socks5h:// 而不是 -x http://：把 HTTP 请求塞进 SOCKS 端口，对端会把
# 'G'(0x47) 当 SOCKS 版本号直接断链 —— 第 1 项会变成红色「VPN 不在线」，而 VPN 其实好好的。
sysproxy_url_from_scutil() {
    local txt v h p
    # __SCOPED__ 之后是各网卡的分域代理，全局设置在它之前；截断，别把别的网卡读成全局。
    txt=$(awk '$1=="__SCOPED__"{exit} {print}')
    v=$(printf '%s\n' "$txt" | awk '$1=="HTTPEnable"{print $3; exit}')
    if [ "$v" = "1" ]; then
        h=$(printf '%s\n' "$txt" | awk '$1=="HTTPProxy"{print $3; exit}')
        p=$(printf '%s\n' "$txt" | awk '$1=="HTTPPort"{print $3; exit}')
        sysproxy_fmt "http" "$h" "$p" && return 0
    fi
    v=$(printf '%s\n' "$txt" | awk '$1=="HTTPSEnable"{print $3; exit}')
    if [ "$v" = "1" ]; then
        h=$(printf '%s\n' "$txt" | awk '$1=="HTTPSProxy"{print $3; exit}')
        p=$(printf '%s\n' "$txt" | awk '$1=="HTTPSPort"{print $3; exit}')
        sysproxy_fmt "http" "$h" "$p" && return 0
    fi
    v=$(printf '%s\n' "$txt" | awk '$1=="SOCKSEnable"{print $3; exit}')
    if [ "$v" = "1" ]; then
        h=$(printf '%s\n' "$txt" | awk '$1=="SOCKSProxy"{print $3; exit}')
        p=$(printf '%s\n' "$txt" | awk '$1=="SOCKSPort"{print $3; exit}')
        sysproxy_fmt "socks5h" "$h" "$p" && return 0
    fi
    v=$(printf '%s\n' "$txt" | awk '($1=="ProxyAutoConfigEnable"||$1=="ProxyAutoDiscoveryEnable")&&$3=="1"{print "1"; exit}')
    if [ "$v" = "1" ]; then printf 'PAC\n'; return 0; fi
    printf '\n'
}
# SYSPROXY-EXTRACT-END

# ---- 参数 ----
DNS_LEAK=1
SPEED_TEST=1
EXPORT_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-dns-leak) DNS_LEAK=0 ;;
        --no-speed-test) SPEED_TEST=0 ;;
        --export)
            shift
            if [ $# -eq 0 ]; then echo "--export 后面要跟一个文件路径" >&2; exit 1; fi
            EXPORT_PATH="$1" ;;
        --export=*) EXPORT_PATH=${1#--export=} ;;
        -h|--help)
            echo "用法: ./vpn-leak-audit.sh [--no-dns-leak] [--no-speed-test] [--export <路径>]"
            echo "  --no-dns-leak    跳过联网的 DNS 泄露主动实测（默认开启，走 bash.ws）"
            echo "  --no-speed-test  跳过链路质量实测（默认开启，约 20MB 流量）"
            echo "  --export <路径>  额外导出一份已脱敏的对照报告（用于跨机器比对）"
            exit 0 ;;
        *) echo "未知参数: ${1}（可用 --no-dns-leak / --no-speed-test / --export）" >&2; exit 1 ;;
    esac
    shift
done

AUDIT_DIR=$(cd "$(dirname "$0")" && pwd)

# ==== 出口归属判定：消费级运营商 ASN 名单 ====================================
# 只存号码，不存机构名 —— 机构名由 "ISP :" 那行打印，重复存一份只多一处腐坏点。
# 号码集合与 auto-select-node.ps1 / vpn-leak-audit.ps1 同源，由 verify-unix.sh 机械比对。
# 名单漏一条只损失一句「住宅」的好消息（降级为「未识别」），不可能变成误报安全 ——
# 这是本文件敢内联一份副本、而不依赖任何外部库文件的全部理由。
# 两条会「告警」的判据（hosting=true / 32 位 ASN）完全不读这张表。
# 维护约束：BEGIN/END 之间除 ASN 号外不得出现任何数字。
# ASN-TABLE-BEGIN
RESI_ASN="
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
"
# ASN-TABLE-END
# 同目录 residential-asn.txt（可选，与 auto-select-node.ps1 读同一个文件、同一套行格式）。
# bash 3.2 没有关联数组：名单就是一个空格分隔的字符串，用 case 做整词匹配
# （两端补空格，防止 3462 被 346 误命中）。文件缺失 = 只用内置名单，功能不减。
# tr -d '\r' 兜底在 Windows 上编辑过该文件的用户。
if [ -f "$AUDIT_DIR/residential-asn.txt" ]; then
    RESI_ASN="$RESI_ASN $(tr -d '\r' < "$AUDIT_DIR/residential-asn.txt" \
        | grep -E '^[[:space:]]*(AS)?[0-9]+[[:space:]]*(#.*)?$' \
        | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/' | tr '\n' ' ')"
fi
RESI_ASN=" $(printf '%s' "$RESI_ASN" | tr '\n' ' ') "

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
            bad "解析器 ${rip}（$rname / ${rasn}）不在出口国 $exit_name —— DNS 正泄露到此解析器"
        else
            info "解析器 ${rip}（$rname / ${rasn}）"
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
# 系统代理是否开启 + 它的地址（第 1 项要显式经它探测）
# 环境变量两个平台一视同仁：curl 原生就读它们，而且比我们更懂 no_proxy / 协议匹配，
# 因此有环境变量时一律不插手 —— 那是今天就正常工作的路径，保持逐字节不变。
ENV_PX_SET=""
if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]; then
    ENV_PX_SET=1
fi
sysproxy=""; SYS_PX=""; SYS_PX_AUTH=""
[ -n "$ENV_PX_SET" ] && sysproxy=1
case "$(uname)" in
    Darwin)
        sp=$(scutil --proxy 2>/dev/null)
        if printf '%s
' "$sp" | grep -qE '(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable) : 1'; then
            sysproxy=1
            SYS_PX=$(printf '%s
' "$sp" | sysproxy_url_from_scutil)
            # 有用户名就说明配了认证，密码在钥匙串里 —— 只读自查绝不去取它。
            printf '%s
' "$sp" | grep -qE '(HTTPUser|HTTPSUser|SOCKSUser) :' && SYS_PX_AUTH=1
        fi ;;
    Linux)
        if [ -z "$ENV_PX_SET" ] && command -v gsettings >/dev/null 2>&1; then
            case "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" in
                "'manual'")
                    sysproxy=1
                    gs_h=$(gsettings get org.gnome.system.proxy.http host 2>/dev/null | tr -d "'")
                    gs_p=$(gsettings get org.gnome.system.proxy.http port 2>/dev/null)
                    SYS_PX=$(sysproxy_fmt http "$gs_h" "$gs_p")
                    if [ -z "$SYS_PX" ]; then
                        gs_h=$(gsettings get org.gnome.system.proxy.socks host 2>/dev/null | tr -d "'")
                        gs_p=$(gsettings get org.gnome.system.proxy.socks port 2>/dev/null)
                        SYS_PX=$(sysproxy_fmt socks5h "$gs_h" "$gs_p")
                    fi
                    if [ "$(gsettings get org.gnome.system.proxy.http use-authentication 2>/dev/null)" = "true" ]; then
                        SYS_PX_AUTH=1
                    fi ;;
                "'auto'") sysproxy=1; SYS_PX="PAC" ;;
            esac
        fi ;;
esac

TAKEOVER="none"
# TUN_ROUTED：严格版 —— 只有「对外路由确实走 TUN 网卡」才为真。第 2 项的出口轮换
# 判定只认这个值：系统代理下 curl --noproxy 是直连，IP 不同就是真泄露，不能读成轮换。
TUN_ROUTED=0
case "$route_if" in
    utun*|tun*|tap*|wg*|Meta*|meta*|mihomo*|sing*)
        TAKEOVER="tun"; TUN_ROUTED=1
        ok "TUN 模式（对外路由走 ${route_if}）—— 全局流量（含 UDP/WebRTC）均被接管" ;;
    *)
        if [ -n "$sysproxy" ]; then
            TAKEOVER="sysproxy"
            case "$SYS_PX" in
                PAC)
                    warn "PAC / 自动配置代理 —— 命中规则的浏览器流量走代理；脚本不执行 PAC，取不到出口地址" ;;
                '')
                    if [ -n "$ENV_PX_SET" ]; then
                        warn "系统代理模式（代理环境变量）—— 浏览器与认变量的程序走代理；不认的与 UDP/WebRTC 绕行直连"
                    else
                        warn "系统代理模式 —— 但读不到可用的代理地址（配置残缺）"
                    fi ;;
                *)
                    warn "系统代理模式（${SYS_PX}）—— 浏览器流量走代理；不支持代理的应用与 UDP/WebRTC 可能绕行直连" ;;
            esac
            info "建议：开启客户端的 TUN/增强模式（Clash Verge: TUN 模式；v2rayN: 启用 Tun；sing-box: tun 入站）"
        else
            warn "未检测到 TUN 路由或系统代理 —— 若你在用浏览器插件级代理或仅本地端口，只有明确配置了代理的应用被接管"
        fi ;;
esac

# PX1：第 1 项要显式补的 -x 地址。只在「系统代理接管、但 curl 自己看不见它」时才有值。
# TUN / 无接管 / 有代理环境变量 三种状态下 PX1 恒为空，第 1 项与旧版逐字节等价。
PX1=""; PX1_WHY=""
if [ "$TAKEOVER" = "sysproxy" ] && [ -z "$ENV_PX_SET" ]; then
    if [ -n "$SYS_PX_AUTH" ];   then PX1_WHY="auth"
    elif [ "$SYS_PX" = "PAC" ]; then PX1_WHY="pac"
    elif [ -z "$SYS_PX" ];      then PX1_WHY="unknown"
    else                             PX1="$SYS_PX"
    fi
fi
# EXIT_TRUSTED=0 表示「第 1 项拿到的不是浏览器实际走的出口」。第 3/4/5 项全都拿它当基准，
# 基准不可信时必须降级为「无法判定」—— 绝不能拿直连出口去比时区 / locale / IPv6 归属后报绿。
EXIT_TRUSTED=1
[ -n "$PX1_WHY" ] && EXIT_TRUSTED=0
line

# ---------- 1. 公网 IPv4 + 地理位置 + 代理标记 ----------
head_ "1) 公网出口 IP 与地理位置"
# ip-api 的 line 格式按 fields 顺序逐行返回，无需 JSON 解析器
# ${PX1:+-x "$PX1"}：只有系统代理接管、且 curl 自己读不到它时才补 —— 否则参数与旧版完全一致。
# 不补的话，macOS 的 scutil / Linux 的 gsettings 代理 curl 都看不见，这里拿到的会是直连出口
# （= 你的真实 IP），而第 2/3/4/5 项全都拿它当浏览器侧基准，会一起给出假的「一致 / 未泄露」。
resp=$(curl -fsS --max-time 15 --connect-timeout 8 ${PX1:+-x "$PX1"} \
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
    # EXIT-CLASS-BEGIN  （verify-classifier.sh 按此标记抽取本块做跨语言比对，别删）
    # ---- 出口归属（住宅/消费级 vs 机房/主机商）----
    # 旧版仅凭 ip-api 的 hosting=false 就写「读起来像住宅/普通 ISP」，2026-08-19 实测是错的：
    # AS131939 IPS INC / AS131642 Pittqiao / AS209642 Mejiro 三家小主机商 hosting 全是 false。
    # 三态，且「未识别」是默认值：判据不足时只说不知道，绝不说安全。
    # 变量名必须用 exit_asnum（纯数字）—— 第 3 项已有 exit_asn 存 "AS14061" 这种带前缀的
    # 字符串做 v4/v6 同 ASN 比对，bash 没有作用域，撞名会破掉 IPv6 误报防护。
    exit_asnum=$(printf '%s' "$ip_as" | sed -n 's/^AS\([0-9][0-9]*\).*$/\1/p')
    resi_hit=0
    if [ -n "$exit_asnum" ]; then
        case "$RESI_ASN" in *" $exit_asnum "*) resi_hit=1 ;; esac
    fi
    if [ "$ip_hosting" = "true" ]; then
        warn "出口归属  : 机房/主机商 —— ip-api 直接标记为 hosting（${ip_as:-未知 ASN}）。高风控平台常拦截机房 IP"
        if [ "$resi_hit" = "1" ]; then
            info "该 ASN 同时在消费级运营商名单里 —— 多半落在该运营商自营的 IDC 段，仍按机房看待。"
        fi
    elif [ -z "$exit_asnum" ]; then
        info "出口归属  : 未识别 —— ip-api 没返回 AS 号，无判据。不能据此认为出口安全。"
    elif [ "$resi_hit" = "1" ]; then
        ok "出口归属  : 住宅/消费级 —— AS${exit_asnum} 在已知消费级运营商名单中"
    elif [ "$exit_asnum" -ge 65536 ]; then
        warn "出口归属  : 推断为机房/主机商 —— AS${exit_asnum} 是 32 位 ASN（2014 年后才发放；家宽运营商都在那之前就拿到了号段）"
        info "ip-api 的 hosting=false 只代表它库里没这条记录，不代表这是住宅 IP。"
        info "若你确认 AS${exit_asnum} 是当地家宽运营商，把它写进同目录 residential-asn.txt（每行一条 AS 号）即可。"
    else
        info "出口归属  : 未识别 —— AS${exit_asnum} 既不在消费级运营商名单中，ip-api 也未标记为机房。"
        info "「未识别」只表示没认出来：既不等于机房，也不等于住宅。别据此判定安全。"
    fi
    # EXIT-CLASS-END
    # 基准可信度。放在 EXIT-CLASS-END 之外：verify-classifier.sh 会按标记抽取上面那段
    # 单独执行做跨语言比对，块内引用 $EXIT_TRUSTED 会让它跑不起来。
    if [ "$EXIT_TRUSTED" != "1" ]; then
        case "$PX1_WHY" in
            pac)     warn "上面这个出口是**直连**取得的，不是浏览器实际走的出口 —— 当前是 PAC / 自动配置代理，脚本不执行 PAC 规则，取不到浏览器会用的地址。" ;;
            auth)    warn "上面这个出口是**直连**取得的，不是浏览器实际走的出口 —— 系统代理配了用户名认证，密码在钥匙串里，只读自查不会去取。" ;;
            *)       warn "上面这个出口是**直连**取得的，不是浏览器实际走的出口 —— 系统代理已开启，但读不到可用的代理地址。" ;;
        esac
        info "curl 不读 macOS 的 scutil / Linux 的 gsettings 代理，只读 http_proxy 等环境变量。"
        info "因此第 3、4、5 项失去了比较基准，下面会标为「无法判定」而不是给出结论。"
        info "想让这几项恢复可用：开客户端的 TUN 模式，或把代理写进 http_proxy / https_proxy 环境变量再跑。"
    fi
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
      "http://ip-api.com/line/?fields=status,country,countryCode,isp,as,query" 2>/dev/null)
    # /line/ 按 ip-api 的固定字段序返回，与请求参数顺序无关；as 排在 isp 之后、query 之前。
    # 已用打乱的请求顺序 A/B 对照实测确认：6 行 = status / country / countryCode / isp / as / query。
    # 改字段前务必重测，位置读取链串位是静默错误。
    b_status=""; b_country=""; b_cc=""; b_isp=""; b_as=""; b_query=""
    if [ -n "$bare" ]; then
        # shellcheck disable=SC2034
        { read -r b_status; read -r b_country; read -r b_cc; read -r b_isp
          read -r b_as; read -r b_query; } <<EOF
$bare
EOF
    fi
    if [ "$b_status" != "success" ]; then
        warn "实测请求失败 —— 若确实完全不通，说明这类程序在当前环境根本连不上网（也是一种信号）"
    elif [ "$b_query" = "$ip_query" ]; then
        if [ "$TAKEOVER" = "none" ]; then
            bad "出口 $b_query 与浏览器一致，但当前没有任何接管 —— 两者都是直连，真实 IP 全程暴露"
        elif [ "$TUN_ROUTED" != "1" ]; then
            # 「被隧道接管」这句话在非 TUN 下恒为假，与两侧 IP 是否相同无关。
            # 结构上：TAKEOVER=sysproxy 只在 case "$route_if" 的 *) 分支里被设置，
            # 而 TUN_ROUTED=1 只在 TUN 分支里被设置 —— 两者互斥。对外路由没走 TUN 网卡，
            # 就意味着「不认代理的程序」按定义是直连的，不可能被隧道接管。
            # 两侧 IP 相同只说明代理把 ip-api.com 也放行直连了（规则型客户端很常见），
            # 或者本机 curl 与浏览器走的是同一条直连路径 —— 都不构成安全结论。
            warn "出口 $b_query 与浏览器一致，但当前是系统代理 / 局部接管，对外路由没走 TUN —— 无法据此判定这类程序安全"
            info "非 TUN 下「不认代理的程序」本来就是直连；两侧相同多半是代理对 ip-api.com 走了直连规则。"
            info "要真正兜住 Claude / Codex 这类程序，只有开客户端的 TUN 模式，或用 ./app-vpn.sh 逐个启动。"
        else
            ok "出口 $b_query 与浏览器一致 —— 不认代理的程序也被隧道接管，Claude/Codex 等不会泄露"
        fi
    else
        # 出口轮换 vs 真泄露。TUN 模式下 curl --noproxy 同样走隧道（--noproxy 只关代理设置，
        # 不改路由），两次观测落在同一出口池的不同成员上就会 IP 不同 —— 那不是泄露。
        # 判据与第 3 项对 IPv6 用的完全一致：同 ASN 时以 ASN 为准。
        # 只在 TUN_ROUTED=1 时才敢这么判：系统代理 / 无接管时 curl 本来就是直连，
        # 两条路本就不同，此时 IP 不同就是真泄露，必须保持红色。
        bare_asn=""
        case "$b_as" in AS[0-9]*) bare_asn=${b_as#AS}; bare_asn=${bare_asn%% *} ;; esac
        exit_asncmp=""
        case "$ip_as" in AS[0-9]*) exit_asncmp=${ip_as#AS}; exit_asncmp=${exit_asncmp%% *} ;; esac
        if [ "$TUN_ROUTED" = "1" ] && [ -n "$bare_asn" ] && [ "$bare_asn" = "$exit_asncmp" ]; then
            warn "出口在轮换：浏览器侧 ${ip_query}、不认代理的程序侧 ${b_query}，两者同属 AS${exit_asncmp} —— 同一出口池的不同成员，不是泄露"
            info "当前节点背后是负载均衡 / 多出口池：出口被大量账号共享（平台按 IP 聚类做关联判定），"
            info "且会话 IP 会中途跳变 —— Claude / ChatGPT 这类平台会把它当成异常信号。"
            info "另注意：第 3、4、5、8 项都是对「第 1 项那一瞬的出口」的快照 —— 出口会变，就说明那些结论只对那一次成立。"
            info "修复：在客户端里选一个固定节点，别用「自动选择 / 负载均衡 / fallback」策略组。"
        else
            bad "不认代理的程序直连出口 ${b_query}（$b_country / ${b_isp}），与浏览器出口 ${ip_query}（${ip_country}）不一致 —— 真实 IP 正在泄露！"
            info "受影响：Codex CLI、Claude Code CLI、Claude/ChatGPT 桌面版的 Node 主进程、各类自动更新与遥测。"
            info "修复 A（推荐，一劳永逸）：开客户端的 TUN 模式，全局接管所有程序。"
            info "修复 B（按应用）：用 ./app-vpn.sh 启动它们（进程级注入 HTTPS_PROXY + TZ，不改任何系统设置）。"
            [ -n "$env_proxy" ] && info "注：你已设了代理环境变量 —— 认这些变量的程序（多数 Node/Rust CLI）不受影响，不认的仍在泄露。"
        fi
    fi
fi
line

# ---------- 3. IPv6 泄露面 ----------
head_ "3) IPv6 泄露面"
v6=$(curl -fsS --max-time 8 "https://api64.ipify.org" 2>/dev/null)
if [ -n "$v6" ] && [[ "$v6" == *:* ]] && [ "$EXIT_TRUSTED" != "1" ]; then
    info "公网 IPv6: ${v6}"
    warn "无法判定 —— 本项要拿它与「出口 IPv4 的归属」比对，而第 1 项的出口是直连取得的（详见第 1 项的说明）"
elif [ -n "$v6" ] && [[ "$v6" == *:* ]]; then
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
        ok "公网 IPv6: ${v6}（$v6country / ${v6as}）—— 与出口国一致，IPv6 也走隧道，未泄露"
    elif [ -n "$exit_asn" ] && [ -n "$v6_asn" ] && [ "$v6_asn" = "$exit_asn" ]; then
        # 国家对不上但 ASN 相同：这是出口节点自己的 IPv6，只是 ip-api 对同一台机器的 v4/v6
        # 地理定位不一致（DigitalOcean / Vultr 等云厂商常见）。只比国家会在这里误报成"泄露"。
        ok "公网 IPv6: ${v6}（${v6as}）—— 与出口同属 ${exit_asn}，是出口节点自己的 IPv6，未泄露"
        info "注：ip-api 把该 IPv6 定位在 ${v6country}、把出口 IPv4 定位在 $ip_country —— 同 ASN 时以 ASN 为准，避免误报。"
    # 必须同时要求 up_exit 非空：第 1 项的 ip-api 调用失败（网络抖动或 45 次/分限流）时
    # ip_country / ip_as 都是空，只凭 up_v6cc 就打红字会宣称一个不存在的 IPv6 泄露。
    # .ps1 侧一直有这道守卫，这里补齐，两版行为对齐。
    elif [ -n "$up_exit" ] && [ -n "$up_v6cc" ]; then
        bad "公网 IPv6: $v6 归属 ${v6country}（${v6as}），与出口 ${ip_country}（${ip_as:-未知 ASN}）既不同国也不同 ASN —— IPv6 绕过 VPN 暴露真实位置！"
        info "修复：关闭物理网卡的 IPv6，或让 VPN(TUN) 接管 IPv6 隧道。"
    else
        warn "存在公网 IPv6: ${v6}，但无法查询其归属以判定是否泄露"
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
if [ "$ip_status" = "success" ] && [ "$EXIT_TRUSTED" != "1" ]; then
    warn "无法判定 —— 第 1 项的出口是直连取得的，拿它比时区没有意义（详见第 1 项的说明）"
    info "这一项恰恰是平台判定「你在用 VPN」的头号依据，所以宁可不给结论，也不给一个假的「一致」。"
elif [ "$ip_status" = "success" ]; then
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
if [ "$ip_status" = "success" ] && [ "$EXIT_TRUSTED" != "1" ]; then
    warn "无法判定 —— 第 1 项的出口是直连取得的，不知道浏览器实际落在哪个国家（详见第 1 项的说明）"
elif [ -n "$ip_cc" ] && [ "$ip_status" = "success" ]; then
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

# ---------- 结构化导出（--export，用于跨机器对照）----------
# 与 vpn-leak-audit.ps1 的 -Export 是同一份格式：**键名必须逐字节一致**，
# 否则 compare-reports 认不出来。verify-classifier.sh 的 E 段机械比对两版键名。
#
# 设计前提：这份文件是要发给别人的，所以默认脱敏，只导出「对照需要的」维度。
# 刻意不导出：完整出口 IP（只留 /24）、完整 IPv6、DNS 服务器地址、代理环境变量的值
# （可能含凭据）、机器名 / 用户名 / 任何绝对路径。
# 系统时区只导出「与出口的差值」而非时区名 —— 时区名会直接暴露所在地。
if [ -n "$EXPORT_PATH" ]; then
    # EXPORT-KEYS-BEGIN  （verify-classifier.sh 按此标记抽取键名与 .ps1 比对，别删）
    mask_ip() {
        case "$1" in
            *.*.*.*) printf '%s.x\n' "${1%.*}" ;;
            *) printf '\n' ;;
        esac
    }
    e_class="n/a"
    if [ "$ip_status" = "success" ]; then
        if   [ "$ip_hosting" = "true" ];        then e_class="datacenter(hosting标记)"
        elif [ -z "$exit_asnum" ];              then e_class="unknown(无AS号)"
        elif [ "$resi_hit" = "1" ];             then e_class="residential"
        elif [ "$exit_asnum" -ge 65536 ];       then e_class="datacenter(32位ASN推断)"
        else                                         e_class="unknown"
        fi
    fi
    e_cli="n/a"
    if [ "$ip_status" = "success" ] && [ "$b_status" = "success" ]; then
        if   [ "$b_query" != "$ip_query" ] && [ "$TUN_ROUTED" = "1" ]; then e_cli="出口轮换(同ASN)或泄露"
        elif [ "$b_query" != "$ip_query" ];                            then e_cli="泄露"
        elif [ "$TAKEOVER" = "none" ];                                 then e_cli="全程直连"
        elif [ "$TUN_ROUTED" != "1" ];                                 then e_cli="无法判定(非TUN)"
        else                                                                e_cli="已被隧道接管"
        fi
    fi
    e_tz="n/a"
    if [ "$ip_status" = "success" ]; then e_tz=$(( (ip_offset - sys_offset) / 3600 )); fi
    # 归一化 locale：bash 侧是 zh_CN.UTF-8、PowerShell 侧是 zh-CN，不归一就没法比。
    e_lang=$(printf '%s' "$sys_lang" | sed 's/\..*$//' | tr '_' '-')
    [ -z "$e_lang" ] && e_lang="未设置"
    e_v6="无公网IPv6"
    if [ -n "$v6" ]; then
        if   [ -n "$up_v6cc" ] && [ "$up_v6cc" = "$up_exit" ];        then e_v6="未泄露(同国)"
        elif [ -n "$v6_asn" ] && [ "$v6_asn" = "$exit_asn" ];         then e_v6="未泄露(同ASN)"
        elif [ -n "$up_v6cc" ];                                       then e_v6="疑似泄露"
        else                                                               e_v6="有IPv6但无法判定"
        fi
    fi
    e_env="未设置"
    [ -n "$ENV_PX_SET" ] && e_env="已设置(值不导出)"
    e_trust="是"
    [ "$EXIT_TRUSTED" != "1" ] && e_trust="否(第1项是直连取得的，下面的出口信息不代表浏览器实际出口)"
    e_seg="n/a"; e_asn="n/a"; e_cc="n/a"; e_isp="n/a"; e_proxy="否"
    if [ "$ip_status" = "success" ]; then
        e_seg=$(mask_ip "$ip_query"); e_cc="$ip_cc"; e_isp="$ip_isp"
        [ -n "$exit_asnum" ] && e_asn="AS${exit_asnum}"
        [ "$ip_proxy" = "true" ] && e_proxy="是"
    fi

    ex_dir=$(dirname "$EXPORT_PATH")
    [ -d "$ex_dir" ] || mkdir -p "$ex_dir" 2>/dev/null
    {
        echo "# vpn-guard 环境对照报告（已脱敏）"
        echo "# 本文件不含完整 IP、IPv6、DNS 地址、代理凭据、机器名或路径。"
        echo "生成时间          : $(date '+%Y-%m-%d %H:%M')"
        echo "报告格式版本      : 1"
        echo "操作系统          : $(uname -s)"
        echo ""
        echo "## 一、网络环境（脚本实测）"
        echo "流量接管方式      : ${TAKEOVER}"
        echo "对外路由确实走TUN : $([ "$TUN_ROUTED" = "1" ] && echo 是 || echo 否)"
        echo "出口基准可信      : ${e_trust}"
        echo "出口国            : ${e_cc}"
        echo "出口网段          : ${e_seg}"
        echo "出口 ASN          : ${e_asn}"
        echo "出口 ISP          : ${e_isp}"
        echo "出口归属判定      : ${e_class}"
        echo "被标记为 proxy    : ${e_proxy}"
        echo "CLI/桌面应用出口  : ${e_cli}"
        echo "时区差(出口-系统) : ${e_tz} 小时"
        echo "系统区域          : ${e_lang}"
        echo "IPv6              : ${e_v6}"
        echo "代理环境变量      : ${e_env}"
        echo ""
        echo "## 二、账号与使用习惯（需人工填写 —— 这部分才是关键变量）"
        echo "# 脚本测不到这些，但按已有结论，它们比上面任何一项都更能决定账号存活。"
        echo "# 请如实填写，不确定就写「不清楚」。"
        echo "被封过吗(次数)    : __待填__"
        echo "最近一次被封时间  : __待填__"
        echo "账号来源          : __待填__  # 自己注册 / 别人给的 / 买的 / 多人合租"
        echo "账号大概注册年份  : __待填__"
        echo "注册用邮箱        : __待填__  # 自己长期在用的 / 为注册临时建的"
        echo "是否与他人共用    : __待填__"
        echo "是否绑过支付方式  : __待填__  # 没绑 / 绑了(哪国的卡)"
        echo "客户端节点策略    : __待填__  # 固定一个节点 / 自动选择 / 负载均衡"
        echo "多久换一次节点    : __待填__"
    } > "$EXPORT_PATH" 2>/dev/null
    # EXPORT-KEYS-END
    if [ -f "$EXPORT_PATH" ]; then ok "对照报告已导出：${EXPORT_PATH}"; else bad "导出失败：写不了 ${EXPORT_PATH}"; fi
fi
