<#
  auto-select-node.ps1  —  自动节点筛选与调配   (vpn-guard v1.1.0)

  在安全性前提下自动找到最优代理节点并切换。
  通过 mihomo named pipe API 通信，渐进式筛选：

    第一轮  延迟预筛     全部节点 → 保留 Top N
    第二轮  安全性测试    Top N → 淘汰 proxy/hosting 标记的节点
    第三轮  带宽测试      安全通过的节点 → 按 TLS 握手 + 吞吐评分
    最终    自动部署      切换到综合评分最高的节点

  安全优先：被标记为 proxy / hosting(机房) 的节点直接淘汰（可用 -AllowProxy /
  -AllowHosting 放宽）。安全性是硬门槛，带宽和延迟只用于在安全节点间排序。

  用法：
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -DryRun       # 只测不切
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -TopN 15      # 延迟预筛保留 15 个
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -Group "国外媒体"
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowHosting # 允许机房 IP
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -NoSpeedTest  # 跳过带宽测试

  前提：Clash Verge Rev (mihomo) 正在运行，TUN 模式已开启。
  只读检查 + 节点切换（PUT /proxies），不修改任何系统设置。
#>

param(
    [string]$Group       = "国外默认",      # 目标代理组名称
    [string]$PipeName    = "verge-mihomo",  # mihomo named pipe 名称
    [int]   $TopN        = 10,              # 延迟预筛后保留的节点数
    [int]   $TopM        = 5,               # 进入带宽测试的节点数
    [int]   $DelayTimeout = 5000,           # 单节点延迟测试超时 (ms)
    [int]   $SpeedBytes  = 10485760,        # 带宽测试下载量 (10MB)
    [switch]$AllowProxy,                    # 允许 proxy 标记的节点
    [switch]$AllowHosting,                  # 允许机房 IP
    [switch]$DryRun,                         # 只测试不切换
    [switch]$NoSpeedTest                     # 跳过带宽测试
)

$ErrorActionPreference = 'SilentlyContinue'

