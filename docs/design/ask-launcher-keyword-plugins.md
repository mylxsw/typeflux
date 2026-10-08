# 随便问：启动器关键字插件（翻译先行）设计方案

> 状态：P1（插件框架 + 翻译）和 P2（AI 指令、网页搜索、完整的关键字设置、`/` 面板插件分组）已实现，实现说明和与设计的差异见第 12、13 节；P3 仍是设计。配套设计稿：`docs/design/ask-launcher-keyword-plugins.html`，截图在 `docs/design/ask-launcher-keyword-plugins/`。基于 GUL-214 之后的启动器（上下文标记、分组结果、底栏按键提示）。
>
> 本文取代 `ask-launcher-translation.md` 里「前缀翻译」一节（§2.2）。那份文档里的翻译引擎、隐私规则和路线仍然有效。

> GUL-235 后续更新：悬浮启动器已移除 `/` 命令面板及 ⌘/ 入口；关键字插件仍通过关键字和 Tab 进入。下文关于启动器 `/` 面板插件分组的内容保留为历史实现说明。

## 0. 一页结论

1. **把「前缀」做成插件系统**，参照 Alfred 的 Workflow 关键字：
   - **关键字**是用户可以自己定义的触发词；**插件**是一项能力。一个插件可以挂多个关键字，每个关键字带自己的预设参数。例如 `fy` 是自动判断方向的翻译，`fyja` 是译成日语，`rw` 是「润色」这个 AI 指令。
   - 翻译只是第一个插件。后面加 AI 指令、网页搜索、文件搜索，都不用再改启动器。
2. **输入规则**就是你说的这条：
   - 关键字后面有内容，就处理这段内容。
   - 没有内容、但识别到了选中文字，按 ↩ 就处理选中文字。
   - 都没有，就提示用户输入。
3. **关键字变成输入框里的一个标签**：输入 `fy` 加空格后，`fy` 变成「文A 翻译」标签，后面的文字就是参数，一眼能看出现在是什么模式。在参数开头按 ⌫，标签会变回文字。
4. **结果的展示和操作，所有插件一套规则**：
   - 结果分三种：**文本卡片**（翻译、AI 指令）、**条目列表**（搜索、词典）、**直接执行**（打开网页）。
   - 按键在各插件里含义一致：

     | 按键 | 含义 |
     |------|------|
     | ↩ | 主操作（翻译 = 复制） |
     | ⌥↩ | 写回原应用；处理的是选中文字时，就是原地替换 |
     | ⇥ | 切换选项（翻译 = 目标语言） |
     | ⌘R | 重新运行（翻译 = 用 AI 重译） |
     | ⌘↩ | 带着原文和结果交给 AI 继续聊 |
     | esc | 先取消运行中的任务，再按一次关闭 |

5. **运行时机由插件声明**：
   - **边打边出**（`live`）：只给又快又不出本机的情况用，例如本机翻译用户刚输入的文字。
   - **按 ↩ 才运行**（`onSubmit`）：处理选中文字、调用 AI、打开网页，都要用户确认。和你的要求一致：识别到选中文字时，输入前缀后直接 ↩ 才翻译。

## 1. 概念

| 概念 | 是什么 | 例子 |
|------|--------|------|
| 插件（Plugin） | 一项能力：输入什么、怎么运行、产出什么结果、有哪些操作。由代码提供（内置）。 | 翻译、AI 指令、网页搜索 |
| 关键字（Keyword） | 用户可编辑的触发词，指向一个插件，并带上预设参数。存在设置里，可以增删改、停用。 | `fy` → 翻译（自动）、`fyja` → 翻译（目标：日语）、`rw` → AI 指令（提示词：润色）、`g` → 网页搜索（Google） |
| 参数（Argument） | 关键字后面的文字。 | `fy 明天开会` 里的「明天开会」 |
| 输入来源（Input） | 插件实际处理的文本：参数，或者选中文字。 | 见 §3 |
| 结果（Result） | 插件的产出，统一的数据模型，由通用视图渲染。 | 文本卡片 / 条目列表 / 直接执行 |
| 操作（Action） | 对结果能做的事，带固定快捷键。 | 复制、写回、朗读、重译、问 AI |

