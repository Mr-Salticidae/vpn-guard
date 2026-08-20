# vpn-guard · VPN 出口一致性 / 防泄露工具箱

![vpn-guard — VPN 出口一致性 / 防泄露工具箱](assets/social-preview.jpg)

[English](README.en.md) | **中文**

[![verify](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml/badge.svg)](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml)
[![version](https://img.shields.io/github/v/tag/Mr-Salticidae/vpn-guard?label=version)](https://github.com/Mr-Salticidae/vpn-guard/releases)
（每次推送在云端真实 macOS + Linux 上跑：语法 / shellcheck / 泄露自查 / 真 Chrome 遵从 `TZ` /
`app-vpn` 进程级 `TZ` 注入验证 / **出口归属分类器行为回归**（硬闸门，`.ps1` 与 `.sh` 输出逐字节比对））

> **Windows / macOS / Linux** 用户在使用 VPN 访问**受地区限制的平台**时，用来自查真实身份是否泄露、
> 并让浏览器指纹（时区 / 语言）与出口 IP 所在国**保持一致**的一组脚本。
> Windows 用 PowerShell 版（`.ps1`），macOS / Linux 用 Bash 版（`.sh`），功能对等。
> 覆盖主流代理客户端：**Clash / Mihomo、V2Ray / Xray（v2rayN）、sing-box、Shadowsocks、
> Hysteria、WireGuard、OpenVPN**——按"流量接管方式"自动适配，不绑定具体客户端。

**为什么需要它 / Why**：VPN 换了你的 IP，但浏览器仍按**本机系统时区和语言**上报。当 IP 显示在东京、
浏览器却报 UTC+8 + zh-CN 时，稍讲究的风控系统一眼就能看出你在用代理——IP 对了，指纹却出卖了你。
本工具把"IP / DNS / WebRTC / 时区 / 语言"这几路信号对齐到同一个国家。

> ⚠️ 面向正当用途：访问因地区限制而无法正常打开的学术 / 研究 / 公共资源，以及个人隐私保护。
> 请遵守你所在地和目标平台的法律与服务条款。

---

## 先说清楚：它保住你已有的信任资产，造不出信任资产

这是本仓库最容易被误读的一点，所以放在最前面。

风控几乎都是**累加计分 + 阈值触发**，不是单点判死。真正决定生死的因素按权重排：

| 权重 | 因素 | 本工具 |
|:---:|---|---|
| 1 | **出口 IP 的共享密度与信誉** —— 机房段、多账号共用同一出口导致的关联封禁 | ⚠️ 只覆盖一半：归属门槛能判机房段，但**没有任何东西能测出一个 IP 背后挂了多少账号** |
| 2 | **账号出身** —— 注册 IP 国别、支付方式归属地、账号年龄、自注册 vs 合租买号 | ❌ **完全管不到** |
| 3 | **行为模式** —— 国家跳变（客户端自动切换造成 impossible travel）、一号多设备、并发 | ✅ 出口轮换检测 |
| 4 | **技术指纹** —— 时区 / 语言 / WebRTC / DNS 不一致 | ✅ `browse-vpn`、`app-vpn` |

**第 2 层是高权重因素里工具唯一碰不到的**，而它恰恰能解释「同样用代理，为什么有人从没事、有人反复被封」：

风控对老账号建的是 **per-account baseline**（这个账号的正常长什么样），对新账号只能用 **population prior**
（这类特征的人一般是什么货色）。一个用了多年、有连续良性历史的号，「从代理 IP 登录」早就写进了它的基线，
不构成异常；一个上周为了注册而新建的号没有基线可比，只能落到人群先验上，而机房段的人群先验极差。
**同样的出口 IP、同样的指纹，判罚可以天差地别。**

所以：装上这套脚本，不会让一个新号变安全。它的价值是**别让一个本来就干净的号，因为技术疏漏白白掉分**。
如果你的号反复被封而这套工具没帮上忙，问题多半在第 2 层，那不是脚本能解决的。

---

## 作用范围 / Scope —— 浏览器？桌面应用？CLI？

常见误解是"这套工具只管浏览器"。实际分工如下：

| | 浏览器（Chrome） | 桌面应用（Claude / ChatGPT / Cursor 等 Electron） | CLI（Codex CLI / Claude Code / git / curl） |
|---|---|---|---|
| `vpn-leak-audit` 自查 | ✅ 全部 8 项 | ✅ 除第 7 项 WebRTC 外全部适用 | ✅ 除第 7 项 WebRTC 外全部适用 |
| `browse-vpn` 一致性会话 | ✅ 就是为它做的 | ❌ 管不到 | ❌ 管不到 |
| `app-vpn` 一致性会话 | —（用 browse-vpn） | ✅ 代理 / 语言；时区见下表 | ✅ 代理 / 时区 / 语言全部生效 |
| `auto-select-node` 节点筛选 | ✅ 选出安全+快速节点并自动切换 | 同左（切的是全局出口） | 同左 |

**桌面应用有一条浏览器没有的泄露路径**，这也是 `app-vpn` 存在的理由：

> 浏览器和 .NET 程序会自动读系统代理设置；但 **Node / Rust / Go 写的 CLI（Codex CLI、Claude Code CLI）
> 与 Electron 的 Node 主进程不读**，它们只认 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量。
> 于是在**只开系统代理、没开 TUN** 的机器上：浏览器安全，而这些程序在直连暴露你的真实 IP。
> 自查的**第 2 项**就是专门实测这条路径的（用 `curl --noproxy '*'` 复刻"完全不认代理的程序"再与浏览器出口比对）。

**时区能不能进程级隔离，取决于运行时而非平台**（下表结论均为实测）：

| 目标程序 | Windows 认 `TZ` 吗 | 做法 |
|---|---|---|
| Node / Rust / Go 等 CLI | ✅ 认 | `app-vpn.ps1` 直接注入 `TZ`，**不碰系统时钟** |
| Chromium / Electron GUI | ❌ 不认 | 需 `app-vpn.ps1 -SystemTz` 临时切系统时区，退出自动还原 |
| macOS / Linux 上的**任何**程序 | ✅ 认（Chromium 也认） | 一律进程级注入 `TZ`，系统时区从头到尾不动 |

> 一句话：**想一劳永逸兜住所有程序，就开客户端的 TUN 模式**；`app-vpn` 是没有 TUN
> （或想让单个程序的时区/语言也对齐）时的按应用方案。

---

## 环境要求 / Requirements

| | Windows | macOS / Linux |
|---|---|---|
| 脚本运行时 | Windows PowerShell 5.1（Win10/11 自带） | bash 3.2+ / curl（系统自带） |
| 浏览器 | Google Chrome | Google Chrome 或 Chromium |
| 代理/VPN | Clash / Mihomo、V2Ray / Xray（v2rayN 等）、sing-box、Shadowsocks、Hysteria、WireGuard、OpenVPN…… | 同左 |
| 网络 | 需联网调用 `ip-api.com`（免费、免密钥）做出口探测 | 同左 |

> 按**流量接管方式**自动适配，与具体客户端品牌解耦：
>
> | 接管方式 | 典型场景 | 工具行为 |
> |---|---|---|
> | **TUN / 虚拟网卡** | Clash Verge TUN、sing-box tun、WireGuard、OpenVPN | 全局接管（含 UDP/WebRTC），自查判 OK |
> | **系统代理 / PAC** | v2rayN 默认、Clash 系统代理 | 浏览器没问题，但会提示"不认代理的应用与 UDP/WebRTC 可能绕行直连" |
> | **仅本地端口** | v2ray 只开 SOCKS/HTTP 入站 | 自查大声警告；浏览会话用 `--proxy` 参数让 Chrome 直接走该端口 |

## 安装 / Install

```bash
git clone https://github.com/<you>/vpn-guard.git
cd vpn-guard
chmod +x *.sh        # 仅 macOS / Linux 需要（git 通常已保留可执行位）
```
脚本用**自身所在目录**做工作目录，克隆到任意位置都能直接用，无需改路径。

## 用法 / Usage

### 1. 一键泄露自查（只读，不改任何系统设置）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1 -NoDnsLeak    # 跳过 DNS 联网实测
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1 -NoSpeedTest  # 跳过链路质量实测
```
```bash
# macOS / Linux
./vpn-leak-audit.sh
./vpn-leak-audit.sh --no-dns-leak     # 跳过 DNS 联网实测
./vpn-leak-audit.sh --no-speed-test   # 跳过链路质量实测
```
检查并以红/黄/绿输出：**代理客户端与流量接管方式**（TUN / 系统代理 / 都没有）、
公网 IP + 地理位置、代理标记、**出口归属**（住宅/消费级 vs 机房/主机商）、**桌面应用 / CLI 出口一致性**、IPv6 泄露面、
**时区一致性**（系统 vs 出口 IP）、语言一致性、DNS 解析路径（静态配置 + **DNS 泄露主动实测**）、
**WebRTC 主动检测入口**、**链路质量**（握手 + 吞吐，够不够看视频）。换节点或换国家后重跑一次即可。

> **出口归属**（第 1 项）：`hosting=false` 只说明 ip-api 库里没这条记录，**不等于住宅**。
> 实测中 `IPS INC` / `Pittqiao Network Information` / `Mejiro Network Limited` 三家小主机商
> `hosting` 全是 `false`，旧版会对它们输出"读起来像住宅/普通 ISP"——这是错的。
> 现在按 ASN 分配年代做三态判定，且**「未识别」是默认值**：判据不足时只说不知道，绝不说安全。
>
> **注意两处判定并不同源**：自查只用「分配年代 + 同一份 `residential-asn.txt` 名单」这一条阶梯；
> `auto-select-node`（第 6 节）在它之上还叠了机构名词表等辅助信号，是加权评分。
> 因此**同一个出口两边可能给出不同判定**——实测例子：32 位 ASN 但机构名含运营商词的出口，
> 选点器判「未识别」而自查判「推断为机房」；16 位 ASN 但机构名含 `Hosting` 的出口反过来。
> 两者共用的只有那份 ASN 名单，`verify-unix.sh` 第 11 项机械比对它不漂移。
>
> **桌面应用 / CLI 出口实测**（第 2 项）：用 `curl --noproxy '*'` 复刻"完全不认代理的程序"发起请求，
> 再与第 1 项的浏览器出口比对。**两者不一致就说明 Claude / Codex 这类程序正在绕过代理直连**。
> 这是被动检查看不出来的：注册表里系统代理开着、浏览器一切正常，而 Node/Electron 主进程根本不读它。
> 判定为泄露时会同时提示两条修复路径（开 TUN / 用 `app-vpn`）。
>
> **非 TUN 下这一项不再给绿灯**（两版都是）：「不认代理的程序也被隧道接管」这句话在系统代理 /
> 局部接管下**恒为假**——结构上 `TAKEOVER=sysproxy` 与「路由走 TUN」互斥，对外路由没走 TUN 网卡，
> 就意味着这类程序按定义是直连的。两侧出口相同只说明代理对 `ip-api.com` 也走了直连规则
> （规则型客户端很常见），不构成安全结论。现在报黄并说明原因，只有真的走了 TUN 才给绿。
>
> 该项同时兼任**出口轮换检测**：TUN 模式下 `--noproxy` 只关代理设置、不改路由，两次观测
> 仍走隧道，此时 IP 不同却同属一个 ASN，说明节点背后是负载均衡池而非泄露——
> 报黄色「出口在轮换」而不是红色泄露。仅在**对外路由确实走 TUN 网卡**时才这么判：
> 系统代理 / PAC / 无接管下 `curl` 本就是直连，IP 不同就是真泄露，保持红色。

> **链路质量实测**（默认开启）：前 7 项回答"我安不安全"，第 8 项回答"我这条链路够不够用"。
> 实测走代理的 TLS 握手耗时与实际吞吐，直接给出"够不够看 720p / 1080p"的判定。
> **别用 ping 判断快慢**——fake-ip 下所有域名都解析到 `198.18.x.x`、ICMP 由本机应答，
> 节点挂了 ping 也照样秒通；客户端面板的延迟数字同样不反映带宽（只测一次握手往返），
> 低延迟节点完全可能是低带宽节点。约 20MB 流量，加 `--no-speed-test` / `-NoSpeedTest` 可跳过。

> **DNS 泄露主动实测**（默认开启）：对随机子域发起真实解析，回查是哪些解析器实际应答（含归属国 / ASN），
> 再与出口国对比——能抓到"配置看着走隧道、实际却漏给本地 ISP"这类被动检查看不出的泄露。
> 走 [bash.ws](https://bash.ws)（dnsleaktest.com 官方 CLI 同源）的免费 API，只发随机子域、不含任何个人数据；
> 加 `--no-dns-leak` / `-NoDnsLeak` 可跳过联网实测。

<details>
<summary>示例输出（示意，非真实数据）</summary>

```
0) 代理客户端与流量接管方式
  客户端进程 : verge-mihomo
  [ OK ] TUN 模式 —— 全局流量（含 UDP/WebRTC）均被接管
1) 公网出口 IP 与地理位置
  位置      : <City> / <Country> (XX)
  [ OK ] 未被标记为 proxy
  [ OK ] 未被标记为机房 IP
