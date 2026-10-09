# AI 指令结果：Markdown 渲染、独立窗口与笔记本 设计方案

> 状态：设计稿第一版，待确认后开发（GUL-292）。可交互设计稿：`docs/design/ai-command-results.html`（浏览器直接打开），截图见 `docs/design/ai-command-results/`。

## 0. 一页结论

1. **结果按 Markdown 渲染**：AI 指令（`ex` 解释、`sum` 总结、`rw` 润色和用户自定义关键词）的结果卡改用 Ask 回答同一套渲染器（`AskTranscriptText`）。标题、加粗、列表、引用、代码块、表格都正常显示；流式输出时也渲染，并始终滚动到最新一行。⌘D 对照模式在 Markdown 下同样可用。
2. **复制分两种**：↩ 复制 Markdown 原文（与现在一致，贴进 Notion / Obsidian / 代码编辑器不丢格式）；⇧⌘C「复制为富文本」，贴进邮件、Pages、飞书文档时是排好版的样子。⌥↩ 替换选中仍写 Markdown 原文（见 §6 待确认）。
3. **⌘O 在独立窗口打开**：把当前结果「拿出」启动器，变成一个普通 macOS 窗口：可调大小、可多开、可置顶、⌘W 关闭；启动器随即收起。生成中按 ⌘O，流式输出在新窗口里继续。窗口里有复制 / 插入回原 App / 重新生成 / 收藏 / 继续问 AI。
4. **⌘S 收藏到「笔记本」**：结果卡和独立窗口右上角都有 ☆。收藏即存为一条笔记：Markdown 正文 + 来源（指令名、模型、原文、来源 App、时间）。再按 ⌘S 取消收藏（未编辑过才直接删除）。
5. **笔记本是独立窗口**（与单词本同一套样式）：⌘B 从结果卡打开，菜单栏也有入口。左栏按「全部 / 置顶 / 按指令 / 标签」，中栏列表 + 全文搜索，右栏阅读 / 编辑（Markdown 源与预览切换）、改标题、打标签、置顶、删除（可撤销）、导出 `.md`、「继续问 AI」。
6. **启动器里搜笔记**：关键词 `note` / `笔记`，留空列出最近 8 条，输入即全文搜索，↩ 打开、⌘↩ 复制正文。
7. **数据只在本机**（`notes.sqlite`，FTS5 全文检索），云同步作为后续阶段，需要后端配合。
8. **分 4 个 PR**：P1 Markdown 渲染（最小、可先上）；P2 独立结果窗口；P3 笔记本存储 + ⌘S 收藏 + 笔记本窗口；P4 `note` 关键词 + 导出。

## 1. 现状

| 能力 | 现状 | 位置 |
|------|------|------|
| AI 指令 | `AskPromptPlugin`：预设 `rw` / `sum` / `ex` 和用户自定义关键词，结果流式写进结果卡 | `Ask/QuickResults/Plugins/Prompt/AskPromptPlugin.swift` |
| 结果渲染 | 结果卡已经有 Markdown 分支（`output.markdown == true` 时用 `AskTranscriptText`），但 **AI 指令从没打开这个开关**，所以走纯文本 `Text(output.body)`，`**加粗**`、`- 列表` 原样显示（即截图里的问题） | `AskPluginViews.result(_:running:streaming:)`；`AskPluginOutput.markdown` |
| Markdown 分支的缺口 | 不支持 ⌘D 对照（`display.comparing` 只在纯文本分支里处理）；流式时不会自动滚到底部 | 同上 |
| 结果去向 | 只有复制 / 替换 / 问 AI；启动器一关，结果就没了，没有历史 | — |
| 独立窗口先例 | 工作流 ⌘E 打开编辑器、翻译 ⌘B 打开单词本；`AskAnswerWindowController` 是旧的回答窗口 | `AskWorkflowEditorWindowController`、`AskWordBookWindowController` |
| 收藏先例 | 单词本：⌘S 收藏、⌘B 打开、`word-book.sqlite`、独立对话框（GUL-237 / GUL-251） | `Translation/WordBook/*` |
| 命名冲突 | Agent 记忆里已经叫「笔记」（`ask.memoryNotes.*`、设置里「已保存的笔记」），是给模型的背景事实，和这次要做的个人内容不是一回事 | `AskMemoryNoteStore` |

结论：第 1 点是「开关没打开 + 两个小缺口」，改动很小；第 2、3 点是新能力，但可以完整复用单词本已经验证过的形态（⌘S / ⌘B / 本机 SQLite / 独立窗口）。

## 2. Markdown 渲染

### 2.1 改动

- `AskPromptPlugin.output(...)` 返回 `markdown: true`。
- `AskPluginResultsView.result` 的 Markdown 分支补齐：
  - **对照**：`display.comparing` 时原文（纯文本、次要色）在上，分隔线，Markdown 结果在下，与纯文本分支一致。
  - **流式滚动**：和纯文本分支一样用 `ScrollViewReader`，流式时 `scrollTo(bottom)`。
  - **高度**：沿用 `markdownHeight`（测量 `AskMarkdownText.render` 的排版高度，上限 280pt）；更长的内容在卡内滚动，或 ⌘O 拿到窗口里看。
