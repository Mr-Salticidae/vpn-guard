#!/usr/bin/env bash
# verify-classifier.sh — 出口归属分类器的回归测试
#
# 用法：bash tests/verify-classifier.sh   （任意目录下运行均可，脚本会先切到仓库根目录）
# 只读：不联网、不改任何设置、不启动浏览器。全部判定都是纯函数比对。
#
# 为什么单独一个文件而不是塞进 verify-unix.sh：
#   verify-unix.sh 里绝大多数检查依赖环境（Chrome 在不在、能不能出网、DNS 上游是谁），
#   在 CI 里失败不代表代码有问题，所以它整体是「信息性」的。
#   本文件相反 —— 全部是纯文本 / 纯函数比对，与平台、网络、时间都无关，
#   失败就一定是代码问题，因此它是硬闸门（非零退出）。
#
# 覆盖三件事：
#   A. bash 侧判定正确性          —— 永远运行
#   B. .ps1 与 .sh 输出逐字节一致  —— 有 PowerShell 时运行（CI 的 ubuntu/macos 都预装 pwsh）
#   C. auto-select-node 分类器的真实样本 + 阈值哨兵 + 词表陷阱 —— 有 PowerShell 时运行
#
# ASN 名单的三方一致性不在这里，在 verify-unix.sh 第 11 项 —— 那是数据比对，这里是行为比对。
#
# 自检过：三种投毒都能抓到 —— 改判定阈值、往机房词表加裸词 data、只改一版的措辞。

# 被测脚本都在仓库根目录，本文件在 tests/ 下，所以切到上一级。
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0; skip=0
ok(){    echo "  [PASS] $1"; pass=$((pass+1)); }
no(){    echo "  [FAIL] $1"; fail=$((fail+1)); }
skipm(){ echo "  [SKIP] $1"; skip=$((skip+1)); }

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/vgcls$$")
mkdir -p "$TMP" 2>/dev/null
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- 定位 PowerShell（CI 的 ubuntu-latest / macos-latest 都预装 pwsh）----
PS=""
for c in pwsh powershell powershell.exe; do
    command -v "$c" >/dev/null 2>&1 && { PS=$c; break; }
done

echo "==== 出口归属分类器回归测试 ===="
echo "  bash: $BASH_VERSION"
if [ -n "$PS" ]; then
    echo "  PowerShell: $PS"
else
    echo "  PowerShell: 未找到（跨语言比对与选点器分类器测试将跳过）"
fi

# =============================================================================
# 样本集。字段：as 字段 | hosting | 期望判定 | 说明
# 期望判定取值：residential / hosting-flag / datacenter / unknown
# 前七条是 2026-08-19 从真实机场实测采集的，as / asname 都向 live ip-api 核对过。
# =============================================================================
cat > "$TMP/fixtures" <<'FIXEOF'
AS3462 Data Communication Business Group|false|residential|中华电信（唯一真住宅；AS 机构名含 Data，是词表陷阱）
AS131939 IPS INC|false|datacenter|IPS INC（32 位；ip-api 漏报为 hosting=false）
AS131642 Pittqiao Network Information Co.,Ltd.|false|datacenter|Pittqiao（32 位；恰好卡在阈值）
AS209642 Mejiro Network Limited|false|datacenter|Mejiro（32 位 + 号段极新 + RIPE 段落地亚太）
AS14061 DigitalOcean, LLC|true|hosting-flag|DigitalOcean（16 位；靠 ip-api 的 hosting 标记拦下）
AS16509 Amazon.com, Inc.|true|hosting-flag|AWS（16 位，同上）
AS31898 Oracle Corporation|true|hosting-flag|Oracle Cloud（16 位，同上）
AS24940 Hetzner Online GmbH|false|unknown|老牌机房持 16 位号段 —— ASN 规则看不见它，必须诚实说未识别
|false|unknown|ip-api 没返回 AS 号，无判据
AS65535 Boundary Low|false|unknown|边界：16 位空间最后一个号
AS65536 Boundary High|false|datacenter|边界：32 位空间第一个号
AS4134 CHINANET|true|hosting-flag|中国电信：hosting=true 且在住宅名单里 —— 仍按机房看待
AS138384 Rakuten Mobile|false|residential|32 位 ASN 但在名单里 —— 名单必须能救回正规新运营商
AS206067 Three UK|false|residential|同上，英国
AS4294967295 Overflow Test|false|datacenter|ASN 空间上限：[int] 会溢出，必须用 [long]
FIXEOF
FIXN=$(grep -c '|' "$TMP/fixtures")

