# 问题反馈：独立窗口 + 富文本正文 + 附件（GUL-427）

> 状态：已确认并实现（GUL-427）。配套可交互设计稿：`docs/design/feedback-window.html`。参数：`?theme=dark|light`，`?style=glass|classic`，`?state=empty|editing|uploading|failed|toolarge|limit|restored|submitting|error|success`。截图在 `docs/design/feedback-window/`，文件名为 `<深浅>-<界面风格>-<状态>.png`。
>
> 所有控件都来自组件库（`Sources/Typeflux/UI/Components/`，规范见 `docs/design/settings-search-unification.md`），对应关系见 §9。
>
> 实现见 `Sources/Typeflux/Feedback/`；服务端改动见 typeflux-api 的对应 PR。

## 修改记录

**第 3 版（按 UI 规范和组件库重做）**：上一版的控件是自绘的，没有按规范来：按钮是 28pt、圆角 7 的方块，提交按钮里塞了快捷键键帽；格式按钮是 28 × 26 的圆角方块，用自绘的悬停提示；联系方式输入框 34pt、1pt 边框，还加了图标；焦点环 3pt；底栏左侧放了两个链接；成功页、提示条、进度环都是自己画的；颜色是手调的近似值；也没有区分 Liquid Glass 和经典界面风格。这一版：

- 尺寸只用 24 / 30 / 36 三档，能点的是胶囊，输入框圆角 8，编辑器圆角 10，焦点环统一为 1pt accent + 3.5pt 30% 外圈，边框 0.5pt；颜色取规范设计稿里的 `StudioTheme` 映射。
- 标题区用 `TFPaneHeader`；格式工具条是小号无边框圆形图标按钮（`TFButton(.plain, iconOnly)`），提示改用系统 `.help()`；联系方式改为 `TFLabeledField` + `TFTextFieldStyle`。
- 底栏按 Sheet 规则：左边只放一个 `TFMenuButton(.link)`「其他反馈方式」（菜单里是发邮件和 GitHub），右边 `[取消] [提交]`；提交中用按钮自带的加载态，⌘↩ 写在 `.help()` 里。
- 提示统一：恢复草稿用 `TFNotice(.info)`，提交失败用 `TFNotice(.danger)`，文件被拒用编辑器下方的 `TFFieldMessage(.warning)`，不再弹 toast。成功页用 `TFEmptyState`（大号主要按钮「完成」+ 链接「再写一条」）。
- 附件：文件块按 `TFListRow` 排（`TFIconTile(.neutral)`、13pt 半粗标题、11.5pt 副标题、尾部小号无边框按钮）；进度用 `TFMeter`；图片、视频上的按钮用玻璃按钮；时长和大小是 16pt 胶囊。
- 窗口背景用 `AskWindowBackdrop`，跟随「设置 › 界面风格」切换 Liquid Glass / 经典。

**第 2 版（评审意见）**：顶部说明只保留「说说遇到的问题或想法。」，去掉粘贴截图和拖入文件的文案；去掉联系方式下方的提示文字。

## 1. 现状问题

- 反馈是挂在设置窗口上的 sheet（`SettingsView` → `DirectFeedbackSheet`）。菜单栏和使用指南的「直接反馈」都要先打开设置；sheet 盖住设置，不能拖动，也不能单独截图。
- 样式是默认控件拼起来的：标题、标签、按钮和其他窗口的层级、间距不一致。
- 正文是纯文本 `NSTextView`，不能排版。图片放在正文外面的单独区域，只能点「添加图片」选文件，不能粘贴截图。
- 只能附图片，不能附录屏、日志。

## 2. 窗口

- 改为独立的普通 `NSWindow`（单实例，由 `FeedbackWindowController` 持有），不再依附设置窗口。菜单栏、使用指南、设置三个入口都直接打开它；已打开时只前置。
- 带红绿灯，标题栏可拖动；可调整大小，最小 520 × 640，默认 600 × 720（都含 52pt 标题行），记住位置和大小。窗口层级为普通级别，所以 ⇧⌘4 + 空格可以单独截取它，也可以和其他窗口并排。
- esc、⌘W、取消、红色按钮都是关闭。**关闭保留草稿**（正文、附件、已上传结果），下次打开恢复，并在顶部提示「已恢复上次未提交的内容 · 清空重写」；提交成功或主动清空后才丢弃。提交过程中不能关闭。
- 背景用 `AskWindowBackdrop`，和笔记本、使用指南窗口一致，跟随「设置 › 界面风格」（Liquid Glass / 经典）和深浅色。控件全部来自组件库（§9）。

## 3. 布局

自上而下：