和现有能力的关系：

- 计算器、应用搜索仍然是**隐式来源**（不用关键字，按内容自动识别）。一旦进入关键字模式，它们就不参与。
- `/` 命令面板管的是「启动器 / 对话本身的操作」（新对话、切模型……），关键字管的是「对一段文字做什么」。面板里新增「插件」分组，列出所有关键字。选中一个就插入对应标签，方便发现和记忆。

## 2. 关键字识别

- 只认输入**开头**的关键字，不区分大小写，全角字符先转半角。
- 关键字后面必须跟空格、`:` / `：`，或者已经到输入结尾，才算命中。所以 `fyi` 不会被 `fy` 抢走。
- 多个关键字都能命中时，**最长的优先**（`fyja` 比 `fy` 先）。
- 只输入了关键字、还没有分隔符时（`fy`），结果区第一行给出提示「文A 翻译 · fy　空格或 ⇥ 进入」，但不抢回车：用户可能就是想搜一个叫 `fy…` 的应用。
- 进入关键字模式后：
  - 输入行左侧（上下文标记右边）出现**关键字标签**：插件颜色、图标、插件名，关键字带预设参数时也显示（例如「翻译 → 日语」）。
  - 占位文字换成插件自己的提示，例如「要翻译的内容 · 留空翻译选中的 2 行」。
  - 参数为空时按 ⌫，标签变回文字 `fy`，可以继续编辑或删掉。
- 结果区由插件独占，最后一行保留「问 AI」（⌘↩）。

## 3. 输入来源（按你的规则）

| 参数 | 选中文字 | 行为 |
|------|----------|------|
| 有内容 | 有或无 | 处理参数。参数优先，选中文字不参与。 |
| 空 | 有 | 结果区显示待运行行「↩ 翻译选中的 2 行 · 英语 → 简体中文」，**按 ↩ 才运行**。 |
| 空 | 无 | 结果区显示等待行「输入要翻译的内容」，↩ 不做任何事。 |

- 选中文字由启动器打开时已有的上下文抓取提供（上下文标记上的 `❝ 2 行`）。在标记里关掉选中文字，就等于「没有选中」。
- 插件可以声明自己接受哪种输入：
  - `text`：参数或选中文字（翻译、AI 指令）。
  - `argument`：只用参数（网页搜索；没有参数时可以退回用选中文字，由插件决定）。
  - `none`：不需要输入（例如以后的「锁屏」「清空剪贴板」类动作）。

## 4. 运行与状态

**运行时机**由插件根据请求决定：

| 插件 / 情况 | 时机 |
|-------------|------|
| 翻译：用户输入的参数，且本机引擎可用 | `live`：防抖 250 ms，边打边出 |
| 翻译：选中文字；或者需要 AI 引擎 | `onSubmit` |
| AI 指令 | `onSubmit`（会调用模型） |
| 网页搜索 | `onSubmit`，直接打开浏览器 |

**状态机**（每次只有一个运行任务，新的输入会取消旧任务）：

```
waiting（没有输入）─输入→ ready（待运行，显示「↩ 翻译…」）─↩→ running ─→ done / failed
                                         └─ live 插件直接进入 running
done ─再编辑参数→ stale（结果变暗，onSubmit 插件提示重新 ↩，live 插件自动重跑）
running ─esc→ ready（取消）
```

↩ 的含义跟着状态变，底栏右侧的提示同步更新：

- ready：「↩ 翻译 · esc 关闭」
- done：「↩ 复制 · ⌥↩ 替换选中 · ⇥ 日语 · ⌘↩ 问 AI」
- running：「esc 取消」

## 5. 结果怎么展示

