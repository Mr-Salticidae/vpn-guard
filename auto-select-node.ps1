<#
  auto-select-node.ps1  —  自动节点筛选与调配   (vpn-guard v1.1.0)

  在安全性前提下自动找到最优代理节点并切换。
  通过 mihomo named pipe API 通信，渐进式筛选：

    第一轮  延迟预筛     全部节点 → 保留 Top N
    第二轮  安全性测试    Top N → 淘汰 proxy/hosting 标记、出口轮换与推断为机房的节点
                        （「未识别」不淘汰）
    第三轮  带宽测试      安全通过的节点 → 按 TLS 握手 + 吞吐评分
    最终    自动部署      切换到综合评分最高的节点

  安全优先：被标记为 proxy / hosting(机房) 的节点直接淘汰（可用 -AllowProxy /
  -AllowHosting 放宽）。安全性是硬门槛，带宽和延迟只用于在安全节点间排序。

  出口轮换检测：同一节点连续探测多次出口 IP，若前后不一致，说明它背后是一个
  负载均衡 / 多出口池。这类节点有两层危害，且在客户端面板里与普通节点完全无法区分：
    1. 出口被大量账号共享 —— 平台按 IP 聚类，一个号出事整簇连坐；
    2. 你自己的会话在 IP / 国家间漂移 —— 直接触发异地登录风控。
  默认淘汰，用 -AllowRotating 放宽。

  出口归属分类：ip-api 的 hosting=false 只说明「它没被标记」，不等于住宅 —— 小主机商
  大多没被收录。用它已经返回、脚本一直没读的 as / asname 字段解析出 ASN，按分配年代
  判断出口是不是住宅段（16 位 ASN 空间 2014 年前后耗尽，家宽运营商全在那之前拿号）。
  淘汰是「相对」的：只有池中还留得下非机房节点时，机房节点才被剔除 —— 全池都是机房
  时门槛整体让位，绝不会把候选池清空。用 -AllowDatacenter 关闭，-PreferResidential 让住宅优先。

  用法：
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -DryRun       # 只测不切
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -TopN 15      # 延迟预筛保留 15 个
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -Group "国外媒体"
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowHosting # 允许机房 IP
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -IpProbes 3   # 每节点探 3 次出口
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowRotating # 允许轮换出口
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowDatacenter   # 不按出口归属淘汰
    powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -PreferResidential # 住宅出口优先
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
    [int]   $IpProbes    = 2,               # 每节点探测出口 IP 的次数（1 = 关闭轮换检测）
    [int]   $ProbeGapMs  = 2500,            # 两次出口探测之间的间隔 (ms)
    [switch]$AllowProxy,                    # 允许 proxy 标记的节点
    [switch]$AllowHosting,                  # 允许机房 IP
    [switch]$AllowRotating,                 # 允许出口轮换（负载均衡池）的节点
    [switch]$AllowDatacenter,               # 允许推断为机房/主机商的出口（关闭归属淘汰）
    [switch]$PreferResidential,             # 住宅出口优先（只重排序，不淘汰、不改评分）
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

# 单次出口探测。每个 curl 进程都是一条独立连接、不复用连接池，
# 所以轮换型出口（负载均衡 / 多出口池）会在多次探测之间给出不同的 IP。
function Get-ExitInfo([string]$fields) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        # 回退到 Invoke-RestMethod
        try { return Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=$fields" -TimeoutSec 12 } catch { return $null }
    }
    $raw = & curl.exe -s --max-time 12 "http://ip-api.com/json/?fields=$fields" 2>$null
    try { return "$raw" | ConvertFrom-Json } catch { return $null }
}

# ==== 出口归属分类：住宅/消费级 vs 机房/主机商（纯离线，零额外网络请求）====
#
# 判据的核心是一条结构性事实，不是一张会过期的名单：
#   16 位 ASN 空间 (1-65535) 在 2014 年前后被各 RIR 分配殆尽。做家用宽带必须先有
#   巨量地址和多年运营历史，所以各国消费级运营商全部在那之前就拿到了号段
#   （中华电信 3462 / KT 4766 / SoftBank 17676 / HKT 4760 / SingNet 3758 / Comcast 7922）。
#   反过来，32 位 ASN (>= 65536) 绝大多数是 2014 年后新注册的小主机商、中转商
#   或机场自建 AS。IPv4 与 16 位 ASN 都已耗尽 —— 这条分界线不会再移动，不会腐坏。
#
# 数据全部来自第 206 行那一次 ip-api 请求：as 字段一直在取却从未被读过，
# asname 是同一次请求里免费多带回来的字段。不占用 45 次/分钟 的限流预算。
#
# 三态，且「未识别」是默认值、不含任何负面含义：
#   residential  名单命中 —— 正面结论
#   unknown      判据不足 —— 永远保留，绝不淘汰
#   datacenter   推断为机房/主机商 —— 交由主流程的「相对淘汰」处理

