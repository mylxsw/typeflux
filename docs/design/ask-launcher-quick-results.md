# 随便问：启动器快捷结果（计算器先行）设计方案

> 状态：设计稿，待确认后再进入开发。配套可交互设计稿：`docs/design/ask-launcher-quick-results.html`（浏览器直接打开），截图见 `docs/design/ask-launcher-quick-results/`。

## 1. 背景与目标

按快捷键（⌥Space）弹出的「随便问」启动器（`AskLauncherView` → `AskComposer(launcher: true)`）目前只做一件事：把输入框内容作为问题发给 AI。输入框为空时，下方是三条起手建议（`AskLauncherSuggestions`）；一旦开始输入，建议消失，回车即 `submitLauncher()` 新建对话。

需求：输入的是数学算式时，**不经过 AI**，在输入框下方直接给出计算结果，像 uTools / Raycast 的计算器那样。后续还会接入「搜索应用」「搜索文档」等。

所以这次不只做一个计算器，而是在启动器里加一层**「快捷结果」（Quick Results）**：本地的、即时的、可扩展的结果来源，计算器是第一个来源。

| # | 目标 | 不做（本期） |
|---|------|-------------|
| G1 | 输入合法算式，边打边出结果，回车复制结果并关闭 | 图形计算、方程求解、符号运算 |
| G2 | 结果附带常用格式：千分位、中文大写金额、英文金额、科学计数、十六进制等，可单独复制 | 汇率换算（要联网取汇率，放到后续） |
| G3 | 任何时候都能一键改为「问 AI」，不能让计算器挡住原有用法 | — |
| G4 | 来源可插拔：以后加应用搜索、文档搜索、历史对话、单位换算，不再改启动器结构 | 本期不实现这些来源，只把接口定好 |
| G5 | 全部本地计算，不联网、不进对话历史 | — |

参考对象（uTools）：左栏是分组的结果列表（APP Results / Defaults），右栏是选中项的详情（算式 + 结果 + 中文大写 / 英文金额），底部是操作栏（Copy Result / Copy Formula）。我们的启动器是 680pt 宽的单列玻璃卡片，没有右栏的空间，也不需要：本方案把「结果卡」直接放在原先起手建议所在的位置，保持单列。

## 2. 交互设计

### 2.1 状态

启动器下半区（编辑行 + 底栏以下）同一时间只显示下面一种内容，优先级从高到低：

| 条件 | 下半区 |
|------|--------|
| `/` 命令面板打开 | 命令面板（现状） |
| 输入为空，且无引用、无附件 | 三条起手建议（现状） |
| 有快捷结果 | **快捷结果列表**（新） |
| 其它 | 空（现状：回车问 AI） |

另外两条限制：

- 草稿里有引用、用户附件、显式选择的 Skill / MCP 时，用户明显是在给 AI 写问题，不显示快捷结果。
- 录音（听写）中快捷结果和建议一样变暗、禁用（`recordingDim`），听写结束后按最终文字重新计算。

### 2.2 计算器结果（主要场景）

```
╭──────────────────────────────────────────────────────────────╮
│ [Chrome · Multica…  ×] [整屏截图 ×]                            │
│ 1234567.89*2                                                 │
│ ＋  ☁  MiniMax M3 ▾  │ 📷 🧠                        🎤  ⬆      │
│ ──────────────────────────────────────────────────────────── │
│ ╭────────────────────────────────────────────────────────╮   │
│ │ 🧮 计算器                              1234567.89 × 2   │   │  ← 高亮行，↩ 复制
│ │                                     = 2,469,135.78     │   │
│ ╰────────────────────────────────────────────────────────╯   │
│   千分位      2,469,135.78                              ⧉    │
│   中文大写    贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分           ⧉    │
│   英文金额    SAY US DOLLARS TWO MILLION … AND CENTS …   ⧉    │
│ ──────────────────────────────────────────────────────────── │
│ ✨ 问 AI：“1234567.89*2”                            ⌘↩      │
│                         ↩ 复制结果 · ⌘↩ 问 AI · esc 关闭      │
╰──────────────────────────────────────────────────────────────╯
```