# 注意：以下所有循环都用 `done < 文件` 而不是 `cmd | while`。
# 管道会让 while 跑在子 shell 里、循环变量的改动出不来，是 bash 里最常见的坑之一。

# =============================================================================
# A. bash 侧判定正确性
# =============================================================================
echo; echo "==== A) bash 侧判定正确性 ===="

if ! grep -q 'EXIT-CLASS-BEGIN' vpn-leak-audit.sh 2>/dev/null; then
    no "vpn-leak-audit.sh 里找不到 EXIT-CLASS-BEGIN 标记 —— 无法抽取判定块"
else
    awk '/ASN-TABLE-BEGIN/,/ASN-TABLE-END/'   vpn-leak-audit.sh > "$TMP/tbl.sh"
    awk '/EXIT-CLASS-BEGIN/,/EXIT-CLASS-END/' vpn-leak-audit.sh > "$TMP/blk.sh"

    {
        echo 'ok(){ printf "OK|%s\n" "$1"; }'
        echo 'warn(){ printf "WARN|%s\n" "$1"; }'
        echo 'info(){ printf "INFO|%s\n" "$1"; }'
        cat "$TMP/tbl.sh"
        echo 'RESI_ASN=" $(printf "%s" "$RESI_ASN" | tr "\n" " ") "'
    } > "$TMP/harness.sh"

    while IFS='|' read -r f_as f_host f_exp f_name; do
        [ -z "$f_exp" ] && continue
        echo "printf '== %s ==\\n' \"$f_name\""
        echo "ip_as='$f_as'"
        echo "ip_hosting='$f_host'"
        cat "$TMP/blk.sh"
    done < "$TMP/fixtures" >> "$TMP/harness.sh"

    bash "$TMP/harness.sh" > "$TMP/out.sh" 2>"$TMP/err.sh"
    if [ -s "$TMP/err.sh" ]; then
        no "bash 判定块执行报错"
        sed 's/^/      /' "$TMP/err.sh" | head -5
    fi

    # 逐样本核对判定类别
    idx=0
    while IFS='|' read -r f_as f_host f_exp f_name; do
        [ -z "$f_exp" ] && continue
        idx=$((idx+1))
        line=$(awk -v n="$idx" '/^== /{c++} c==n && /^(OK|WARN|INFO)\|出口归属/{print; exit}' "$TMP/out.sh")
        got="?"
        case "$line" in
            *"住宅/消费级"*)              got="residential" ;;
            *"ip-api 直接标记为 hosting"*) got="hosting-flag" ;;
            *"推断为机房"*)                got="datacenter" ;;
            *"未识别"*)                    got="unknown" ;;
        esac
        if [ "$got" = "$f_exp" ]; then
            echo "PASS|$f_name"
        else
            echo "FAIL|$f_name —— 期望 ${f_exp}，实得 ${got}"
        fi
    done < "$TMP/fixtures" > "$TMP/verdicts"

    while IFS='|' read -r st msg; do
        if [ "$st" = "PASS" ]; then ok "$msg"; else no "$msg"; fi
    done < "$TMP/verdicts"

    # 反退化：被判住宅的条数必须与样本集里标注 residential 的条数完全相等 ——
    # 防止「全判机房」这种既通过大部分断言、又毫无区分力的退化解。
    rc=$(grep -c '住宅/消费级' "$TMP/out.sh")
    exp_rc=$(grep -c '|residential|' "$TMP/fixtures")
    if [ "$rc" = "$exp_rc" ]; then
        ok "反退化：恰好 $rc 条被判住宅（不能靠全判机房蒙混过关）"
    else
        no "反退化：$rc 条被判住宅，期望 $exp_rc 条"
    fi
fi

# =============================================================================
# B. .ps1 与 .sh 输出逐字节一致（README 承诺两版功能对等）
# =============================================================================
echo; echo "==== B) .ps1 与 .sh 输出一致性 ===="
if [ -z "$PS" ]; then
    skipm "未找到 PowerShell —— 跳过跨语言比对"
elif ! grep -q 'EXIT-CLASS-BEGIN' vpn-leak-audit.ps1 2>/dev/null; then
    no "vpn-leak-audit.ps1 里找不到 EXIT-CLASS-BEGIN 标记"
