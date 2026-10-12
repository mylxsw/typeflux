# 启动器：右侧预览栏（Preview Pane）设计方案

> 状态：设计稿，待评审。可交互设计稿：`docs/design/ask-launcher-preview-pane.html`（浏览器直接打开，支持键盘操作、深浅色、开关预览栏对比现状）；截图在 `docs/design/ask-launcher-preview-pane/`。

## 1. 需求与评估

需求：参考竞品，把启动器有搜索结果时的样子改成**两栏**：左栏是搜索结果，右栏显示高亮结果的详情，包括计算结果、文件信息与内容、文件夹列表，以及关键词、工作流等。

### 1.1 现状

- 启动器是 700pt 宽（`AskMetrics.launcherWidth`）的单栏玻璃卡片。快捷结果（`AskQuickResults` / `AskQuickResultsView`）在输入框下面按“计算 → 最佳匹配 → 功能 → 应用 → 系统设置 → 文件 → 文件夹 → 浏览器标签”分组列出，高度随内容变化，最高 430pt。
- 计算的各种写法（`.format(Int)`）在列表里占一行一行，方向键可以选中并复制；文件和应用的更多操作在 → 打开的 `AskQuickActionPanel` 浮层里。
- `ask-launcher-quick-results.md` §1 当时决定“没有右栏的空间，也不需要，保持单列”。这次的需求推翻了那个决定，需要同步更新那份文档。

### 1.2 结论

**可以做，建议做，工作量中等（约 6–7 人日，分 4 个里程碑）。** 理由：

1. **数据已经齐了。** 右栏要显示的东西大部分已经有：计算写法（`AskCalculatorFormats` / `AskNumberConversions`）、应用 entry、文件命中（`AskFileHit`）、缩略图（`QLThumbnailGenerator` + `AskResultImageCache`）、受控读文件（`AskFileReader` 子进程，带超时和取消）、浏览器标签（`AskBrowserSearchEntry`）、关键词（`AskLauncherSearchEntry`）、工作流 manifest。主要新增的是**右栏视图**和**按高亮项异步加载详情**这一层。
2. **结构改动可控。** 右栏只看 `results.highlightedRow`，不改搜索、排序、最佳匹配这些逻辑。唯一有语义变化的是计算写法从左栏移到右栏（见 §3.2）。
3. **收益明显。** 现在选中文件只能看到文件名和目录，要确认是不是想要的那个，只能打开或按 → 再选“快速查看”；同名文件（比如多个 `Localizable.strings`）尤其难分。右栏可以直接回答“这是哪个文件、里面是什么”。计算的写法挪到右栏后，左栏也不会被一长串写法挤占。

### 1.3 风险与对策

| 风险 | 对策 |
|------|------|
| 窗口变宽，在小屏 / 分屏时太占地方 | 宽度 780pt（+80pt），`AskLauncherPlacement` 已经按屏幕宽度夹紧；设置里提供“显示预览栏”开关，关掉后回到 700pt 单栏 |
| 高亮切换时右栏高度不同，窗口跳动 | 有结果时结果区**固定 432pt**，右栏自己滚动；和现在的 430pt 上限基本一样，`AskLauncherHeightAnimator` 只在“无结果 ↔ 有结果”时动画 |
| 读文件内容卡住（网络盘、iCloud 占位文件、大文件） | 一律走 `AskFileReader` 子进程：80ms 去抖、切走即取消、最多读 64 KB / 200 行、先检测二进制；iCloud 未下载的文件只显示信息，不触发下载 |
| 屏幕共享时把敏感内容显示出来 | 名字像密钥 / 凭证的文件（`*.env`、`.env.*`、`*.pem`、`*.key`、`id_rsa*`、`*.p12`、`credentials*`）只显示信息、不读内容；遵守 `AskFileScope` 屏蔽目录 |
| ⌘1–9、→、↩ 这些快捷键用户已经习惯 | 全部保持原意；新增的 ⌥1–9（复制第 N 种写法）和 ⌘C（复制高亮项的值）不和现有快捷键冲突 |

## 2. 交互设计

### 2.1 什么时候两栏

| 状态 | 布局 |
|------|------|
| 输入为空（首页：继续对话、最近应用、关键词 chips） | 单栏，**不变** |
| `/` 命令面板、关键词插件会话（`fy …`、`clip` 等） | 单栏，**不变**（插件会话的预览放到 M3 以后再评估） |
| 有快捷结果 | **两栏**：左 340pt 列表，右 440pt 预览 |
| 没有本地结果 | 单栏，回车问 AI，**不变** |
| 设置里关掉“显示预览栏” | 现在的单栏样式，700pt |