2) 桌面应用 / CLI 出口
  代理环境变量 : 未设置 —— 这类程序不会主动走代理，只能靠 TUN 兜底
  [FAIL] 不认代理的程序直连出口 <真实IP>（China / <你的ISP>），
         与浏览器出口 <出口IP>（Japan）不一致 —— 真实 IP 正在泄露！
         受影响：Codex CLI、Claude Code CLI、Claude/ChatGPT 桌面版的 Node 主进程……
3) IPv6 泄露面        [ OK ] 公网 IPv6 归属与出口国一致（走隧道，未泄露）
4) 时区一致性         [FAIL] 系统 UTC+8 vs 出口 UTC+9，差 +1 小时  ← 头号破绽
5) 语言 / locale      [WARN] 浏览器默认语言与出口国不符
6) DNS 解析路径       [ OK ] fake-ip 隧道解析（静态配置）
   DNS 泄露主动实测   [FAIL] 解析器在 China，出口却在 Japan —— DNS 正泄露给本地 ISP
7) WebRTC 泄露面      [ OK ] 检测页已就绪，实测：browse-vpn --webrtc
8) 链路质量           [ OK ] TLS 握手 0.27s —— 节点响应快
                      [ OK ] 下行 167.8 Mbps —— 1080p 流畅
```
</details>

### 2. 通用一致性浏览会话（**主力，推荐**）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1           # 自动识别当前出口国
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -DryRun   # 只预览，不切时区/不开浏览器
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country US  # 强制某国（离线兜底 / 固定语言）
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Proxy http://127.0.0.1:10809
    # 客户端只开本地端口（未开系统代理/TUN）时，让 Chrome 直接走该端口（v2rayN 默认 HTTP 10809）
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -WebRTC   # 附带打开 WebRTC 泄露主动检测页
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -LockOnly # 只回写语言/locale 偏好，不切时区/不开浏览器
```
```bash
# macOS / Linux
./browse-vpn.sh              # 自动识别当前出口国
./browse-vpn.sh --dry-run    # 只预览，不开浏览器
./browse-vpn.sh US           # 强制某国（离线兜底 / 固定语言）
./browse-vpn.sh --proxy=socks5://127.0.0.1:1080   # 仅本地端口场景：探测和 Chrome 都走它
./browse-vpn.sh --webrtc     # 附带打开 WebRTC 泄露主动检测页
./browse-vpn.sh --lock-only  # 只回写语言/locale 偏好，不开浏览器
```