# ==== 输出辅助（与现有脚本风格一致）====
function Line($c='-'){ Write-Host ($c * 60) -ForegroundColor DarkGray }
function Ok($m){   Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad($m){  Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Best($m){ Write-Host "  [BEST] $m" -ForegroundColor Cyan }
function Head($m){ Write-Host $m -ForegroundColor Cyan }

# ==== named pipe API 通信 ====

# 解码 chunked transfer encoding 响应体
function Dechunk-Bytes([byte[]]$bytes) {
    $ms = New-Object System.IO.MemoryStream
    $pos = 0
    while ($pos -lt $bytes.Length) {
        # 找到 \r\n 标记 chunk size 行结束
        $lineEnd = -1
        for ($i = $pos; $i -lt ($bytes.Length - 1); $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) { $lineEnd = $i; break }
        }
        if ($lineEnd -eq -1) { break }
        # 解析十六进制 chunk size（忽略 chunk extensions，即 ; 之后的部分）
        $sizeStr = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, $lineEnd - $pos).Trim()
        if ($sizeStr -match ';') { $sizeStr = ($sizeStr -split ';')[0].Trim() }
        try { $chunkSize = [Convert]::ToInt32($sizeStr, 16) } catch { break }
        if ($chunkSize -eq 0) { break }
        $pos = $lineEnd + 2
        if ($pos + $chunkSize -le $bytes.Length) {
            $ms.Write($bytes, $pos, $chunkSize)
        }
        $pos += $chunkSize + 2  # 跳过 chunk data + 尾部 \r\n
    }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# 核心：通过 named pipe 发送 HTTP 请求，返回响应体字符串
function Invoke-PipeRequest {
    param([string]$Method, [string]$Path, [string]$Body = $null, [int]$Timeout = 15000)

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
    } catch {
        return $null
    }

    # 组装 HTTP 请求
    $reqLines = @("$Method $Path HTTP/1.1", "Host: localhost", "Connection: close")
    $bodyBytes = $null
    if ($Body) {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $reqLines += "Content-Type: application/json"
        $reqLines += "Content-Length: $($bodyBytes.Length)"
    }
    $request = ($reqLines -join "`r`n") + "`r`n`r`n"
    $reqBytes = [System.Text.Encoding]::UTF8.GetBytes($request)

    $pipe.Write($reqBytes, 0, $reqBytes.Length)
    if ($bodyBytes) { $pipe.Write($bodyBytes, 0, $bodyBytes.Length) }
    $pipe.Flush()

    # 读取响应（异步 + 超时保护：NamedPipeClientStream 不支持 ReadTimeout）
    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    $startTime = [DateTime]::Now
    try {
        while ($true) {
            $elapsed = ([int]([DateTime]::Now - $startTime).TotalMilliseconds)
            if ($elapsed -ge $Timeout) { break }
            $remaining = $Timeout - $elapsed
            $ar = $pipe.BeginRead($buffer, 0, $buffer.Length, $null, $null)
            $got = $ar.AsyncWaitHandle.WaitOne($remaining, $false)
            if (-not $got) { break }  # 超时
            $read = $pipe.EndRead($ar)
            if ($read -le 0) { break }  # 连接关闭
            $ms.Write($buffer, 0, $read)
        }
    } catch {
        # 连接异常 —— 用已收到的数据继续
    }
    $pipe.Dispose()

    $allBytes = $ms.ToArray()
    if ($allBytes.Length -eq 0) { return $null }

    # 分离 HTTP 头和体
    $responseStr = [System.Text.Encoding]::UTF8.GetString($allBytes)
    $headerEnd = $responseStr.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) { return $responseStr }

    $headers = $responseStr.Substring(0, $headerEnd)
    $bodyStart = $headerEnd + 4

    # 检查 HTTP 状态码
    if ($headers -notmatch 'HTTP/1\.1\s+2\d\d') {
        return $null
    }

    # chunked 编码则解码
    if ($headers -match 'Transfer-Encoding:\s*chunked') {
        $bodyBytes = $allBytes[$bodyStart..($allBytes.Length - 1)]
        return Dechunk-Bytes $bodyBytes
    } else {
        return $responseStr.Substring($bodyStart)
    }
}

# 获取所有代理信息
function Get-ProxyInfo {
    $resp = Invoke-PipeRequest -Method 'GET' -Path '/proxies' -Timeout 10000
    if (-not $resp) { return $null }
    try { return $resp | ConvertFrom-Json } catch { return $null }
}

# 切换代理组的当前节点
function Switch-ProxyNode([string]$groupName, [string]$nodeName) {
    $encoded = [uri]::EscapeDataString($groupName)
    $body = @{ name = $nodeName } | ConvertTo-Json -Compress
    $resp = Invoke-PipeRequest -Method 'PUT' -Path "/proxies/$encoded" -Body $body -Timeout 5000
    return $null -ne $resp -or $true  # PUT 可能返回空体，不报错即视为成功
}

# 测试组内所有节点的延迟
function Test-GroupDelay([string]$groupName) {
    $encoded = [uri]::EscapeDataString($groupName)
    $testUrl = [uri]::EscapeDataString('https://www.gstatic.com/generate_204')
    $path = "/group/$encoded/delay?url=$testUrl&timeout=$DelayTimeout"
    $resp = Invoke-PipeRequest -Method 'GET' -Path $path -Timeout ([Math]::Max(30000, $DelayTimeout * 3))
    if (-not $resp) { return $null }
    try { return $resp | ConvertFrom-Json } catch { return $null }
}

# ==== 测试函数 ====