所有插件产出同一种 `AskPluginResult`，由三种通用视图渲染。插件不写界面。

### 5.1 文本卡片（翻译、AI 指令）

```
╭ 文A 翻译   英语 → [简体中文 ⌄]                         本机 ╮
│ 这次更新修复了外接显示器上启动器位置偏移的问题，              │
│ 并让会议中的语音输入更稳定。                                 │
│                          ⧉ 复制  ↧ 替换选中  🔊 朗读  ⇄ 对照 │
╰────────────────────────────────────────────────────────────╯
```

- **头部**：插件图标和名称；元信息标签可以点击（例如目标语言，点开是下拉菜单，⇥ 轮换）；右侧标明来源（「本机」或「AI · 模型名」）。
- **正文**：可以选中复制，最多 8 行，超出在卡片内滚动。启动器整体高度有上限，并且贴着顶边（沿用 #307 的行为，不跳动）。
- **操作条**：常用操作做成带图标的小按钮，鼠标可以点，键盘用快捷键。
- **状态**：
  - 运行中，本机：骨架闪烁。
  - 运行中，AI：流式出字，末尾带光标。
  - 过期：上一次结果变暗，加细进度条。
  - 出错：卡片里一行原因，加上可以执行的下一步（「设置模型」「下载离线语言包」「重试」）。
- **对照（⌘D）**：原文和结果按段落上下交替显示，适合长文本和校对。

### 5.2 条目列表（网页搜索、词典释义，以及以后的文件、历史）

- 复用现有的结果行样式（图标、标题、副标题、右侧动作提示），↑ / ↓ 选择，↩ 执行。
- 网页搜索默认只有一行「在 Google 中搜索 “swift actors”」。以后接入搜索建议时，会变成多行。

### 5.3 直接执行（打开网页、以后的系统动作）

- 按 ↩ 执行后关闭启动器，不需要结果卡片。
- 执行失败时启动器不关闭，在结果区显示原因。

### 5.4 写回与交给 AI

- **⌥↩ 写回**：关闭启动器，用 `TextInjector` 写回打开启动器前的前台应用。
  - 处理的是选中文字时，**替换原来的选区**；否则在光标处插入。
  - 写回失败时自动复制，并在下次打开启动器时提示一次（「没能写回 Notes，已复制」）。
- **⌘↩ 问 AI**：打开对话。第一条消息带上插件名、原文和结果（例如「把下面的翻译改得更口语」），方便继续追问。

### 5.5 统一的操作与快捷键

| 操作 | 快捷键 | 翻译 | AI 指令 | 网页搜索 |
|------|--------|------|---------|----------|
| 主操作 | ↩ | 复制译文 | 复制结果 | 打开浏览器 |
| 写回 / 替换 | ⌥↩ | ✓ | ✓ | — |
| 复制 | ⌘C（正文里没有选中文字时） | ✓ | ✓ | 复制链接 |
| 切换选项 | ⇥ / ⇧⇥ | 目标语言 | — | 换搜索引擎 |
| 重新运行 | ⌘R | 用 AI 重译 | 重新生成 | — |
| 对照 | ⌘D | ✓ | ✓（改写前后） | — |
| 交给 AI | ⌘↩ | ✓ | ✓ | ✓ |
| 取消 / 关闭 | esc | 先取消运行中的任务，再按一次关闭 |  |  |

插件可以不提供某个操作，但**不能给同一个按键换成别的含义**。这样用户学一次就够了。

## 6. 架构

新目录 `Sources/Typeflux/Ask/QuickResults/Plugins/`：

