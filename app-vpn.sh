#!/usr/bin/env bash
#
#   app-vpn.sh  —  一致性桌面应用 / CLI 会话（macOS / Linux 版）   vpn-guard v1.0.1
#
#   它是 browse-vpn.sh 的「非浏览器」对应物。browse-vpn 只作用于它启动的那个 Chrome；
#   Claude Desktop / Codex / Claude Code / Cursor 这类桌面应用与 CLI 完全不在它的射程内。
#
#   为什么需要它：
#     Chrome 会读 macOS 的系统代理设置；但 Node / Rust / Go 写的 CLI（Codex CLI、
#     Claude Code CLI）与 Electron 的 Node 主进程**不读系统代理**，只认
#     HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 环境变量。
#     结果：只开「系统代理」而没开 TUN 时，浏览器安全，这些程序却在直连暴露真实 IP。
#
#   它做什么（全部只作用于被启动的那一个进程，不改任何系统设置）：
#     探测当前出口国 → 注入 HTTPS_PROXY/HTTP_PROXY/ALL_PROXY/NO_PROXY + TZ + LANG → 启动它。
#
#   与 Windows 版的差别：macOS/Linux 上 Chromium 也认 TZ，所以 GUI 应用同样能进程级对齐时区，
#   不存在 Windows 那种「必须临时切系统时区」的情况（故本脚本没有 -SystemTz）。
#
#   用法：
#     ./app-vpn.sh --list                  # 列出可识别的应用别名
#     ./app-vpn.sh codex                   # 在一致性环境里跑 Codex CLI
#     ./app-vpn.sh claude                  # Claude Code CLI
#     ./app-vpn.sh claude-desktop          # Claude 桌面版（Electron，TZ 一样生效）
#     ./app-vpn.sh /path/to/app            # 任意可执行文件
#     ./app-vpn.sh --print                 # 只打印要注入的环境变量，自己 copy 到别的终端
#     ./app-vpn.sh codex --dry-run
#     ./app-vpn.sh codex --proxy=socks5://127.0.0.1:1080
#     ./app-vpn.sh codex -- --model o3     # -- 之后的参数原样传给目标程序
#
#   依赖：bash 3.2+、curl。Windows 用户请使用同目录下的 app-vpn.ps1。

set -u

# 注意：本文件带中文输出，凡是变量后面紧跟全角字符的地方一律写成 ${变量} 花括号形式。
# macOS 自带的 bash 3.2 会把多字节字符的首字节当成变量名的一部分（例如「退出码 」加变量 rc
# 再加全角右括号，会被解析成变量 rc\xef），在 set -u 下直接报 unbound variable 退出。
# CI 里有一条 perl 扫描守着这条规则，注释里也不要出现反例，否则会被一并判违规。

C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_MAGENTA=$'\033[35m'; C_RESET=$'\033[0m'
ok()   { echo "${C_GREEN}  [ OK ] $1${C_RESET}"; }
warn() { echo "${C_YELLOW}  [WARN] $1${C_RESET}"; }
bad()  { echo "${C_RED}  [FAIL] $1${C_RESET}"; }
info() { echo "${C_GRAY}  $1${C_RESET}"; }

# ---- 参数 ----
APP=""; COUNTRY=""; PROXY=""; DRYRUN=0; PRINT=0; LIST=0
# APP_ARGC 单独计数：bash 3.2（macOS 自带）在 set -u 下对空数组求 ${#arr[@]} 会直接报
# "unbound variable"，所以不能靠数组长度判空。展开时统一用 ${arr[@]+"${arr[@]}"} 惯用法。
APP_ARGS=(); APP_ARGC=0; rest=0
for a in "$@"; do
    if [ "$rest" -eq 1 ]; then APP_ARGS+=("$a"); APP_ARGC=$((APP_ARGC+1)); continue; fi
    case "$a" in
        --)            rest=1 ;;
        --dry-run)     DRYRUN=1 ;;
        --print)       PRINT=1 ;;
        --list)        LIST=1 ;;
        --country=*)   COUNTRY=${a#*=} ;;
        --proxy=*)     PROXY=${a#*=} ;;
        -h|--help)     sed -n '3,30p' "$0"; exit 0 ;;
        -*)            echo "未知参数: ${a}（目标程序自己的参数请放在 -- 之后）" >&2; exit 1 ;;
        *)             if [ -z "$APP" ]; then APP=$a; else APP_ARGS+=("$a"); APP_ARGC=$((APP_ARGC+1)); fi ;;
    esac
done
COUNTRY=$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')
OS=$(uname)

