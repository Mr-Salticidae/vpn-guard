<#
  browse-vpn.ps1  —  通用一致性浏览会话（自动识别出口国）
  作用：探测当前 VPN 出口所在国 → 自动把系统时区切到与出口匹配的时区、
        用独立 Chrome 配置启动（语言匹配出口国、关闭浏览器 DoH 走隧道解析）→
        你关闭该 Chrome 窗口后，自动还原系统时区。一个脚本适配所有出口国。

  用法：
    powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1            # 自动识别当前出口
    powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -DryRun    # 只预览会怎么设置，不切时区/不开浏览器
    powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country US # 强制按某国预设（不依赖探测）
#>

param(
    [string]$Country = "",   # 留空=自动探测；或 JP/US/SG/HK/TW/KR/GB/DE/FR/NL/CA/AU
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# 自动定位 Chrome；$BaseDir 取脚本所在目录，克隆到任意位置都能直接用
$Chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Chrome) { Write-Host "未找到 Chrome，请安装 Google Chrome 或在脚本顶部手动指定 \$Chrome 路径。" -ForegroundColor Red; exit 1 }
$BaseDir = $PSScriptRoot

# ==== 出口国 → Windows 时区 ID + 浏览器语言 预设表 ====
# 单时区国家直接给固定时区；美加澳等多时区国家再按探测到的 IANA 细分（见 $usZone 等）。
$presets = @{
    JP = @{ tz='Tokyo Standard Time';      lang='ja-JP,ja' }
    KR = @{ tz='Korea Standard Time';       lang='ko-KR,ko' }
    SG = @{ tz='Singapore Standard Time';   lang='en-SG,en' }
    HK = @{ tz='China Standard Time';       lang='zh-HK,zh,en' }   # UTC+8（Chrome 会报 Asia/Shanghai，偏移一致）
    TW = @{ tz='Taipei Standard Time';      lang='zh-TW,zh' }
    GB = @{ tz='GMT Standard Time';         lang='en-GB,en' }
    DE = @{ tz='W. Europe Standard Time';   lang='de-DE,de' }
    FR = @{ tz='Romance Standard Time';     lang='fr-FR,fr' }
    NL = @{ tz='W. Europe Standard Time';   lang='nl-NL,nl,en' }
    US = @{ tz='Eastern Standard Time';     lang='en-US,en' }      # 默认东部，若探测到具体分区会覆盖
    CA = @{ tz='Eastern Standard Time';     lang='en-CA,en,fr' }
    AU = @{ tz='AUS Eastern Standard Time'; lang='en-AU,en' }
}
# 多时区国家：按 ip-api 返回的 IANA 名细分到正确的 Windows 时区
$ianaToWin = @{
    'America/New_York'    = 'Eastern Standard Time'
    'America/Detroit'     = 'Eastern Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Phoenix'     = 'US Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'America/Toronto'     = 'Eastern Standard Time'
    'America/Vancouver'   = 'Pacific Standard Time'
    'Australia/Sydney'    = 'AUS Eastern Standard Time'
    'Australia/Perth'     = 'W. Australia Standard Time'
    'Europe/London'       = 'GMT Standard Time'
    'Europe/Paris'        = 'Romance Standard Time'
    'Europe/Berlin'       = 'W. Europe Standard Time'
    'Europe/Amsterdam'    = 'W. Europe Standard Time'
    'Asia/Tokyo'          = 'Tokyo Standard Time'
    'Asia/Seoul'          = 'Korea Standard Time'
    'Asia/Singapore'      = 'Singapore Standard Time'
    'Asia/Hong_Kong'      = 'China Standard Time'
    'Asia/Taipei'         = 'Taipei Standard Time'
}

