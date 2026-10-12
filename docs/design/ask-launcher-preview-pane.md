# 启动器：文件预览窗口设计方案（v3）

> 状态：设计稿，待评审。可交互设计稿：`docs/design/ask-launcher-preview-pane.html`（浏览器直接打开；可以切换慢动作、减弱动态效果、窄屏、深浅色）；截图在 `docs/design/ask-launcher-preview-pane/`。
>
> v1 和 v2 把启动器改成两栏，评审后换了思路：**启动器保持现状，一点不改**。高亮停在能预览的文件上时，在启动器旁边弹出一个**独立的预览窗口**。

## 1. 行为

用 ↑↓ 或鼠标停在一个**能预览的文件**上时，启动器右侧出现预览窗口，高度和启动器一致。停在应用、文件夹、计算或不支持的文件上时，窗口不出现，已经出现的会收起。启动器本身的布局、快捷键、提示文字都不变。

| 高亮项 | 预览窗口 |
|--------|----------|
| 能预览的文件 | 停留 **120ms** 后开始加载；内容好了就滑出。150ms 内没好就先带着骨架条滑出，不出现空窗口 |
| 换到另一个能预览的文件 | 窗口不动，标题立即更新，内容 **120ms 交叉淡入**；新内容没好之前保留旧内容，超过 150ms 换成骨架条 |
| 换到不能预览的行 | 等 **150ms** 再收起：方向键连续经过一行应用或文件夹时不会闪；150ms 内回到能预览的文件就不收起 |
| 改输入、结果变化 | 按新的高亮项重新判断；没有结果立即收起 |
| 启动器高度变化 | 和启动器用同一个弹簧动画（`AskLauncherHeightAnimator`）一起改高度，顶边对齐 |
| 拖动启动器 | 作为子窗口（`addChildWindow`）跟着移动 |
| Esc / 打开 / 发送 / 启动器失焦 | 和启动器一起立即消失，不单独做动画 |
| → 操作面板 | 保持显示（面板在启动器内部） |
| ⌘Y 快速查看 | 先收起，避免两个预览叠在一起 |

鼠标悬停沿用列表现有的规则：指针真的移动过才改高亮（`AskSearchPointer`），所以窗口滑出时不会因为指针碰巧在某一行上而误切换。

## 2. 外观、位置与尺寸

- **位置**：启动器卡片右侧 **10pt**，顶边与卡片对齐。
- **高度**：等于卡片高度；结果很少、启动器很矮时最低 **320pt**（往下多出一截），否则 PDF 和图片会小到看不清。**这一点和“高度一致”略有出入，请确认。**
- **宽度**：优先 **380pt**；右侧放不下就放左侧；两侧都不足 **280pt** 就不显示。例如 1280pt 宽的屏幕上，启动器居中时两侧都只剩约 270pt。
- **外观**：和启动器同一套玻璃材质（`AskGlassBackground`）、16pt 圆角、同样的描边和阴影。
- **结构**：
  1. 顶部 50pt：文件图标、文件名（一行，中间截断）、一行信息（种类 · 大小 · 尺寸 / 时长 / 行数）。
  2. 中间：预览区，10pt 内边距，圆角 10pt 的底。
  3. 底部 38pt：所在目录（太长时截掉开头）和现有的“⌘Y 快速查看”提示。
- **窗口性质**：不能成为 key window，键盘焦点始终在启动器；可以接收滚轮（翻 PDF、长文本），不接收点击以外的输入。

## 3. 动效

| 动作 | 参数 |
|------|------|
| 出现 | 180ms；透明度 0→1，从启动器一侧滑出 10pt，缩放 0.985→1（以靠近启动器的边为原点），ease-out `(0.2, 0.8, 0.2, 1)` |
| 收起 | 140ms；透明度 1→0，往启动器方向收回 10pt，ease-in；结束后 `orderOut`，窗口不销毁 |
| 切换文件 | 120ms；只做内容层交叉淡入，窗口位置和大小不动 |
| 高度 | 跟随启动器的 critically damped 弹簧，无回弹 |
| 减弱动态效果 | 系统开了“减弱动态效果”时只保留透明度变化（100ms），不位移、不缩放 |

窗口的透明度和位移用 `NSAnimationContext` 驱动 `animator().alphaValue` 和 frame。内容层交叉淡入在 SwiftUI 里用 `.transition(.opacity)`，以文件路径作为 `id`。

## 4. 哪些能预览

| 类型 | 预览内容 | 来源 |
|------|----------|------|
| 图片（png jpg heic gif webp tiff bmp svg icns psd…） | 按比例放进预览区，透明部分显示棋盘格 | `QLThumbnailGenerator` |
| PDF | 前 3 页竖向排列，滚轮可以翻看；右下角写总页数 | `QLThumbnailGenerator`，页数用 PDFKit |
| 代码 / 纯文本（`AskFileType.code` 列表、txt、log、json、yaml…） | 等宽、带行号；只给注释、关键字、字符串、数字上色；最多 200 行 | `AskFileReader`（子进程） |
| Markdown | 简单渲染：标题、列表、行内代码 | `AskFileReader` |
| Word / Pages / Keynote / PPT | 第一页缩略图 | `QLThumbnailGenerator` |
| Excel / Numbers | 表格缩略图 | `QLThumbnailGenerator` |
| CSV / TSV | 直接画成表格，最多 30 行 | `AskFileReader` |
| 视频 | 一帧画面 + 时长，**不自动播放** | `AVAssetImageGenerator` |
| 音频 | 波形 + 时长，不自动播放 | `AVAsset`，只读前 30 秒 |