# 安全性测试：切换到指定节点 → 查询出口 IP 信息 → 检查 proxy/hosting 标记
function Test-NodeSecurity([string]$nodeName) {
    # 切换节点
    Switch-ProxyNode $Group $nodeName | Out-Null
    Start-Sleep -Milliseconds 1500  # 等待切换生效

    # 通过 curl 查询出口 IP（每个 curl 进程独立连接，不会复用旧连接池）
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        # 回退到 Invoke-RestMethod
        try {
            $result = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,as,query,proxy,hosting' -TimeoutSec 12
        } catch { return @{ ok=$false; reason='无法查询出口 IP' } }
    } else {
        $raw = & curl.exe -s --max-time 12 'http://ip-api.com/json/?fields=status,country,countryCode,city,timezone,offset,isp,as,query,proxy,hosting' 2>$null
        try { $result = "$raw" | ConvertFrom-Json } catch { return @{ ok=$false; reason='出口 IP 查询失败' } }
    }

    if (-not $result -or $result.status -ne 'success') {
        return @{ ok=$false; reason='节点无法连接' }
    }

    $sec = @{
        ok       = $true
        ip       = $result.query
        country  = $result.country
        cc       = $result.countryCode
        city     = $result.city
        isp      = $result.isp
        timezone = $result.timezone
        offset   = $result.offset
        proxy    = [bool]$result.proxy
        hosting  = [bool]$result.hosting
    }

    # 安全性判定
    if ($sec.proxy -and -not $AllowProxy) {
        $sec.ok = $false
        $sec.reason = '被标记为 proxy'
    } elseif ($sec.hosting -and -not $AllowHosting) {
        $sec.ok = $false
        $sec.reason = '机房 IP (hosting)'
    }

    return $sec
}

# 带宽测试：通过 Cloudflare 测速点测量 TLS 握手 + 下行吞吐
function Test-NodeBandwidth {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { return $null }

    $url = "https://speed.cloudflare.com/__down?bytes=$SpeedBytes"
    $raw = & curl.exe -s -o NUL -w "%{time_appconnect} %{speed_download} %{http_code}" --connect-timeout 10 -m 12 $url 2>$null
    $f = "$raw".Trim() -split '\s+'
    if ($f.Count -lt 3 -or $f[2] -notmatch '^2\d\d$') { return $null }

    return @{
        tls   = [double]$f[0]
        mbps  = [math]::Round(([double]$f[1]) * 8 / 1e6, 1)
    }
}

# ==== 主流程 ====