# ==== 出口国 → 语言 预设表（与 browse-vpn.sh 保持一致）====
# 时区不在这里定：始终以探测到的真实出口 IANA 时区为准。
lang_preset() {
    case "$1" in
        JP) echo "ja-JP,ja" ;;   KR) echo "ko-KR,ko" ;;      SG) echo "en-SG,en" ;;
        HK) echo "zh-HK,zh,en";; TW) echo "zh-TW,zh" ;;      GB) echo "en-GB,en" ;;
        DE) echo "de-DE,de" ;;   FR) echo "fr-FR,fr" ;;      NL) echo "nl-NL,nl,en" ;;
        US) echo "en-US,en" ;;   CA) echo "en-CA,en,fr" ;;   AU) echo "en-AU,en" ;;
        *)  echo "" ;;
    esac
}
# 探测失败且手动指定国家时的兜底时区
fallback_tz() {
    case "$1" in
        JP) echo "Asia/Tokyo" ;;      KR) echo "Asia/Seoul" ;;     SG) echo "Asia/Singapore" ;;
        HK) echo "Asia/Hong_Kong" ;;  TW) echo "Asia/Taipei" ;;    GB) echo "Europe/London" ;;
        DE) echo "Europe/Berlin" ;;   FR) echo "Europe/Paris" ;;   NL) echo "Europe/Amsterdam" ;;
        US) echo "America/New_York";; CA) echo "America/Toronto";; AU) echo "Australia/Sydney" ;;
        *)  echo "" ;;
    esac
}

if [ "$LIST" -eq 1 ]; then
    echo ""
    echo "${C_CYAN} 内置应用别名（也可直接传任意可执行文件路径或 PATH 里的命令名）${C_RESET}"
    echo "${C_GRAY}  codex                          Codex CLI${C_RESET}"
    echo "${C_GRAY}  claude / claude-code / cc      Claude Code CLI${C_RESET}"
    echo "${C_GRAY}  claude-desktop / claudeapp     Claude 桌面版（Electron）${C_RESET}"
    echo "${C_GRAY}  cursor                         Cursor${C_RESET}"
    echo "${C_GRAY}  code / vscode                  VS Code${C_RESET}"
    echo "${C_GRAY}  chatgpt                        ChatGPT 桌面版${C_RESET}"
    echo ""
    echo "${C_GRAY}  macOS/Linux 上 Chromium 也认 TZ，GUI 与 CLI 一样是进程级生效，不改系统时区。${C_RESET}"
    echo ""
    exit 0
fi

# macOS 的 .app 必须直接跑 Contents/MacOS 里的二进制，`open -a` 不会传递环境变量
mac_app_bin() {
    for base in "/Applications/$1.app" "$HOME/Applications/$1.app"; do
        [ -d "$base" ] || continue
        b="$base/Contents/MacOS/$2"
        [ -x "$b" ] && { echo "$b"; return; }
        # 回退：主二进制名不一定等于 .app 名（如 VS Code 是 Electron），取目录里第一个可执行文件。
        # 不用 find -perm：符号模式在 BSD find 与 GNU find 上写法不通用，直接用 [ -x ] 最稳。
        for f in "$base/Contents/MacOS/"*; do
            [ -f "$f" ] && [ -x "$f" ] && { echo "$f"; return; }
        done
    done
    echo ""
}

resolve_app() {
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        codex)                  TARGET=$(command -v codex 2>/dev/null); LABEL="Codex CLI" ;;
        claude|claude-code|cc)  TARGET=$(command -v claude 2>/dev/null); LABEL="Claude Code CLI" ;;
        claude-desktop|claudeapp)
            LABEL="Claude 桌面版"
            if [ "$OS" = "Darwin" ]; then TARGET=$(mac_app_bin "Claude" "Claude")
            else for c in claude-desktop /opt/Claude/claude /usr/bin/claude-desktop; do
                     command -v "$c" >/dev/null 2>&1 && { TARGET=$(command -v "$c"); break; }
                     [ -x "$c" ] && { TARGET=$c; break; }
                 done; fi ;;
        cursor)
            LABEL="Cursor"
            if [ "$OS" = "Darwin" ]; then TARGET=$(mac_app_bin "Cursor" "Cursor")
            else TARGET=$(command -v cursor 2>/dev/null); fi ;;
        code|vscode)
            LABEL="VS Code"
            if [ "$OS" = "Darwin" ]; then TARGET=$(mac_app_bin "Visual Studio Code" "Electron")
            else TARGET=$(command -v code 2>/dev/null); fi ;;
        chatgpt)
            LABEL="ChatGPT 桌面版"
            if [ "$OS" = "Darwin" ]; then TARGET=$(mac_app_bin "ChatGPT" "ChatGPT")
            else TARGET=$(command -v chatgpt 2>/dev/null); fi ;;
        *)
            LABEL="$1"
            TARGET=$(command -v "$1" 2>/dev/null)
            [ -z "$TARGET" ] && [ -x "$1" ] && TARGET="$1" ;;
    esac
    if [ -z "${TARGET:-}" ]; then
        bad "找不到应用：$1（既不是能定位的内置别名、也不在 PATH、也不是可执行文件路径）"
        info "用 --list 查看内置别名，或直接传完整路径。"
        exit 1
    fi
}

