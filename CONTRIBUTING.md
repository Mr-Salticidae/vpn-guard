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

## 改出口归属分类之前，先跑回归

出口归属（住宅/消费级 vs 机房/主机商）的判定逻辑分散在三个文件里，判据本身很窄、
很容易在「顺手改一下」时静默失效。动它之前和之后各跑一次：

```bash
bash tests/verify-classifier.sh    # 硬闸门，CI 里也跑；纯函数比对，不联网
```

它守着三件事：**bash 侧判定正确性**、**`.ps1` 与 `.sh` 输出逐字节一致**、
**选点器分类器的真实样本 + 两个哨兵**。已自检过能抓到改阈值、往机房词表加裸词
`data`、以及只改一版措辞这三种改动。

两个哨兵值得单独说，它们守的是「改了不报错、但结果悄悄变了」这类情况：

- **阈值哨兵**：`Pittqiao (AS131642)` 的得分**恰好等于**判定阈值 3，全靠单一的
  32 位 ASN 信号支撑。把阈值从 3 调到 4，它会静默翻成「未识别」。
- **词表陷阱哨兵**：机房词表**刻意不含裸词 `data`**。加了它，持 16 位号段、
  名字带 data 却不含运营商词的正规运营商会被凭空判成机房。

另外，ASN 名单在三个文件里各有一份拷贝（这是刻意的 —— 仓库的分发方式就是
「拷一个脚本走」，共享库文件会让分类器的正面判定依赖一个用户没有的文件）。
三份必须是同一个集合，由 `tests/verify-unix.sh` 第 11 项机械比对，漂移即硬失败。
**在 `ASN-TABLE-BEGIN` / `ASN-TABLE-END` 之间除 ASN 号外不得出现任何数字**，
说明性文字写在 BEGIN 之上。

## 几条硬性约定

- **文件编码**：所有 `.ps1` 必须存为**带 BOM 的 UTF-8**。Windows PowerShell 5.1 默认按系统 ANSI(GBK) 读无 BOM 文件，中文会乱码并解析失败。
  VS Code 右下角选 “UTF-8 with BOM”，或：
  ```powershell
  $c = Get-Content -Raw -Encoding UTF8 .\browse-vpn.ps1
  Set-Content -Path .\browse-vpn.ps1 -Value $c -Encoding UTF8   # PS5.1 写出带 BOM
  ```
- **主脚本留在根目录**：`webrtc-leak-test.html`、`residential-asn.txt` 和 Chrome 配置目录都按「脚本所在目录」定位，
  主脚本一旦挪进子目录就会找不到它们。快捷入口放 `shortcuts/`，测试放 `tests/`，它们用 `..` 指回根目录。
- **PowerShell 5.1 兼容**：不用三元运算符 `?:`、`??`、`?.`（5.1 不支持）。
- **不改系统持久状态**：时区切换必须用 `try/finally` 保证还原；只作用于本会话。
- **隐私**：PR / issue 里**不要**出现真实出口 IP、真实 DNS、账号、本机绝对路径。用 `<xxx>` 占位。

## 设计原则（改动请遵守）

- **时区始终跟随真实出口 IP**，不跟随 `-Country`——避免制造"IP 在 A 国、时区却设成 B 国"的新矛盾。
- 审查脚本 `vpn-leak-audit.ps1` **只读**，不改任何系统设置。
