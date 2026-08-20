#!/usr/bin/env bash
# field-report.sh — 环境对照报告（给非技术协作者用的一键流程 · macOS / Linux）
#
# 与 field-report.ps1 功能对等：跑一次自查、问 9 个账号相关的问题、
# 在桌面产出一份**已脱敏**的报告，由使用者自己决定发不发。
#
# 设计取舍（与 Windows 版一致）：
#   1. 只读。不改任何系统设置，不装任何东西，不需要 sudo。
#   2. 默认脱敏。完整出口 IP / IPv6 / DNS 地址 / 代理凭据 / 机器名 / 路径一律不进报告。
#   3. 绝不自动发送。脚本把报告全文打在屏幕上让他先看，发不发是他的决定。
#   4. 详细自查输出另存本地，明确告诉他「这份不用发」—— 那份里有完整 IP。
#
# bash 3.2 兼容（macOS 自带的就是 3.2）：无关联数组、无 mapfile、无 ${var,,}。

cd "$(dirname "$0")" || exit 1

if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_CYAN=''; C_GRAY=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi
say()  { printf '%s%s%s\n' "$2" "$1" "$C_RESET"; }
rule() { printf '%s%s%s\n' "$C_GRAY" '--------------------------------------------------------------' "$C_RESET"; }

echo ""
say "  vpn-guard · 环境对照体检" "$C_CYAN"
rule
say "  这个脚本会做两件事：" ""
say "    1) 检查你当前的网络环境（只读，不改任何设置、不装任何东西）" ""
say "    2) 问你几个关于账号的问题" ""
echo ""
say "  然后生成一份**已经脱敏**的报告放到桌面。" ""
say "  报告里不会有你的完整 IP、DNS、密码或任何路径 —— 生成后会全文打给你看，" "$C_YELLOW"
say "  发不发给对方，由你自己决定。脚本不会自动发送任何东西。" "$C_YELLOW"
rule
echo ""

printf '  先起个代号，用来区分不同人的报告（比如 小王，直接回车用 A）: '
read -r who
[ -z "$who" ] && who="A"
who=$(printf '%s' "$who" | tr -d '/\\:*?"<>|' | tr -d '[:cntrl:]')
[ -z "$who" ] && who="A"

desktop="$HOME/Desktop"
[ -d "$desktop" ] || desktop="$HOME"
report="${desktop}/vpn-guard对照报告_${who}.txt"
detail="${desktop}/vpn-guard详细结果_${who}_本地留存.txt"

echo ""
say "  [1/3] 正在检查网络环境，大约 20 秒，请稍等……" "$C_CYAN"

if [ ! -f ./vpn-leak-audit.sh ]; then
    echo ""
    say "  x 找不到 vpn-leak-audit.sh。" "$C_RED"
    say "    请确认你把整个文件夹解压出来了，而不是只拷了一个文件。" "$C_RED"
    exit 1
fi

# 跳过链路测速：要下载约 20MB，而且跟本次要对照的东西无关。
# DNS 主动实测保留 —— 它是真实信号。
bash ./vpn-leak-audit.sh --no-speed-test --export "$report" > "$detail" 2>&1

if [ ! -f "$report" ]; then
    echo ""
    say "  x 没能生成报告。可能是当前完全没联网。" "$C_RED"
    say "    详细信息已存到：${detail}" "$C_GRAY"
    exit 1
fi
say "  √ 网络环境检查完成" "$C_GREEN"

echo ""
say "  [2/3] 下面 9 个问题，跟账号有关。" "$C_CYAN"
say "        这部分脚本测不出来，但它比网络环境更能说明问题，所以别跳过。" ""
say "        不确定的直接回车，会记成「不清楚」。" ""
echo ""

# bash 3.2 没有关联数组：键与问题各用一个「行分隔」的字符串，按序号对齐。
QKEYS="被封过吗(次数)
最近一次被封时间
账号来源
账号大概注册年份
注册用邮箱
是否与他人共用
是否绑过支付方式
客户端节点策略
多久换一次节点"
QTEXT="你的账号被封过吗？封过几次？
最近一次是什么时候？（大概月份就行）
账号是怎么来的？自己注册 / 别人给的 / 买的 / 多人合租
大概哪一年注册的？
注册用的邮箱，是你长期在用的那个，还是为了注册临时建的？
这个账号有没有和别人一起用？
绑过银行卡/支付方式吗？哪个国家的？
你的代理客户端里，是固定选一个节点，还是用「自动选择 / 负载均衡」？
大概多久换一次节点？"

tmp_ans=$(mktemp) || exit 1
trap 'rm -f "$tmp_ans"' EXIT INT TERM

i=1
n=$(printf '%s\n' "$QKEYS" | grep -c .)
while [ "$i" -le "$n" ]; do
    k=$(printf '%s\n' "$QKEYS" | sed -n "${i}p")
    q=$(printf '%s\n' "$QTEXT" | sed -n "${i}p")
    printf '  %s. %s: ' "$i" "$q"
    read -r a
    [ -z "$a" ] && a="不清楚"
    a=$(printf '%s' "$a" | tr -d '[:cntrl:]')
    printf '%s\t%s\n' "$k" "$a" >> "$tmp_ans"
    i=$((i + 1))
done

# 把答案写回报告里的占位符。逐行读报告，命中「键 ... : __待填__」就替换整行。
merged=$(mktemp) || exit 1
while IFS= read -r line; do
    out="$line"
    case "$line" in
        *"__待填__"*)
            lk=${line%%:*}                      # 键名（含右侧空格）
            lkey=$(printf '%s' "$lk" | sed 's/[[:space:]]*$//')
            av=$(grep -F "$(printf '%s\t' "$lkey")" "$tmp_ans" | head -1 | cut -f2-)
            [ -n "$av" ] && out="${lk}: ${av}"
            ;;
    esac
    printf '%s\n' "$out"
done < "$report" > "$merged"
cat "$merged" > "$report"
rm -f "$merged"

echo ""
say "  [3/3] 报告已生成。下面是它的**全部内容** —— 请先看一遍：" "$C_CYAN"
rule
while IFS= read -r l; do printf '  %s\n' "$l"; done < "$report"
rule
echo ""
say "  以上就是全部内容，没有别的东西。" "$C_GREEN"
say "  文件位置：${report}" "$C_CYAN"
echo ""
say "  确认没问题的话，把这个文件发给请你帮忙的人就可以了。" "$C_YELLOW"
say "  如果你觉得其中某一行不方便透露，用文本编辑器打开删掉那一行再发 —— 不影响对照。" "$C_YELLOW"
echo ""
say "  另外还有一份详细结果存在：${detail}" "$C_GRAY"
say "  那份里有完整 IP 等信息，**是给你自己看的，不用发**。" "$C_GRAY"
echo ""

printf '  现在打开文件所在的文件夹吗？(直接回车=打开, n=不用): '
read -r op
if [ "$op" != "n" ] && [ "$op" != "N" ]; then
    if [ "$(uname)" = "Darwin" ]; then
        open -R "$report" 2>/dev/null
    else
        command -v xdg-open >/dev/null 2>&1 && xdg-open "$desktop" >/dev/null 2>&1
    fi
fi
echo ""
say "  完成，感谢帮忙。" "$C_CYAN"
