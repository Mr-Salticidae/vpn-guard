<#
  app-vpn.ps1  —  一致性桌面应用 / CLI 会话（Windows 版）   (vpn-guard v1.0.1)

  它是 browse-vpn.ps1 的「非浏览器」对应物。browse-vpn 只作用于它启动的那个 Chrome；
  Claude Desktop / Codex / Claude Code / Cursor 这类桌面应用与 CLI 完全不在它的射程内。

  为什么需要它：
    浏览器和 .NET 程序会自动读 Windows 的系统代理设置（注册表 Internet Settings）；
    但 Node / Rust / Go 写的 CLI（Codex CLI、Claude Code CLI）与 Electron 的 Node 主进程
    **不读注册表**，只认 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 环境变量。
    结果：只开「系统代理」而没开 TUN 时，浏览器安全，这些程序却在直连暴露真实 IP。

  它做什么（全部只作用于被启动的那一个进程，不改任何系统设置）：
    探测当前出口国 → 给目标程序注入 HTTPS_PROXY/HTTP_PROXY/ALL_PROXY/NO_PROXY
    + TZ（Node 在 Windows 上认 TZ，实测有效）+ LANG → 启动它。

  时区的平台事实（已实测）：
    Node.js on Windows  —— 认 TZ 环境变量  → CLI 可做到进程级时区，不碰系统钟
    Chromium / Electron —— 不认 TZ 环境变量 → GUI 应用要对齐时区只能临时切系统时区（-SystemTz）

  用法：
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -List        # 列出可识别的应用别名
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex        # 在一致性环境里跑 Codex CLI
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude       # Claude Code CLI
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude-desktop -SystemTz
        # Claude 桌面版（Electron）：加 -SystemTz 才能让它的时区也对齐，退出后自动还原
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 "D:\some\app.exe"   # 任意可执行文件
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -Print       # 只打印要注入的环境变量，自己 copy 到别的终端
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex -DryRun
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex -Proxy http://127.0.0.1:10809

  给目标程序传参数：直接写在后面即可，本脚本不认识的参数会原样透传。
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex resume --last
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 node -e "console.log(process.env.HTTPS_PROXY)"
  例外：目标程序的短选项若恰好是本脚本参数名的唯一前缀（-c→-Country、-s→-SystemTz、
  -d→-DryRun、-l→-List），会被 PowerShell 抢走。这时把整条命令用 -Run 传：
    powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -Run "codex -c model=gpt-5 -s workspace-write"
  （PowerShell 的 -File 模式不支持 -- 分隔符，所以用 -Run 代替；Unix 版 app-vpn.sh 直接用 --。）
#>

# 注意：这里刻意不写 [CmdletBinding()] / [Parameter()]，保持「简单函数」绑定。
# 一旦变成 advanced function，PowerShell 会对任何未声明的 -xxx 报错 ——
# 而目标程序自己的参数（如 node 的 -e、codex 的 -m）必须能原样透传，
# 简单绑定下它们会自动落进 $args。（-File 模式无法用 -- 分隔，PS 的参数绑定器不认它。）
param(
    [string]$App     = "",   # 应用别名或可执行文件路径
    [string]$Country = "",   # 留空=自动探测；仅影响语言，时区始终跟随真实出口
    [string]$Proxy   = "",   # 留空=自动从系统代理推断；如 http://127.0.0.1:7897
    [string]$Run     = "",   # 整条命令（含参数）作为一个字符串传入，完全绕开 PS 的参数绑定
    [switch]$SystemTz,       # 额外临时切系统时区（Electron/Chromium GUI 需要），退出还原
    [switch]$Print,          # 只打印环境变量，不启动任何程序
    [switch]$List,           # 列出内置应用别名
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# 把一整条命令行按空白切分，尊重双引号（-Run 用）
function Split-CommandLine([string]$s) {
    $out = @(); $cur = ''; $inQuote = $false; $started = $false
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '"')                        { $inQuote = -not $inQuote; $started = $true; continue }
        if (-not $inQuote -and $ch -match '\s') { if ($started) { $out += $cur; $cur = ''; $started = $false }; continue }
        $cur += $ch; $started = $true
    }
    if ($started) { $out += $cur }
    return ,$out
}