- 流式中途的不完整语法（如只来了 `**比较`）按原文显示，下一段到了自然变成加粗，不做特殊处理——Ask 聊天的流式回答就是这样表现的。

### 2.2 复制与写回

| 动作 | 快捷键 | 内容 |
|------|--------|------|
| 复制 | ↩ | Markdown 原文（现状，不变） |
| 复制为富文本 | ⇧⌘C（新） | 同时写入 HTML（`MarkdownHTMLRenderer`）、RTF 和纯文本三种类型，目标 App 自己挑 |
| 替换选中 / 插入 | ⌥↩ | Markdown 原文（现状，不变；见 §6-Q4） |

`rw` 润色这类结果本身基本是纯文本，开渲染对它没有可见变化。

## 3. 独立结果窗口（⌘O）

### 3.1 行为

- 结果卡新增动作「在窗口中打开 ⌘O」（`AskPluginAction.Kind.openInWindow`，`Shortcut.commandO`），底栏提示里也列出。
- 按下后：结果连同它的上下文（指令名、原文、模型、来源 App、当前对照状态）交给一个新的 `AskResultWindowController`，启动器收起。
- **生成中也能拿出去**：结果的流式任务不随启动器结束，而是转交给窗口继续；窗口标题栏显示「生成中…」和停止按钮。
- **可多开**：每次 ⌘O 一个新窗口，依次错位排开（cascade），记住上次的尺寸；默认 560 × 640，最小 420 × 360。
- 普通窗口（不是浮动面板）：能进 Mission Control、⌘` 切换；工具栏「📌 置顶」切换到 `.floating` 层级。
- ⌘W / Esc 关闭。关闭不提示——没收藏的结果本来就是临时的。

### 3.2 窗口内容

```
┌ ● ● ●        解释 · gpt-5-mini · 10:42           📌  ☆ ┐
│ 原文 ▸ 比较优势（Comparative Advantage）           （可展开）│
│ ─────────────────────────────────────────────── │
│ # 比较优势                                         │
│ **一句话理解：** 即使一方样样都比对方强 …           │
│ - 比较的不是「谁绝对更强」…                          │
│ ─────────────────────────────────────────────── │
│ [复制 ⌘C] [富文本 ⇧⌘C] [插入到 备忘录 ⌥↩] [重新生成 ⌘R] [继续问 AI ⌘↩] │
└─────────────────────────────────────────────────────┘
```

- 正文可选中、可滚动，最大阅读宽度 680pt 居中，字号比卡片大一档（15 → 16）。
- 「插入到 <App>」：回到当初唤起启动器时的 App 并写入；那个 App 已退出时按钮置灰，提示「原 App 已关闭，可复制后粘贴」。
- 「重新生成」：在窗口里重跑同一个指令，旧结果变暗直到新结果开始流出（和卡片一致）。
- 「继续问 AI」：与卡片上的「问 AI」相同，带上指令、原文、结果打开聊天。

### 3.3 实现要点

- 把结果的状态从 `AskPluginSession` 中抽成可共享的 `AskResultDocument`（`ObservableObject`：body、original、meta、running、noteID），卡片和窗口观察同一个对象；⌘O 只是「换一个观察者 + 把运行中的 Task 的所有权转交给窗口」。
- 窗口关闭时取消仍在运行的生成任务，避免泄漏。
- `AskResultWindowController` 持有一个窗口数组，窗口关闭时移除；和 `AskWordBookWindowController` 同一套外观（`StudioTheme`）。

## 4. 笔记本（收藏 / 个人 Notes）

### 4.1 收藏

- 结果卡头部右侧 ☆（与单词卡一致），⌘S 收藏 / 取消；独立窗口同样有 ☆ 和 ⌘S。
- 收藏成功：☆ 变黄，底栏来源处临时显示「已收藏到笔记本 · ⌘B 打开」1.5 秒。
- 只有**完成的结果**能收藏；生成中按 ⌘S 会在完成后自动收藏（☆ 显示为半透明的「待收藏」）。
- 收藏后 ⌘R 重新生成：新结果是新内容，☆ 回到空心；旧的那条留在笔记本里。
- 取消收藏：笔记没被编辑过 → 直接删除；在笔记本里编辑过 → 不删，只提示「这条笔记已编辑，请在笔记本里删除」。

### 4.2 一条笔记存什么

| 字段 | 说明 |
|------|------|
| `id` | UUID |
| `title` | 默认「指令名 · 原文前 24 字（超出加 …）」，如「解释 · 比较优势（Comparative Advantage）」；可改 |
| `body` | Markdown 正文；可编辑 |
| `command` | 指令名 + 关键词（`解释` / `ex`），用于左栏「按指令」 |
| `input` | 原文（选中的文字或关键词后的输入），只读 |
| `model` | 生成它的模型名，只读 |
| `sourceApp` | 来源 App 名称和 bundle id（可能为空），只读 |
| `tags` | 标签，多对多 |
| `pinned` | 置顶 |
| `createdAt` / `updatedAt` / `editedAt` | `editedAt` 非空表示用户改过正文，决定取消收藏的行为 |
| `deletedAt` | 软删除，支撑「撤销」，30 秒后物理删除 |

存储：`~/Library/Application Support/Typeflux/notes.sqlite`，`notes` + `note_tags` 两张表，`notes_fts`（FTS5，`title` + `body` + `input`）做全文搜索；模式与 `SQLiteAskWordBookStore` 相同（单写连接、迁移版本号）。不设条数上限，但列表分页加载。

### 4.3 笔记本窗口

- 打开方式：结果卡 / 独立窗口里的「笔记本 ⌘B」、收藏提示里的 ⌘B、`note` 关键词的「打开笔记本…」、菜单栏菜单「笔记本…」。
- 三栏：
  - **左栏**：全部、置顶、按指令（解释 / 总结 / 润色 / 自定义…，带数量）、标签。
  - **中栏**：搜索框（标题 + 正文 + 原文全文搜索）、排序（最近更新 / 创建时间）、按日期分组的列表，每行标题 + 正文首行 + 指令徽标 + 时间。
  - **右栏**：标题（可直接改）、元信息行（指令 · 模型 · 来源 App · 时间）、可折叠的原文、正文（默认渲染；「编辑」切到 Markdown 源码编辑，⌘↩ / 点「完成」保存）、标签编辑、底部操作：复制、复制为富文本、继续问 AI、导出 `.md`、删除（带撤销条）。
- 多选后可批量导出（每条一个 `.md`，带 YAML front matter：title、command、model、source、created）、批量删除。
- 空状态：「在 AI 指令结果上按 ⌘S，就会收藏到这里」。

### 4.4 启动器里找笔记

- 关键词 `note`（中文别名 `笔记`），`AskNotesPlugin`，`runsWithoutInput = true`。
- 留空：最近 8 条（置顶在前）。输入：FTS 搜索前 8 条，高亮命中。
- 行内动作：↩ 在窗口中打开这条笔记（复用 §3 的结果窗口，带「在笔记本中显示」）；⌘↩ 复制正文；最后一行「打开笔记本… ⌘B」。

## 5. 不做 / 后续

- **云同步 / 多设备**：本期只存本机；需要后端存储与冲突策略，另开需求。
- **其他插件的结果**：工作流的文本 / Markdown 输出、翻译的句子结果同样可以 ⌘O / ⌘S，接口是通用的（`AskResultDocument` + `openInWindow` / `saveNote` 动作），但本期只给 AI 指令打开，先验证使用情况。
- **笔记作为 Agent 上下文**：可以让笔记本里的内容被 Ask 检索引用，但要和「记忆」的边界一起设计，本期不做。
- **富文本编辑器**：笔记编辑只提供 Markdown 源码 + 预览，不做所见即所得。

## 6. 待确认

| # | 问题 | 建议 |
|---|------|------|
| Q1 | 名称：「笔记本 / Notes」会和 Agent 记忆里的「笔记」混淆 | 新功能叫「笔记本」；把记忆设置里的「已保存的笔记」改称「记住的事」（仅文案） |
| Q2 | 笔记本放独立窗口，还是工作台侧栏新页面 | 独立窗口（与单词本一致，启动器里随手打开）；菜单栏提供入口 |
| Q3 | ⌘O 打开窗口后启动器是否收起 | 收起；需要回启动器再按唤起快捷键即可 |
| Q4 | ⌥↩ 替换写回时，要不要把 Markdown 转成纯文本（去掉 `**`、`#`） | 本期保持写原文；后续在设置里加「写回时去掉 Markdown 标记」 |
| Q5 | 笔记正文是否允许编辑 | 允许（Markdown 源码 + 预览） |