function Get-Exit {
    try { return Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,query,proxy,hosting" -TimeoutSec 15 }
    catch { return $null }
}

# ---- 1) 探测出口 ----
Write-Host "探测当前 VPN 出口……" -ForegroundColor Cyan
$exit = Get-Exit
if (-not $exit -or $exit.status -ne 'success') {
    if ($Country -eq "") { Write-Host "无法探测出口（ip-api 不可达），且未指定 -Country。请检查 VPN 是否在线，或加 -Country XX 手动指定。" -ForegroundColor Red; exit 1 }
    Write-Host "探测失败，改用手动指定的 -Country $Country" -ForegroundColor Yellow
    $cc = $Country.ToUpper(); $iana = ""; $ipOffset = $null
} else {
    Write-Host ("  出口 IP : {0}" -f $exit.query) -ForegroundColor Gray
    Write-Host ("  位置    : {0} / {1} ({2}), {3} (UTC{4:+0;-0}:00)" -f $exit.city,$exit.country,$exit.countryCode,$exit.timezone,($exit.offset/3600)) -ForegroundColor Gray
    if ($exit.proxy -or $exit.hosting) { Write-Host "  注意：该 IP 被标记为 proxy/hosting，高风控平台可能拦截。" -ForegroundColor Yellow }
    $cc = $exit.countryCode.ToUpper(); $iana = $exit.timezone; $ipOffset = $exit.offset
    if ($Country -ne "" -and $Country.ToUpper() -ne $cc) {
        Write-Host ("  你指定了 -Country {0}，但探测到出口在 {1}；以你指定的为准。" -f $Country.ToUpper(),$cc) -ForegroundColor Yellow
        $cc = $Country.ToUpper()
    }
}

# ---- 2) 决定时区 + 语言 ----
if (-not $presets.ContainsKey($cc)) {
    Write-Host ("未预置国家 {0}。" -f $cc) -ForegroundColor Yellow
    if ($iana -and $ianaToWin.ContainsKey($iana)) {
        $winTz = $ianaToWin[$iana]; $lang = "en-US,en"
        Write-Host ("  按出口时区 {0} 匹配到 {1}，语言用通用 en-US。" -f $iana,$winTz) -ForegroundColor Yellow
    } elseif ($ipOffset -ne $null) {
        $winTz = ([System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object { $_.GetUtcOffset([DateTimeOffset]::UtcNow).TotalSeconds -eq $ipOffset } | Select-Object -First 1).Id
        $lang = "en-US,en"
        if (-not $winTz) { Write-Host "  无法按偏移匹配时区，请手动加 -Country。" -ForegroundColor Red; exit 1 }
        Write-Host ("  按 UTC 偏移匹配到 {0}，语言用通用 en-US。" -f $winTz) -ForegroundColor Yellow
    } else { Write-Host "  信息不足，无法决定时区。" -ForegroundColor Red; exit 1 }
} else {
    $winTz = $presets[$cc].tz; $lang = $presets[$cc].lang
    # 多时区国家：用探测到的 IANA 覆盖到更精确的分区
    if ($iana -and $ianaToWin.ContainsKey($iana)) { $winTz = $ianaToWin[$iana] }
}

# ---- 3) 一致性校验：所选时区当前偏移是否与出口 IP 一致 ----
$chosenOffset = ([System.TimeZoneInfo]::FindSystemTimeZoneById($winTz)).GetUtcOffset([DateTimeOffset]::UtcNow).TotalSeconds
if ($ipOffset -ne $null -and [math]::Abs($chosenOffset - $ipOffset) -ge 1) {
    Write-Host ("  ⚠ 所选时区偏移(UTC{0:+0;-0}) 与出口(UTC{1:+0;-0}) 不一致，可能夏令时边界，请人工确认。" -f ($chosenOffset/3600),($ipOffset/3600)) -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("将使用  时区: {0} (UTC{1:+0;-0}:00)   语言: {2}   出口国: {3}" -f $winTz,($chosenOffset/3600),$lang,$cc) -ForegroundColor Cyan

$profileDir = Join-Path $BaseDir ("chrome-{0}-profile" -f $cc.ToLower())

if ($DryRun) { Write-Host "[DryRun] 仅预览，未切换时区、未启动浏览器。" -ForegroundColor Magenta; exit 0 }

# ---- 4) 预置独立配置：关闭安全 DNS(DoH) + 默认语言（仅本会话专用配置）----
$prefDir = Join-Path $profileDir "Default"
$prefFile = Join-Path $prefDir "Preferences"
if (-not (Test-Path $prefFile)) {
    New-Item -ItemType Directory -Force -Path $prefDir | Out-Null
    (@{ dns_over_https=@{mode='off'}; intl=@{selected_languages=$lang}; browser=@{check_default_browser=$false} } | ConvertTo-Json -Depth 5) |
        Set-Content -Path $prefFile -Encoding UTF8
    Write-Host "已为专用配置关闭浏览器 DoH（DNS 交由 VPN 隧道解析）" -ForegroundColor DarkCyan
}

# ---- 5) 切时区 → 启动 → 关闭后还原 ----
$origTZ = (tzutil /g)
Write-Host ("当前系统时区: {0}" -f $origTZ) -ForegroundColor Gray
try {
    tzutil /s $winTz
    Write-Host ("已临时切换到: {0}（会话期间系统钟随出口国走，属正常）" -f $winTz) -ForegroundColor Yellow
    Write-Host "正在启动一致性 Chrome 会话……关闭该 Chrome 窗口后时区会自动还原。" -ForegroundColor Cyan
    $args = @("--user-data-dir=$profileDir", "--lang=$($lang.Split(',')[0])", "--accept-lang=$lang", "--no-first-run", "--no-default-browser-check")
    Start-Process -FilePath $Chrome -ArgumentList $args -Wait
}
finally {
    tzutil /s $origTZ
    Write-Host ("时区已还原为: {0}" -f (tzutil /g)) -ForegroundColor Green
}
Write-Host "会话结束。建议关闭前在目标平台点一次登出，避免会话 cookie 跨时区复用。" -ForegroundColor DarkGray