宽度一律是 780pt（空输入时也是），所以第一次出结果时只往下展开，不会横向跳。

### 2.2 右栏内容

右栏由三部分组成：类型标题行（左边是类型或文件名，右边是来源或状态）、内容区（可以滚动）、底部动作条。

| 高亮项 | 内容 | 数据来源 |
|--------|------|----------|
| 计算 | 算式 + 大号结果；全部写法（中文大写金额、千分位、英文金额、十六进制、二进制、科学计数法…），每行有复制按钮和 ⌥N 快捷键；算式没写完时保留上一次结果并变暗 | `AskCalculation`、`AskCalculatorFormats`（同步计算） |
| 纯数字 | 同上，写法来自数字转换；数值在合理区间时**可选**加一行“Unix 时间戳（秒 / 毫秒）” | `AskNumberConversions`，时间戳是新的 `Kind` |
| 应用 | 大图标、名称、分类；位置、版本、大小、上次打开、安装时间、Bundle ID；正在运行时显示窗口数 | `Bundle.infoDictionary`、`URLResourceValues`、`kMDItemLastUsedDate`、`NSRunningApplication` |
| 系统设置 | 图标、路径（系统设置 › 显示器）、一句说明 | 本地化文案，按 pane id 查 |
| 文本 / 代码文件 | 前若干行（带行号，只区分注释、键和字符串）+ “共 N 行”；位置、大小、行数、修改 / 创建时间 | `AskFileReader`（新增 `preview` 操作） |
| 图片 / PDF / 其他 | Quick Look 缩略图（图片带尺寸，PDF 带页数）；其他类型显示大图标 | `QLThumbnailGenerator`、`AskResultImageCache` |
| 敏感文件 | “不预览内容”的说明 + 文件信息 | 文件名规则，见 §1.3 |
| 文件夹 | 前 20 个子项（文件夹在前，带大小或项数）；位置、总大小、修改时间；点子项直接打开 | `AskFileReader` 现有的 `directory` 操作；大小取索引里的值 |
| 关键词 | 名称、关键词与别名、说明、用法示例、使用次数、引擎 | `AskKeyword`、`AskKeywordUsage`，manifest 新增可选 `examples` |
| 工作流 | 名称、说明、步骤（每步带参数摘要）、需要的输入、上次运行结果 | `AskWorkflowManifest`、`AskWorkflowActionsSummaryView` 的摘要逻辑、`WorkflowController+History` |
| 浏览器标签 / 书签 | 标题、完整 URL、浏览器 / 窗口 / 标签序号、同一网站的其他标签 | `AskBrowserSearchEntry`，按域名分组，不再调 AppleScript |

### 2.3 动作条

右栏底部显示最多 5 个动作 + “更多（→）”。动作条和 → 面板是**同一份** `AskQuickAction` 列表：前 5 个放在动作条，其余的放进面板。每个按钮都标出快捷键。

| 类型 | 动作条 |
|------|--------|
| 计算 / 数字 | 复制结果 ↩ · 复制算式 ⇧⌘C · 问 AI ⌘↩ |
| 应用 | 打开 ↩ · 在访达中显示 ⌘R · 复制路径 ⇧⌘C · 退出 ⌘Q（运行中时）· 显示简介 ⌘I |
| 文件 | 打开 ↩ · 在访达中显示 ⌘R · 快速查看 ⌘Y · 复制文件 ⌘C · 问 AI ⌘↩ |
| 文件夹 | 打开 ↩ · 在此搜索 ⌘F · 终端 ⌘T · 复制路径 ⇧⌘C |
| 关键词 | 进入 ↩ · 补全 ⇥ · 设置 ⌘, |
| 工作流 | 运行 ↩ · 编辑 ⌘E · 运行记录 ⌘L |
| 标签 | 切到标签 ↩ · 复制链接 ⇧⌘C · 关闭标签 ⌘W |

### 2.4 键盘

| 按键 | 行为 |
|------|------|
| ↑ ↓ | 在左栏移动高亮，右栏立即切换；需要读文件的内容 80ms 去抖后加载，加载期间显示骨架屏 |
| ↩ | 主操作（不变） |
| ⌘1–9 | 执行左栏第 N 项（不变） |
| ⌥1–9 | **新增**：复制右栏第 N 种写法（计算 / 数字转换） |
| → / ← | 打开 / 收起更多操作面板（不变） |
| ⌘C | **新增**：输入框没有选区时，复制高亮项的值（结果 / 路径 / 链接） |
| ⇥ | 关键词补全（不变） |
| ⌘↩ | 问 AI（不变） |
| Esc | 关面板 → 清空输入 → 收起启动器（不变） |