echo ""
echo "${C_CYAN} 一致性桌面应用 / CLI 会话 ${C_RESET}"

# ---- 0) 接管方式：决定要不要注入代理环境变量 ----
echo "${C_CYAN}0) 流量接管方式${C_RESET}"
route_if=""; sys_proxy=""
case "$OS" in
    Darwin)
        route_if=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
        # 从 scutil 里取系统代理地址（Chrome 认它，Node/Electron 主进程不认）
        sp=$(scutil --proxy 2>/dev/null)
        if echo "$sp" | grep -qE 'HTTPSEnable : 1'; then
            h=$(echo "$sp" | awk '/HTTPSProxy/{print $3}'); p=$(echo "$sp" | awk '/HTTPSPort/{print $3}')
            [ -n "$h" ] && sys_proxy="http://$h:$p"
        elif echo "$sp" | grep -qE 'HTTPEnable : 1'; then
            h=$(echo "$sp" | awk '/HTTPProxy/{print $3}'); p=$(echo "$sp" | awk '/HTTPPort/{print $3}')
            [ -n "$h" ] && sys_proxy="http://$h:$p"
        elif echo "$sp" | grep -qE 'SOCKSEnable : 1'; then
            h=$(echo "$sp" | awk '/SOCKSProxy/{print $3}'); p=$(echo "$sp" | awk '/SOCKSPort/{print $3}')
            [ -n "$h" ] && sys_proxy="socks5://$h:$p"
        fi ;;
    Linux)
        route_if=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | awk '{print $2}')
        # Linux 没有全局「系统代理」，环境变量就是事实标准
        sys_proxy="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}" ;;
esac

tun_active=0
case "$route_if" in
    utun*|tun*|tap*|wg*|Meta*|meta*|mihomo*|sing*) tun_active=1 ;;
esac
if [ "$tun_active" -eq 1 ]; then
    ok "TUN 模式（${route_if}）—— 全局流量已被接管，桌面应用/CLI 本来就走隧道"
fi
[ -n "$sys_proxy" ] && info "系统代理     : ${sys_proxy}（Chrome 认它，Node/Rust CLI 与 Electron 主进程不认）"

proxy_url=""; proxy_source=""
if [ -n "$PROXY" ]; then      proxy_url=$PROXY;    proxy_source="你用 --proxy 指定的"
elif [ -n "$sys_proxy" ]; then proxy_url=$sys_proxy; proxy_source="从系统代理设置推断的"
fi

if [ -z "$proxy_url" ] && [ "$tun_active" -eq 0 ]; then
    bad "既没有 TUN 接管、也没有可用的代理地址 —— 目标程序会直连，暴露真实 IP！"
    info "请开客户端的 TUN 模式，或加 --proxy=socks5://127.0.0.1:<端口>（Clash 默认 7897，v2rayN/Xray 常用 10808）。"
elif [ -z "$proxy_url" ]; then
    info "无代理地址可注入，但 TUN 已全局接管 —— 目标程序仍走隧道。"
fi

# ---- 1) 探测出口 ----
echo "${C_CYAN}1) 探测当前出口${C_RESET}"
resp=$(curl -fsS --max-time 15 ${proxy_url:+-x "$proxy_url"} \
  "http://ip-api.com/line/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting" 2>/dev/null)
ip_status=""; ip_country=""; ip_cc=""; ip_city=""; ip_tz=""; ip_offset=""; ip_isp=""; ip_query=""; ip_proxy=""; ip_hosting=""
if [ -n "$resp" ]; then
    # ip-api 的 line 格式按其固定字段顺序返回（query 在最后），与请求参数顺序无关
    # shellcheck disable=SC2034
    { read -r ip_status; read -r ip_country; read -r ip_cc; read -r ip_city; read -r ip_tz
      read -r ip_offset; read -r ip_isp; read -r ip_proxy; read -r ip_hosting; read -r ip_query; } <<EOF
$resp
EOF
fi