else
    awk '/ASN-TABLE-BEGIN/,/ASN-TABLE-END/'   vpn-leak-audit.ps1 | tr -d '\r' > "$TMP/tbl.ps1"
    awk '/EXIT-CLASS-BEGIN/,/EXIT-CLASS-END/' vpn-leak-audit.ps1 | tr -d '\r' > "$TMP/blk.ps1"

    # UTF-8 BOM 是必需的：Windows PowerShell 5.1 读无 BOM 的 .ps1 时按系统 ANSI 代码页解码，
    # 中文会碎成乱码并直接报语法错。pwsh 在 Linux/macOS 上默认 UTF-8，多一个 BOM 无副作用。
    printf '\357\273\277' > "$TMP/harness.ps1"
    {
        echo '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
        echo '$OutputEncoding = [System.Text.Encoding]::UTF8'
        echo 'function Ok($m){Write-Host "OK|$m"}'
        echo 'function Warn($m){Write-Host "WARN|$m"}'
        echo 'function Info($m){Write-Host "INFO|$m"}'
        cat "$TMP/tbl.ps1"
        echo '$ResiAsn = @{}'
        echo 'foreach ($a in ($ResiAsnRaw -split "[^0-9]+")) { if ($a) { $ResiAsn[$a] = $true } }'
    } >> "$TMP/harness.ps1"

    while IFS='|' read -r f_as f_host f_exp f_name; do
        [ -z "$f_exp" ] && continue
        echo "Write-Host \"== $f_name ==\""
        echo "\$ipapi = [pscustomobject]@{ as = '$f_as'; hosting = \$$f_host }"
        cat "$TMP/blk.ps1"
    done < "$TMP/fixtures" >> "$TMP/harness.ps1"

    "$PS" -NoProfile -ExecutionPolicy Bypass -File "$TMP/harness.ps1" > "$TMP/out.ps1" 2>"$TMP/err.ps1"
    tr -d '\r' < "$TMP/out.ps1" > "$TMP/a"
    tr -d '\r' < "$TMP/out.sh"  > "$TMP/b"
    if [ -s "$TMP/err.ps1" ]; then
        no "PowerShell 判定块执行报错"
        sed 's/^/      /' "$TMP/err.ps1" | head -5
    elif [ ! -s "$TMP/a" ]; then
        no "PowerShell 判定块没有输出"
    elif diff -q "$TMP/a" "$TMP/b" >/dev/null 2>&1; then
        ok "两版输出逐字节一致（$(grep -c . "$TMP/a") 行 / $FIXN 个样本）"
    else
        no "两版输出不一致 —— README 承诺的「功能对等」已被打破"
        diff "$TMP/a" "$TMP/b" | head -20 | sed 's/^/      /'
    fi
fi

# =============================================================================
# C. auto-select-node 分类器：真实样本 + 阈值哨兵 + 词表陷阱
# =============================================================================
echo; echo "==== C) auto-select-node 分类器 ===="
if [ -z "$PS" ]; then
    skipm "未找到 PowerShell —— 跳过选点器分类器测试"
elif [ ! -f auto-select-node.ps1 ]; then
    skipm "auto-select-node.ps1 不存在"