- **结果行**：左边是计算器图标和标题，右边是规范化后的算式（`*` 显示为 `×`，`/` 显示为 `÷`）和放大的结果。结果用千分位显示，**复制的是不带千分位的原始值**（`2469135.78`），粘到表格或计算器里都能用。
- **格式行**：最多 3 行，每行右侧一个复制按钮。点击只复制、不关闭，图标变成 ✓ 约 1 秒。格式按情况出现：

  | 格式 | 何时出现 | 示例 |
  |------|---------|------|
  | 千分位 | \|x\| ≥ 1000（主结果已带千分位，但 ↩ 复制的是原始值，这一行用来复制带千分位的版本） | `2,469,135.78` |
  | 中文大写金额 | 界面语言为中文，0 < \|x\| < 10¹⁶；按「分」四舍五入 | `贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分` |
  | 英文金额 | 同上范围；按 cent 四舍五入 | `SAY US DOLLARS TWO MILLION FOUR HUNDRED SIXTY-NINE THOUSAND ONE HUNDRED THIRTY-FIVE AND CENTS SEVENTY-EIGHT ONLY` |
  | 科学计数 | \|x\| ≥ 10¹⁵ 或 0 < \|x\| < 10⁻⁶ | `2^64` → `1.84467440737096 × 10¹⁹` |
  | 十六进制 / 二进制 | 结果为整数且在 Int64 范围内，且算式里出现过 `0x` / `0b` | `0xff+1` → `0x100` |

  中文界面的顺序是：中文大写 → 千分位 → 英文金额；其它语言是：千分位 → 英文金额 → 科学计数。超过 3 行的不显示，保持面板高度稳定。
- **「问 AI」行**：始终在列表最后，把原文当问题发出（等价于没有快捷结果时按回车）。这是 G3 的保证：计算器识别错了，用户也只需要 ⌘↩。

### 2.3 键盘

| 按键 | 行为 |
|------|------|
| ↩ | 执行高亮行的默认操作。默认高亮是计算器行 → 复制结果并关闭启动器 |
| ⌘↩ | 无论高亮在哪，都按原文问 AI（`submitLauncher()`） |
| ⇧↩ | 换行（现状不变） |
| ↑ / ↓ | 在结果行、格式行、「问 AI」行之间移动（复用 `AskArrowKeyMonitor`） |
| ⌘C（输入框无选区时） | 复制高亮行的值，不关闭 |
| esc | 关闭（现状不变） |

底部提示随状态切换：有快捷结果时为「↩ 复制结果 · ⌘↩ 问 AI · esc 关闭」，否则保持「↩ 发送 · esc 关闭」。

输入法组字中（`hasMarkedText()`）不计算、不响应回车，和现在的提交逻辑一致。

### 2.4 执行之后

- 复制并关闭后，**清空启动器草稿**。否则 `persistDrafts()` 会把「1+1」留到下次打开。
- 快捷结果不创建对话、不写历史、不发任何网络请求。
- 后续可加 ⌥↩「粘贴到 <原应用>」：启动器打开前已经记下了前台应用（`tools?.targetApplication`），可以复用 `TextInjection` 的粘贴通路。放到 M2，因为要处理焦点恢复和失败回退。

### 2.5 中间态与错误

- **算式没写完**（以运算符或左括号结尾，如 `12*3+`）：保留上一次的结果行，数值变暗（`textTertiary`），不让面板高度在每次按键时跳动。上一次也没有结果时，什么都不显示。
- **语法完整但无法计算**（除以 0、`sqrt(-1)`、溢出）：显示结果行，结果位置显示原因（「除数不能为 0」「超出可计算范围」），↩ 不可用，高亮落到「问 AI」行。
- **不是算式**：不显示快捷结果，回车照常问 AI。