cc=""; tz=""
if [ "$ip_status" = "success" ]; then
    info "出口 IP : $ip_query"
    info "位置    : $ip_city / $ip_country ($ip_cc), $ip_tz (UTC$(printf '%+d' $((ip_offset/3600))):00)"
    [ "$ip_proxy" = "true" ] || [ "$ip_hosting" = "true" ] && warn "该 IP 被标记为 proxy/hosting，高风控平台可能拦截。"
    cc=$ip_cc; tz=$ip_tz
    if [ -n "$COUNTRY" ] && [ "$COUNTRY" != "$cc" ]; then
        warn "你指定了国家 ${COUNTRY}，但出口在 ${cc}；语言按你指定的走，时区仍跟随真实出口。"
        cc=$COUNTRY
    fi
else
    if [ -z "$COUNTRY" ]; then
        bad "无法探测出口（ip-api 不可达），且未指定 --country=XX。请检查 VPN 是否在线。"; exit 1
    fi
    warn "探测失败，改用手动指定的国家 $COUNTRY"
    cc=$COUNTRY; tz=$(fallback_tz "$cc")
    [ -z "$tz" ] && { bad "未预置国家 ${cc}，探测又失败，无法决定时区。"; exit 1; }
fi

# ---- 2) 决定语言 ----
lang=$(lang_preset "$cc")
if [ -z "$lang" ]; then warn "未预置国家 ${cc}，语言退回通用 en-US。"; lang="en-US,en"; fi
primary=${lang%%,*}
posix_locale="$(echo "$primary" | tr '-' '_').UTF-8"

if [ ! -f "/usr/share/zoneinfo/$tz" ] && [ ! -f "/etc/zoneinfo/$tz" ] && [ ! -f "/usr/share/lib/zoneinfo/$tz" ]; then
    warn "本机时区数据库中找不到 $tz —— TZ 可能不生效（程序会回退到系统时区），请确认已安装 tzdata。"
fi

echo ""
echo "${C_CYAN}将注入  时区: $tz   语言: $lang   出口国: $cc${C_RESET}"

# ---- 3) 组装环境变量 ----
no_proxy_val='localhost,127.0.0.1,::1,*.local'   # 本地 MCP server / 开发服务不该被代理
ENV_KEYS=(TZ LANG LC_ALL); ENV_VALS=("$tz" "$posix_locale" "$posix_locale")
if [ -n "$proxy_url" ]; then
    for k in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy; do
        ENV_KEYS+=("$k"); ENV_VALS+=("$proxy_url")
    done
    ENV_KEYS+=(NO_PROXY no_proxy); ENV_VALS+=("$no_proxy_val" "$no_proxy_val")
    info "代理环境变量取自：$proxy_source"
fi

if [ "$PRINT" -eq 1 ]; then
    echo ""
    echo "${C_CYAN}# 复制到你自己的 shell 里，之后在该窗口启动的程序都会走一致性环境：${C_RESET}"
    i=0; while [ $i -lt ${#ENV_KEYS[@]} ]; do echo "export ${ENV_KEYS[$i]}='${ENV_VALS[$i]}'"; i=$((i+1)); done
    echo ""
    exit 0
fi

if [ -z "$APP" ]; then
    bad "未指定要启动的应用。"
    info "示例：./app-vpn.sh codex   /   ./app-vpn.sh claude-desktop   /   ./app-vpn.sh --list   /   ./app-vpn.sh --print"
    exit 1
fi

# ---- 4) 解析目标应用 ----
resolve_app "$APP"
echo ""
echo "${C_CYAN}目标应用: $LABEL${C_RESET}"
info "路径     : $TARGET"
[ "$APP_ARGC" -gt 0 ] && info "透传参数 : ${APP_ARGS[*]}"

if [ "$DRYRUN" -eq 1 ]; then
    echo ""
    echo "${C_MAGENTA}[DryRun] 将注入以下环境变量，但不启动程序：${C_RESET}"
    i=0; while [ $i -lt ${#ENV_KEYS[@]} ]; do info "${ENV_KEYS[$i]}=${ENV_VALS[$i]}"; i=$((i+1)); done
    exit 0
fi

# ---- 5) 注入并启动（env 只作用于这一个子进程，当前 shell 与系统均不受影响）----
echo ""
echo "${C_CYAN}正在启动……（环境变量仅对该进程生效，退出即结束）${C_RESET}"
printf '%s\n' "${C_GRAY}------------------------------------------------------------${C_RESET}"

ENV_PAIRS=(); i=0
while [ $i -lt ${#ENV_KEYS[@]} ]; do ENV_PAIRS+=("${ENV_KEYS[$i]}=${ENV_VALS[$i]}"); i=$((i+1)); done

env "${ENV_PAIRS[@]}" "$TARGET" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
rc=$?

printf '%s\n' "${C_GRAY}------------------------------------------------------------${C_RESET}"
echo "${C_GREEN}会话结束（退出码 ${rc}）。当前 shell 与系统设置从未被改动。${C_RESET}"
exit $rc
