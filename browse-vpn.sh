#!/usr/bin/env bash
#
#   browse-vpn.sh  —  通用一致性浏览会话（macOS / Linux 版，自动识别出口国）
#   作用：探测当前 VPN 出口所在国 → 用 TZ 环境变量让 Chrome 按出口国报时区
#         （只影响这个 Chrome 进程，不改系统时区、无需还原）→
#         用独立 Chrome 配置启动（语言匹配出口国、关闭浏览器 DoH 走隧道解析）。
#         一个脚本适配所有出口国。
#
#   用法：
#     ./browse-vpn.sh              # 自动识别当前出口
#     ./browse-vpn.sh --dry-run    # 只预览会怎么设置，不开浏览器
#     ./browse-vpn.sh US           # 强制按某国预设（不依赖探测）
#     ./browse-vpn.sh JP --dry-run # 可组合
#     ./browse-vpn.sh --proxy=socks5://127.0.0.1:10808
#         # 客户端只开了本地端口（如 v2rayN/Xray 的 SOCKS 端口）而没开系统代理/TUN 时，
#         # 让出口探测和 Chrome 都直接走该端口
#
#   依赖：bash 3.2+、curl、Google Chrome（或 Chromium）。
#   Windows 用户请使用同目录下的 browse-vpn.ps1。

set -u

# ---- 参数 ----
COUNTRY=""; DRYRUN=0; PROXY=""
for a in "$@"; do
    case "$a" in
        --dry-run|-DryRun) DRYRUN=1 ;;
        --country=*)       COUNTRY=${a#*=} ;;
        --proxy=*)         PROXY=${a#*=} ;;
        [A-Za-z][A-Za-z])  COUNTRY=$a ;;
        *) echo "未知参数: $a   用法: ./browse-vpn.sh [国家码] [--dry-run] [--proxy=socks5://127.0.0.1:端口]" >&2; exit 1 ;;
    esac
done
COUNTRY=$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')

C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_MAGENTA=$'\033[35m'; C_RESET=$'\033[0m'

BASE_DIR=$(cd "$(dirname "$0")" && pwd)

# ---- 自动定位 Chrome / Chromium ----
CHROME=""
case "$(uname)" in
    Darwin)
        for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
            [ -x "$c" ] && { CHROME=$c; break; }
        done ;;
    Linux)
        for c in google-chrome google-chrome-stable chromium chromium-browser; do
            command -v "$c" >/dev/null 2>&1 && { CHROME=$(command -v "$c"); break; }
        done ;;
esac
if [ -z "$CHROME" ]; then
    if [ "$DRYRUN" -eq 1 ]; then
        echo "${C_YELLOW}未找到 Chrome/Chromium（DryRun 模式，继续预览）。${C_RESET}"
    else
        echo "${C_RED}未找到 Chrome/Chromium，请先安装，或在脚本顶部手动指定 CHROME 路径。${C_RESET}"; exit 1
    fi
fi

# ==== 出口国 → 默认 IANA 时区 + 浏览器语言 预设表 ====
# Unix 直接用 IANA 时区名（TZ 环境变量），无需 Windows 时区 ID 映射。
# 探测成功时，时区始终以 ip-api 返回的出口 IANA 时区为准（多时区国家自动精确到分区）；
# 此表的时区只在「探测失败 + 手动指定国家」时兜底。
preset() {
    case "$1" in
        JP) echo "Asia/Tokyo|ja-JP,ja" ;;
        KR) echo "Asia/Seoul|ko-KR,ko" ;;
        SG) echo "Asia/Singapore|en-SG,en" ;;
        HK) echo "Asia/Hong_Kong|zh-HK,zh,en" ;;
        TW) echo "Asia/Taipei|zh-TW,zh" ;;
        GB) echo "Europe/London|en-GB,en" ;;
        DE) echo "Europe/Berlin|de-DE,de" ;;
        FR) echo "Europe/Paris|fr-FR,fr" ;;
        NL) echo "Europe/Amsterdam|nl-NL,nl,en" ;;
        US) echo "America/New_York|en-US,en" ;;   # 默认东部，探测到具体分区会覆盖
        CA) echo "America/Toronto|en-CA,en,fr" ;;
        AU) echo "Australia/Sydney|en-AU,en" ;;
        *)  echo "" ;;
    esac
}