## 3. 什么算「数学算式」

这是体验的关键：识别过宽，会抢走用户本来要问 AI 的输入；过窄，又不好用。规则如下。

**规范化（先做）**

- 全角转半角：`０-９ ＋ － × ÷ （ ） ％ ＾ ． ，`，中文输入法下也能直接用。
- `×` `x` `X`（两边都是数字时）→ `*`；`÷` → `/`；`**` → `^`；末尾的 `=` 去掉（`1+1=` 也行）。
- 千分位逗号：只有在数字中、并且后面正好是 3 位数字时才当千分位，其它逗号是函数参数分隔符。

**认定为算式，必须同时满足**

1. 整串能被完整解析（第 4 节的文法），不允许残留字符；
2. 至少含一个运算符、函数调用或常量（`2024` 这种纯数字不算，`pi` 算）；
3. 长度 ≤ 256 字符；
4. 不命中「像别的东西」的排除规则：
   - 日期：`2024-10-05`、`2024/10/5`、`10/5/2024`
   - 电话 / 编号：`138-1234-5678`、`010-12345678`
   - 时间与比分：`10:30`、`3:2`（`:` 本来就不在文法里，这里只是说明）
   - 版本号、IP：`1.2.3`、`192.168.0.1`（解析就会失败）

排除规则只看整串的形状，用正则判断，写成表驱动测试。

**设置项**：设置 → 随便问 → 「快捷结果」里提供每个来源的开关（本期只有「计算器」），默认开启。

## 4. 计算引擎

### 4.1 为什么不用 `NSExpression`

`NSExpression(format:)` 最省事，但不能用：

- 非法输入会抛 Objective-C 异常，Swift 接不住，**直接崩溃**。而启动器会对每次按键都尝试解析。
- 整数运算：`1/2` 得 `0`。
- 格式串支持 `FUNCTION(...)`，能调用任意 selector，不能拿用户输入去喂。
- 浮点误差：`0.1+0.2` 得 `0.30000000000000004`。

所以自己写一个小的递归下降解析器，数值用 `Decimal`。

### 4.2 文法与语义

```
expr     := term (('+' | '-') term)*
term     := unary (('*' | '/' | 'mod') unary)*      // 取模写作 mod，% 只表示百分号
unary    := ('-' | '+') unary | power
power    := postfix ('^' unary)?                         // 右结合：2^3^2 = 512；-2^2 = -4
postfix  := primary ('%' | '!')*
primary  := number | constant | function '(' args ')' | '(' expr ')'
number   := 十进制（可带千分位、小数、科学计数 1e3） | 0x… | 0b…
constant := pi | π | e
function := sqrt abs round floor ceil ln log log2 sin cos tan asin acos atan min max
```

- **百分号**：后缀 `%` 是 ÷100（`50%` = 0.5）；但 `a + b%`、`a - b%` 按日常计算器理解为 `a × (1 ± b/100)`，即 `200+10%` = 220，与 macOS 计算器、手机计算器一致。`a * b%` 仍是 `a × b/100`。
- **精度**：加减乘除、乘方（整数指数）、百分比、阶乘用 `Decimal`，所以 `0.1+0.2` = `0.3`、金额计算不出尾差。三角、对数、开方和非整数乘方转 `Double` 计算，结果保留 15 位有效数字再转回。
- **显示**：最多 15 位有效数字，去掉末尾的 0；绝对值 ≥ 10¹⁵ 或 < 10⁻⁶ 时主结果改用科学计数。
- **三角函数**用弧度；`sin(30°)` 支持 `°` 后缀表示角度。

### 4.3 安全与性能边界