**不显示窗口**：应用、文件夹、系统设置、计算、关键词、浏览器标签与书签、压缩包 / dmg / 未知二进制、名字像密钥的文件（`.env`、`.env.*`、`*.pem`、`*.key`、`id_rsa*`、`*.p12`、`credentials*`）、iCloud 未下载的文件、网络盘上的文件（`AskFileMounts.shouldSkip` 的那些文件系统），以及缩略图生成失败或读取超时的文件。最后两种是加载后才知道的：此时如果窗口已经显示就收起，没显示就不出现。

## 5. 性能

- **启动器零改动**：预览是另一个窗口、另一棵视图树，启动器打字和列表滚动的开销不变。启动器只需要把“当前高亮的文件”和“卡片 frame”交给预览控制器。
- **一个窗口反复用**：第一次需要时才创建，之后只 `orderFront` / `orderOut`。
- **预览窗口里不用 `QLPreviewView`**：它每换一个文件都要重新起一次渲染，视频还会自动播放，方向键快速移动时开销大。要看完整内容仍用现有的 ⌘Y 快速查看（`AskQuickLook`）。
- **停留才加载**：120ms 去抖；高亮一变就取消上一个请求（`QLThumbnailGenerator.cancel(_:)`、Swift Task 取消、`AskFileReader` 有超时）。旧请求的结果即使晚到也不会覆盖新高亮。
- **尺寸受控**：缩略图按预览区的像素尺寸（宽 × backingScaleFactor）生成；文本最多读 64 KB / 200 行，先检测是不是二进制；视频只取一帧；音频只读前 30 秒。
- **缓存**：最近 32 项、上限 64 MB，key 是路径 + 修改时间 + 大小；启动器收起 60 秒后，或收到内存压力通知（`DispatchSource.makeMemoryPressureSource`）时清空。
- **预取**：显示第 N 项后，空闲时以低优先级预取相邻两项的缩略图，只限图片和 PDF。
- **“能不能预览”是纯函数**：只看扩展名 / UTType 和文件名，不读磁盘，切换高亮时几乎没有开销。
- **目标**：本地文件从停下到内容出现，p95 ≤ 250ms（120ms 去抖 + 加载）；方向键连续移动时不触发任何加载；启动器列表滚动保持 60fps。

## 6. 实现方案

新增（都放在 `Sources/Typeflux/Ask/QuickResults/Preview/`）：

| 类型 | 职责 |
|------|------|
| `AskFilePreviewKind` + `AskFilePreviewPolicy` | 纯函数：文件 → 预览方式（image / pdf / text / markdown / table / document / video / audio）或“不预览”；包括敏感文件名和网络盘规则 |
| `AskFilePreviewLoader` | `@MainActor`：去抖、取消、LRU 缓存、预取；按类型调用 `QLThumbnailGenerator`、`AskFileReader`、AVFoundation |
| `AskFilePreviewController` | 持有预览 `NSPanel`（复用 `AskHoverCardPresenter.Panel` 那种不会成为 key 的面板）；计算位置和宽度、左右侧选择；出现 / 收起 / 跟随高度；Reduce Motion |
| `AskFilePreviewView` | SwiftUI：顶部信息、各类型的预览、底部路径 |

需要改的现有代码：

- `AskFileReadRequest.Operation`（现有 `directory / entry / resolve`）新增 `preview`：在子进程里按字节数和行数截好再返回，`AskFileReadResponse` 加一个 `text` 字段。
- `AskComposer`（launcher）：高亮变化时调用 `previewController.request(hit)` 或 `previewController.dismiss()`。打开、发送、Esc、⌘Y 时调用 `dismissNow()`。
- `AskConversationWindowController`：在 `AskLauncherHeightAnimator` 的 `apply` 里同时更新预览窗口的 frame；启动器关闭和失焦时一起收起。
- 设置：启动器设置里加“预览文件”开关（默认开）。
- 本地化：信息行里的单位、“共 N 页”“共 N 行”“不自动播放”等，6 种语言。

里程碑：

| 里程碑 | 内容 | 估时 |
|--------|------|------|
| M1 | 预览窗口：位置、尺寸、子窗口、出现 / 收起 / 切换动效、跟随高度、Reduce Motion、设置开关；`AskFilePreviewPolicy`；图片和 PDF | 2 天 |
| M2 | `AskFileReader.preview`；代码 / 文本 / Markdown / CSV；Office、视频、音频；缓存、预取、内存压力 | 1.5 天 |
| M3 | 浅色、VoiceOver（窗口出现时读出文件名和类型）、截图、文档 | 0.5 天 |

## 7. 测试

按仓库要求覆盖率 ≥ 90%：

- `AskFilePreviewPolicy`：每种扩展名对应的预览方式，敏感文件名，网络盘，没有扩展名的文件。
- `AskFilePreviewController` 的时序（用可注入的时钟）：停留不足 120ms 不加载；150ms 内回到可预览文件不收起；连续切换时只有最后一个请求生效；内容 150ms 内没好时先显示骨架；Esc / 打开时立即消失。
- 位置计算：右侧够、只有左侧够、两侧都不够、启动器很矮（最低 320pt）、多显示器。
- `AskFilePreviewLoader`：取消、缓存命中、修改时间变化后失效、内存压力清空、读取超时变成“不预览”。用假的 `AskFileReading` 和缩略图生成器。
- `AskFileReader.preview`：按字节 / 行截断、UTF-8 半个字符、二进制文件、空文件、无权限。

## 8. 不做（本期）

- 预览窗口里的操作按钮和新快捷键（操作仍走启动器里的 ↩ / → / ⌘Y）。
- 文件夹、应用的预览。
- 视频 / 音频在预览窗口里播放。
- 完整语法高亮。