```swift
/// A capability the launcher can run on a piece of text, reached by keywords.
protocol AskLauncherPlugin: Sendable {
    var id: String { get }                         // "translate"
    var title: String { get }                      // "翻译"
    var symbol: String { get }                     // SF Symbol
    var input: AskPluginInput { get }              // .text / .argument / .none
    var defaultKeywords: [AskKeyword] { get }
    /// Options a keyword can preset, for the settings form: target language, URL template, prompt…
    var options: [AskPluginOption] { get }
    func runMode(for request: AskPluginRequest) -> AskPluginRunMode      // .live(debounce:) / .onSubmit
    func run(_ request: AskPluginRequest) -> AsyncThrowingStream<AskPluginResult, Error>
}

struct AskKeyword: Codable, Equatable, Identifiable {
    var keyword: String                            // "fyja"
    var pluginID: String                           // "translate"
    var options: [String: String]                  // ["target": "ja"]
    var enabled = true
}

struct AskPluginRequest: Equatable {
    var text: String
    var origin: Origin                             // .argument / .selection
    var keyword: AskKeyword
    var sourceApp: String?                         // where ⌥↩ writes back
    var interfaceLanguage: AppLanguage
}

enum AskPluginResult: Equatable {
    case text(AskPluginText)                       // body, original, meta chips, badge, streaming
    case items([AskPluginItem])
    case perform(AskPluginAction)                  // run it and close
}

struct AskPluginAction: Equatable {
    var kind: Kind                                 // copy / insert(replaceSelection:) / open(URL) / speak / rerun(options) / askAI(prompt) / setOption
    var shortcut: AskPluginShortcut?               // .return / .optionReturn / .commandC / .tab / .commandR / .commandD / .commandReturn
    var title: String; var symbol: String
}
```

| 组件 | 职责 |
|------|------|
| `AskKeywordMatcher` | 纯函数：输入 → 命中的关键字和参数。规则见 §2，表驱动测试。 |
| `AskKeywordStore` | 设置里的关键字列表（JSON），用户没改过时用各插件的默认关键字；校验格式和重名（实现为 `SettingsStore.askLauncherKeywords` 加上 `AskKeywordList`）。 |
| `AskPluginRegistry` | 内置插件表。以后的脚本插件也从这里注册。 |
| `AskPluginSession`（`@MainActor ObservableObject`，由 `AskConversationModel` 持有） | 状态机（§4）、防抖、按代号丢弃过期结果、取消，**只在状态真的变化时发布**（吸取 M1 录音回归的教训）。 |
| `AskPluginActionPerformer` | 执行操作：剪贴板、`TextInjector`、`NSWorkspace`、`AVSpeechSynthesizer`、打开对话。全部可以注入，测试里替换。 |
| `AskKeywordChip`、`AskPluginResultView` | 输入行标签，以及三种结果视图。 |

接入现有代码的方式：

- `AskComposer` 的结果路径变成：先看是否命中关键字，命中就交给 `AskPluginSession`；否则走现有的计算器和应用搜索。
- 按键通道（`onCommandKey`）增加 ⌥↩、⇥、⌘R、⌘D 的分派。
- 上下文标记里的选中文字通过 `AskPluginRequest` 传进插件。

## 7. 第一批插件

| 插件 | 默认关键字 | 输入 | 时机 | 结果 |
|------|-----------|------|------|------|
| 翻译 | `fy`、`tr`、`翻译`（自动方向）；示例 `fyen` → 英语、`fyja` → 日语 | text | 本机且输入的是参数时 live，否则 onSubmit | 文本卡片 |
| AI 指令 | `rw` 润色、`sum` 总结、`ex` 解释（用户可以自己加：关键字 + 提示词，`{input}` 是占位符） | text | onSubmit | 流式文本卡片 |
| 网页搜索 | `g` Google、`bd` 百度、`gh` GitHub（用户可以自己加：关键字 + URL 模板，`{query}` 是占位符） | argument（为空时用选中文字） | onSubmit | 直接执行 |

- **翻译**：引擎和隐私规则沿用翻译设计稿。本机 Translation 优先，AI 用文本处理模型；选中文字只有在用户按 ↩ 后才会处理；会走 AI 时，卡片上始终标明。翻译模型和翻译服务商（DeepL、Google 等）后来可以单独配置，见 `translation-engines.md`（GUL-255）。
- **AI 指令**最能体现扩展性：用户不写代码，加一个「关键字 + 提示词」就是一个新功能。例如 `jd` → 「把下面的内容改写成京东客服口吻：{input}」。