> **检测页仍报浏览器语言 zh-CN / Intl locale zh-CN？** 这是 v1.0 的已知坑：`--lang` /
> `--accept-lang` 只在**首次创建配置**时生效，真正决定指纹的 `intl.accept_languages`
> （`navigator.languages` / Accept-Language 头）和 Local State 的 `intl.app_locale`
> （`navigator.language` / Intl locale）存在磁盘上，配置一旦在中文环境建过就永久残留。
> **v1.1 起每次启动都会回写这三个键**——升级到本版后正常重跑一次即可清除，无需手删配置目录；
> 也可用 `-LockOnly` / `--lock-only` 只回写不启动浏览器。
> （若回写时该配置的 Chrome 窗口还开着，脚本会拒绝执行——它退出时会用内存里的旧偏好覆盖磁盘。）

> 脚本启动前会自查流量接管方式：既没有 TUN / 系统代理、又没给 `--proxy` 时会**红字警告**
> ——那种情况下 Chrome 会直连暴露真实 IP。v2ray 系用户没开系统代理时请带上 `--proxy`。
> （Windows PS5.1 的出口探测只支持 `http://` 代理，v2rayN 用户建议填 10809 的 HTTP 端口；
> macOS/Linux 的 curl 原生支持 `socks5://`。）

它会：**探测当前 VPN 节点的出口国** → 让浏览器时区与出口匹配、用一个独立 Chrome 配置启动
（语言匹配出口国、关闭浏览器内置 DoH 让 DNS 走隧道）。**一个脚本适配所有出口国**，
换节点后直接再跑一次，无需改脚本。

