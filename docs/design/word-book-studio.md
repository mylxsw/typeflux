# 单词本 UI 重构：与主窗口统一 设计方案

> 状态：设计稿（GUL-251），待确认后实现。可交互设计稿：`docs/design/word-book-studio.html`（直接用浏览器打开），截图见 `docs/design/word-book-studio/`。取代 `docs/design/word-book-redesign.md` §2 中的 Liquid Glass 外观；功能、快捷键、数据与文案不变。

## 0. 一页结论

1. **问题**：单词本（GUL-237）用了随便问工作区的 Liquid Glass：毛玻璃底、左上蓝 / 左下紫两团径向渐变、悬浮玻璃侧栏、发光查词胶囊、底部玻璃操作条。和主窗口（概览 / 词库 / 历史 / 模型）的平铺样式完全不是一套，渐变背景尤其廉价（`0-before.png`）。
2. **方向**：单词本当作主窗口的「又一页」来画，全部用 `StudioTheme` token：平铺画布、贴边侧栏、`StudioCard` 细边框卡片、中性灰选中态。**强调色只用于焦点环、主按钮、「新词」徽标和本周柱条的「今天」**。不用渐变、光晕或玻璃。
3. **布局**：侧栏 210pt（与主窗口同宽）｜页面标题 23pt + 词数，右侧查词输入框｜列表卡片 300pt + 详情卡片。
4. **详情**：一张卡片，包含头部（元信息、30pt 词头、音标按钮、收藏）、一条固定工具栏（复制释义、朗读、问 AI、重新生成 | 删除），以及分组内容（释义、例句、近义词与词形、查词记录）。原来底部悬浮的玻璃操作条去掉。

## 1. 截图

| 文件 | 内容 |
|---|---|
| `0-before.png` | 现状（issue 附图） |
| `1-window-dark.png` / `2-window-light.png` | 有词，深色 / 浅色 |
| `3-new-word.png` | 查新词 `gregarious` 完成，「新词 · 已记入今天」 |
| `4-loading.png` | 生成单词卡中的骨架屏 |
| `5-empty.png` | 空单词本 |
| `6-plain-light.png` | 本机译文词条（未生成 AI 卡） |
| `7-narrow.png` | 900pt 窄窗口，侧栏收起为图标列 |

## 2. 改动对照

| 部位 | 现在 | 改为 | SwiftUI 落点 |
|---|---|---|---|
| 窗口背景 | `AskWindowBackdrop` + 两个 `RadialGradient` | `StudioTheme.windowBackground` 平铺 | 删除 `AskWordBookView.backdrop` |
| 侧栏 | `askInWindowGlass` 悬浮面板 | 贴边 `StudioTheme.sidebar` + 右侧 1px `border`；红绿灯下方直接是分类，不放图标和「单词本」标题 | `sidebar` |
| 导航选中 | `AskTheme.accentSoft` 蓝底 + 蓝图标 | `StudioTheme.sidebarSelection` + semibold，34pt 行高、8pt 圆角 | `shelfRow` |
| 底部统计 | 裸放 | 包进小卡片（同账户卡）；柱条中性灰，仅今天用 `accent` | `sidebarFooter` / `weekBars` |
| 标题 | 列表顶部 15pt | 内容区顶部 23pt 页面标题 + 词数（`shellContentTopInset` 区域） | 新 `pageHeader` |
| 查词栏 | `askInWindowGlassPill` 发光胶囊 | 380pt 输入框：`cardSurface`、8pt 圆角、细边框，聚焦时 accent 描边 + 3pt 柔光；方向切换是框内小按钮；本机预览是下拉弹层（含已有词前缀匹配，↑↓ 选择） | `lookupBar` / `previewLine` |
| 列表 | 铺在背景上；选中蓝底 + 蓝描边 | `StudioCard`；顶部过滤框 + 原生样式排序弹出按钮；行间内缩分隔线；选中 `sidebarSelection` | `list` / `AskWordBookRow` |
| 详情 | 半透明卡片 + 浮动操作条 | 单张 `StudioCard`；工具栏滚动时吸顶；内容分组为带边框的 grouped rows | `detailColumn` / `AskWordBookDetail` |
| 徽标 | 紫「AI 卡」、黄收藏底、绿「本机」 | 中性灰胶囊；「新词」accent；收藏只给星形图标着色 | `badge` |
| 提示条 / 弹层 / 确认框 | 玻璃 | `cardSurface` + `border` + 轻阴影 | `noticeToast`、settings popover |
| 空状态 | 蓝底 84pt 图标 | 56pt 中性图标块 + 三行提示分组卡片 + 「查第一个词」主按钮（聚焦查词框） | `emptyBook` |

## 3. 不变的部分

- 快捷键：⌘L、⌘F、↑↓、⌘S、⌘C、⌫、⌘Z、esc（逐级：清空查词 → 离开输入框 → 关窗）。
- 数据与行为：分类、语言方向、排序、按天分组、删除撤销、重新生成前确认模型、暂停记录、保留时间、清除未收藏、导出。
- 窄窗口（< 980pt）侧栏收起为 60pt 图标列；导出 / 设置移到图标列底部；列表卡片 260pt。

## 4. 实现建议（确认后另起 PR）

- 只改 `AskWordBookView.swift` 的视图层，`AskWordBookViewModel` 不动；`AskGlass` 相关修饰器从该文件移除。
- 颜色与圆角全部引用 `StudioTheme` / `StudioTheme.CornerRadius`，不新增私有色值。
- 在 `AskConversationVisualTests` 中补单词本深 / 浅色、空状态、窄窗口截图，并与本设计稿截图对照。

## 5. 设计稿自检

- 用 Playwright（系统 Chrome）跑了 19 项交互脚本：分类计数、过滤、排序、选词、⌘S、删除 / 撤销、查词预览 → 骨架 → 新词、点近义词查词、重新生成保留收藏与次数、设置弹层、暂停记录、清除未收藏、空状态、主题、窄窗口。全部通过，无控制台错误。