1. 52pt 标题行：只有红绿灯，可拖动。
2. `TFPaneHeader`：40pt 强调色图标块 +「问题反馈」+ 说明「说说遇到的问题或想法。」（粘贴、拖入的用法由正文占位文字和工具栏提示说明，不在这里重复。）
3. **编辑器**（占满剩余高度）：工具栏 / 正文 / 状态行。
4. 联系方式：`TFLabeledField`「联系方式」+ 30pt 输入框，占位「邮箱或其他联系方式（可选）」，登录时默认填账号邮箱；下方不加说明文字。
5. 提交失败时的 `TFNotice(.danger)`（内容不丢）。
6. 底栏：左侧链接样式的菜单按钮「其他反馈方式 ⌄」（菜单项复用 `FeedbackDestination` 的发邮件、GitHub），右侧「取消」「提交」，⌘↩ 提交。

提交成功后窗口内容换成 `TFEmptyState`：对勾、「反馈已提交，谢谢」、会通过哪个联系方式回复；大号主要按钮「完成」+ 链接「再写一条」。不再只弹 toast。

## 4. 富文本正文

- 工具栏：粗体 ⌘B、斜体 ⌘I、删除线、小标题、项目列表、编号列表（复现步骤）、引用、代码 / 日志（选中单行为行内代码，否则为代码块）、链接 ⌘K（只接受 http / https）。右侧：「添加文件」「截图」。
- Markdown 快捷输入：行首 `- ` / `* ` 列表、`1. ` 编号、`> ` 引用、`## ` 小标题。
- 粘贴富文本时只保留上面这些格式，其余样式（字体、颜色、字号）丢弃。
- 实现上用 `NSTextView`（rich text）+ 受限属性集，附件用 `NSTextAttachment` 的自定义 cell 渲染为块。提交时把正文序列化为 Markdown。

## 5. 附件

附件作为正文里的块插入在光标所在段落之后，所以说明文字和截图可以交替出现。

**添加方式**：⌘V 粘贴（截图、从访达复制的文件）、拖入编辑器（显示虚线框和「松开以添加附件」）、「添加文件」选择、或「截图」：隐藏反馈窗口 → 框选屏幕区域 → 结果插入正文 → 窗口回来（复用应用已有的区域截图能力）。

**类型和大小**（在插入前检查）：

| 类型 | 格式 | 处理 | 上限 |
|------|------|------|------|
| 图片 | png / jpg / heic / webp / gif | 先压缩：最长边 1600、JPEG（沿用 `FeedbackImageProcessor`），仍超限再逐级降质量；gif 不压缩 | 压缩后 ≤ 3 MB |
| 视频 | mov / mp4 / m4v | 先压缩：720p H.264（`AVAssetExportSession`），保留音轨 | 压缩后 ≤ 50 MB |
| 文本 | txt / log / md | 不压缩 | ≤ 5 MB |
| 文档 | docx | 不压缩 | ≤ 10 MB |

- 最多 6 个附件（图片、视频、文件合计）。
- 不支持的类型、文本/文档超限、动图超过 3 MB：**不插入**，用提示说明原因（例如「不支持 logs.zip：仅支持图片、视频，以及 txt / log / md / docx」「typeflux-full.log 有 12 MB，超过 5 MB 上限」）。
- 视频要压缩后才知道大小：块先插入并显示「压缩中 42% · 148 MB · 转为 720p」，再「上传中」；完成后显示「148 MB → 38 MB」和时长。压缩后仍超过 50 MB 时块保留在原位标红：「压缩后仍有 161 MB，超过 50 MB 上限，请剪短后重新添加」，只能移除。

**块的样式与状态**：

- 图片：缩略图，圆角 8，最高 220pt；悬停显示玻璃按钮「预览」「移除」和压缩后大小（16pt 胶囊）。
- 视频：16:9 封面 + 36pt 玻璃播放按钮 + 时长胶囊；点击用 Quick Look 风格的预览播放。
- 文件：`TFListRow` 样式的一行：28pt `TFIconTile(.neutral)`、文件名（13pt 半粗）、「大小 · 类型」（11.5pt），尾部小号无边框「移除」按钮；上传时副标题换成 `TFMeter` + 百分比。
- 状态：压缩中 / 上传中（`TFMeter` + 文字）→ 已上传；上传失败（红字 +「重试」）；超限（红字，只能移除）。文件被拒（类型不支持、超限）时不插入，在编辑器下方用 `TFFieldMessage(.warning)` 说明原因。
- 单击选中块，Delete 删除；再次单击图片或视频打开预览。
- 编辑器底部状态行：平时显示规则「图片 ≤ 3 MB · 视频 ≤ 50 MB（自动压缩）· txt / log / md / docx」和「附件 n/6」；有压缩、上传、失败、超限时换成对应说明。

**提交条件**：正文有文字，且没有压缩中、上传中、失败或超限的附件。

## 6. 提交内容

- `content`：正文 Markdown。图片写成 `![name](url)`，视频和文件写成 `[name](url)`，留在原来的位置。
- 兼容字段：图片 URL 继续放进 `image_urls`；新增 `attachments`（`url`、`filename`、`content_type`、`size_bytes`、`kind`）。
- 联系方式不变。

## 7. 依赖的服务端改动（typeflux-api）