## 8. 设置

设置 → Agent → 内置工具 →「启动器插件」：

- 列表：每个插件一行，显示图标、名称、它的关键字（小标签）和总开关。
- 点开插件：
  - 关键字表格：关键字、预设参数、启用。
  - 「添加关键字」：输入关键字，再填插件声明的选项（下拉、文本框、提示词编辑器）。
  - 实时校验：空、过长、含空格或冒号、以 `/` 开头、重名。**互为前缀不算冲突**：关键字后面必须跟空格或冒号，`f hello` 只会进入 `f`，`fy hello` 只会进入 `fy`。
- 「恢复默认关键字」。
- AI 指令的提示词编辑器带 `{input}` 插入按钮和一行预览。

## 9. 测试

- `AskKeywordMatcher`：分隔符、大小写、全角、最长优先、`fyi` 不命中、仅关键字时的提示。
- 输入来源表（§3）的全部组合；关掉选中文字时等于没有选中。
- 运行时机：live 与 onSubmit 的判定；状态机的每条边（防抖、取消、过期、出错）。
- 隐私：用假引擎断言选中文字在按 ↩ 之前**不会**交给任何引擎。
- 操作：用假的剪贴板、`TextInjector`、`NSWorkspace` 测 ↩、⌥↩（替换选中 / 插入）、⇥、⌘R、⌘↩，以及写回失败时的回退。
- 交互：用真实启动器按键，覆盖进入 / 退出标签、↩ 运行 → ↩ 复制、esc 先取消再关闭。
- 稳定性：沿用 #307 的逐帧测量，结果卡片出现、变长、流式输出时，编辑区不动。
- 截图：设计稿里的每个状态。
- 新代码覆盖率 ≥ 90%。

## 10. 里程碑

| 阶段 | 内容 |
|------|------|
| P1 | 插件框架（协议、关键字识别与存储、会话状态机、操作执行器、标签与结果视图）+ 翻译插件（本机 + AI）+ 统一快捷键 + 设置里管理翻译关键字 |
| P2 | AI 指令插件 + 网页搜索插件 + 完整的「添加关键字」界面 + `/` 面板里的插件分组 |
| P3 | 条目列表类插件（文件、历史对话、剪贴板历史）；脚本插件已单独设计为「自定义工作流」，见 `ask-launcher-workflows.md` |

## 11. 需要你确认

1. 默认关键字 `fy` / `tr` / `翻译` 可以吗？`fyen`、`fyja` 这类「带目标语言」的关键字，是默认就提供，还是只作为示例、让用户自己加？
2. 对用户输入的参数，本机引擎边打边出；选中文字和 AI 引擎必须按 ↩。这样区分可以吗？
3. 翻译选中文字后，↩ 是「复制」，⌥↩ 是「替换选中」，还是反过来？我建议 ↩ 复制：选中外文多半是为了看懂，不是为了替换。
4. P1 只做翻译加框架，P2 再做 AI 指令和网页搜索。这个顺序可以吗？还是希望 AI 指令一起上（它最能体现扩展性）？
5. 脚本插件（类似 Alfred 跑用户脚本）这次只预留，不做，可以吗？

## 12. P1 实现说明（与设计的差异）

确认的默认值：关键字 `fy` / `tr` / `翻译`（`fyja` 这类只作为可以添加的示例）；用户输入的参数在本机引擎下边打边出，选中文字和 AI 必须按 ↩；↩ 复制、⌥↩ 写回 / 替换；先做框架加翻译；脚本插件只预留。

