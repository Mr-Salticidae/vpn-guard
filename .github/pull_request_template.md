<!-- 感谢贡献！提交前请过一遍下面的清单 -->

## 改动内容 / What
<!-- 简述这个 PR 做了什么 -->

## 类型 / Type
- [ ] 新增/修正国家预设（`$presets` / `$ianaToWin`）
- [ ] Bug 修复
- [ ] 文档
- [ ] 其它：

## 自检 / Checklist
- [ ] `.ps1` 保存为 **带 BOM 的 UTF-8**（否则 Windows PowerShell 5.1 会按 GBK 读，中文乱码导致解析失败）
- [ ] 语法检查通过：`[System.Management.Automation.Language.Parser]::ParseFile(...)` 无报错
- [ ] 若改了 `browse-vpn.ps1`，已用 `-DryRun` 验证选型正确
- [ ] **未包含任何个人隐私**（真实出口 IP、真实 DNS、账号、本机绝对路径等）