焦点始终留在输入框，右栏不接收键盘焦点，用鼠标点击可以操作（复制写法、点子项、点动作）。

## 3. 实现方案

### 3.1 结构

```
AskLauncherView
└─ AskQuickResultsView            // 不变：列表
   → 改为 AskQuickResultsSplitView（有结果 && 设置开启）
      ├─ AskQuickResultsView(list) // 左栏，宽 340
      └─ AskQuickPreviewView       // 新：右栏
         ├─ content(for: AskQuickPreview)
         └─ AskQuickActionBar      // 新：底部动作条，复用 AskQuickAction
```

新增类型：

- `AskQuickPreview`（纯值类型）：从 `AskQuickResults` + `highlightedRow` 推出右栏要显示的内容。case 有 `.calculation`、`.app`、`.pane`、`.file(AskFileHit, AskFilePreview?)`、`.folder(AskFileHit, [AskFileHit]?)`、`.feature`、`.workflow`、`.browser`。纯函数，好写单元测试。
- `AskQuickPreviewLoader`（`@MainActor` 的 ObservableObject）：按高亮项的 identity 去抖、取消、缓存（LRU 64 项，key 是路径 + 修改时间）。文本 / 目录走 `AskFileReader`，应用元数据在后台队列读取。
- `AskFileReadRequest.Operation`（现有 `directory / entry / resolve`）新增 `preview`，在子进程里按 `maxBytes` / `maxLines` 截好再返回，`AskFileReadResponse` 加一个 `text` 字段；文件夹列表直接复用 `directory`，`limit: 20`。
- `AskQuickPreviewPolicy`：敏感文件名规则、二进制检测、iCloud 占位文件判断。纯函数。

### 3.2 需要改的已有行为

- `AskQuickResults.rows`：开启预览栏时不再包含 `.format(Int)` 行，计算只剩 `.calculation` 一行；写法的复制改走 ⌥1–9 和右栏按钮。关闭预览栏时保持现在的行为。`keepChoice` 里 `.format` 的分支同理。
- `AskQuickResultsView.height(for:)`：开启预览栏时返回固定的 432pt。
- 文件行的 `→ 更多操作` 提示和右侧的修改时间，在两栏模式下省掉（右栏已经显示），文件行改成“文件名 + 第二行目录”，这样同名文件能区分开。
- `AskMetrics.launcherWidth` 改成随设置变化：780 / 700。
- `SettingsStore.askLauncherPreviewPane`（默认 `true`），在启动器设置里加开关。
- 本地化：右栏标题、元数据标签、动作、敏感文件说明，6 种语言。

### 3.3 里程碑

| 里程碑 | 内容 | 估时 |
|--------|------|------|
| M1 | 两栏骨架、宽度和高度规则、设置开关；`AskQuickPreview` 模型；计算 / 数字 / 应用（只用同步可得的字段）/ 系统设置 / 关键词预览；动作条；⌥1–9、⌘C | 2 天 |
| M2 | `AskQuickPreviewLoader` + `AskFileReader` 的 preview 操作；文本、图片、PDF、文件夹预览；敏感文件和 iCloud 规则；应用的版本、大小、上次打开 | 2 天 |
| M3 | 工作流、浏览器标签 / 书签预览；数字的 Unix 时间戳写法（可选） | 1.5 天 |
| M4 | 浅色、无障碍（VoiceOver 读出右栏标题和主值）、截图、更新 `ask-launcher-quick-results.md` 中“保持单列”的描述 | 1 天 |

### 3.4 测试

按仓库要求覆盖率 ≥ 90%：

- `AskQuickPreview`：每种 row 推出的内容；高亮越界、行被移除时的回退。
- `AskQuickResults`：预览栏开 / 关两种模式下的 `rows`、`keepChoice`、`height`。
- `AskQuickPreviewPolicy`：敏感文件名、二进制检测、iCloud 占位文件。
- `AskQuickPreviewLoader`：去抖、切换取消（旧结果不覆盖新高亮）、缓存命中与失效（修改时间变化）、读取超时显示为“无法预览”。用假的 `AskFileReading`。
- `AskFileReader` 的 preview：截断、UTF-8 半个字符、空文件、无权限。
- 快捷键：⌥1–9、⌘C 在有选区 / 无选区时的行为。

## 4. 不做（本期）

- 右栏里的可编辑设置（竞品 2 的时区 / 时间格式切换），第一版只读。
- 完整的语法高亮，只区分注释、键和字符串。
- 关键词插件会话（剪贴板历史、笔记、对话历史）的右栏预览，等两栏稳定后单独评估，其中剪贴板历史收益最大。
- 右栏获得键盘焦点（例如 ⇥ 切到右栏选择写法），用 ⌥1–9 代替。