**代码位置**
- `Ask/QuickResults/Plugins/`：
  - `AskKeyword.swift`：关键字和识别规则。
  - `AskLauncherPlugin.swift`：协议、请求、计划、结果、操作。
  - `AskPluginSession.swift`：状态机。
  - `AskPluginViews.swift`：关键字标签和结果视图，高度可以先算出来。
  - `Translation/`：语言、检测、两个引擎、翻译插件。
- `AskConversationModel+Plugins.swift`：执行操作（复制、写回、朗读、对照、交给 AI），关闭时把关键字折回输入框。
- `AskComposerViews.swift`：标签、结果区、按键、占位文字、底栏提示、高度（沿用 #307 的保留高度）。
- `Settings/AskLauncherPluginSettingsView.swift`：设置 → Agent → 内置工具 →「启动器关键字」。可以增删改翻译关键字、给关键字设预设目标语言、启用或停用，并选择第二语言。

**和设计不同、或留到后面的地方**
1. **本机翻译只支持 macOS 26 以上**（直接 `TranslationSession(installedSource:target:)`）。macOS 15–25 需要通过 SwiftUI `.translationTask` 桥接，这台开发 Mac 是 26，没法验证，这次没有做。这些系统以及没下载语言包的语言对，会按 ↩ 用 AI 翻译，卡片上注明「已用 AI 翻译」。语言包下载引导留到后面。
2. **AI 结果整段返回，不是流式**（用的是 `LLMService.complete`）。流式输出和 AI 指令插件一起在 P2 做。
3. **⌘C 复制没有做**（↩ 已经是复制）；条目列表和直接执行两种结果类型随网页搜索在 P2 做；`/` 面板里的「插件」分组也在 P2。
4. **⌥↩ 写回**：关闭启动器后，往原应用的当前输入位置写入。启动器不会激活本应用，所以原应用的选区还在，写入时就是替换选区。写入失败会把结果复制到剪贴板，并在启动器底栏提示一次。
5. **关键字前缀冲突**：见 §8，改为不检查（不会真的冲突）。


**实际渲染**（`AskPluginVisualTests`，设置 `TYPEFLUX_ASK_SNAPSHOTS` 时生成）：`ask-launcher-keyword-plugins/` 目录下的 `implemented-hint-dark.png`、`implemented-selection-ready-dark.png`、`implemented-selection-done-dark.png`、`implemented-selection-done-light.png`、`implemented-typed-dark.png`。

**测试**
- `AskKeywordTests`：识别规则、格式和重名校验、关键字列表的编辑、设置项的读写。
- `AskTranslationTests`：方向判断和 ⇥ 轮换、系统语言检测；插件的运行时机（含隐私：选中文字和 AI 必须按 ↩）、引擎选择、各种操作；AI 引擎的提示词和空结果处理。
- `AskPluginSessionTests`：状态机的每条边，包括防抖、过期结果、取消、失败重试、⇥ 和 ⌘R 的选项。
- `AskPluginViewTests`：高度计算、底栏提示、按键标签。
- `AskQuickResultsInteractionTests+Plugins`：用真实启动器按键，覆盖进入 / 退出标签、边打边出后 ↩ 复制、选中文字 ↩ 后才翻译、⌥↩ 写回、⇥ / ⇧⇥ / ⌘R / ⌘D、单独输入关键字时 ↩ 仍然问 AI、⌘↩ 带结果问 AI、esc 先取消再关闭、写回失败时的回退。

## 13. P2 实现说明（与设计的差异）