# 目标程序的参数：默认收集所有未被本脚本消费的剩余参数（node 的 -e、codex 的 --model 等都能直接透传）；
# 若用了 -Run，则整条命令由它决定 —— 那些恰好与本脚本参数前缀撞车的短选项（-c/-s/-d/-l）必须走这条路。
$targetArgs = @($args)
if ($Run) {
    $parts = Split-CommandLine $Run
    if ($parts.Count -eq 0) { Write-Host "-Run 内容为空。" -ForegroundColor Red; exit 1 }
    $App = $parts[0]
    $targetArgs = @($parts | Select-Object -Skip 1) + $targetArgs
}

function Ok($m){   Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad($m){  Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }

# ==== 出口国 → 浏览器/应用语言 预设表（与 browse-vpn.ps1 保持一致）====
# 时区不在这里定：始终以探测到的真实出口 IANA 时区为准，避免「IP 在东京、时区设成纽约」。
$langPresets = @{
    JP='ja-JP,ja'; KR='ko-KR,ko'; SG='en-SG,en'; HK='zh-HK,zh,en'; TW='zh-TW,zh'
    GB='en-GB,en'; DE='de-DE,de'; FR='fr-FR,fr'; NL='nl-NL,nl,en'
    US='en-US,en'; CA='en-CA,en,fr'; AU='en-AU,en'
}
# 探测失败且手动指定国家时的兜底时区（探测成功时一律用出口返回的 IANA 名）
$fallbackTz = @{
    JP='Asia/Tokyo'; KR='Asia/Seoul'; SG='Asia/Singapore'; HK='Asia/Hong_Kong'; TW='Asia/Taipei'
    GB='Europe/London'; DE='Europe/Berlin'; FR='Europe/Paris'; NL='Europe/Amsterdam'
    US='America/New_York'; CA='America/Toronto'; AU='Australia/Sydney'
}
# -SystemTz 用：IANA → Windows 时区 ID（Chromium 不认 TZ，只能切系统时区）
$ianaToWin = @{
    'America/New_York'='Eastern Standard Time';    'America/Detroit'='Eastern Standard Time'
    'America/Chicago'='Central Standard Time';     'America/Denver'='Mountain Standard Time'
    'America/Phoenix'='US Mountain Standard Time'; 'America/Los_Angeles'='Pacific Standard Time'
    'America/Toronto'='Eastern Standard Time';     'America/Vancouver'='Pacific Standard Time'
    'Australia/Sydney'='AUS Eastern Standard Time';'Australia/Perth'='W. Australia Standard Time'
    'Europe/London'='GMT Standard Time';           'Europe/Paris'='Romance Standard Time'
    'Europe/Berlin'='W. Europe Standard Time';     'Europe/Amsterdam'='W. Europe Standard Time'
    'Asia/Tokyo'='Tokyo Standard Time';            'Asia/Seoul'='Korea Standard Time'
    'Asia/Singapore'='Singapore Standard Time';    'Asia/Hong_Kong'='China Standard Time'
    'Asia/Taipei'='Taipei Standard Time'
}

# ==== 内置应用别名 ====
# gui=$true 的是 Electron/Chromium 系（不认 TZ，需 -SystemTz 才能对齐时区）。
$appAliases = @(
    @{ Names=@('codex');                    Label='Codex CLI';        Gui=$false; Cmd='codex' }
    @{ Names=@('claude','claude-code','cc');Label='Claude Code CLI';  Gui=$false; Cmd='claude' }
    @{ Names=@('claude-desktop','claudeapp');Label='Claude 桌面版';   Gui=$true;  Cmd=''
       Paths=@('%LOCALAPPDATA%\AnthropicClaude\claude.exe','%LOCALAPPDATA%\Programs\claude\Claude.exe','%LOCALAPPDATA%\Programs\AnthropicClaude\claude.exe')
       Reg='Claude' }
    @{ Names=@('cursor');                   Label='Cursor';           Gui=$true;  Cmd=''
       Paths=@('%LOCALAPPDATA%\Programs\cursor\Cursor.exe'); Reg='Cursor' }
    @{ Names=@('code','vscode');            Label='VS Code';          Gui=$true;  Cmd=''
       Paths=@('%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe','%ProgramFiles%\Microsoft VS Code\Code.exe'); Reg='Visual Studio Code' }
    @{ Names=@('chatgpt');                  Label='ChatGPT 桌面版';   Gui=$true;  Cmd=''
       Paths=@('%LOCALAPPDATA%\Programs\ChatGPT\ChatGPT.exe'); Reg='ChatGPT' }
)

if ($List) {
    Write-Host ""
    Write-Host " 内置应用别名（也可直接传任意 .exe / .cmd 路径或 PATH 里的命令名）" -ForegroundColor Cyan
    foreach ($a in $appAliases) {
        $kind = if ($a.Gui) { 'GUI(Electron，时区需 -SystemTz)' } else { 'CLI(TZ 进程级生效)' }
        Write-Host ("  {0,-28} {1,-16} {2}" -f ($a.Names -join ' / '), $a.Label, $kind) -ForegroundColor Gray
    }
    Write-Host ""
    exit 0
}

# 从注册表卸载项里找安装路径（比硬编码路径可靠：用户可能装到 D 盘）
function Find-InstalledApp([string]$displayName) {
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*$displayName*" } | Select-Object -First 1
        if (-not $hit) { continue }
        # DisplayIcon 常直接就是主程序路径（可能带 ",0" 图标索引后缀）
        if ($hit.DisplayIcon) {
            $p = ($hit.DisplayIcon -split ',')[0].Trim('"')
            if ($p -match '\.exe$' -and (Test-Path $p)) { return $p }
        }
        if ($hit.InstallLocation -and (Test-Path $hit.InstallLocation)) {
            $exe = Get-ChildItem $hit.InstallLocation -Filter '*.exe' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notmatch '(?i)unins|update|crash|setup' } | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

# 读 PE 头的 Subsystem 字段判定 GUI(2) / 控制台(3)。
# 决定用 & 内联运行（控制台程序，保持交互）还是 Start-Process -Wait（GUI 程序才能正确等待退出）。
# Subsystem 在 PE32 与 PE32+ 的可选头里都位于偏移 68。
function Test-GuiExe([string]$path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            $fs.Position = $peOff + 4 + 20 + 68
            return ($br.ReadUInt16() -eq 2)
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# 解析用户给的 App：内置别名 → PATH 命令 → 直接路径
function Resolve-App([string]$name) {
    $lower = $name.ToLower()
    foreach ($a in $appAliases) {
        if ($a.Names -notcontains $lower) { continue }
        if ($a.Cmd) {
            $g = Get-Command $a.Cmd -ErrorAction SilentlyContinue
            if ($g) { return @{ Path=$g.Source; Label=$a.Label; Gui=$a.Gui } }
        }
        foreach ($p in @($a.Paths)) {
            if (-not $p) { continue }
            $ex = [Environment]::ExpandEnvironmentVariables($p)
            if (Test-Path $ex) { return @{ Path=$ex; Label=$a.Label; Gui=$a.Gui } }
        }
        if ($a.Reg) {
            $found = Find-InstalledApp $a.Reg
            if ($found) { return @{ Path=$found; Label=$a.Label; Gui=$a.Gui } }
        }
        Bad ("识别出别名「{0}」（{1}），但在本机找不到它的可执行文件。" -f $lower, $a.Label)
        Info "可直接传完整路径，例如：app-vpn.ps1 `"D:\path\to\app.exe`""
        exit 1
    }
    # 不是别名：先当 PATH 里的命令，再当路径
    $g = Get-Command $name -ErrorAction SilentlyContinue
    if ($g -and $g.Source) { return @{ Path=$g.Source; Label=$name; Gui=$null } }
    if (Test-Path $name)   { return @{ Path=(Resolve-Path $name).Path; Label=(Split-Path $name -Leaf); Gui=$null } }
    Bad ("找不到应用：{0}（既不是内置别名、也不在 PATH、也不是有效路径）" -f $name)
    Info "用 -List 查看内置别名。"
    exit 1
}

Write-Host ""
Write-Host " 一致性桌面应用 / CLI 会话 " -ForegroundColor Cyan

# ---- 0) 接管方式：决定要不要注入代理环境变量 ----
Write-Host "0) 流量接管方式" -ForegroundColor Cyan
$tunPat = 'tun|tap|wintun|wireguard|meta|mihomo|sing-?box'
$tunUp = @(Get-NetAdapter -ErrorAction SilentlyContinue |
           Where-Object { $_.Status -eq 'Up' -and ($_.Name -match $tunPat -or $_.InterfaceDescription -match $tunPat) })
$routeIf = $null
try { $routeIf = (Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction Stop).InterfaceAlias | Select-Object -First 1 } catch {}
$tunActive = ($tunUp.Count -gt 0 -and $routeIf -and ($tunUp.Name -contains $routeIf))
$reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue

# 系统代理地址：ProxyServer 可能是 "host:port" 或 "http=h:p;https=h:p"
$sysProxyUrl = $null
if ($reg -and $reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
    $px = "$($reg.ProxyServer)".Trim()
    if     ($px -match '(?:^|;)\s*https?=([^;]+)') { $px = $Matches[1] }
    elseif ($px -match ';')                        { $px = ($px -split ';')[0] }
    if ($px -notmatch '://') { $px = "http://$px" }
    $sysProxyUrl = $px
}

if ($tunActive)          { Ok ("TUN 模式（{0}）—— 全局流量已被接管，桌面应用/CLI 本来就走隧道" -f $routeIf) }
elseif ($tunUp.Count -gt 0) { Warn ("检测到 TUN 网卡（{0}），但对外路由走 {1} —— TUN 可能未完全接管" -f $tunUp[0].Name, $routeIf) }
if ($sysProxyUrl)        { Info ("系统代理     : {0}（浏览器/.NET 认它，Node/Rust CLI 与 Electron 主进程不认）" -f $sysProxyUrl) }
if ($reg -and $reg.AutoConfigURL) { Warn ("PAC 模式（{0}）—— 无法从 PAC 推断固定代理地址，请用 -Proxy 显式指定" -f $reg.AutoConfigURL) }

# 决定注入哪个代理地址
$proxyUrl = $null; $proxySource = ''
if ($Proxy)              { $proxyUrl = $Proxy;      $proxySource = '你用 -Proxy 指定的' }
elseif ($sysProxyUrl)    { $proxyUrl = $sysProxyUrl; $proxySource = '从系统代理设置推断的' }

if (-not $proxyUrl -and -not $tunActive) {
    Bad "既没有 TUN 接管、也没有可用的代理地址 —— 目标程序会直连，暴露真实 IP！"
    Info "请开客户端的 TUN 模式，或加 -Proxy http://127.0.0.1:<端口>（Clash 默认 7897，v2rayN HTTP 默认 10809）。"
} elseif (-not $proxyUrl) {
    Info "无代理地址可注入，但 TUN 已全局接管 —— 目标程序仍走隧道。"
}

# ---- 1) 探测出口 ----
Write-Host "1) 探测当前出口" -ForegroundColor Cyan
$exit = $null
try {
    $u = "http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting"
    # PS5.1 的 -Proxy 只支持 http(s)；SOCKS 时退回直连探测（TUN 下结果依然正确）
    if ($proxyUrl -match '^https?://') { $exit = Invoke-RestMethod -Uri $u -Proxy $proxyUrl -TimeoutSec 15 }
    else                               { $exit = Invoke-RestMethod -Uri $u -TimeoutSec 15 }
} catch {}

$cc = ''; $iana = ''; $ipOffset = $null
if ($exit -and $exit.status -eq 'success') {
    Info ("出口 IP : {0}" -f $exit.query)
    Info ("位置    : {0} / {1} ({2}), {3} (UTC{4:+0;-0}:00)" -f $exit.city,$exit.country,$exit.countryCode,$exit.timezone,($exit.offset/3600))
    if ($exit.proxy -or $exit.hosting) { Warn "该 IP 被标记为 proxy/hosting，高风控平台可能拦截。" }
    $cc = $exit.countryCode.ToUpper(); $iana = $exit.timezone; $ipOffset = $exit.offset
    if ($Country -and $Country.ToUpper() -ne $cc) {
        Warn ("你指定了 -Country {0}，但出口在 {1}；语言按你指定的走，时区仍跟随真实出口。" -f $Country.ToUpper(), $cc)
        $cc = $Country.ToUpper()
    }
} else {
    if (-not $Country) { Bad "无法探测出口（ip-api 不可达），且未指定 -Country。请检查 VPN 是否在线。"; exit 1 }
    Warn ("探测失败，改用手动指定的 -Country {0}" -f $Country.ToUpper())
    $cc = $Country.ToUpper()
    if (-not $fallbackTz.ContainsKey($cc)) { Bad ("未预置国家 {0}，探测又失败，无法决定时区。" -f $cc); exit 1 }
    $iana = $fallbackTz[$cc]
}

# ---- 2) 决定时区 + 语言 ----
$lang = if ($langPresets.ContainsKey($cc)) { $langPresets[$cc] } else {
    Warn ("未预置国家 {0}，语言退回通用 en-US。" -f $cc); 'en-US,en'
}
$primary = $lang.Split(',')[0]
# POSIX 风格 locale：Node/Python/Go 等跨平台程序读 LANG，Windows 下无副作用
$posixLocale = ($primary -replace '-','_') + '.UTF-8'

Write-Host ""
Write-Host ("将注入  时区: {0}   语言: {1}   出口国: {2}" -f $iana, $lang, $cc) -ForegroundColor Cyan

# ---- 3) 组装环境变量 ----
$noProxy = 'localhost,127.0.0.1,::1,*.local'   # 本地 MCP server / 开发服务不该被代理
# 必须用区分大小写的字典：PowerShell 的 [ordered]@{} 与 @{} 都是大小写不敏感的，
# HTTPS_PROXY 与 https_proxy 会被折叠成同一个键。而两种写法都得设 ——
# 多数 Node 库先读大写，curl 对 http_proxy 只认小写（CGI 历史遗留的安全约定）。
$inject = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
$inject['TZ'] = $iana; $inject['LANG'] = $posixLocale; $inject['LC_ALL'] = $posixLocale
if ($proxyUrl) {
    foreach ($n in 'HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','https_proxy','http_proxy','all_proxy') { $inject[$n] = $proxyUrl }
    $inject['NO_PROXY'] = $noProxy; $inject['no_proxy'] = $noProxy
    Info ("代理环境变量取自：{0}" -f $proxySource)
}

if ($Print) {
    Write-Host ""
    Write-Host "# 复制到你自己的 PowerShell 里，之后在该窗口启动的程序都会走一致性环境：" -ForegroundColor DarkCyan
    foreach ($k in $inject.Keys) { Write-Host ("`$env:{0} = '{1}'" -f $k, $inject[$k]) }
    Write-Host ""
    Write-Host "# 对应的 bash / WSL 写法：" -ForegroundColor DarkCyan
    foreach ($k in $inject.Keys) { Write-Host ("export {0}='{1}'" -f $k, $inject[$k]) }
    Write-Host ""
    if (-not $SystemTz) { Info "注意：Electron/Chromium GUI 应用不认 TZ，要对齐它们的时区需用 -SystemTz 启动。" }
    exit 0
}

if (-not $App) {
    Bad "未指定要启动的应用。"
    Info "示例：app-vpn.ps1 codex   /   app-vpn.ps1 claude-desktop -SystemTz   /   app-vpn.ps1 -List   /   app-vpn.ps1 -Print"
    exit 1
}

# ---- 4) 解析目标应用 ----
$target = Resolve-App $App
$isGui = if ($null -ne $target.Gui) { $target.Gui } else {
    if ($target.Path -match '\.(cmd|bat|ps1|sh)$') { $false } else { Test-GuiExe $target.Path }
}
Write-Host ""
Write-Host ("目标应用: {0}" -f $target.Label) -ForegroundColor Cyan
Info ("路径     : {0}" -f $target.Path)
Info ("类型     : {0}" -f $(if ($isGui) { 'GUI（Chromium/Electron 系不认 TZ）' } else { '控制台（Node/Rust 等认 TZ，进程级生效）' }))
if ($targetArgs) { Info ("透传参数 : {0}" -f ($targetArgs -join ' ')) }

if ($isGui -and -not $SystemTz) {
    Warn "GUI 应用不读 TZ 环境变量 —— 它报的仍是系统时区。要让时区也对齐请加 -SystemTz。"
    Info "（代理与语言的注入对它依然有效；如果你只关心 IP 不泄露，不加 -SystemTz 也行。）"
}
if (-not $isGui -and $SystemTz) {
    Info "控制台程序本来就认 TZ，-SystemTz 并非必需；仍会按你的要求临时切系统时区。"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] 将注入以下环境变量，但不启动程序、不切系统时区：" -ForegroundColor Magenta
    foreach ($k in $inject.Keys) { Info ("{0}={1}" -f $k, $inject[$k]) }
    exit 0
}

# ---- 5) 注入环境变量 → 启动 → 退出后还原 ----
$savedEnv = @{}
foreach ($k in $inject.Keys) {
    $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    Set-Item -Path "env:$k" -Value $inject[$k]
}

$origTZ = $null
try {
    if ($SystemTz) {
        $winTz = if ($ianaToWin.ContainsKey($iana)) { $ianaToWin[$iana] } else {
            # 未收录的 IANA 名：按当前 UTC 偏移找一个等效的 Windows 时区
            if ($null -ne $ipOffset) {
                ([System.TimeZoneInfo]::GetSystemTimeZones() |
                 Where-Object { $_.GetUtcOffset([DateTimeOffset]::UtcNow).TotalSeconds -eq $ipOffset } |
                 Select-Object -First 1).Id
            } else { $null }
        }
        if (-not $winTz) {
            Warn ("无法把 {0} 映射到 Windows 时区 ID —— 跳过 -SystemTz，系统时区保持不变。" -f $iana)
        } else {
            $origTZ = (tzutil /g)
            tzutil /s $winTz
            Warn ("已临时切换系统时区: {0} → {1}（会话期间所有程序的钟都随出口国走，退出自动还原）" -f $origTZ, $winTz)
        }
    }

    Write-Host ""
    Write-Host "正在启动……（关闭该程序后环境自动还原）" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray

    if ($isGui) {
        # GUI 程序：& 不会等待，必须 Start-Process -Wait
        if ($targetArgs) { Start-Process -FilePath $target.Path -ArgumentList $targetArgs -Wait }
        else             { Start-Process -FilePath $target.Path -Wait }
    } else {
        # 控制台程序：内联运行，保留 stdin/stdout，交互式 CLI 才能正常用
        if ($targetArgs) { & $target.Path @targetArgs }
        else             { & $target.Path }
    }
}
finally {
    if ($origTZ) {
        tzutil /s $origTZ
        Write-Host ("系统时区已还原为: {0}" -f (tzutil /g)) -ForegroundColor Green
    }
    foreach ($k in $savedEnv.Keys) {
        if ($null -eq $savedEnv[$k]) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "env:$k" -Value $savedEnv[$k] }
    }
}

Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host "会话结束，环境变量已还原（本脚本从未写入用户级/系统级环境变量）。" -ForegroundColor Green