## 7. 落地计划

| PR | 内容 | 主要文件 | 测试 |
|----|------|---------|------|
| P1 | AI 指令结果 Markdown 渲染：`markdown: true`、Markdown 分支支持对照和流式滚动、⇧⌘C 复制为富文本 | `AskPromptPlugin`、`AskPluginViews`、`AskPluginSession` | `AskPromptPlugin` 输出断言；`AskCommandVisualTests` 增加 Markdown / 对照快照；富文本剪贴板类型断言 |
| P2 | ⌘O 独立结果窗口：`AskResultDocument`、任务所有权转交、`AskResultWindowController`、插入回原 App | 新增 `Ask/ResultWindow/*` | 文档状态与任务转交单测；窗口关闭取消任务；动作可用性（原 App 已退出） |
| P3 | 笔记本：`SQLiteAskNoteStore`（含 FTS5、软删除）、⌘S 收藏、笔记本窗口（三栏、编辑、标签、导出、撤销） | 新增 `Ask/Notes/*` | Store CRUD / 搜索 / 迁移 / 软删除；收藏与取消收藏规则；导出格式；视图模型筛选排序 |
| P4 | `note` 关键词插件 + 菜单栏入口 + 批量导出 | `AskNotesPlugin` | 插件计划与结果；空状态 |

每个 PR 新增代码单测覆盖率目标 ≥ 90%（仓库 CLAUDE.md 要求），五种语言（en / zh-Hans / zh-Hant / ja / ko）文案同步。