**新增**
- `Plugins/Prompt/AskPromptPlugin.swift`：AI 指令。默认关键字 `rw` 润色、`sum` 总结、`ex` 解释（选项 `preset`，名称和提示词跟随界面语言）；用户自己加的关键字填「名称」和「提示词」，`{input}` 是占位符，没写 `{input}` 时内容接在提示词后面。总是等 ↩ 才运行（内容会交给模型），结果流式出字；↩ 复制、⌥↩ 写回 / 替换、⌘R 重新生成、⌘D 对照、⌘↩ 带上原文和结果问 AI。用的是「设置 → 模型」里的文本处理模型（新增 `LLMService.streamComplete`，OpenAI 兼容服务真正流式，其余服务退回整段返回）。
- `Plugins/WebSearch/AskWebSearchPlugin.swift`：网页搜索。默认 `g` Google、`bd` 百度、`gh` GitHub；用户可以加「名称 + 网址模板」，`{query}` 是占位符。查询词做百分号编码，只接受带主机名的 http / https 网址。这是「直接执行」类：计划里就带了操作，↩ 打开浏览器并关闭启动器，⌘C 复制链接（启动器不关），⇥ / ⇧⇥ 换搜索引擎。
- 框架：`run` 多了 `progress` 回调，会话里的 `partial` 是正在生成的结果（亮色、末尾带光标，正文自动滚到底）；`AskPluginPlan.actions` 让插件不运行也能响应按键；新增 `.open(URL)` 操作和 ⌘C（输入框没有选中文字时才接管，结果默认就能 ⌘C 复制，复制后不关闭，底栏提示「已复制」）；插件可以声明 ⇥ 改的是什么（`optionName`），底栏提示按插件实际有的按键拼出来。
- `/` 面板（只在启动器里）新增「插件」分组，列出所有启用的关键字，例如「AI 指令 → 润色」；选中后进入该关键字，输入框里剩下的文字就是它的内容。和内置命令重名时加 `kw:` 前缀。
- 设置 → Agent → 内置工具 →「启动器关键字」：三个插件分组，每个关键字可以改名、启用 / 停用、删除；翻译选目标语言，AI 指令填名称和提示词（带「插入 {input}」按钮，默认提示词显示为占位文字），网页搜索填名称和网址（实时校验 `{query}` 和 http / https）；底部「恢复默认关键字」。
- 关键字升级：保存关键字时同时记下当时有哪些插件（`ask.launcher.keywordPlugins`）。P1 时保存过关键字的用户，会自动得到 AI 指令和网页搜索的默认关键字；以后删掉的不会再回来；和用户已有关键字重名的默认关键字不加。

**实际渲染**（`AskPluginVisualTests.renderSearchAndPrompt`）：`ask-launcher-keyword-plugins/` 下的 `implemented-web-dark.png`、`implemented-prompt-ready-dark.png`、`implemented-prompt-done-dark.png`、`implemented-prompt-done-light.png`。

**和设计不同、或留到后面的地方**
1. 条目列表（多行结果，例如搜索建议）没有做：网页搜索目前只有一行，直接执行就够了，列表视图随 P3 的文件 / 历史插件一起做。
2. AI 指令的 ⌘D 对照显示的是原文和结果上下排列，没有按段落交替。
3. 元信息标签还不能点开下拉菜单（⇥ 轮换已经可以）。
4. macOS 15–25 的本机翻译桥接仍未做（见第 12 节）。

**测试**
- `AskPromptAndWebPluginTests`：AI 指令的名称 / 提示词解析、`{input}` 替换、运行时机、流式进度、各种操作和失败；网页搜索的引擎解析、编码和网址安全校验、计划里的操作、⇥ 换引擎；关键字升级合并和设置里的选项编辑。
- `AskPluginSessionTests`：流式结果的出现、替换和取消；`/` 面板进入关键字。
- `AskPluginViewTests`：直接执行和带 ⇥ 选项时的底栏提示、流式结果的高度。
- `AskCommandTests`：插件分组只在启动器出现、重名前缀、执行后进入关键字；⌘C 的按键映射。
- `AskQuickResultsInteractionTests+Plugins`：真实启动器里 `g swift actors` → ⌘C 复制链接 → ⇥ 换百度 → ↩ 打开；`rw` → ↩ 流式出字 → 复制（不关闭）→ ⌘R 重新生成 → ↩ 复制并关闭。
- `LLMRouterTests`：`streamComplete` 按服务商转发，以及不支持流式时的整段回退。