- 输入 ≤ 256 字符，括号嵌套 ≤ 64 层，超出直接判定「不是算式」。
- 整数指数 \|n\| ≤ 1000，阶乘 n ≤ 170，超出报「超出可计算范围」，防止一次按键卡住主线程。
- 纯函数、无副作用、无 I/O，单次计算在微秒级，主线程同步执行即可，无需防抖。

## 5. 架构：可扩展的快捷结果

### 5.1 模块与文件

新目录 `Sources/Typeflux/Ask/QuickResults/`：

| 文件 | 职责 |
|------|------|
| `AskQuickResult.swift` | 结果模型：`AskQuickResult`（id、来源、标题、副标题、图标、排序分、默认操作、附加操作、格式行） |
| `AskQuickResultProvider.swift` | 来源协议 |
| `AskQuickResultEngine.swift` | 调度：调用各来源、合并、排序、分组、取消过期请求 |
| `Calculator/AskCalculatorLexer.swift` | 规范化 + 词法 |
| `Calculator/AskCalculatorParser.swift` | 递归下降解析，产出 AST |
| `Calculator/AskCalculatorEvaluator.swift` | 求值（`Decimal` / `Double`） |
| `Calculator/AskCalculatorFormats.swift` | 千分位、中文大写、英文金额、科学计数、进制 |
| `Calculator/AskCalculatorProvider.swift` | 把上面串起来，实现来源协议 |
| `AskQuickResultsView.swift` | 启动器里的列表视图 |
| `AskConversationModel+QuickResults.swift` | 模型侧状态与执行动作 |

### 5.2 接口

```swift
/// What the launcher's text looks like to a quick-result source.
struct AskQuickQuery: Equatable, Sendable {
    var text: String
    var generation: Int
}

enum AskQuickAction: Equatable, Sendable {
    case copy(String)
    case open(URL)              // apps, documents
    case reveal(URL)            // show in Finder
    case insertIntoTarget(String)
}

protocol AskQuickResultProvider: Sendable {
    var id: String { get }
    /// Cheap, synchronous answers such as the calculator. Called on every keystroke.
    func immediateResults(for query: AskQuickQuery) -> [AskQuickResult]
    /// Slower sources such as Spotlight. Called after a short debounce; the
    /// engine cancels the task when the text changes.
    func results(for query: AskQuickQuery) async -> [AskQuickResult]
}
```

两档接口的原因：计算器必须逐键同步出结果，不能有闪烁；应用、文档搜索要走 Spotlight，必须异步、防抖（约 120 ms）、可取消。引擎用 `generation` 丢弃过期结果，和现有的启动任务取消方式一致。

**排序**：每条结果带 0–1 的分数。计算器认定为算式时给 1.0（独占首位）；应用名完全匹配 0.9、前缀 0.8、拼音首字母 0.7 …… 同分按来源固定顺序。按来源分组显示（「计算器」「应用」「文档」），每组最多 N 条，总高度有上限，超出滚动。

### 5.3 接入点（改动现有代码）

- `AskComposer`：
  - 新增 `showsQuickResults`（条件见 2.1），和 `showsLauncherSuggestions` 一样只在 `launcher` 下生效；
  - `card` 里在 `AskLauncherSuggestions` 的位置渲染 `AskQuickResultsView`；
  - `submit()` 增加分支：有快捷结果时执行高亮行的默认操作；
  - 高度上报：`AskQuickResultsView.height(for:)` 和 `AskLauncherSuggestions.height` 一样是纯函数，`onChange` 时调用 `reportHeight()`。
- `AskComposerTextView.keyDown`：回车时把是否按下 ⌘ 传给 `onSubmit`，区分 ↩ 和 ⌘↩。
- `AskConversationModel`：`@Published var quickResults`，随 `launcherDraft.text` 变化重算；执行动作后清空 `launcherDraft` 并关闭启动器（通过现有 `onDismiss`）。
- 本地化：新增 `ask.quick.*` 文案，5 种语言（en / zh-Hans / zh-Hant / ja / ko）。
- 设置：`AskToolsSettingsView` 旁边加「快捷结果」开关组。

