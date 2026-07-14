# 贡献指南 / Contributing

欢迎贡献！最常见、也最受欢迎的贡献是**新增一个出口国的预设**。

## 加一个国家预设（最常见）

编辑 [`browse-vpn.ps1`](browse-vpn.ps1) 顶部两张表：

1. **`$presets`** — 国家 ISO 两字码 → Windows 时区 ID + 浏览器语言。单时区国家加一行即可：
   ```powershell
   IT = @{ tz='W. Europe Standard Time'; lang='it-IT,it' }   # 意大利
   ```
   - Windows 时区 ID 用 `tzutil /l` 查（列出所有）。
   - 语言用 BCP-47，主语言在前，可跟备选，如 `it-IT,it,en`。

2. **`$ianaToWin`**（仅多时区国家需要）— ip-api 返回的 IANA 名 → Windows 时区 ID，
   让美/加/澳这类跨时区国家能按实际节点分区选对时区：
   ```powershell
   'Europe/Rome' = 'W. Europe Standard Time'
   ```

### 验证
```powershell
# 无需真到该国节点，强制预览选型是否正确
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country IT -DryRun
```
若能真连到该国节点，实跑后在浏览器控制台确认
`Intl.DateTimeFormat().resolvedOptions().timeZone` 与出口 IP 所在时区一致，最佳。

## 几条硬性约定

- **文件编码**：所有 `.ps1` 必须存为**带 BOM 的 UTF-8**。Windows PowerShell 5.1 默认按系统 ANSI(GBK) 读无 BOM 文件，中文会乱码并解析失败。
  VS Code 右下角选 “UTF-8 with BOM”，或：
  ```powershell
  $c = Get-Content -Raw -Encoding UTF8 .\browse-vpn.ps1
  Set-Content -Path .\browse-vpn.ps1 -Value $c -Encoding UTF8   # PS5.1 写出带 BOM
  ```
- **PowerShell 5.1 兼容**：不用三元运算符 `?:`、`??`、`?.`（5.1 不支持）。
- **不改系统持久状态**：时区切换必须用 `try/finally` 保证还原；只作用于本会话。
- **隐私**：PR / issue 里**不要**出现真实出口 IP、真实 DNS、账号、本机绝对路径。用 `<xxx>` 占位。

## 设计原则（改动请遵守）

- **时区始终跟随真实出口 IP**，不跟随 `-Country`——避免制造"IP 在 A 国、时区却设成 B 国"的新矛盾。
- 审查脚本 `vpn-leak-audit.ps1` **只读**，不改任何系统设置。
