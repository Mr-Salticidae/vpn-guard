# browse-hk.ps1 — 快捷入口：中国香港出口一致性会话
# 等价于  browse-vpn.ps1 -Country HK。可加 -DryRun 预览。
# 时区始终跟随真实出口 IP；本入口主要用于固定语言/离线兜底。
& "$PSScriptRoot\browse-vpn.ps1" -Country HK @args

