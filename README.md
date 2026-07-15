# vpn-guard · VPN 出口一致性 / 防泄露工具箱

![vpn-guard — VPN 出口一致性 / 防泄露工具箱](assets/social-preview.jpg)

[English](README.en.md) | **中文**

[![verify](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml/badge.svg)](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml)
（每次推送在云端真实 macOS + Linux 上跑：语法 / shellcheck / 泄露自查 / 真 Chrome 遵从 `TZ` 验证）

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
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1 -NoDnsLeak  # 跳过 DNS 联网实测
```
```bash
# macOS / Linux
./vpn-leak-audit.sh
./vpn-leak-audit.sh --no-dns-leak   # 跳过 DNS 联网实测
```
检查并以红/黄/绿输出：**代理客户端与流量接管方式**（TUN / 系统代理 / 都没有）、
公网 IP + 地理位置、代理/机房标记、IPv6 泄露面、**时区一致性**（系统 vs 出口 IP）、
语言一致性、DNS 解析路径（静态配置 + **DNS 泄露主动实测**）、**WebRTC 主动检测入口**。换节点或换国家后重跑一次即可。

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
2) IPv6 泄露面        [ OK ] 公网 IPv6 归属与出口国一致（走隧道，未泄露）
3) 时区一致性         [FAIL] 系统 UTC+8 vs 出口 UTC+9，差 +1 小时  ← 头号破绽
4) 语言 / locale      [WARN] 浏览器默认语言与出口国不符
5) DNS 解析路径       [ OK ] fake-ip 隧道解析（静态配置）
   DNS 泄露主动实测   [FAIL] 解析器在 China，出口却在 Japan —— DNS 正泄露给本地 ISP
6) WebRTC 泄露面      [ OK ] 检测页已就绪，实测：browse-vpn --webrtc
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
```
```bash
# macOS / Linux
./browse-vpn.sh              # 自动识别当前出口国
./browse-vpn.sh --dry-run    # 只预览，不开浏览器
./browse-vpn.sh US           # 强制某国（离线兜底 / 固定语言）
./browse-vpn.sh --proxy=socks5://127.0.0.1:1080   # 仅本地端口场景：探测和 Chrome 都走它
./browse-vpn.sh --webrtc     # 附带打开 WebRTC 泄露主动检测页
```

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

### 3. `webrtc-leak-test.html` — WebRTC 泄露主动检测

WebRTC 会为了打洞通过 STUN 发 UDP，拿回"公网看到的你的 IP"。**若这条 UDP 没走 VPN 隧道，
它会暴露你的真实 IP**——哪怕网页用 HTTP 看到的是出口 IP。系统代理模式挡不住它，TUN 模式才行。
这是浏览器 API，命令行审计覆盖不到，所以单独做了一个主动检测页：

- **推荐**：`browse-vpn.ps1 -WebRTC` / `./browse-vpn.sh --webrtc` —— 在一致性会话（真实隧道）里打开检测页，最贴近实战。
- 或直接双击 `webrtc-leak-test.html`，用任意浏览器打开。

页面会自动发起真实 STUN 探测，对比 WebRTC 反射候选（srflx）与出口 IP，给出判定：
**一致**（安全）/ **泄露**（暴露了与出口不同的公网 IP，红字标出）/ **无 srflx**（UDP 已被隧道，无泄露面）。
纯前端、无外部依赖（仅连公共 STUN），不上传任何数据。

> 修复泄露：用浏览器扩展禁用 WebRTC，或让客户端以 **TUN 模式**接管全局 UDP。

### 4. 各国快捷入口（Windows，双击 / 免记参数）
`browse-jp` 日本 · `browse-us` 美国 · `browse-sg` 新加坡 · `browse-hk` 香港 · `browse-gb` 英国 · `browse-de` 德国 · `browse-kr` 韩国。
每个都等价于 `browse-vpn.ps1 -Country XX`，均支持 `-DryRun`。
macOS / Linux 直接传国家码即可（`./browse-vpn.sh jp`），无需单独入口脚本。