else
    printf '\357\273\277' > "$TMP/cls.ps1"   # 同 B 段：无 BOM 会被 PS 5.1 按 ANSI 读
    {
        echo '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
        echo '$ErrorActionPreference = "SilentlyContinue"'
        echo '$src = [System.IO.File]::ReadAllText((Resolve-Path "./auto-select-node.ps1"))'
        echo '$a = $src.IndexOf("# ==== 出口归属分类")'
        echo '$b = $src.IndexOf("# 安全性测试：切换到指定节点")'
        echo 'if ($a -lt 0 -or $b -le $a) { Write-Host "FAIL|抽取不到分类器块"; exit 1 }'
        echo '$code = $src.Substring($a, $b - $a)'
        echo 'Invoke-Expression $code'
        echo 'function T($name,$cond,$got){ if($cond){Write-Host "PASS|$name"}else{Write-Host "FAIL|$name —— $got"} }'

        # 四个真实样本
        echo '$c1 = Get-ExitClass -AsField "AS3462 Data Communication Business Group" -AsName "HINET" -Isp "Chunghwa Telecom Co., Ltd." -Ip "203.0.113.1" -Cc "TW"'
        echo 'T "中华电信判为住宅" ($c1.class -eq "residential") $c1.class'
        echo '$c2 = Get-ExitClass -AsField "AS131939 IPS INC" -AsName "APNIC-ASBLOCK-131478" -Isp "IPS INC" -Ip "203.0.113.2" -Cc "JP"'
        echo 'T "IPS INC 判为机房" ($c2.class -eq "datacenter") $c2.class'
        echo '$c3 = Get-ExitClass -AsField "AS131642 Pittqiao Network Information Co.,Ltd." -AsName "PNI-AS-TW" -Isp "Pittqiao Network Information Co., Ltd." -Ip "203.0.113.3" -Cc "TW"'
        echo 'T "Pittqiao 判为机房" ($c3.class -eq "datacenter") $c3.class'
        echo '$c4 = Get-ExitClass -AsField "AS209642 Mejiro Network Limited" -AsName "MEJIRONETWORK" -Isp "Mejiro Network Limited" -Ip "89.0.0.1" -Cc "HK"'
        # 89.0.0.1 的首字节 89 落在 RIPE 段(77-95)，配 Cc=HK 触发「欧洲段落地亚太」+2，
        # 这是 Mejiro 得分 6 的组成部分之一 —— 换成别的首字节会让下面的分数哨兵失败。
        echo 'T "Mejiro 判为机房" ($c4.class -eq "datacenter") $c4.class'

        # 阈值哨兵。Pittqiao 的得分恰好等于阈值，全靠单一的 32 位信号支撑：
        # 把阈值从 3 调到 4，它就会静默翻成「未识别」而没有任何报错。这两条就是为了让那次改动响。
        echo 'T "阈值哨兵：Pittqiao 得分恰为 3（改阈值会让它静默翻盘）" ($c3.score -eq 3) ("score=" + $c3.score)'
        echo 'T "Mejiro 三重佐证得分 6" ($c4.score -eq 6) ("score=" + $c4.score)'

        # 词表陷阱哨兵：守「不得把裸词 data 加进机房词表」。
        # 样本必须同时满足三个条件，否则哨兵会被自己的样本中和掉（初版就栽在这里）：
        #   16 位 ASN（否则 32 位规则本身就够判机房）、不在住宅名单里（否则第 1 步就短路）、
        #   且名字里不含任何运营商词（否则 -3 正好抵掉裸 data 的 +3，永远触发不了）。
        echo '$c5 = Get-ExitClass -AsField "AS12345 Datapipe Holdings" -AsName "X" -Isp "Datapipe Holdings" -Ip "1.2.3.4" -Cc "TW"'
        echo 'T "词表陷阱：16 位 + 名字带 data + 无运营商词，不得被判机房" ($c5.class -ne "datacenter") ("class=" + $c5.class + " score=" + $c5.score)'

        # 大云不得被误判为住宅 —— 唯一不可接受的方向
        echo '$c6 = Get-ExitClass -AsField "AS14061 DigitalOcean, LLC" -AsName "DIGITALOCEAN-ASN" -Isp "DigitalOcean, LLC" -Ip "203.0.113.6" -Cc "SG"'
        echo 'T "DigitalOcean 不得被判住宅" ($c6.class -ne "residential") $c6.class'
        echo '$c7 = Get-ExitClass -AsField "AS16509 Amazon.com, Inc." -AsName "AMAZON-02" -Isp "Amazon.com" -Ip "203.0.113.7" -Cc "JP"'
        echo 'T "AWS 不得被判住宅" ($c7.class -ne "residential") $c7.class'

        # ASN 溢出：[int] 会抛异常并退化为 unknown，[long] 才能正确解析
        echo '$c8 = Get-ExitClass -AsField "AS4294967295 Overflow" -AsName "X" -Isp "X" -Ip "1.2.3.4" -Cc "JP"'
        echo 'T "ASN 上限不溢出（[long] 而非 [int]）" ($c8.asn -eq 4294967295) ("asn=" + $c8.asn)'

        # 边界
        echo '$c9  = Get-ExitClass -AsField "AS65535 X" -AsName "X" -Isp "X" -Ip "1.2.3.4" -Cc "JP"'
        echo 'T "边界 65535 不判机房" ($c9.class -ne "datacenter") $c9.class'
        echo '$c10 = Get-ExitClass -AsField "AS65536 X" -AsName "X" -Isp "X" -Ip "1.2.3.4" -Cc "JP"'
        echo 'T "边界 65536 判机房" ($c10.class -eq "datacenter") $c10.class'

        # 无判据必须落在安全方向
        echo '$c11 = Get-ExitClass -AsField "" -AsName "" -Isp "X" -Ip "1.2.3.4" -Cc "JP"'
        echo 'T "无 AS 号退化为未识别（绝不宣称安全）" ($c11.class -eq "unknown") $c11.class'
    } >> "$TMP/cls.ps1"

    "$PS" -NoProfile -ExecutionPolicy Bypass -File "$TMP/cls.ps1" > "$TMP/cls.out" 2>"$TMP/cls.err"
    if [ ! -s "$TMP/cls.out" ]; then
        no "选点器分类器测试无输出"
        sed 's/^/      /' "$TMP/cls.err" | head -5
    else
        tr -d '\r' < "$TMP/cls.out" > "$TMP/cls.clean"
        while IFS='|' read -r st msg; do
            [ -z "$msg" ] && continue
            if [ "$st" = "PASS" ]; then ok "$msg"; else no "$msg"; fi
        done < "$TMP/cls.clean"
    fi