Write-Host ""
Head " 自动节点筛选与调配 (auto-select-node) "
Head (" 时间: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Line '='

# Step 0: 验证连接
Head "Step 0: 验证 mihomo 连接"
$allProxies = Get-ProxyInfo
if (-not $allProxies -or -not $allProxies.proxies) {
    Bad "无法连接 mihomo named pipe (\\.\pipe\$PipeName)"
    Info "请确认 Clash Verge Rev 正在运行"
    exit 1
}

# 检查 TUN 模式
$tunPat = 'tun|tap|wintun|wireguard|meta|mihomo|sing-?box'
$upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
$tunAdapters = @($upAdapters | Where-Object { $_.Name -match $tunPat -or $_.InterfaceDescription -match $tunPat })
if ($tunAdapters.Count -gt 0) {
    Ok ("TUN 模式已开启（{0}）—— 安全/带宽测试将通过隧道进行" -f $tunAdapters[0].Name)
} else {
    Warn "未检测到 TUN 网卡 —— 测试结果可能不准确（出口探测和测速可能不走代理）"
    Info "建议开启 Clash Verge 的 TUN 模式后重跑"
}

# 找到目标代理组
$groupProxy = $allProxies.proxies.$Group
if (-not $groupProxy) {
    Bad "找不到代理组: $Group"
    Info "可用代理组:"
    $allProxies.proxies.PSObject.Properties | Where-Object { $_.Value.type -match 'Selector|URLTest|Fallback|LoadBalance' } | ForEach-Object {
        Info ("  {0} (type={1}, {2} 个节点)" -f $_.Name, $_.Value.type, ($_.Value.all.Count))
    }
    exit 1
}

$nodes = @($groupProxy.all | Where-Object { $_ -ne 'DIRECT' -and $_ -ne 'REJECT' })
$originalNode = $groupProxy.now

Ok ("代理组 : {0} ({1} 个节点)" -f $Group, $nodes.Count)
Info ("当前节点: {0}" -f $originalNode)
if ($DryRun) { Warn "DryRun 模式 —— 只测试不切换，结束后还原原节点" }
Line

# Step 1: 延迟预筛
Head "Step 1: 延迟预筛 (全部 $($nodes.Count) 节点)"
Info "测试中 (https://www.gstatic.com/generate_204, 超时 ${DelayTimeout}ms)..."

$delayResult = Test-GroupDelay $Group
if (-not $delayResult) {
    Bad "延迟测试失败 —— 无法通过 API 获取组延迟"
    Info "尝试检查 mihomo 是否支持 /group/{name}/delay 端点"
    exit 1
}

# 解析延迟结果：响应是 PSCustomObject，属性名=节点名，属性值=延迟(ms)
$latencies = @()
foreach ($node in $nodes) {
    $delay = $null
    try {
        $val = $delayResult.$node
        if ($val -is [int] -or $val -is [long]) { $delay = [int]$val }
        elseif ($val.delay) { $delay = [int]$val.delay }
    } catch {}
    if ($delay -and $delay -gt 0) {
        $latencies += @{ name=$node; delay=$delay }
    }
}

if ($latencies.Count -eq 0) {
    Bad "所有节点延迟测试均失败 —— 请检查网络连接或节点是否在线"
    exit 1
}

# 按延迟排序，取 Top N
$topLatency = $latencies | Sort-Object { [int]$_.delay } | Select-Object -First $TopN
Ok ("{0}/{1} 个节点响应" -f $latencies.Count, $nodes.Count)
$failedCount = $nodes.Count - $latencies.Count
if ($failedCount -gt 0) { Warn "$failedCount 个节点超时或无响应" }

Info ""
Info ("Top {0} (按延迟排序):" -f $topLatency.Count)
for ($i = 0; $i -lt $topLatency.Count; $i++) {
    $n = $topLatency[$i]
    Write-Host ("  {0,2}. {1,-44} {2}ms" -f ($i+1), $n.name, $n.delay) -ForegroundColor Gray
}
Line

# Step 2: 安全性测试
Head "Step 2: 安全性测试 (Top $($topLatency.Count) 节点)"
if (-not $AllowProxy)   { Info "proxy 标记的节点将被淘汰 (加 -AllowProxy 放宽)" }
if (-not $AllowHosting) { Info "机房 IP (hosting) 将被淘汰 (加 -AllowHosting 放宽)" }

$secureNodes = @()
$eliminated = @()

foreach ($n in $topLatency) {
    Write-Host ""
    Info ("[测试] {0}" -f $n.name)
    $sec = Test-NodeSecurity $n.name

    if (-not $sec.ok) {
        Bad ("淘汰: {0}" -f $sec.reason)
        $eliminated += @{ name=$n.name; reason=$sec.reason; delay=$n.delay }
        continue
    }

    Info ("出口: {0} ({1} / {2}, {3})" -f $sec.ip, $sec.city, $sec.country, $sec.cc)
    Info ("ISP : {0}" -f $sec.isp)
    Info ("时区: {0} (UTC{1:+0;-0}:00)" -f $sec.timezone, ($sec.offset/3600))

    if ($sec.proxy) {
        Warn "被标记为 proxy —— 部分平台会据此拦截 (已因 -AllowProxy 保留)"
    } else { Ok "未被标记为 proxy" }

    if ($sec.hosting) {
        Warn "被标记为机房 IP —— 高风控平台常拦截 (已因 -AllowHosting 保留)"
    } else { Ok "未被标记为机房 IP" }

    # 时区一致性（仅提示，不淘汰）
    $sysOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds
    if ([math]::Abs($sysOffset - $sec.offset) -ge 3600) {
        $diff = ($sec.offset - $sysOffset)/3600
        Warn ("时区差异 {0:+0;-0} 小时 —— 用 browse-vpn / app-vpn 对齐浏览器指纹" -f $diff)
    } else {
        Ok "时区与系统一致"
    }

    $secureNodes += @{
        name     = $n.name
        delay    = $n.delay
        ip       = $sec.ip
        country  = $sec.country
        cc       = $sec.cc
        city     = $sec.city
        isp      = $sec.isp
        timezone = $sec.timezone
        offset   = $sec.offset
        proxy    = $sec.proxy
        hosting  = $sec.hosting
    }
}

Write-Host ""
Ok ("安全通过: {0}/{1}" -f $secureNodes.Count, $topLatency.Count)
if ($eliminated.Count -gt 0) {
    Info "淘汰原因:"
    foreach ($e in $eliminated) {
        Info ("  {0}: {1}" -f $e.name, $e.reason)
    }
}

if ($secureNodes.Count -eq 0) {
    Write-Host ""
    Bad "所有节点均未通过安全检测"
    Info "尝试: -AllowProxy 允许 proxy 标记 / -AllowHosting 允许机房 IP"
    # 还原原节点
    Switch-ProxyNode $Group $originalNode | Out-Null
    Info "已还原到原节点: $originalNode"
    exit 1
}
Line

# Step 3: 带宽测试
$ranked = @()
if ($NoSpeedTest) {
    Head "Step 3: 带宽测试 (已跳过)"
    Info "仅按延迟排序"
    foreach ($sn in $secureNodes) {
        $sn | Add-Member -NotePropertyName tls -NotePropertyValue 0.0 -ErrorAction SilentlyContinue
        $sn | Add-Member -NotePropertyName mbps -NotePropertyValue 0.0 -ErrorAction SilentlyContinue
        $sn | Add-Member -NotePropertyName score -NotePropertyValue 0.0 -ErrorAction SilentlyContinue
    }
    $ranked = $secureNodes | Sort-Object { [int]$_.delay }
} else {
    $bwCount = [Math]::Min($TopM, $secureNodes.Count)
    $bwCandidates = $secureNodes | Sort-Object { [int]$_.delay } | Select-Object -First $bwCount
    Head "Step 3: 带宽测试 ($bwCount 个安全节点)"
    Info ("实测中 (Cloudflare 测速点, {0:N1}MB / 节点)..." -f ($SpeedBytes / 1MB))

    $bwResults = @()
    foreach ($n in $bwCandidates) {
        # 确保切换到该节点
        Switch-ProxyNode $Group $n.name | Out-Null
        Start-Sleep -Milliseconds 1500

        $bw = Test-NodeBandwidth
        Write-Host ""
        Info ("[测试] {0}" -f $n.name)
        if (-not $bw) {
            Warn "测速失败 —— 节点可能不稳定"
            $n | Add-Member -NotePropertyName tls -NotePropertyValue 99.0
            $n | Add-Member -NotePropertyName mbps -NotePropertyValue 0.0
        } else {
            if     ($bw.tls -le 0.5) { Ok   ("TLS 握手 {0:N2}s, 下行 {1} Mbps" -f $bw.tls, $bw.mbps) }
            elseif ($bw.tls -le 2.0) { Warn ("TLS 握手 {0:N2}s (偏慢), 下行 {1} Mbps" -f $bw.tls, $bw.mbps) }
            else                     { Bad  ("TLS 握手 {0:N2}s (拥塞), 下行 {1} Mbps" -f $bw.tls, $bw.mbps) }
            $n | Add-Member -NotePropertyName tls -NotePropertyValue $bw.tls
            $n | Add-Member -NotePropertyName mbps -NotePropertyValue $bw.mbps
        }
        $bwResults += $n
    }

    # 未测带宽的安全节点也保留（排后面）
    $untested = $secureNodes | Where-Object { $bwCandidates.name -notcontains $_.name }
    foreach ($n in $untested) {
        $n | Add-Member -NotePropertyName tls -NotePropertyValue 99.0
        $n | Add-Member -NotePropertyName mbps -NotePropertyValue 0.0
    }

    # 评分：带宽 60% + 延迟 25% + TLS 15%（归一化到候选池）
    $allScored = @($bwResults) + @($untested)
    if ($bwResults.Count -gt 0) {
        $maxBw = ($bwResults | Measure-Object mbps -Maximum).Maximum
        $minBw = ($bwResults | Measure-Object mbps -Minimum).Minimum
        $maxLat = ($bwResults | Measure-Object delay -Maximum).Maximum
        $minLat = ($bwResults | Measure-Object delay -Minimum).Minimum
        $maxTls = ($bwResults | Measure-Object tls -Maximum).Maximum
        $minTls = ($bwResults | Measure-Object tls -Minimum).Minimum

        foreach ($n in $allScored) {
            $bwNorm  = if ($maxBw -gt $minBw) { ($n.mbps - $minBw) / ($maxBw - $minBw) } else { 1.0 }
            $latNorm = if ($maxLat -gt $minLat) { ($maxLat - $n.delay) / ($maxLat - $minLat) } else { 1.0 }
            $tlsNorm = if ($maxTls -gt $minTls) { ($maxTls - $n.tls) / ($maxTls - $minTls) } else { 1.0 }
            $score = [math]::Round($bwNorm * 60 + $latNorm * 25 + $tlsNorm * 15, 1)
            $n | Add-Member -NotePropertyName score -NotePropertyValue $score
        }
    }
    $ranked = $allScored | Sort-Object { [double]$_.score } -Descending
}
Line

# 汇总报告
Head "=== 筛选结果 ==="
Write-Host ""
Write-Host ("  {0,-4} {1,-42} {2,8} {3,10} {4,8} {5,6}" -f "排名", "节点", "延迟", "带宽", "TLS", "评分") -ForegroundColor DarkGray
Write-Host ("  {0}" -f ("-" * 88)) -ForegroundColor DarkGray

for ($i = 0; $i -lt $ranked.Count; $i++) {
    $n = $ranked[$i]
    $delayStr = "$($n.delay)ms"
    $bwStr = if ($n.mbps -gt 0) { "$($n.mbps)Mbps" } else { "-" }
    $tlsStr = if ($n.tls -gt 0 -and $n.tls -lt 99) { "$([math]::Round($n.tls,2))s" } else { "-" }
    $scoreStr = if ($n.score) { "$($n.score)" } else { "-" }
    $color = if ($i -eq 0) { 'Cyan' } else { 'Gray' }
    Write-Host ("  {0,-4} {1,-42} {2,8} {3,10} {4,8} {5,6}" -f ($i+1), $n.name, $delayStr, $bwStr, $tlsStr, $scoreStr) -ForegroundColor $color
}

Write-Host ""
$best = $ranked[0]
Best ("最优节点: {0}" -f $best.name)
if ($best.score) {
    Info ("评分: {0}  (延迟 {1}ms, 带宽 {2}Mbps, TLS {3:N2}s)" -f $best.score, $best.delay, $best.mbps, $best.tls)
}
Info ("出口: {0} ({1} / {2})" -f $best.ip, $best.city, $best.country)

# Step 4: 部署
Write-Host ""
Head "Step 4: 部署"
if ($DryRun) {
    Warn "DryRun 模式 —— 不切换节点，还原到原节点"
    Switch-ProxyNode $Group $originalNode | Out-Null
    Ok "已还原到原节点: $originalNode"
} else {
    Switch-ProxyNode $Group $best.name | Out-Null
    Start-Sleep -Milliseconds 1000
    # 验证切换
    $verify = Get-ProxyInfo
    $currentNow = $verify.proxies.$Group.now
    if ($currentNow -eq $best.name) {
        Ok "已切换到最优节点: $($best.name)"
        Info "原节点: $originalNode"
    } else {
        Bad "切换验证失败 —— 当前节点: $currentNow (期望: $($best.name))"
        Info "可能是 API 延迟，请在 Clash Verge 面板确认"
    }
}

Line '='
Write-Host ""
Info "建议后续操作:"
Info "  - 运行 vpn-leak-audit.ps1 复查安全性"
Info "  - 运行 browse-vpn.ps1 对齐浏览器时区/语言"
if ($best.offset -and [math]::Abs([System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds - $best.offset) -ge 3600) {
    Info "  - 时区差异较大，务必用 browse-vpn / app-vpn 对齐"
}
Write-Host ""