# ---- 0) 接管方式安全检查：都没有时 Chrome 会直连暴露真实 IP ----
if [ -z "$PROXY" ]; then
    route_if=""; sysproxy=""
    case "$(uname)" in
        Darwin)
            route_if=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
            scutil --proxy 2>/dev/null | grep -qE '(HTTPEnable|HTTPSEnable|SOCKSEnable) : 1' && sysproxy=1 ;;
        Linux)
            route_if=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | awk '{print $2}')
            [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ] && sysproxy=1 ;;
    esac
    case "$route_if" in
        utun*|tun*|tap*|wg*|Meta*|meta*|mihomo*|sing*) : ;;  # TUN 接管，安全
        *)
            if [ -z "$sysproxy" ]; then
                echo "${C_RED}⚠ 未检测到 TUN 路由或系统代理 —— Chrome 将直连（暴露真实 IP）！${C_RESET}"
                echo "${C_YELLOW}  若客户端只开了本地端口，请加 --proxy=socks5://127.0.0.1:<端口>（v2rayN/Xray 常用 10808/1080）。${C_RESET}"
            fi ;;
    esac
fi

# ---- 1) 探测出口（指定了 --proxy 时探测也走它，保证拿到真实出口）----
echo "${C_CYAN}探测当前 VPN 出口……${C_RESET}"
resp=$(curl -fsS --max-time 15 ${PROXY:+-x "$PROXY"} \
  "http://ip-api.com/line/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting" 2>/dev/null)
ip_status=""; ip_country=""; ip_cc=""; ip_city=""; ip_tz=""; ip_offset=""; ip_isp=""; ip_query=""; ip_proxy=""; ip_hosting=""
if [ -n "$resp" ]; then
    # 注意：ip-api 的 line 格式按其固定字段顺序返回（query 在最后），与请求参数顺序无关
    # ip_isp 本脚本不展示，仅作占位以推进到后续字段（故 shellcheck 忽略未使用告警）
    # shellcheck disable=SC2034
    { read -r ip_status; read -r ip_country; read -r ip_cc; read -r ip_city; read -r ip_tz
      read -r ip_offset; read -r ip_isp; read -r ip_proxy; read -r ip_hosting; read -r ip_query; } <<EOF
$resp
EOF
fi

cc=""; iana=""; ipOffset=""
if [ "$ip_status" != "success" ]; then
    if [ -z "$COUNTRY" ]; then
        echo "${C_RED}无法探测出口（ip-api 不可达），且未指定国家。请检查 VPN 是否在线，或加国家码手动指定（如 ./browse-vpn.sh JP）。${C_RESET}"; exit 1
    fi
    echo "${C_YELLOW}探测失败，改用手动指定的国家 $COUNTRY${C_RESET}"
    cc=$COUNTRY
else
    echo "${C_GRAY}  出口 IP : $ip_query${C_RESET}"
    echo "${C_GRAY}  位置    : $ip_city / $ip_country ($ip_cc), $ip_tz (UTC$(printf '%+d' $((ip_offset/3600))):00)${C_RESET}"
    if [ "$ip_proxy" = "true" ] || [ "$ip_hosting" = "true" ]; then
        echo "${C_YELLOW}  注意：该 IP 被标记为 proxy/hosting，高风控平台可能拦截。${C_RESET}"
    fi
    cc=$ip_cc; iana=$ip_tz; ipOffset=$ip_offset
    if [ -n "$COUNTRY" ] && [ "$COUNTRY" != "$cc" ]; then
        echo "${C_YELLOW}  你指定了国家 $COUNTRY，但探测到出口在 $cc；语言以你指定的为准，时区跟随真实出口。${C_RESET}"
        cc=$COUNTRY
    fi
