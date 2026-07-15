#!/usr/bin/env bash
# verify-unix.sh — 在真实 macOS/Linux 上验证 vpn-guard 的平台相关部分
# 用法：把此文件放到 vpn-guard 目录里，bash ./verify-unix.sh
# 只读、不启动浏览器、不改任何设置。

pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
note(){ echo "  [ .. ] $1"; }

echo "==== 平台 ===="; uname -a; echo "bash: $BASH_VERSION"

echo; echo "==== 1) 依赖 ===="
command -v curl >/dev/null && ok "curl 存在" || no "curl 缺失（脚本无法探测出口）"
case "$(uname)" in
  Darwin) command -v scutil >/dev/null && ok "scutil 存在" || no "scutil 缺失"
          command -v route  >/dev/null && ok "route 存在"  || no "route 缺失" ;;
  Linux)  command -v ip >/dev/null && ok "ip 存在" || no "ip 缺失（无法查路由）"
          command -v resolvectl >/dev/null && ok "resolvectl 存在" || note "无 resolvectl，将回退 /etc/resolv.conf" ;;
esac

echo; echo "==== 2) Chrome 定位 ===="
CHROME=""
case "$(uname)" in
  Darwin) for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
            [ -x "$c" ] && { CHROME=$c; break; }; done ;;
  Linux)  for c in google-chrome google-chrome-stable chromium chromium-browser; do
            command -v "$c" >/dev/null 2>&1 && { CHROME=$(command -v "$c"); break; }; done ;;
esac
[ -n "$CHROME" ] && ok "找到浏览器: $CHROME" || no "未找到 Chrome/Chromium（browse-vpn.sh 非 DryRun 会退出）"

echo; echo "==== 3) TZ 是否真的被 Chrome/date 识别（核心卖点）===="
z_sh=$(TZ=Asia/Shanghai date +%z); z_ny=$(TZ=America/New_York date +%z)
echo "  TZ=Asia/Shanghai → $z_sh    TZ=America/New_York → $z_ny"
if [ "$z_sh" != "$z_ny" ] && [ -n "$z_sh" ]; then ok "TZ 环境变量生效（tzdata 可用）"; else no "TZ 未生效——需安装 tzdata，否则 browse-vpn.sh 改不了浏览器时区"; fi
if command -v "$CHROME" >/dev/null 2>&1 || [ -x "$CHROME" ]; then
  note "如需彻底确认，可手动跑： TZ=America/New_York \"$CHROME\" --user-data-dir=/tmp/tztest 然后在 console 输入 Intl.DateTimeFormat().resolvedOptions().timeZone"
fi

echo; echo "==== 4) 路由/接管方式探测（真实命令）===="
case "$(uname)" in
  Darwin) rif=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}') ;;
  Linux)  rif=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | awk '{print $2}') ;;
esac
[ -n "$rif" ] && ok "对外路由网卡: $rif" || no "未解析出对外路由网卡"
case "$rif" in
  utun*|tun*|tap*|wg*|Meta*|meta*|mihomo*|sing*) note "→ 判定为 TUN 接管" ;;
  *) note "→ 非 TUN 网卡（若你正开着 VPN 且用 TUN，请把 '$rif' 反馈给作者补进匹配表）" ;;
esac

echo; echo "==== 5) DNS 解析（真实命令，验证不再有 Link 编号杂质）===="
case "$(uname)" in
  Darwin) dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u) ;;
  Linux)  if command -v resolvectl >/dev/null 2>&1; then
            dns=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
          fi
          [ -z "$dns" ] && [ -r /etc/resolv.conf ] && dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | sort -u) ;;
esac
if [ -n "$dns" ]; then
  echo "$dns" | while read -r d; do echo "    DNS: $d"; done
  if echo "$dns" | grep -qvE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then no "存在非 IP 杂质（解析有问题，请反馈）"; else ok "DNS 列表均为合法 IPv4（无编号杂质）"; fi
else
  note "未读到 DNS（可能纯 IPv6 或权限限制）"
fi

echo; echo "==== 6) 语法检查 ===="
bash -n ./vpn-leak-audit.sh 2>/dev/null && ok "vpn-leak-audit.sh 语法 OK" || no "vpn-leak-audit.sh 语法错误"
bash -n ./browse-vpn.sh 2>/dev/null && ok "browse-vpn.sh 语法 OK" || no "browse-vpn.sh 语法错误"

echo; echo "==== 7) browse-vpn.sh --dry-run（端到端，不开浏览器）===="
bash ./browse-vpn.sh --dry-run >/tmp/bv.log 2>&1
if grep -q '将使用' /tmp/bv.log; then ok "DryRun 走通并输出决策"; sed 's/^/    /' /tmp/bv.log | grep -E '将使用|时区|⚠'; else no "DryRun 未产出决策，见 /tmp/bv.log"; cat /tmp/bv.log; fi

echo; echo "==== 8) WebRTC 检测页冒烟（真 Chrome 跑完检测逻辑）===="
if [ -n "$CHROME" ] && [ -f ./webrtc-leak-test.html ]; then
  # 硬超时兜底：封了 STUN/出网时无头 Chrome 会卡住，20s 强杀，避免脚本挂起
  "$CHROME" --headless=new --disable-gpu --no-sandbox --virtual-time-budget=8000 \
        --user-data-dir=/tmp/rtcsmoke --dump-dom "file://$PWD/webrtc-leak-test.html" \
        >/tmp/rtcsmoke.out 2>/dev/null &
  cpid=$!; ( sleep 20; kill -9 $cpid 2>/dev/null ) & kpid=$!
  wait $cpid 2>/dev/null || true; kill $kpid 2>/dev/null || true
  v=$(grep -oE 'WEBRTC RESULT:[A-Z_]+' /tmp/rtcsmoke.out 2>/dev/null | head -1 | sed 's/.*://')
  case "$v" in
    OK|LEAK|NO_SRFLX|SRFLX_NO_EXITREF) ok "检测页跑到终态（判定=$v），逻辑无报错" ;;
    PENDING|UNSUPPORTED) no "检测页停在 ${v}——可能 JS 报错或 RTCPeerConnection 不可用" ;;
    *) note "无终态输出（本机可能封了 STUN/出网），跳过冒烟" ;;
  esac
  note "无头下拿不到 STUN 反射候选属正常；真实泄露请用 ./browse-vpn.sh --webrtc 在真浏览器里判定"
else
  note "无 Chrome 或缺检测页，跳过 WebRTC 冒烟"
fi

echo; echo "============================================"
echo "  结果：PASS=$pass  FAIL=$fail"
[ "$fail" -eq 0 ] && echo "  ✅ 平台相关部分全部通过" || echo "  ⚠ 有失败项，请把上面 [FAIL] 行反馈给作者"