平台差异（这是 Unix 版更省心的地方）：

- **Windows**：Chrome 不认 `TZ` 环境变量，只能用 `tzutil` **临时切系统时区**，
  你关闭该 Chrome 窗口后自动还原（`finally` 保证）。会话期间系统钟随出口国走，属正常。
- **macOS / Linux**：Chrome 认 `TZ` 环境变量，脚本用 `TZ=<出口IANA时区>` 启动 Chrome，
  **只影响这一个浏览器进程，系统时区从头到尾不被改动**，也就不存在还原问题。

> 关键设计：时区**始终跟随真实出口 IP**（而非国家参数），避免出现"IP 在东京、时区却设成纽约"的新矛盾。

### 3. `app-vpn` — 桌面应用 / CLI 的一致性会话（**Claude、Codex 等用这个**）

`browse-vpn` 只作用于它启动的那个 Chrome。**Claude 桌面版 / Codex CLI / Claude Code / Cursor
完全不在它的射程内**——这个脚本就是给它们准备的。

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -List      # 列出可识别的应用别名
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex      # 在一致性环境里跑 Codex CLI
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude     # Claude Code CLI
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude-desktop -SystemTz
    # Claude 桌面版（Electron）：加 -SystemTz 时区才会跟着变，关闭后自动还原
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 "D:\any\app.exe"   # 任意可执行文件
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -Print     # 只打印环境变量，自己贴到别的终端
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex -DryRun
```
```bash
# macOS / Linux
./app-vpn.sh --list
./app-vpn.sh codex
./app-vpn.sh claude-desktop          # Unix 上 Chromium 也认 TZ，GUI 无需任何额外开关
./app-vpn.sh --print
./app-vpn.sh codex --dry-run
./app-vpn.sh codex -- --model o3     # -- 之后的参数原样透传给目标程序
```

它会：**探测当前出口国** → 给目标程序**进程级**注入
`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`（大小写两套都设，因为各语言生态读法不一）、
`NO_PROXY=localhost,127.0.0.1,::1,*.local`（本地 MCP server / 开发服务不该被代理）、
`TZ`、`LANG` / `LC_ALL` → 启动它 → 退出后还原。

**内置别名**：`codex` · `claude`（Claude Code CLI）· `claude-desktop` · `cursor` · `code` · `chatgpt`，
也可直接传任意路径或 PATH 里的命令名。Windows 上找不到硬编码路径时会去注册表卸载项里查真实安装位置
（装到非 C 盘也能找到）。

> **给目标程序传参数**：直接写在后面即可，本脚本不认识的参数会原样透传
> （`app-vpn.ps1 node -e "..."`、`./app-vpn.sh codex resume --last`）。
> 例外是 Windows 上目标程序的短选项恰好是本脚本参数名的唯一前缀（`-c` → `-Country`、
> `-s` → `-SystemTz`、`-d` → `-DryRun`、`-l` → `-List`），会被 PowerShell 抢走；
> 这时把整条命令交给 `-Run`：`app-vpn.ps1 -Run "codex -c model=gpt-5 -s workspace-write"`。
> （PowerShell 的 `-File` 模式不支持 `--` 分隔符，所以 Windows 用 `-Run`，Unix 直接用 `--`。）

> **不改任何系统设置**：环境变量只注入被启动的那个进程，脚本自身退出前还原，
> 从不写入用户级/系统级环境变量。唯一的例外是 Windows 上显式加了 `-SystemTz`——
> 那会临时切系统时区（Chromium 不认 `TZ`，别无他法），退出时 `finally` 保证还原。

### 4. `webrtc-leak-test.html` — WebRTC 泄露主动检测

WebRTC 会为了打洞通过 STUN 发 UDP，拿回"公网看到的你的 IP"。**若这条 UDP 没走 VPN 隧道，
它会暴露你的真实 IP**——哪怕网页用 HTTP 看到的是出口 IP。系统代理模式挡不住它，TUN 模式才行。
这是浏览器 API，命令行审计覆盖不到，所以单独做了一个主动检测页：

- **推荐**：`browse-vpn.ps1 -WebRTC` / `./browse-vpn.sh --webrtc` —— 在一致性会话（真实隧道）里打开检测页，最贴近实战。
- 或直接双击 `webrtc-leak-test.html`，用任意浏览器打开。

页面会自动发起真实 STUN 探测，对比 WebRTC 反射候选（srflx）与出口 IP，给出判定：
**一致**（安全）/ **泄露**（暴露了与出口不同的公网 IP，红字标出）/ **无 srflx**（UDP 已被隧道，无泄露面）。
纯前端、无外部依赖（仅连公共 STUN），不上传任何数据。

> 修复泄露：用浏览器扩展禁用 WebRTC，或让客户端以 **TUN 模式**接管全局 UDP。

### 5. 各国快捷入口（Windows，双击 / 免记参数）
`browse-jp` 日本 · `browse-us` 美国 · `browse-sg` 新加坡 · `browse-hk` 香港 · `browse-gb` 英国 · `browse-de` 德国 · `browse-kr` 韩国。
每个都等价于 `browse-vpn.ps1 -Country XX`，均支持 `-DryRun`。
macOS / Linux 直接传国家码即可（`./browse-vpn.sh jp`），无需单独入口脚本。

**已内置预设**（时区 + 语言）：JP / KR / SG / HK / TW / GB / DE / FR / NL / US / CA / AU。
美 / 加 / 澳等多时区国家按探测到的具体分区（东部 / 中部 / 太平洋…）自动选对时区。
**未预置的国家**：探测成功时时区直接用出口 IANA 时区（Unix 天然支持；Windows 按映射表/UTC 偏移匹配），
语言退回 `en-US` 并提示确认。新增国家只需编辑 `browse-vpn.ps1` 顶部 `$presets` /
`browse-vpn.sh` 里的 `preset()` 函数。

### 6. `auto-select-node` — 自动节点筛选与调配（Windows）

在安全性前提下自动找到最优代理节点并切换。通过 mihomo named pipe API 通信，渐进式筛选：

1. **延迟预筛**：组内全部节点 → 按延迟排序，保留 Top N
2. **安全性测试**：逐节点切换 → **多次**查询出口 IP → 淘汰 proxy / 机房标记 / **出口轮换** / **推断为机房的出口**（「未识别」不淘汰）
3. **带宽测试**：安全通过的节点 → Cloudflare 测速点测 TLS 握手 + 吞吐
4. **自动部署**：综合评分（带宽 60% + 延迟 25% + TLS 15%）最高者自动切换

> ⚠️ v1.1.0 之前延迟那 25% **实际上是失效的**：`delay` 存在 hashtable 键里，而 `Measure-Object`
> 只认 PSObject 属性，取不到最大/最小值就退化成常数，真正生效的是「带宽 80% + TLS 20%」。已修复。
>
> 修复后延迟项才真正参与评分，**是否改变名次取决于当批数据**：2026-08-19 的一次实测里名次翻转
> （台湾07 142ms 由 100 分降到 75，香港03 101ms 由 98.2 升到 88.3，冠军易主）；而仓库里的
> `auto-select-live.txt`（2026-08-11）那批数据名次不变，只是分数变了（香港03 92.8 → 67.7）。
> 两批数据的结论不同是正常的——差别在于高延迟节点不再白拿那 25 分。

```powershell
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1                 # 默认: 国外默认组, Top10→Top5
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -DryRun         # 只测不切，结束后还原原节点
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -TopN 15 -TopM 3 # 自定义每轮保留数量
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -Group "国外媒体"
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowHosting   # 允许机房 IP（放宽安全门槛）
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -IpProbes 3     # 每节点探 3 次出口（默认 2，1=关闭轮换检测）
powershell -ExecutionPolicy Bypass -File .uto-select-node.ps1 -AllowRotating  # 允许轮换出口（放宽安全门槛）
powershell -ExecutionPolicy Bypass -File .uto-select-node.ps1 -ProbeGapMs 5000 # 两次出口探测的间隔，默认 2500 毫秒
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowDatacenter   # 不按出口归属淘汰
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -PreferResidential # 住宅出口优先（只重排序）
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -NoSpeedTest    # 跳过带宽测试，仅按延迟+安全排序
```

> **安全优先策略**：被标记为 `proxy` 或 `hosting`（机房 IP）的节点直接淘汰，不参与后续评分。
> 高风控平台（Claude 等）对机房段敏感，住宅 IP 节点才是安全选择。
> 用 `-AllowProxy` / `-AllowHosting` 可放宽门槛，但需自行承担风险。
>
> **出口轮换检测（默认开启）**：同一节点连续探测 2 次出口 IP（每个 `curl` 进程都是独立连接，
> 不复用连接池），前后不一致即判定它背后是一个**负载均衡 / 多出口池**并淘汰。
> 这类节点有两层危害，而且**在客户端面板里与普通节点完全无法区分**：
>
> 1. **出口被大量账号共享** —— 平台按 IP 聚类做关联判定，一个号出事整簇连坐；
> 2. **你自己的会话在 IP / 国家间漂移** —— 直接触发异地登录风控。
>
> 跨国轮换（两次探测落在不同国家）比同国轮换更致命，淘汰理由会分别标注。
> **复探失败一律不淘汰**：超时或 ip-api 限流时按「未检测」处理，宁可漏判也不误杀。
> 用 `-IpProbes 1` 可完全关闭该检测（恢复旧行为），`-AllowRotating` 则检测但不淘汰。
>
> **已注定淘汰的节点会跳过复探**：节点若已因 `proxy` / `hosting` 出局，它轮不轮换都改变不了结果，
> 复探纯属浪费时间，直接短路。实测（`-IpProbes 3`）中 Top10 有 6 个是机房 IP，出口探测因此从 30 次降到 18 次；默认 `-IpProbes 2` 下是 20 → 14。
> 副作用是这类节点的淘汰理由只会显示「机房 IP」而不是「轮换」——两者都是硬淘汰，结果一致，
> 丢失的只是诊断标签；加了 `-AllowHosting` 时机房节点会继续进入排序，此时复探照常执行，信息不丢。
>
> **出口归属分类（默认开启）**：ip-api 的 `hosting=false` 只说明「它没被收录」，**不等于住宅**。
> 实测中通过前面所有门槛的 4 个节点里，只有 1 个是真住宅段（中华电信），另外 3 个
> （`IPS INC` / `Pittqiao Network Information` / `Mejiro Network Limited`）都是小主机商。
>
> 判据是一个**结构性事实**，不是名字长相：16 位 ASN 空间（1–65535）在 2014 年前后被各
> 注册局分配殆尽，而做大众家宽需要巨量地址和多年运营史，所以在位运营商全都持有低号段
> （中华电信 AS3462、KT AS4766、SoftBank AS17676、HKT AS4760、Comcast AS7922……）。
> 反过来，32 位 ASN（≥ 65536）绝大多数是 2014 年后新注册的小主机商。IPv4 与 16 位 ASN
> 空间双双耗尽，**这条分界线本身不会再移动**。
> 数据取自 `as` / `asname` 字段，**与现有请求同一次调用，零额外配额开销**。
>
> 但**分类器不止这一条判据**（这点别被上面那段带偏）：它是一个加权评分，总分 ≥ 3 判机房——
> 分配年代 +3（号段 ≥ 200000 再 +1）、机构名含机房词 +3（**单这一条就够到阈值**）、
> 亚太落地的欧洲 RIPE 段 +2、AS-NAME 仍是 RIR 占位符 +1、机构名含运营商词 **−3**。
> 分配年代那条不会腐坏，**两张词表会**——`verify-classifier.sh` 为它们留了专门的哨兵，
> 改词表之前先跑它。
>
> **淘汰是「相对」的**：只有池中还留得下非机房节点时，机房节点才被剔除。全池都被判为机房
> 时门槛整体让位、一个都不淘汰，并提示换机场——**候选池被清空在结构上不可能发生**。
> 三档判定中 `未识别` 是「信息缺失」而非「负面结论」，永远不参与淘汰。
>
> 用 `-AllowDatacenter` 关闭淘汰（分类仍照常显示）；`-PreferResidential` 让住宅出口在排序中
> 整体优先——它是**字典序分档**而非加分项：池中节点归属档位相同时，排序与不加完全一致；与 `-AllowDatacenter` 同用时，「未识别」档仍会整体排在「推断为机房」的节点之前（这是预期行为）。
> 认错了可把 ASN 写进 `residential-asn.txt`（脚本对每个节点都打印 `ASN : AS<号> <机构名>`，
> 从自己的运行日志里收割即可），不必改脚本。
>
> ⚠️ **跑之前先退掉高风控平台的会话**。这是本节最该先知道的一条操作事实：
> Step 2 / Step 3 会把**全局出口**逐个切到每个候选节点上——默认最多十余次
> （Top10 安全测试各切一次 + Top5 带宽测试各切一次 + 最后部署或还原一次），
> 每次停留数秒，**包括那些随后才被判 proxy / 机房 / 轮换而淘汰的节点**。
> 此时若开着 Claude / ChatGPT，你的会话会在几分钟内跨多国跳变——正是开头那张权重表里
> 第 3 层的「国家跳变 / impossible travel」。
> **`-DryRun` 同样会切**，它只是不部署赢家，结束时把原节点还原回去。
>
> **前提**：Clash Verge Rev (mihomo) 正在运行，TUN 模式已开启。
> 脚本通过 `\\.\pipe\verge-mihomo` named pipe 与 mihomo 通信，不依赖 TCP 外部控制器端口。
>
> **别用客户端面板的延迟数字挑节点**——那只测一次握手往返，不反映带宽，也不检查 IP 信誉，
> 更看不出这个节点是不是负载均衡池。面板里延迟最低的节点往往是所有人都在用的节点，
> 也就是共享出口密度最高、关联风险最大的那个。
> 本脚本的安全检测（proxy/hosting 标记 + 出口轮换 + 出口归属）是面板里完全没有的维度。

### 7. 环境对照 —— 请非技术的朋友帮忙测一次（Windows）

想验证「到底是什么在决定账号存活」，一台机器的数据不够。这套流程让**完全不懂命令行的人**
双击一次就能产出可对照的数据。

**给对方**：把整个文件夹打包发过去，让他按自己的系统双击对应的那个文件。

```
一键体检.cmd          ← Windows 用户双击这个
一键体检.command      ← macOS 用户双击这个
```

脚本会跑一次自查、问 9 个关于账号的问题，然后在**桌面**生成一份报告。
Linux 没有双击约定，直接 `bash ./field-report.sh`。

> **macOS 第一次双击会被系统拦下，这是正常的**，务必连同这句一起发给对方：
> 在「访达」里**右键点击 `一键体检.command` → 打开**，弹窗里再点一次「打开」即可。
> 只需做这一次。（macOS 对下载来的脚本默认不放行，双击会提示「来自身份不明的开发者」。）
> 提醒 Windows 用户：解压前先**右键 zip → 属性 → 勾选「解除锁定」**，否则脚本会被拦。

> **隐私是这套流程的第一约束**，因为产出物是要发给别人的：
> - 报告**默认脱敏**——不含完整出口 IP（只留 `1.2.3.x`）、不含 IPv6、不含 DNS 地址、
>   不含代理环境变量的值（可能带凭据）、不含机器名 / 用户名 / 任何路径；
>   系统时区只导出**与出口的差值**而不是时区名（时区名会直接暴露所在地）。
> - 生成后**把全文打在屏幕上**让他先看一遍，并明确告诉他「发不发由你决定，
>   哪一行不方便就删掉再发，不影响对照」。
> - **脚本不会自动发送任何东西。**
> - 完整自查结果另存一份到桌面，标注「这份是给你自己看的，不用发」。

**给你自己**：拿到两份以上报告后并排比对。

```powershell
powershell -ExecutionPolicy Bypass -File .\compare-reports.ps1 报告A.txt 报告B.txt
powershell -ExecutionPolicy Bypass -File .\compare-reports.ps1 .\reports\*.txt   # 多份一起
```

> 报告刻意分成两段，**比对工具也分开输出**：
>
> | 段 | 内容 | 权重 |
> |---|---|---|
> | 一、网络环境 | 接管方式、出口归属、指纹一致性…… | 脚本能测，但**权重较低** |
> | 二、账号与使用习惯 | 被封过几次（结果变量）、账号来源、注册年份、是否共用…… | 脚本测不到，**但这是主变量** |
>
> 判读方式：**如果被封的人和没被封的人在第二段上分得开、在第一段上分不开，
> 就验证了「差异在账号出身，不在 IP 质量」**（见开头的定位说明）。
> 只有两份样本时工具会主动提醒：任何差异都可能是巧合，只能当线索。

`vpn-leak-audit.ps1 -Export <路径>` 可单独产出报告的机器部分（问卷部分留空待填）。

> **报告生成端两版对等**（`.cmd` / `.command`，`-Export` / `--export`），
> 两版导出的**键名逐字节一致**，由 `verify-classifier.sh` 的 E 段做硬闸门比对 ——
> 键名一旦有一版被改动，比对会静默漏掉那一行，所以它必须是机械保证的。
>
> ⚠️ **比对端（`compare-reports.ps1`）目前只有 Windows 版**。这是有意的：报告由各人生成、
> 汇总到一个人手里比对，所以生成端要跨平台，比对端跟着收集者的机器走即可。
>
> ⚠️ **Unix 上若「出口基准可信」为「否」**（系统代理且脚本读不到代理地址，如 PAC / 需认证），
> 那份报告里的出口国 / ASN / ISP / 时区差拿到的是他的**直连出口**，不能用于对照 ——
> 比对工具会用红字点名是哪几份，让对方开 TUN 后重跑。

## 工作原理 / How it works

| 信号 | Windows | macOS / Linux |
|---|---|---|
| 时区（浏览器） | `tzutil /s` 临时切系统时区（Chrome 不认 `TZ`），会话结束 `finally` 自动还原 | `TZ=<IANA时区>` 启动 Chrome，仅该进程生效，不碰系统时区 |
| 时区（桌面/CLI） | Node/Rust/Go 类程序**认 `TZ`**，`app-vpn` 直接进程级注入；Electron GUI 不认，需显式 `-SystemTz` 临时切系统时区 | 一律进程级注入 `TZ`（Chromium 在 Unix 上也认），系统时区从头到尾不动 |
| 代理（桌面/CLI） | `app-vpn` 注入 `HTTP(S)_PROXY` / `ALL_PROXY` / `NO_PROXY`（大小写各一套），地址取自 `-Proxy` 或系统代理注册表 | 同左，地址取自 `--proxy` 或 macOS `scutil --proxy` / Linux 现有环境变量 |
| 桌面应用泄露实测 | `curl --noproxy '*'` 复刻"完全不认代理的程序"取出口，与浏览器侧（走系统代理的 .NET）出口比对，不一致即判泄露 | **两侧都是 curl，所以第 1 项必须显式补 `-x`**：curl 不读 macOS 的 `scutil`、也不读 Linux 的 `gsettings`，不补的话两侧都直连、拿到同一个 IP，会打出假的绿色。地址取自 `scutil --proxy` / `gsettings`（SOCKS 用 `socks5h://`）；PAC 与需认证的代理取不到地址，此时第 1 项标注「出口是直连取得的」，第 3/4/5 项降级为「无法判定」 |
| 语言 | Chrome `--lang` / `--accept-lang` + **每次启动回写**独立配置的 `intl.accept_languages` / `intl.selected_languages` 与 Local State 的 `intl.app_locale`（旧配置残留的中文指纹会被强制覆盖），不改系统区域；桌面/CLI 由 `app-vpn` 注入 `LANG` / `LC_ALL` | 同左 |
| DNS（静态） | 独立 Chrome 配置里关闭"安全 DNS(DoH)"，强制走系统 DNS（TUN 模式=fake-ip 隧道；系统代理模式下域名由代理远端解析），避免浏览器自行解析泄露 | 同左 |
| DNS（主动实测） | 对随机子域发起真实连接触发递归解析，用 bash.ws 回查实际应答的解析器归属国/ASN，与出口国比对判定泄露 | 同左（curl 触发，逻辑一致） |
| IP | 由 TUN / 系统代理 / `--proxy` 接管，脚本审查接管方式 | 同左 |
| IPv6 | 取公网 IPv6 后查其归属并**与出口国比对**：一致=也走隧道（未泄露）；不一致=绕过 VPN 暴露真实 ISP（真泄露）。避免"有 IPv6 就报警"的误报 | 同左 |
| WebRTC | `webrtc-leak-test.html` 主动检测：真实 STUN 探测，对比 srflx 与出口 IP 判定是否泄露；`browse-vpn --webrtc` 在真实隧道内跑 | 同左（纯前端，跨平台一致） |
| 链路质量 | 走当前接管路径（TUN 直连隧道 / 系统代理加 `-x`）向 Cloudflare 测速点取 20MB，读 `time_appconnect` 与 `speed_download`，按 480p/720p/1080p 档位判定 | PAC 模式跳过以免失真 | 同左（macOS 系统代理从 `scutil --proxy` 取地址，读不到时跳过）。PAC 模式未单独识别，会按「无接管」直测 |

