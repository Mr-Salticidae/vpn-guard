# vpn-guard · VPN 出口一致性 / 防泄露工具箱

![vpn-guard — VPN 出口一致性 / 防泄露工具箱](assets/social-preview.jpg)

> **Windows / macOS / Linux** 用户在使用 VPN 访问**受地区限制的平台**时，用来自查真实身份是否泄露、
> 并让浏览器指纹（时区 / 语言）与出口 IP 所在国**保持一致**的一组脚本。
> Windows 用 PowerShell 版（`.ps1`），macOS / Linux 用 Bash 版（`.sh`），功能对等。
>
> A cross-platform toolkit (PowerShell for Windows, Bash for macOS/Linux) to **audit VPN leaks**
> (IP / DNS / WebRTC / IPv6) and keep browser fingerprint (timezone / locale) **consistent with the
> exit-node country**, so geo-fingerprinting doesn't flag "this user is on a VPN".

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
| VPN | 基于 **Clash / Mihomo（TUN + fake-ip DNS）** 的客户端效果最佳 | 同左 |
| 网络 | 需联网调用 `ip-api.com`（免费、免密钥）做出口探测 | 同左 |

> 脚本对 Clash 的 fake-ip + TUN 做了针对性判断。其它 VPN 也能用时区/语言对齐功能，
> 但 DNS 一节的判定文案是按 Clash 写的。

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
```
```bash
# macOS / Linux
./vpn-leak-audit.sh
```
检查并以红/黄/绿输出：公网 IP + 地理位置、代理/机房标记、IPv6 泄露面、
**时区一致性**（系统 vs 出口 IP）、语言一致性、DNS 解析路径是否漏到本地 ISP。
换节点或换国家后重跑一次即可。

<details>
<summary>示例输出（示意，非真实数据）</summary>

```
1) 公网出口 IP 与地理位置
  位置      : <City> / <Country> (XX)
  [ OK ] 未被标记为 proxy
  [ OK ] 未被标记为机房 IP
2) IPv6 泄露面        [ OK ] 无公网 IPv6 出口
3) 时区一致性         [FAIL] 系统 UTC+8 vs 出口 UTC+9，差 +1 小时  ← 头号破绽
4) 语言 / locale      [WARN] 浏览器默认语言与出口国不符
5) DNS 解析路径       [ OK ] fake-ip 隧道解析
```
</details>

### 2. 通用一致性浏览会话（**主力，推荐**）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1           # 自动识别当前出口国
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -DryRun   # 只预览，不切时区/不开浏览器
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country US  # 强制某国（离线兜底 / 固定语言）
```
```bash
# macOS / Linux
./browse-vpn.sh              # 自动识别当前出口国
./browse-vpn.sh --dry-run    # 只预览，不开浏览器
./browse-vpn.sh US           # 强制某国（离线兜底 / 固定语言）
```

它会：**探测当前 VPN 节点的出口国** → 让浏览器时区与出口匹配、用一个独立 Chrome 配置启动
（语言匹配出口国、关闭浏览器内置 DoH 让 DNS 走隧道）。**一个脚本适配所有出口国**，
换节点后直接再跑一次，无需改脚本。

平台差异（这是 Unix 版更省心的地方）：

- **Windows**：Chrome 不认 `TZ` 环境变量，只能用 `tzutil` **临时切系统时区**，
  你关闭该 Chrome 窗口后自动还原（`finally` 保证）。会话期间系统钟随出口国走，属正常。
- **macOS / Linux**：Chrome 认 `TZ` 环境变量，脚本用 `TZ=<出口IANA时区>` 启动 Chrome，
  **只影响这一个浏览器进程，系统时区从头到尾不被改动**，也就不存在还原问题。

> 关键设计：时区**始终跟随真实出口 IP**（而非国家参数），避免出现"IP 在东京、时区却设成纽约"的新矛盾。

### 3. 各国快捷入口（Windows，双击 / 免记参数）
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
| DNS | 独立 Chrome 配置里关闭"安全 DNS(DoH)"，强制走系统 DNS = Clash fake-ip 隧道，避免浏览器自行解析泄露 | 同左 |
| IP / WebRTC | 由 Clash TUN 接管，脚本只做审查（泄露自查脚本会提示 WebRTC / IPv6 泄露面） | 同左 |

> 独立 Chrome 配置存放于 `chrome-<国家>-profile/`（已在 `.gitignore` 忽略，不会进仓库），
> 两个平台的脚本共用同一套目录命名。

## 局限 / Caveats

- 只解决"**技术信号别露馅**"。账号自身的行为特征（登录历史、支付地区、填写地址）不在此列，需你自己保持一致。
- **仅 Windows**：切换系统时区会让**所有程序**的显示时钟随出口国走；会话期间若有按本地时间触发的定时任务会顺移，属正常，浏览器关闭后自动还原。macOS / Linux 版不改系统时区，无此影响。
- macOS / Linux 版依赖本机 tzdata 时区数据库解析 IANA 时区名（主流系统均自带；极简容器环境需先装 `tzdata`，脚本检测不到时会提示）。
- DNS 一节按 Clash（fake-ip + TUN）判定；其它 VPN 请自行确认 DNS 走向。

## 许可 / License

MIT，见 [LICENSE](LICENSE)。