fi

# =============================================================================
# D. 系统代理地址提取器（vpn-leak-audit.sh 的 SYSPROXY-EXTRACT 块）
# 纯文本函数，可在任何平台离线穷举 —— 作者本机是 Windows，没有 mac/Linux 也能验。
# 它决定第 1 项要不要补 -x：取错地址会让第 1 项直接红成「VPN 不在线」，
# 取不到地址则第 3/4/5 项降级为「无法判定」。
# =============================================================================
echo; echo "==== D) 系统代理地址提取器 ===="
if ! grep -q 'SYSPROXY-EXTRACT-BEGIN' vpn-leak-audit.sh 2>/dev/null; then
    no "vpn-leak-audit.sh 里找不到 SYSPROXY-EXTRACT-BEGIN 标记"
else
    awk '/SYSPROXY-EXTRACT-BEGIN/,/SYSPROXY-EXTRACT-END/' vpn-leak-audit.sh > "$TMP/px.sh"
    # 样本：名称 :: 期望输出 :: scutil 原文（\n 代表换行）
    cat > "$TMP/pxfix" <<'PXEOF'
标准 HTTP 代理|http://127.0.0.1:7890|HTTPEnable : 1\nHTTPPort : 7890\nHTTPProxy : 127.0.0.1
只开 HTTPS（不被 HTTPEnable 子串误伤）|http://10.0.0.5:8443|HTTPSEnable : 1\nHTTPSPort : 8443\nHTTPSProxy : 10.0.0.5
只开 SOCKS 必须给 socks5h|socks5h://127.0.0.1:1080|SOCKSEnable : 1\nSOCKSPort : 1080\nSOCKSProxy : 127.0.0.1
PAC 自动配置|PAC|ProxyAutoConfigEnable : 1
WPAD 自动发现|PAC|ProxyAutoDiscoveryEnable : 1
全部关闭||HTTPEnable : 0\nSOCKSEnable : 0
端口为 0 的残留配置||HTTPEnable : 1\nHTTPPort : 0\nHTTPProxy : 127.0.0.1
缺 HTTPProxy||HTTPEnable : 1\nHTTPPort : 7890
HTTP 残缺时回落到 SOCKS|socks5h://192.168.1.1:1080|HTTPEnable : 1\nHTTPPort : 0\nHTTPProxy : 127.0.0.1\nSOCKSEnable : 1\nSOCKSPort : 1080\nSOCKSProxy : 192.168.1.1
__SCOPED__ 分域代理不得当成全局||SOCKSEnable : 0\n__SCOPED__ : <dictionary> {\nHTTPEnable : 1\nHTTPPort : 9999\nHTTPProxy : 10.9.9.9
IPv6 字面量加方括号|http://[::1]:7890|HTTPEnable : 1\nHTTPPort : 7890\nHTTPProxy : ::1
端口越界 65536||HTTPEnable : 1\nHTTPPort : 65536\nHTTPProxy : 127.0.0.1
端口 65535 合法|http://127.0.0.1:65535|HTTPEnable : 1\nHTTPPort : 65535\nHTTPProxy : 127.0.0.1
20 位超长端口不得溢出||HTTPEnable : 1\nHTTPPort : 99999999999999999999\nHTTPProxy : 127.0.0.1
端口非数字||HTTPEnable : 1\nHTTPPort : abc\nHTTPProxy : 127.0.0.1
HTTP 优先于 SOCKS|http://127.0.0.1:7890|HTTPEnable : 1\nHTTPPort : 7890\nHTTPProxy : 127.0.0.1\nSOCKSEnable : 1\nSOCKSPort : 1080\nSOCKSProxy : 127.0.0.1
静态代理优先于 PAC|http://127.0.0.1:7890|HTTPEnable : 1\nHTTPPort : 7890\nHTTPProxy : 127.0.0.1\nProxyAutoConfigEnable : 1
空输入||
PXEOF
    {
        cat "$TMP/px.sh"
        echo 'while IFS="|" read -r nm exp body; do'
        echo '  got=$(printf "%b\n" "$body" | sysproxy_url_from_scutil)'
        echo '  if [ "$got" = "$exp" ]; then printf "PASS|%s\n" "$nm"'
        echo '  else printf "FAIL|%s —— 期望 %s 实得 %s\n" "$nm" "${exp:-<空>}" "${got:-<空>}"; fi'
        echo 'done < "$1"'
    } > "$TMP/pxrun.sh"
    bash "$TMP/pxrun.sh" "$TMP/pxfix" > "$TMP/pxout" 2>"$TMP/pxerr"
    if [ -s "$TMP/pxerr" ]; then
        no "提取器执行报错"; sed 's/^/      /' "$TMP/pxerr" | head -5
    fi
    while IFS='|' read -r st msg; do
        [ -z "$msg" ] && continue
        if [ "$st" = "PASS" ]; then ok "$msg"; else no "$msg"; fi
    done < "$TMP/pxout"
fi

# =============================================================================
# E. 对照报告键名两版一致性
# compare-reports 靠键名匹配把两份报告并排。键名一旦有一版被改动，
# 比对会静默漏掉那一行（不报错、只是那项永远显示「—」），所以做成硬闸门。
# 纯静态文本比对：从两个文件的 EXPORT-KEYS 标记之间抽键名，不联网、不执行。
# =============================================================================
echo; echo "==== E) 对照报告键名两版一致性 ===="
if ! grep -q 'EXPORT-KEYS-BEGIN' vpn-leak-audit.sh 2>/dev/null || ! grep -q 'EXPORT-KEYS-BEGIN' vpn-leak-audit.ps1 2>/dev/null; then
    no "找不到 EXPORT-KEYS-BEGIN 标记（.sh 或 .ps1）"
else
    # .sh 侧：echo "键名   : ..."      .ps1 侧：('键名   : {0}' -f ...) 或 '键名 : x'
    awk '/EXPORT-KEYS-BEGIN/,/EXPORT-KEYS-END/' vpn-leak-audit.sh \
      | sed -n 's/^[[:space:]]*echo "\([^":]*\)[[:space:]]*:.*/\1/p' \
      | sed 's/[[:space:]]*$//' | grep -v '^#' > "$TMP/keys.sh"
    awk '/EXPORT-KEYS-BEGIN/,/EXPORT-KEYS-END/' vpn-leak-audit.ps1 | tr -d '\r' \
      | sed -n "s/^[[:space:]]*(\{0,1\}'\([^':]*\)[[:space:]]*:.*/\1/p" \
      | sed 's/[[:space:]]*$//' | grep -v '^#' > "$TMP/keys.ps1"
    n1=$(grep -c . "$TMP/keys.sh"); n2=$(grep -c . "$TMP/keys.ps1")
    if [ "$n1" -lt 20 ] || [ "$n2" -lt 20 ]; then
        no "抽到的键名太少（sh=${n1} ps1=${n2}，预期 20+）—— 抽取头子或导出块被改过，无法判定"
    elif diff -q "$TMP/keys.sh" "$TMP/keys.ps1" >/dev/null 2>&1; then
        ok "两版导出键名逐字节一致（${n1} 个）"
    else
        no "两版导出键名不一致 —— compare-reports 会静默漏项"
        diff "$TMP/keys.sh" "$TMP/keys.ps1" | head -12 | sed 's/^/      /'
    fi
fi

echo; echo "============================================"
echo "  结果：PASS=$pass  FAIL=$fail  SKIP=$skip"
if [ "$fail" -eq 0 ]; then
    echo "  ✅ 分类器行为回归全部通过"
    exit 0
fi
echo "  ✖ 分类器行为已变化 —— 这是纯函数比对，与平台/网络无关，失败必然是代码问题"
exit 1