当前反馈上传只收图片：`AllowedContentTypes` 默认 `image/jpeg|png|webp|gif`，单文件上限 5 MB（`DefaultFeedbackUploadMaxSizeBytes`），并校验图片字节；反馈最多 5 张图（`maxFeedbackImages`）。要支持本设计需要：

- 上传接口按类型放开 content type 和上限：图片 3 MB、`video/mp4` / `video/quicktime` 50 MB、`text/plain` / `text/markdown` 5 MB、docx 10 MB；视频和文档按各自格式校验文件头。
- 50 MB 视频走预签名直传对象存储（现有 presigned 流程），不经 API 进程中转。
- 反馈提交接受 `attachments`，总数上限 6；生成 GitHub Issue 时按 Markdown 原样渲染。

## 8. 实现说明与定稿

待确认的三项已按设计稿的建议定稿：

1. 文本 / 日志 / Markdown ≤ 5 MB，docx ≤ 10 MB，附件合计 ≤ 6 个。
2. 视频压缩为 720p H.264（mp4）；原始视频时长上限 10 分钟，超过时直接提示，不开始压缩。
3. 暂不加「录屏」入口，只保留「截图」。

实现上的取舍：

- 「截图」调用系统 `screencapture -i`：隐藏窗口、框选区域、结果插入正文。它和应用自带截图使用同一项「屏幕录制」权限，不接入应用自己的截图编辑器。
- 正文是 TextKit 1 的 `NSTextView`，附件块是 `NSTextAttachmentCell` 子类；列表符号和引用竖线由自定义 `NSLayoutManager` 绘制，不写入文本，所以选择、删除、序列化都看不到它们。
- 草稿只保存在内存里（窗口关闭后保留，退出应用后丢弃）。
- 图片、视频压缩后才检查大小；GIF 不压缩，超过 3 MB 直接拒绝。
- 提交时 `content` 里的图片和文件链接已在原位置；`image_urls` 继续发送图片地址以兼容旧服务端，新服务端发现正文已包含这些地址时不再重复追加。
- 服务端上传仍走现有的单次使用 PUT 票据（经 API 转发），没有改成对象存储预签名直传；视频的读取超时放宽到 10 分钟。

## 9. 组件对应

| 位置 | 组件 | 规格 |
|------|------|------|
| 标题区 | `TFPaneHeader` | 40pt soft 图标块，17pt 半粗标题，12.5pt 说明 |
| 恢复草稿 / 提交失败 | `TFNotice(.info)` / `TFNotice(.danger)` | 圆角 8，12.5pt；恢复草稿带链接按钮「清空重写」 |
| 编辑器外框 | `TFTextArea` 的外观 | 圆角 10，`controlSurface` + 0.5pt 边框，TF 焦点环；拖入时同样显示焦点环 |
| 格式工具条 | `TFButton(.plain, iconOnly: true)`，`.tfControlSize(.small)`，组间 `TFDivider` | 24pt 圆形，`.help()` 写名称和快捷键，激活时叠加按下色 |
| 添加文件 / 截图 | `TFButton(.plain)` 小号带图标 | 24pt 胶囊 |
| 状态行 | 脚注样式 | 11pt `textTertiary`，数量用等宽数字 |
| 文件被拒 | `TFFieldMessage(.warning)` | 11.5pt，放在编辑器下方 |
| 文件附件 | `TFListRow` 排法 + `TFIconTile(.neutral)` + `TFMeter` | 最小 52pt 高，尾部 24pt 无边框按钮 |
| 图片 / 视频上的按钮 | `TFButton(.glass, iconOnly: true)` | 小号 24pt；视频播放按钮大号 36pt |
| 时长 / 大小 | `TFTag` 尺寸 | 16pt 胶囊，10.5pt |
| 联系方式 | `TFLabeledField` + `TFTextFieldStyle` | 30pt，圆角 8 |
| 其他反馈方式 | `TFMenuButton`（`.link`）+ 原生 `NSMenu` | 标准 30pt |
| 取消 / 提交 | `TFButton(.secondary)` / `TFButton(.primary, isLoading:)` | 标准 30pt，最小宽 64pt，右对齐 |
| 成功页 | `TFEmptyState` | 44pt 图标块；大号主要按钮 + 链接 |
| 链接输入 | `TFMenuPanel` 外观 | 玻璃，圆角 12，内边距 5；30pt 输入框 + 标准主要按钮 |

组件库里没有现成的：富文本编辑区（`NSTextView` + 附件 cell）和附件块本身。它们只用上表里的组件和 `TFMetrics` / `TFColors`，不新增尺寸、圆角或颜色。

实现截图：`docs/design/feedback-window/impl-dark-editing.png`、`impl-light-editing.png`（经典界面风格，由 `FeedbackWindowControllerTests` 生成：`TYPEFLUX_FEEDBACK_SNAPSHOT_DIR=<目录>`；`FeedbackWindowRenderTests` 另外渲染编辑中和已提交两种状态：`TYPEFLUX_FEEDBACK_SNAPSHOTS=<目录>`）。