> 独立 Chrome 配置存放于 `chrome-<国家>-profile/`（已在 `.gitignore` 忽略，不会进仓库），
> 两个平台的脚本共用同一套目录命名。

## 局限 / Caveats

- **检测页把 UTC+8 本身标为「更像中国用户」**：新加坡 / 马来西亚等节点本就在 +8 时区，与出口 IP 完全一致，不算泄露；这是检测页对「与中国相同偏移」的笼统提示。脚本已把时区名和语言对齐到出口国，要彻底规避这条提示只能换非 +8 时区的节点。
- **机房 IP（IDC/hosting 标记）与风险评分取决于节点质量**：自查第 1 项会提示 proxy/hosting 标记，但脚本无法改变 IP 属性——高风控平台（Claude 等）对机房段敏感，需换住宅 IP（原生 IP）节点才能解决。`browse-vpn` / `app-vpn` 启动会话前也会就这一点告警（含 ip-api 未收录、但 ASN 号段暴露了身份的小主机商），但它们只提示、不阻拦，也不做完整判定——完整判定看自查第 1 项。
- **住宅 ASN 判定是启发式，不是证明；判为住宅更不等于安全**：这是本工具最大的剩余盲区——住宅代理产业卖的正是「真实住宅 IP + 在位运营商 ASN」，它 `hosting=false`、ASN 是 16 位、名字是知名运营商，能通过本脚本的每一道门槛并被标为「住宅/消费级」，而它背后可能挂着几百个共用者。粘性会话的住宅代理连轮换检测也一并绕过。
- **它只针对「持 32 位 ASN 的新小主机商」这一类失败，不是通用机房检测器**：老牌大机房持的是 16 位号段，ASN 规则看不见它们。这不是缺陷而是分工——两个机制沿号段年代这条轴线正好互补，已用实测数据验证：

  | 机制 | 覆盖 | 实测证据 |
  |---|---|---|
  | ip-api `hosting=true` | 老牌大云（16 位老号段） | AWS AS16509、DigitalOcean AS14061、Oracle AS31898 —— 6/6 命中 |
  | ASN 年代规则 | 新小主机商（32 位号段） | IPS INC AS131939、Pittqiao AS131642、Mejiro AS209642 —— 3/3 命中，而 ip-api 对这三个全部漏报 |

  单独看，ASN 规则漏掉全部 6 个大云；但它们无一被误判为**住宅**（唯一不可接受的方向），
  且都已被前一道关卡拦下。同理，2014 年后成立且名字里不含运营商词的正规区域宽带商会被误判——
  代价是少一个候选（而非清空池），把它的 ASN 写进 `residential-asn.txt` 即可永久修正。
