# 封面 / 社交预览图制作记录

`social-preview.jpg`（1920×960，2:1）由「Midjourney 底图 + 代码叠字」合成：
底图用 Midjourney 出图，标题/面板用 HTML + Chrome headless 渲染叠加，最后转 JPEG。

## Midjourney 底图 prompt

> 注：Midjourney 的 v8.2 是测试功能，用 `--v 8.1 --preview` 组合即可使用。

```
abstract digital privacy atmosphere, a dark stylized world map as a faint glowing wireframe mesh, luminous cyan network meridians converging toward a single bright anchor point over east asia, thin latitude and longitude graticule dissolving into deep shadow, drifting data particles and soft signal streaks, large empty negative space in the upper-left, diagonal composition with the glow anchored lower-right, restrained composition, clear visual hierarchy, generous title-safe dark area, volumetric glow, rim lighting, deep shadow falloff, deep navy-teal and electric cyan color grading, near-black background, minimal high-end developer-tool aesthetic, cinematic wide establishing shot, shallow depth of field, intricate detail, ultra-clean --ar 2:1 --v 8.1 --preview --style raw --no text, watermark, logo, ui, letters, numbers, people, blurry, low quality
```

## 叠字合成

- 左侧：标题 `vpn-guard`（等宽字 + cyan 光晕）、中文副标、卖点、徽章；左侧加压暗 scrim 保证辨识度（暗底配浅字）。
- 右侧：`exit consistency` 终端面板，演示 IP / WebRTC / 时区 / 语言从露馅到对齐的核心故事。
- 遵循对角平衡：文字在左，底图发光网络簇在右。

重制：改底图后替换 `base-plate.png` 背景层，用 Chrome headless `--screenshot --force-device-scale-factor=1.5 --window-size=1280,640` 渲染，再转 JPEG（q90）压到 1MB 以内。

## 设为 GitHub 社交预览图（需网页端）

仓库 → Settings → General → **Social preview** → Upload an image → 选 `assets/social-preview.jpg`。
（API/CLI 无法上传社交预览图，只能网页端操作。）