fi

# ---- 2) 决定时区 + 语言 ----
p=$(preset "$cc")
if [ -n "$p" ]; then
    preset_tz=${p%%|*}; lang=${p#*|}
else
    echo "${C_YELLOW}未预置国家 $cc，语言用通用 en-US。${C_RESET}"
    preset_tz=""; lang="en-US,en"
fi
# 时区优先级：真实出口 IANA 时区 > 预设兜底
if [ -n "$iana" ]; then
    tz=$iana
elif [ -n "$preset_tz" ]; then
    tz=$preset_tz
else
    echo "${C_RED}信息不足，无法决定时区（未预置国家且探测失败）。${C_RESET}"; exit 1
fi

# ---- 3) 一致性校验：所选时区当前偏移是否与出口 IP 一致 ----
if [ ! -f "/usr/share/zoneinfo/$tz" ] && [ ! -f "/etc/zoneinfo/$tz" ] && [ ! -f "/usr/share/lib/zoneinfo/$tz" ]; then
    echo "${C_YELLOW}  ⚠ 本机时区数据库中找不到 $tz —— TZ 可能不生效（Chrome 会回退到系统时区），请确认已安装 tzdata。${C_RESET}"
fi
chosen_z=$(TZ=$tz date +%z)
sign=${chosen_z:0:1}; hh=${chosen_z:1:2}; mm=${chosen_z:3:2}
chosen_offset=$((10#$hh * 3600 + 10#$mm * 60)); [ "$sign" = "-" ] && chosen_offset=$((-chosen_offset))
if [ -n "$ipOffset" ] && [ "$chosen_offset" -ne "$ipOffset" ]; then
    echo "${C_YELLOW}  ⚠ 所选时区偏移(UTC$(printf '%+d' $((chosen_offset/3600)))) 与出口(UTC$(printf '%+d' $((ipOffset/3600)))) 不一致，可能夏令时边界，请人工确认。${C_RESET}"
fi

echo ""
echo "${C_CYAN}将使用  时区: $tz (UTC$(printf '%+d' $((chosen_offset/3600))):00)   语言: $lang   出口国: $cc${C_RESET}"

profile_dir="$BASE_DIR/chrome-$(echo "$cc" | tr '[:upper:]' '[:lower:]')-profile"

if [ "$DRYRUN" -eq 1 ]; then
    echo "${C_MAGENTA}[DryRun] 仅预览，未启动浏览器。${C_RESET}"; exit 0
fi

# ---- 4) 预置独立配置：关闭安全 DNS(DoH) + 默认语言（仅本会话专用配置）----
pref_dir="$profile_dir/Default"
pref_file="$pref_dir/Preferences"
if [ ! -f "$pref_file" ]; then
    mkdir -p "$pref_dir"
    printf '{"dns_over_https":{"mode":"off"},"intl":{"selected_languages":"%s"},"browser":{"check_default_browser":false}}\n' "$lang" > "$pref_file"
    echo "${C_CYAN}已为专用配置关闭浏览器 DoH（DNS 交由 VPN 隧道解析）${C_RESET}"
fi

# ---- 5) 启动（TZ 只作用于这个 Chrome 进程，系统时区不受影响，无需还原）----
echo "${C_CYAN}正在启动一致性 Chrome 会话……（TZ 仅对该进程生效，关闭窗口即结束）${C_RESET}"
TZ=$tz "$CHROME" \
    --user-data-dir="$profile_dir" \
    --lang="${lang%%,*}" \
    --accept-lang="$lang" \
    --no-first-run \
    --no-default-browser-check \
    ${PROXY:+--proxy-server="$PROXY"} >/dev/null 2>&1
echo "${C_GREEN}会话结束。系统时区从未被改动。${C_RESET}"
echo "${C_GRAY}建议关闭前在目标平台点一次登出，避免会话 cookie 跨时区复用。${C_RESET}"
