# Typeflux 图标与吉祥物探索

这是基于现有无限丝带标志制作的概念稿。用户选定 A 方向的深色底板与白色光泽无限丝带，已接入 macOS 客户端图标资源。

| 文件 | 内容 |
| --- | --- |
| `concepts-overview.png` | 三个方向及 64/32/16 px 缩小预览 |
| `logo-a-dark-sculptural.png` | A：深色底、浅色立体丝带 |
| `logo-b-flat-flow.png` | B：浅色底、左右形态有变化的平面丝带 |
| `logo-c-character.png` | C：带眼睛的角色化图标 |
| `mascot-flux.png` | 透明背景的 Flux 吉祥物 |
| `typeflux-dark-ribbon-icon-source.png` | 从 A 方向图提取的透明背景高清图 |
| `typeflux-dark-ribbon-icon-1024.png` | 最终 macOS 应用图标母版，1024×1024 PNG |
| `typeflux-dark-ribbon-preview.icns` | 最终 macOS 图标预览文件 |
| `typeflux-dark-ribbon-icon-64.png`、`typeflux-dark-ribbon-icon-32.png` | 小尺寸预览 |
| `concept-*.svg` | 三个方向的可编辑结构草图，尚非最终矢量母版 |

三种方向均为概念探索；当前采用 A 方向。

PNG 由内置 image_gen 根据现有 Typeflux 图形生成，完整提示词见 [prompts.md](prompts.md)。SVG 为手工绘制的结构草图，尚非正式矢量母版。

图标从 A 方向高清图提取，并把圆角底板校正到原图标的 824×824 像素占位。底板外透明，内部不透明，保留白色丝带的光泽与中心紫光。按应用切换器预览反馈，底板外围高亮已改为哑光深色。`app/TypefluxIcon.png` 是打包用母版；`app/Typeflux.iconset`、`app/Typeflux.icns` 和应用内帮助界面的图标也由该母版生成。iOS 图标尚未修改。