# 消费级运营商 ASN 名单。只能「提升」，永远不会「降级」：查不到 = unknown = 保留。
# 因此名单过期只损失召回（住宅被标成未识别），不可能造成误杀 —— 这一点由
# 「删掉中华电信条目后它仍判为 unknown」的回归用例锁定，不是口头保证。
# 名单唯一不可替代的用途，是救确实持有 32 位 ASN 的新入场正规运营商。
$script:ResidentialAsn = @{
    '3462'   = 'TW 中华电信 HiNet'      ; '4780'   = 'TW 数位联合 Seednet'
    '9924'   = 'TW 台湾固网 TFN'        ; '17421'  = 'TW 亚太电信 APT'
    '24158'  = 'TW 台湾大哥大'
    '4760'   = 'HK HKT / Netvigator'    ; '9269'   = 'HK 香港宽频 HKBN'
    '9304'   = 'HK HGC 环球全域'        ; '4515'   = 'HK HKT STAR'
    '9908'   = 'HK 有线宽频'            ; '17444'  = 'HK 中国移动香港'
    '4609'   = 'MO 澳门电讯 CTM'
    '4713'   = 'JP NTT OCN'             ; '2516'   = 'JP KDDI au'
    '17676'  = 'JP SoftBank'            ; '2527'   = 'JP Sony So-net'
    '2518'   = 'JP BIGLOBE'             ; '4685'   = 'JP ASAHI Net'
    '2497'   = 'JP IIJ'                 ; '9605'   = 'JP NTT docomo'
    '9824'   = 'JP J:COM'               ; '17511'  = 'JP OPTAGE eo'
    '18126'  = 'JP 中部电话 CTC'        ; '7679'   = 'JP QTNet BBIQ'
    '138384' = 'JP 乐天移动 Rakuten Mobile (32 位 ASN 例外)'
    '4766'   = 'KR KT Olleh'            ; '9318'   = 'KR SK Broadband'
    '3786'   = 'KR LG DACOM'            ; '17858'  = 'KR LG Powercomm'
    '9644'   = 'KR SK Telecom'
    '3758'   = 'SG SingNet'             ; '9506'   = 'SG Singtel 宽带'
    '4657'   = 'SG StarHub'             ; '4773'   = 'SG M1'
    '4788'   = 'MY TM Unifi'            ; '9930'   = 'TH TOT'
    '17552'  = 'TH True Internet'       ; '45758'  = 'TH 3BB'
    '7713'   = 'ID Telkom Indonesia'    ; '23693'  = 'ID Telkomsel'
    '9299'   = 'PH PLDT'                ; '4775'   = 'PH Globe Telecom'
    '45899'  = 'VN VNPT'                ; '7552'   = 'VN Viettel'
    '18403'  = 'VN FPT Telecom'
    '55836'  = 'IN Reliance Jio'        ; '24560'  = 'IN Bharti Airtel'
    '9829'   = 'IN BSNL'                ; '55577'  = 'IN ACT Fibernet'
    '17488'  = 'IN Hathway'
    '4134'   = 'CN 中国电信'            ; '4837'   = 'CN 中国联通'
    '9808'   = 'CN 中国移动'            ; '4808'   = 'CN 联通北方'
    '7922'   = 'US Comcast'             ; '7018'   = 'US AT&T'
    '701'    = 'US Verizon'             ; '6167'   = 'US Verizon Wireless'
    '20115'  = 'US Charter Spectrum'    ; '11427'  = 'US Spectrum'
    '22773'  = 'US Cox'                 ; '21928'  = 'US T-Mobile'
    '209'    = 'US CenturyLink / Lumen' ; '5650'   = 'US Frontier'
    '6128'   = 'US Optimum'             ; '812'    = 'CA Rogers'
    '577'    = 'CA Bell'                ; '852'    = 'CA Telus'
    '2856'   = 'GB BT'                  ; '5607'   = 'GB Sky Broadband'
    '5089'   = 'GB Virgin Media'        ; '13285'  = 'GB TalkTalk'
    '12576'  = 'GB EE'                  ; '13037'  = 'GB Zen Internet'
    '206067' = 'GB Three UK (32 位 ASN 例外)'
    '3320'   = 'DE Deutsche Telekom'    ; '3209'   = 'DE Vodafone DE'
    '6805'   = 'DE Telefonica O2 DE'    ; '8422'   = 'DE NetCologne'
    '3215'   = 'FR Orange'              ; '12322'  = 'FR Free / Proxad'
    '15557'  = 'FR SFR'                 ; '3269'   = 'IT Telecom Italia'
    '12874'  = 'IT Fastweb'             ; '3352'   = 'ES Telefonica'
    '6739'   = 'ES Vodafone ONO'        ; '1136'   = 'NL KPN'
    '6830'   = 'EU Liberty Global / UPC'; '3301'   = 'SE Telia'
    '1221'   = 'AU Telstra'             ; '7474'   = 'AU Optus'
    '4739'   = 'AU iiNet / TPG'         ; '4771'   = 'NZ Spark'
}