**已内置预设**（时区 + 语言）：JP / KR / SG / HK / TW / GB / DE / FR / NL / US / CA / AU。
美 / 加 / 澳等多时区国家按探测到的具体分区（东部 / 中部 / 太平洋…）自动选对时区。
**未预置的国家**：探测成功时时区直接用出口 IANA 时区（Unix 天然支持；Windows 按映射表/UTC 偏移匹配），
语言退回 `en-US` 并提示确认。新增国家只需编辑 `browse-vpn.ps1` 顶部 `$presets` /
`browse-vpn.sh` 里的 `preset()` 函数。

## 工作原理 / How it works

| 信号 | Windows | macOS / Linux |
|---|---|---|
| 时区 | `tzutil /s` 临时切系统时区（Chrome 不认 `TZ`），会话结束 `finally` 自动还原 | `TZ=<IANA时区>` 启动 Chrome，仅该进程生效，不碰系统时区 |
| 语言 | Chrome `--lang` / `--accept-lang` + 独立配置的 `intl.selected_languages`，不改系统区域 | 同左 |
| DNS（静态） | 独立 Chrome 配置里关闭"安全 DNS(DoH)"，强制走系统 DNS（TUN 模式=fake-ip 隧道；系统代理模式下域名由代理远端解析），避免浏览器自行解析泄露 | 同左 |
| DNS（主动实测） | 对随机子域发起真实连接触发递归解析，用 bash.ws 回查实际应答的解析器归属国/ASN，与出口国比对判定泄露 | 同左（curl 触发，逻辑一致） |
| IP | 由 TUN / 系统代理 / `--proxy` 接管，脚本审查接管方式 | 同左 |
| IPv6 | 取公网 IPv6 后查其归属并**与出口国比对**：一致=也走隧道（未泄露）；不一致=绕过 VPN 暴露真实 ISP（真泄露）。避免"有 IPv6 就报警"的误报 | 同左 |
| WebRTC | `webrtc-leak-test.html` 主动检测：真实 STUN 探测，对比 srflx 与出口 IP 判定是否泄露；`browse-vpn --webrtc` 在真实隧道内跑 | 同左（纯前端，跨平台一致） |

> 独立 Chrome 配置存放于 `chrome-<国家>-profile/`（已在 `.gitignore` 忽略，不会进仓库），
> 两个平台的脚本共用同一套目录命名。

## 局限 / Caveats

- 只解决"**技术信号别露馅**"。账号自身的行为特征（登录历史、支付地区、填写地址）不在此列，需你自己保持一致。
- **仅 Windows**：切换系统时区会让**所有程序**的显示时钟随出口国走；会话期间若有按本地时间触发的定时任务会顺移，属正常，浏览器关闭后自动还原。macOS / Linux 版不改系统时区，无此影响。
- macOS / Linux 版依赖本机 tzdata 时区数据库解析 IANA 时区名（主流系统均自带；极简容器环境需先装 `tzdata`，脚本检测不到时会提示）。
- 泄露自查按"接管方式"判定（TUN / 系统代理 / 仅本地端口），主流客户端（Clash/Mihomo、V2Ray/Xray、sing-box、SS、WireGuard、OpenVPN）均适用；`198.18.x` fake-ip 特征判定覆盖 Clash/Mihomo/sing-box/Xray fakedns。
- 系统代理模式下浏览器是安全的，但 UDP/WebRTC 与不认代理的应用可能绕行——想全局兜住请开客户端的 TUN 模式。
- DNS 泄露主动实测依赖第三方服务 [bash.ws](https://bash.ws)（与 ip-api / ipify 同为默认联网项）：只发随机子域探测、不上传个人数据，服务只看到你的解析器 IP（这正是检测目标）。介意联网可加 `--no-dns-leak`。fake-ip 环境下若仍报解析器在本地，多因客户端 DNS 用了域内上游——按提示让 DNS 走隧道远端解析即可。

## 许可 / License

MIT，见 [LICENSE](LICENSE)。
