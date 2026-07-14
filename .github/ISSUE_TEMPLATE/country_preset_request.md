---
name: 新增/修正国家预设 / Country preset
about: 申请新增一个出口国的时区+语言预设，或修正现有预设
title: "[preset] "
labels: preset
---

**出口国 / Country**
<!-- 国家名 + ISO 两字码，如 日本 JP -->

**期望的时区与语言 / Desired timezone & locale**
- Windows 时区 ID（`tzutil /l` 可查，如 `Tokyo Standard Time`）：
- 浏览器语言（如 `ja-JP,ja`）：

**多时区国家？/ Multi-timezone?**
<!-- 若该国跨多个时区（美/加/澳等），请列出你用到的分区对应的 IANA 名，
     如 America/Los_Angeles → Pacific Standard Time -->

**验证 / Verified**
- [ ] 我用 `browse-vpn.ps1 -Country <XX> -DryRun` 预览过，选型正确
- [ ] （可选）实跑后 `Intl.DateTimeFormat().resolvedOptions().timeZone` 与出口 IP 一致