# 可选侧车文件：与脚本同目录的 residential-asn.txt，每行 "AS1234  # 备注"。
# 只增不改判定逻辑；文件缺失、编码错误、垃圾行一律安静忽略。
# 它永远只能让节点更容易被保留，不可能让节点被误杀 —— 这是名单防腐的主要手段：
# 脚本对每个节点（无论通过与否）都打印 AS 号，用户从自己的运行日志里收割条目
# 写进这个文件即可，不必改脚本，也不必等上游更新。
# $PSScriptRoot 只在「以脚本文件形式运行」时有值；被 dot-source 进别的上下文或用
# Invoke-Expression 执行时它是空的，Join-Path 会产出空串、Test-Path 随即报错。
# 正常 -File 运行不会走到这条分支，但守住它才能让这段代码可被单独载入测试。
$script:ResidentialAsnFile = ''
if ($PSScriptRoot) { $script:ResidentialAsnFile = Join-Path $PSScriptRoot 'residential-asn.txt' }
if ($script:ResidentialAsnFile -and (Test-Path $script:ResidentialAsnFile)) {
    foreach ($line in @(Get-Content $script:ResidentialAsnFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*(?:AS)?(\d+)\s*(?:#\s*(.*?))?\s*$') {
            $note = '用户自定义'
            if ($Matches[2]) { $note = $Matches[2] }
            $script:ResidentialAsn[$Matches[1]] = $note
        }
    }
}

# 亚太国家码：只有落地在这些国家时，欧洲 (RIPE) 段才构成「租用段」信号。
$script:ApacCc = @('JP','TW','HK','SG','KR','IN','CN','MO','TH','MY','VN','PH','ID','AU','NZ')
# RIPE (欧洲) 独占的 /8 段首字节区间。IPv4 已耗尽，这张表同样不会再变。
$script:RipeOctets = @(@(62,62),@(77,95),@(176,176),@(178,178),@(185,185),
                       @(188,188),@(193,195),@(212,213),@(217,217))

# 机房 / 主机商词表。刻意不含裸词 "data"。
# 起因是中华电信的 AS 机构名就叫 "Data Communication Business Group" —— 但它本身不会因此
# 被误杀：AS3462 在名单里，第 1 步就短路返回了，根本走不到词表；就算走到，同一串里的
# "Communication" 也会命中运营商词表把分数抵消回去。
# 真正的风险是更广的一类：持 16 位号段、不在名单里、名字带 data 却不含任何运营商词的
# 正规运营商（"Datacom" 之类），加了裸 data 就会被凭空判成机房。
# 往这张表里加词之前，跑 verify-classifier.sh —— 它有一条专门守这个的哨兵。
$script:RxHosting = '(?i)hosting|\bhosts?\b|datacent|data\s*cent(er|re)|colocat|\bcolo\b|\bidc\b|\bcloud|\bservers?\b|\bdedicated\b|\bvps\b|\bvds\b|\bcdn\b|anycast|\btransit\b|carrier[- ]?neutral|bare\s?metal'
# 运营商词表 —— 全脚本唯一的减分项，用来救持有 32 位 ASN 的新入场正规运营商
# （乐天移动靠 "Mobile"，Three UK 的机构名 "Hutchison 3G UK Limited" 只能靠 3G 认出来）。
# \b[2-6]G\b 刻意不写成 \d\s*G\b：后者会把 "100G Network" 这类中转商也一并放行。
$script:RxCarrier = '(?i)telecom|telekom|telecommunicat|telecomunica|\bcommunications?\b|\bmobile\b|broadband|\bcable\s*(tv|television)\b|wireless|cellular|fib(er|re)|\bftth\b|\bdsl\b|\b[2-6]G\b|\blte\b|internet\s*service\s*provider|netvigator|\bhinet\b|\bcatv\b|residential'

# 返回 @{ class; rank; label; asn; asOrg; note; score; signals }
# rank 用于排序：0 住宅 < 1 未识别 < 2 机房
function Get-ExitClass {
    param(
        [string]$AsField,   # ip-api 的 as 字段，如 "AS131939 IPS INC"
        [string]$AsName,    # ip-api 的 asname 字段，如 "APNIC-ASBLOCK-131478"
        [string]$Isp,       # ip-api 的 isp 字段
        [string]$Ip,        # 出口 IP
        [string]$Cc         # 国家码
    )

    $r = @{
        class = 'unknown'; rank = 1; label = '未识别'
        asn = 0; asOrg = ''; note = ''; score = 0; signals = @()
    }

    if ("$AsField" -match '^\s*AS(\d+)\s*(.*)$') {
        # [long] 而非 [int]：ASN 空间到 4294967295，超过 [int] 上限会抛异常并被脚本头部的
        # SilentlyContinue 静默吃掉，$r.asn 保持 0 从而退化成 unknown（方向安全，但白白丢掉判据）。
        $r.asn   = [long]$Matches[1]
        $r.asOrg = $Matches[2].Trim()
    }

    # 没有 AS 号就没有判据 —— 保持 unknown，绝不淘汰。
    if ($r.asn -le 0) {
        $r.signals += 'ip-api 未返回 AS 号 —— 无判据'
        return $r
    }

    # 1) 名单命中 = 确定住宅，直接短路，不再走任何词表。
    #    这一步必须排在词表之前：中华电信的 AS 名含 "Data"，先短路才能保证
    #    以后任何人往词表里加词都碰不到它。
    if ($script:ResidentialAsn.ContainsKey([string]$r.asn)) {
        $r.class   = 'residential'
        $r.rank    = 0
        $r.label   = '住宅/消费级'
        $r.note    = $script:ResidentialAsn[[string]$r.asn]
        $r.signals += ('名单命中 AS{0}' -f $r.asn)
        return $r
    }

    $text = ("{0} {1} {2}" -f $Isp, $r.asOrg, $AsName).Trim()

    # 2a) 分配年代 —— 主判据
    if ($r.asn -ge 65536) {
        $r.score += 3
        $r.signals += ('32 位 ASN (AS{0}) —— 2014 年后新注册，做不了家宽' -f $r.asn)
        if ($r.asn -ge 200000) {
            $r.score += 1
            $r.signals += '号段极新 (>= 200000)'
        }
    } else {
        $r.signals += ('16 位 ASN (AS{0}) —— 老号段' -f $r.asn)
    }

    # 2b) 跨注册局落地：欧洲 (RIPE) 段却定位在亚太 = 典型的买 / 租 IP 段。
    #     必须带国家码条件 —— 德国本土的 91.x 不能触发。
    if ($Cc -and ($script:ApacCc -contains "$Cc".ToUpper())) {
        $oct = 0
        if ("$Ip" -match '^(\d{1,3})\.') { $oct = [int]$Matches[1] }
        foreach ($rg in $script:RipeOctets) {
            if ($oct -ge $rg[0] -and $oct -le $rg[1]) {
                $r.score += 2
                $r.signals += ('欧洲 (RIPE) 段 {0}.x 却落地在 {1} —— 租用段特征' -f $oct, $Cc)
                break
            }
        }
    }

    # 2c) 机构名含机房词
    if ($text -match $script:RxHosting) {
        $r.score += 3
        $r.signals += ('机构名含机房词「{0}」' -f $Matches[0])
    }

    # 2d) AS-NAME 仍是 RIR 占位符（如 APNIC-ASBLOCK-131478）：
    #     连正式 AS 名都没在注册局登记，是极小号段的旁证。
    if ("$AsName" -match 'ASBLOCK') {
        $r.score += 1
        $r.signals += ('AS-NAME 仍是 RIR 占位符 ({0})' -f $AsName)
    }

    # 2e) 机构名含运营商词 —— 唯一减分项，救 32 位 ASN 的正规运营商。
    if ($text -match $script:RxCarrier) {
        $r.score -= 3
        $r.signals += ('机构名含运营商词「{0}」' -f $Matches[0])
    }

    if ($r.score -ge 3) {
        $r.class = 'datacenter'
        $r.rank  = 2
        $r.label = '机房/主机商 (推断)'
    }
    return $r
}

# 安全性测试：切换到指定节点 → 多次探测出口 IP → 检查 proxy/hosting 标记与出口轮换
function Test-NodeSecurity([string]$nodeName) {
    # 切换节点
    Switch-ProxyNode $Group $nodeName | Out-Null
    Start-Sleep -Milliseconds 1500  # 等待切换生效

    # asname 与 as 同属一次请求，不额外消耗配额。as 字段脚本一直在取却从未解析。
    $result = Get-ExitInfo 'status,country,countryCode,city,timezone,offset,isp,as,asname,query,proxy,hosting'
    if (-not $result) { return @{ ok=$false; reason='出口 IP 查询失败'; exitClass='unknown' } }
    if ($result.status -ne 'success') { return @{ ok=$false; reason='节点无法连接'; exitClass='unknown' } }

    $cls = Get-ExitClass -AsField $result.as -AsName $result.asname -Isp $result.isp -Ip $result.query -Cc $result.countryCode

    $sec = @{
        ok           = $true
        ip           = $result.query
        country      = $result.country
        cc           = $result.countryCode
        city         = $result.city
        isp          = $result.isp
        timezone     = $result.timezone
        offset       = $result.offset
        proxy        = [bool]$result.proxy
        hosting      = [bool]$result.hosting
        ips          = @($result.query)          # 本轮探到的全部不同出口 IP
        ccs          = @($result.countryCode)    # 本轮探到的全部不同出口国家
        rotating     = $false
        multiCountry = $false
        probesOk     = 1
        probeSkipped = $false
        exitClass    = $cls.class      # residential / unknown / datacenter
        exitRank     = $cls.rank       # 0 住宅 < 1 未识别 < 2 机房
        exitAsn      = $cls.asn
        exitAsOrg    = $cls.asOrg
        exitNote     = $cls.note
        exitSignals  = $cls.signals
    }

    # 短路：该节点已因 proxy / hosting 注定淘汰时，复探不再产生任何决策价值 ——
    # 轮换与否都改变不了结果，只会白白多等 ($IpProbes-1) × $ProbeGapMs。
    # 条件必须带上 -Allow* 开关：加了 -AllowHosting 时机房节点会继续进入排序，
    # 那时「它是不是负载均衡池」依然是需要知道的信息，不能跳。
    $doomed = (($sec.proxy -and -not $AllowProxy) -or ($sec.hosting -and -not $AllowHosting))
    $sec.probeSkipped = $doomed

    # 复探：只问 IP 和国家，字段更少、开销更小。
    # 关键性质——复探失败（超时 / ip-api 限流）一律跳过，绝不据此淘汰节点：
    # 只有真的探到了「不同的 IP」才判为轮换，宁可漏判也不误杀。
    if (-not $doomed) {
        for ($p = 2; $p -le $IpProbes; $p++) {
            Start-Sleep -Milliseconds $ProbeGapMs
            $again = Get-ExitInfo 'status,query,countryCode'
            if (-not $again -or $again.status -ne 'success' -or -not $again.query) { continue }
            $sec.probesOk++
            if ($sec.ips -notcontains $again.query)      { $sec.ips += $again.query }
            if ($again.countryCode -and ($sec.ccs -notcontains $again.countryCode)) { $sec.ccs += $again.countryCode }
        }
    }
    $sec.rotating     = ($sec.ips.Count  -gt 1)
    $sec.multiCountry = ($sec.ccs.Count  -gt 1)

    # 安全性判定。轮换排在最前：它同时踩中「出口被多账号共享」与「会话跨 IP/ 跨国漂移」
    # 两个高权重风控因素，比单纯的机房标记更致命。
    if ($sec.multiCountry -and -not $AllowRotating) {
        $sec.ok = $false
        $sec.reason = ('出口跨国轮换 ({0} 个 IP / {1} 个国家: {2})' -f $sec.ips.Count, $sec.ccs.Count, ($sec.ccs -join ', '))
    } elseif ($sec.rotating -and -not $AllowRotating) {
        $sec.ok = $false
        $sec.reason = ('出口轮换 / 负载均衡池 ({0} 次探测得到 {1} 个不同 IP)' -f $sec.probesOk, $sec.ips.Count)
    } elseif ($sec.proxy -and -not $AllowProxy) {
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
if ($IpProbes -gt 1) {
    if (-not $AllowRotating) { Info ("出口轮换 (负载均衡池) 将被淘汰 —— 每节点探 {0} 次出口 IP (加 -AllowRotating 放宽)" -f $IpProbes) }
    Info ("轮换检测最多增加 {0:N0} 秒 —— 已因 proxy/机房注定淘汰的节点会跳过复探 (加 -IpProbes 1 关闭)" -f ($topLatency.Count * ($IpProbes - 1) * ($ProbeGapMs / 1000)))
} else {
    Info "出口轮换检测已关闭 (-IpProbes 1)"
}
if (-not $AllowDatacenter) { Info "非住宅 ASN (推断为机房/主机商) 将被淘汰 —— 但仅在池中还留得下非机房节点时才执行 (加 -AllowDatacenter 关闭)" }
if ($PreferResidential)    { Info "已开启住宅优先 —— 排序时住宅出口整体排在未识别出口之前" }

$secureNodes = @()
$eliminated = @()

foreach ($n in $topLatency) {
    Write-Host ""
    Info ("[测试] {0}" -f $n.name)
    $sec = Test-NodeSecurity $n.name

    if (-not $sec.ok) {
        # 被淘汰的节点也打出口与 ISP：判断「这个机场在哪些地区租的是机房」需要这些字符串，
        # 只打一句「淘汰: 机房 IP」是看不出规律的。
        if ($sec.ip) {
            Info ("出口: {0} ({1} / {2}, {3})" -f $sec.ip, $sec.city, $sec.country, $sec.cc)
            Info ("ISP : {0}" -f $sec.isp)
            Info ("ASN : AS{0} {1}" -f $sec.exitAsn, $sec.exitAsOrg)
        }
        Bad ("淘汰: {0}" -f $sec.reason)
        $eliminated += @{ name=$n.name; reason=$sec.reason; delay=$n.delay; ip=$sec.ip; isp=$sec.isp; cc=$sec.cc; asn=$sec.exitAsn; exitClass=$sec.exitClass }
        continue
    }

    Info ("出口: {0} ({1} / {2}, {3})" -f $sec.ip, $sec.city, $sec.country, $sec.cc)
    Info ("ISP : {0}" -f $sec.isp)
    Info ("ASN : AS{0} {1}" -f $sec.exitAsn, $sec.exitAsOrg)
    Info ("时区: {0} (UTC{1:+0;-0}:00)" -f $sec.timezone, ($sec.offset/3600))

    if ($sec.rotating) {
        Warn ("出口轮换 —— {0} 次探测得到 {1} 个不同 IP: {2} (已因 -AllowRotating 保留)" -f $sec.probesOk, $sec.ips.Count, ($sec.ips -join ', '))
    } elseif ($IpProbes -gt 1 -and -not $sec.probeSkipped) {
        if ($sec.probesOk -gt 1) {
            Ok ("出口稳定 —— {0} 次探测均为 {1}" -f $sec.probesOk, $sec.ip)
        } else {
            Warn "复探未成功 (超时或限流) —— 本节点的轮换检测未生效，结果按未检测处理"
        }
    }

    if ($sec.proxy) {
        Warn "被标记为 proxy —— 部分平台会据此拦截 (已因 -AllowProxy 保留)"
    } else { Ok "未被标记为 proxy" }

    if ($sec.hosting) {
        Warn "被标记为机房 IP —— 高风控平台常拦截 (已因 -AllowHosting 保留)"
    } else { Ok "未被标记为机房 IP" }

    # 出口归属：三档各用一种严重度。residential 是正面发现（绿），datacenter 是推断出的
    # 负面结论（黄），unknown 用普通灰色 —— 它是「信息缺失」不是「负面判定」，
    # 印成黄色会训练用户把它读成后者。
    if ($sec.exitClass -eq 'residential') {
        Ok ("出口归属: 住宅/消费级 —— AS{0} ({1})" -f $sec.exitAsn, $sec.exitNote)
    } elseif ($sec.exitClass -eq 'datacenter') {
        Warn ("出口归属: 推断为机房/主机商 —— {0}" -f ($sec.exitSignals -join '; '))
    } else {
        Info ("出口归属: 未识别 —— AS{0} 不在住宅名单中。「未识别」只表示没认出来，不等于机房" -f $sec.exitAsn)
    }

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
        ips      = $sec.ips
        rotating = $sec.rotating
        probesOk = $sec.probesOk
        # 这是手工维护的再投影：漏掉哪个字段，它就会在 Step 3、结果表和部署摘要里
        # 静默消失，不报任何错。加字段时必须同步这里。
        exitClass   = $sec.exitClass
        exitRank    = $sec.exitRank
        exitAsn     = $sec.exitAsn
        exitAsOrg   = $sec.exitAsOrg
        exitNote    = $sec.exitNote
        exitSignals = $sec.exitSignals
    }
}

# ==== 出口归属淘汰：延迟执行的「相对」硬门槛 ====
# 为什么不写在 Test-NodeSecurity 里就地淘汰：
#   「这是不是机房」是绝对判断，「要不要因此淘汰它」是相对判断 ——
#   只有池子里还留得下非机房节点时，淘汰机房节点才是净收益。
#   就地淘汰会把 4 个候选打成 1 个，一次误判就打成 0 个（撞上「全部淘汰」的退出分支）；
#   放到循环之后做分区，「池子被清空」这件事在结构上就不可能发生。
if (-not $AllowDatacenter -and $secureNodes.Count -gt 0) {
    $provKeep = @($secureNodes | Where-Object { $_.exitClass -ne 'datacenter' })
    $provDrop = @($secureNodes | Where-Object { $_.exitClass -eq 'datacenter' })
    if ($provDrop.Count -gt 0 -and $provKeep.Count -gt 0) {
        Write-Host ""
        Info ("出口归属淘汰: 剔除 {0} 个推断为机房的节点，池中仍有 {1} 个非机房节点" -f $provDrop.Count, $provKeep.Count)
        foreach ($d in $provDrop) {
            $rsn = ('非住宅 ASN —— AS{0} {1}' -f $d.exitAsn, $d.exitAsOrg)
            Bad ("淘汰: {0}" -f $d.name)
            Info ("  ISP : {0}" -f $d.isp)
            Info ("  依据: {0}" -f ($d.exitSignals -join '; '))
            $eliminated += @{ name=$d.name; reason=$rsn; delay=$d.delay; ip=$d.ip; isp=$d.isp; cc=$d.cc; asn=$d.exitAsn; exitClass=$d.exitClass }
        }
        $secureNodes = $provKeep
    } elseif ($provDrop.Count -gt 0) {
        Write-Host ""
        Warn ("全部 {0} 个安全节点都被推断为机房/主机商 —— 归属门槛整体让位，本轮不淘汰任何节点" -f $provDrop.Count)
        Info "这说明该机场的这个分组根本没有住宅出口。对 Claude / ChatGPT 这类高风控平台，换机场比在池内继续挑更值得。"
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
    Info "尝试: -AllowProxy 允许 proxy 标记 / -AllowHosting 允许机房 IP / -AllowRotating 允许轮换出口"
    Info "若淘汰原因大多是「出口轮换」，说明这个机场的该分组整体是负载均衡池 —— 换分组或换机场比放宽门槛更值得。"
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
    # @() 是必需的，不是风格：池里只剩 1 个节点时 Sort-Object 返回的是标量 Hashtable，
    # $ranked[0] 会退化成「按键取值」返回 $null（部署目标为空），而 $ranked.Count 返回的是
    # 该 hashtable 的键数（十几），结果表会照着打十几行空行。
    if ($PreferResidential) {
        $ranked = @($secureNodes | Sort-Object @{Expression={[int]$_.exitRank};Ascending=$true}, @{Expression={[int]$_.delay};Ascending=$true})
    } else {
        $ranked = @($secureNodes | Sort-Object { [int]$_.delay })
    }
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
        # delay 是 hashtable 的「键」，不是 Add-Member 加的属性（mbps / tls 才是）。
        # Measure-Object 只认 PSObject 属性，看不见 hashtable 键 —— 它会抛错，而错误被
        # 脚本头部的 $ErrorActionPreference='SilentlyContinue' 吞掉，$maxLat/$minLat 双双为
        # $null，于是下面的 $latNorm 恒等于 1.0：延迟那 25 分变成人人拿满的常数，
        # 实际生效的是「带宽 80% + TLS 20%」。先把值取出来再 Measure-Object 才真正生效。
        $latVals = @($bwResults | ForEach-Object { [int]$_.delay })
        $maxLat = ($latVals | Measure-Object -Maximum).Maximum
        $minLat = ($latVals | Measure-Object -Minimum).Minimum
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
    if ($PreferResidential) {
        # 住宅优先是「字典序分档」而不是加分：先分两档，档内仍按原评分排。
        # 这样它既不会凭空造出一个既不快又不住宅的赢家，也不可能清空候选池 ——
        # 池里一个住宅节点都没有时，排序结果与不加此开关完全一致。
        $ranked = @($allScored | Sort-Object @{Expression={[int]$_.exitRank};Ascending=$true}, @{Expression={[double]$_.score};Descending=$true})
    } else {
        $ranked = @($allScored | Sort-Object { [double]$_.score } -Descending)   # @() 见上方说明
    }
}
Line

# 汇总报告
Head "=== 筛选结果 ==="
Write-Host ""
Write-Host ("  {0,-4} {1,-42} {2,8} {3,10} {4,8} {5,6} {6,-3}" -f "排名", "节点", "延迟", "带宽", "TLS", "评分", "归属") -ForegroundColor DarkGray
Write-Host ("  {0}" -f ("-" * 92)) -ForegroundColor DarkGray

for ($i = 0; $i -lt $ranked.Count; $i++) {
    $n = $ranked[$i]
    $delayStr = "$($n.delay)ms"
    $bwStr = if ($n.mbps -gt 0) { "$($n.mbps)Mbps" } else { "-" }
    $tlsStr = if ($n.tls -gt 0 -and $n.tls -lt 99) { "$([math]::Round($n.tls,2))s" } else { "-" }
    $scoreStr = if ($n.score) { "$($n.score)" } else { "-" }
    $color = if ($i -eq 0) { 'Cyan' } else { 'Gray' }
    # 标记用 ASCII 而非中文：-f 按「字符数」补位，终端按「显示宽度」渲染，中文会错列。
    $clsStr = if ($n.exitClass -eq 'residential') { "R" } elseif ($n.exitClass -eq 'datacenter') { "D" } else { "?" }
    Write-Host ("  {0,-4} {1,-42} {2,8} {3,10} {4,8} {5,6} {6,-3}" -f ($i+1), $n.name, $delayStr, $bwStr, $tlsStr, $scoreStr, $clsStr) -ForegroundColor $color
}
Info "归属: R=住宅/消费级   ?=未识别 (不等于机房)   D=推断为机房/主机商"

Write-Host ""
$best = $ranked[0]
Best ("最优节点: {0}" -f $best.name)
if ($best.score) {
    Info ("评分: {0}  (延迟 {1}ms, 带宽 {2}Mbps, TLS {3:N2}s)" -f $best.score, $best.delay, $best.mbps, $best.tls)
}
Info ("出口: {0} ({1} / {2})" -f $best.ip, $best.city, $best.country)

# 部署前最后一眼：这是用户在切换发生前读到的最后一行，价值最高。
if ($best.exitClass -eq 'residential') {
    Ok ("出口归属: 住宅/消费级 —— AS{0} {1}" -f $best.exitAsn, $best.exitNote)
} elseif ($best.exitClass -eq 'datacenter') {
    Warn ("出口归属: 推断为机房/主机商 —— AS{0} {1} (已因 -AllowDatacenter 保留)" -f $best.exitAsn, $best.exitAsOrg)
} else {
    Warn ("出口归属: 未识别 —— AS{0} {1}，未确认为住宅段" -f $best.exitAsn, $best.exitAsOrg)
    $altRes = @($ranked | Where-Object { $_.exitClass -eq 'residential' })
    if ($altRes.Count -gt 0) {
        Info ("池中有已识别的住宅出口: {0} ({1})" -f $altRes[0].name, $altRes[0].isp)
        Info "  若本次是为 Claude / ChatGPT 选点，加 -PreferResidential 重跑可优先部署它"
    }
}

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
if ($best.exitClass -ne 'residential') {
    Info "  - 出口未确认为住宅段，登录 Claude / ChatGPT 前先跑 vpn-leak-audit.ps1"
}
Write-Host ""