工作区里的输入框（`launcher == false`）**不接入**：那是在一段对话里继续提问，`1+1` 更可能就是问题本身。

### 5.4 以后的来源（不在本期实现）

| 来源 | 实现思路 | 注意 |
|------|---------|------|
| 应用 | 启动时扫描 `/Applications`、`~/Applications`、`/System/Applications`，取 `CFBundleDisplayName` + 本地化名，建内存索引；`NSWorkspace` 监听安装/卸载 | 中文名做拼音全拼和首字母匹配（`CFStringTransform` 转拉丁字母），如「微信」可用 `wx` 找到 |
| 文档 | `NSMetadataQuery`，限定在用户目录，按 `kMDItemDisplayName` 匹配，按最近使用排序 | 异步、防抖；可结合已有的文件夹授权（`AskFolderGrants`） |
| 历史对话 | 复用 `AskSearchPalette` 的检索 | 打开对应对话 |
| 单位 / 日期换算 | 同计算器一样做成同步来源 | `10km in mi`、`今天+30天` |
| 汇率 | 同步解析 + 异步取汇率，缓存 | 唯一需要联网的来源，单独开关 |
| 语音算式 | 听写结果「一百二十乘以三」先做中文数字与运算词的规范化，再交给计算器 | 和 Typeflux 的语音输入天然契合 |
| 网页搜索快捷词 | `g 关键词`、`bd 关键词` | 可配置 |

## 6. 测试计划

单元测试放在 `Tests/TypefluxTests/`，与生产文件同名，目标覆盖率 ≥ 90%：

- `AskCalculatorParserTests`：运算优先级、右结合乘方、一元负号、括号、函数、常量、`0x` / `0b`、千分位、科学计数、全角输入、末尾 `=`、嵌套深度上限。
- `AskCalculatorEvaluatorTests`：`0.1+0.2 = 0.3`、`200+10% = 220`、`50% = 0.5`、`1/3` 的显示精度、除以 0、`sqrt(-1)`、阶乘上限、超大指数。
- `AskCalculatorDetectionTests`（表驱动）：应识别（`1+1`、`(3+4)*5`、`pi*2`、`１＋１`）与不应识别（`2024`、`2024-10-05`、`138-1234-5678`、`1.2.3`、`hello 1+1`、`1+`）。
- `AskCalculatorFormatsTests`：中文大写（`2` → `贰元整`、`100.05` → `壹佰元零伍分`、`1005` → `壹仟零伍元整`、`10000` → `壹万元整`、`100000000` → `壹亿元整`、`0.5` → `伍角`、负数加「负」）、英文金额、科学计数、进制。
- `AskQuickResultEngineTests`：合并与排序、过期 generation 被丢弃、异步来源被取消。
- `AskQuickResultsViewTests`：高度计算、格式行上限、提示文案切换。
- `AskComposer` 相关：有快捷结果时 ↩ 复制、⌘↩ 问 AI、草稿被清空。

## 7. 里程碑

| 阶段 | 内容 |
|------|------|
| M1 | 快捷结果框架（同步档）+ 计算器 + 结果视图 + 键盘 + 设置开关 + 测试 |
| M2 | 异步档 + 应用搜索（含拼音）+ ⌥↩ 粘贴到原应用 |
| M3 | 文档搜索、历史对话 |
| M4 | 单位 / 日期 / 汇率换算、语音算式 |

## 8. 待确认

1. ↩ 的默认行为：本方案是「复制结果并关闭」。另一种是「把结果写回输入框」（`1+1` 变成 `2`，可以继续算）。建议默认复制，后者作为 Tab 的行为。
2. `200+10%` 按日常计算器语义算作 220（而不是 200.1），是否认可。
3. 中文大写金额默认显示「元角分」形式；需不需要再提供不带「元」的纯数字大写（`贰仟肆佰陆拾玖`）。