- **内置住宅 ASN 名单未逐条实测**：写错一个不存在的号是无害的（永远匹配不上）；唯一危险方向是把真正的主机商 ASN 写了进去，那会让它免于归属淘汰。缓解在于 ip-api 的 `hosting=true` 判定在更早的关卡独立生效，名单的影响范围仅限于「ip-api 没标记为机房」的那批节点。
- **出口轮换检测是抽样，不是证明**：默认只在几秒内探 2 次，抓得住「每连接轮换」和「短周期轮换」的池子，但**抓不住慢速轮换**（比如每 10 分钟才换一次出口）——那种节点会以「出口稳定」通过。判定为稳定只代表**这次没抓到**，不代表它一定是独占出口。想提高把握就加 `-IpProbes` 和 `-ProbeGapMs`，代价是耗时线性增长。
- 只解决"**技术信号别露馅**"。账号自身的行为特征（登录历史、支付地区、填写地址）不在此列，需你自己保持一致。参见开头的定位说明：**账号出身是高权重因素里、工具唯一完全碰不到的那一层。**
- **仅 Windows**：切换系统时区会让**所有程序**的显示时钟随出口国走；会话期间若有按本地时间触发的定时任务会顺移，属正常，浏览器关闭后自动还原。macOS / Linux 版不改系统时区，无此影响。（`app-vpn.ps1` 只在你显式加 `-SystemTz` 时才会切系统时区，CLI 场景默认不切。）
- **`app-vpn` 靠环境变量约定生效，不是强制拦截**：它注入 `HTTPS_PROXY` 等变量，前提是目标程序愿意读。绝大多数 Node / Rust / Go / Python 生态的工具都读，但**硬编码直连、或自带网络栈完全忽略这些变量的程序它管不住**。要对任意程序都强制生效，只有 TUN 模式（内核层接管）。自查第 2 项测的正是"完全不读代理设置的程序"这一最坏情况——它报绿，才说明 TUN 真的兜住了。
- **Electron 应用的时区是半覆盖的**：`app-vpn` 注入的 `TZ` 在 Windows 上只对 Node 主进程生效，Chromium 渲染层（也就是应用里显示的网页内容）仍读系统时区，必须加 `-SystemTz` 才一致。macOS / Linux 无此问题。
- **`-Print` 模式打印的环境变量含代理地址**，贴到公开场合前请自行判断（通常是 `127.0.0.1:<端口>`，不含凭据）。
- macOS / Linux 版依赖本机 tzdata 时区数据库解析 IANA 时区名（主流系统均自带；极简容器环境需先装 `tzdata`，脚本检测不到时会提示）。
- 泄露自查按"接管方式"判定（TUN / 系统代理 / 仅本地端口），主流客户端（Clash/Mihomo、V2Ray/Xray、sing-box、SS、WireGuard、OpenVPN）均适用；`198.18.x` fake-ip 特征判定覆盖 Clash/Mihomo/sing-box/Xray fakedns。
- 系统代理模式下浏览器是安全的，但 UDP/WebRTC 与不认代理的应用可能绕行——想全局兜住请开客户端的 TUN 模式。
- DNS 泄露主动实测依赖第三方服务 [bash.ws](https://bash.ws)（与 ip-api / ipify 同为默认联网项）：只发随机子域探测、不上传个人数据，服务只看到你的解析器 IP（这正是检测目标）。介意联网可加 `--no-dns-leak`。fake-ip 环境下若仍报解析器在本地，多因客户端 DNS 用了域内上游——按提示让 DNS 走隧道远端解析即可。
- **链路质量只是一次快检，不是测速软件**：单次 20MB / 8 秒采样，够区分「能不能看 720p / 1080p」这几档，但对高速链路（>100 Mbps）区分度不足，同一节点多次测量会有波动。要在多个节点间**排序**请用专门的测速工具，别拿这个数字做精细比较。它依赖 Cloudflare 测速点（`speed.cloudflare.com`），不可达时会优雅跳过并提示——那本身也是节点不稳的信号。
- **ping 通 ≠ 链路可用**：fake-ip 模式下所有域名都解析到 `198.18.x.x`、ICMP 由本机应答，无论节点好坏 ping 都秒通、延迟接近 0，`ping` / `tracert` / `nslookup` 在这里全部失去诊断意义。同理，客户端面板的「延迟测试」只测一次握手往返，**不反映带宽**——实测中出现过延迟排名中上游的节点带宽垫底（2.72 Mbps，连 480p 都紧张）。判断快慢请看第 8 项的握手耗时与吞吐。

## 许可 / License

MIT，见 [LICENSE](LICENSE)。
