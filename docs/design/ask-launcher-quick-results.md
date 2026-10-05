# 随便问：启动器快捷结果（计算器先行）设计方案

> 状态：M1（计算器）、M2（应用搜索，见第 9 节）已实现；M3 及以后仍是设计。配套可交互设计稿：`docs/design/ask-launcher-quick-results.html`（浏览器直接打开），截图见 `docs/design/ask-launcher-quick-results/`。

## 1. 背景与目标

按快捷键（⌥Space）弹出的「随便问」启动器（`AskLauncherView` → `AskComposer(launcher: true)`）目前只做一件事：把输入框内容作为问题发给 AI。输入框为空时，下方是三条起手建议（`AskLauncherSuggestions`）；一旦开始输入，建议消失，回车即 `submitLauncher()` 新建对话。

需求：输入的是数学算式时，**不经过 AI**，在输入框下方直接给出计算结果，像 uTools / Raycast 的计算器那样。后续还会接入「搜索应用」「搜索文档」等。

所以这次不只做一个计算器，而是在启动器里加一层**「快捷结果」（Quick Results）**：本地的、即时的、可扩展的结果来源，计算器是第一个来源。

| # | 目标 | 不做（本期） |
|---|------|-------------|
| G1 | 输入合法算式，边打边出结果，回车复制结果并关闭 | 图形计算、方程求解、符号运算 |
| G2 | 结果附带常用格式：千分位、中文大写金额、英文金额、十六进制 / 二进制，可单独复制 | 汇率换算（要联网取汇率，放到后续） |
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
  | 中文大写金额 | 0 < \|x\| < 10¹⁶；按「分」四舍五入 | `贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分` |
  | 英文金额 | 同上范围且不为负；按 cent 四舍五入 | `SAY US DOLLARS TWO MILLION FOUR HUNDRED SIXTY-NINE THOUSAND ONE HUNDRED THIRTY-FIVE AND CENTS SEVENTY-EIGHT ONLY` |
  | 十六进制 / 二进制 | 结果为整数且在 Int64 范围内，且算式里出现过 `0x` / `0b`；排在最前 | `0xff+1` → `0x100`、`0b100000000` |

  简体中文界面的顺序是：中文大写 → 千分位 → 英文金额；其它语言是：千分位 → 英文金额 → 中文大写。超过 3 行的不显示，保持面板高度稳定。
  很大或很小的结果（\|x\| ≥ 10¹⁵ 或 < 10⁻⁶）主结果直接用科学计数显示（`2^64` → `1.84467440737096 × 10¹⁹`，复制为 `1.84467440737096e19`），不再单独占一行。
- **「问 AI」行**：始终在列表最后，把原文当问题发出（等价于没有快捷结果时按回车）。这是 G3 的保证：计算器识别错了，用户也只需要 ⌘↩。

### 2.3 键盘

| 按键 | 行为 |
|------|------|
| ↩ | 执行高亮行的默认操作。默认高亮是计算器行 → 复制结果并关闭启动器 |
| ⌘↩ | 无论高亮在哪，都按原文问 AI（`submitLauncher()`） |
| ⇧↩ | 换行（现状不变） |
| ↑ / ↓ | 在结果行、格式行、「问 AI」行之间移动，跳过不可执行的行 |
| ⇥ | 把结果写回输入框，接着算（`1+1` 变成 `2`） |
| esc | 关闭（现状不变） |

底部提示随状态切换：有快捷结果时为「↩ 复制结果 · ⌘↩ 问 AI · esc 关闭」；高亮在「问 AI」行、或没有快捷结果时，保持「↩ 发送 · esc 关闭」。

用户用方向键或鼠标选中的行，在继续输入时保持选中；默认高亮则跟随结果（算出来就回到结果行）。

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
2. 至少含一个运算符或函数调用（`2024` 这种纯数字不算；单独的 `pi`、`e` 也不算，因为 `e` 也是很多句子的开头）；
3. 长度 ≤ 256 字符；
4. 不命中「像别的东西」的排除规则：
   - 日期：`2024-10-05`、`2024/10/5`、`10/5/2024`
   - 电话 / 编号：`138-1234-5678`、`010-12345678`
   - 时间与比分：`10:30`、`3:2`（`:` 本来就不在文法里，这里只是说明）
   - 版本号、IP：`1.2.3`、`192.168.0.1`（解析就会失败）

排除规则只看整串的形状，用正则判断，写成表驱动测试。

**设置项**：设置 → Agent → 内置工具 →「启动器计算器」开关，默认开启。以后每个来源一个开关。

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
postfix  := primary ('%' | '!' | '°')*
primary  := number | constant | function '(' args ')' | '(' expr ')'
number   := 十进制（可带千分位、小数、科学计数 1e3） | 0x… | 0b…
constant := pi | π | e
function := sqrt abs round floor ceil ln log log2 sin cos tan asin acos atan min max
```

- **百分号**：后缀 `%` 是 ÷100（`50%` = 0.5）；但 `a + b%`、`a - b%` 按日常计算器理解为 `a × (1 ± b/100)`，即 `200+10%` = 220，与 macOS 计算器、手机计算器一致。`a * b%` 仍是 `a × b/100`。
- **精度**：加减乘除、乘方（整数指数）、百分比、阶乘用 `Decimal`，所以 `0.1+0.2` = `0.3`、金额计算不出尾差。三角、对数、开方和非整数乘方转 `Double` 计算，结果保留 16 位有效数字再转回（去掉 `2.9999999999999996` 这类二进制尾差，又比显示多留一位，`asin(1)*2` 仍能得到正确的 15 位）；`sin(pi)` 这类小于 10⁻¹⁵ 的三角结果按 0 处理。
- **显示**：最多 15 位有效数字，去掉末尾的 0；绝对值 ≥ 10¹⁵ 或 < 10⁻⁶ 时主结果改用科学计数。
- **三角函数**用弧度；`sin(30°)` 支持 `°` 后缀表示角度。

### 4.3 安全与性能边界

- 输入 ≤ 256 字符，括号嵌套 ≤ 64 层，超出直接判定「不是算式」。
- 整数指数 \|n\| ≤ 1000 时用 `Decimal` 计算，更大的指数走 `Double`；阶乘 n ≤ 170。`Decimal` 的上限约为 10¹⁶⁵，超出报「超出可计算范围」。一次按键不会卡住主线程。
- 纯函数、无副作用、无 I/O，单次计算在微秒级，主线程同步执行即可，无需防抖。

## 5. 架构：可扩展的快捷结果

### 5.1 模块与文件

新目录 `Sources/Typeflux/Ask/QuickResults/`（M1 已实现）：

| 文件 | 职责 |
|------|------|
| `AskQuickResults.swift` | 快捷结果的状态：行（结果 / 格式 / 问 AI）、高亮与移动、「没写完时保留上一次结果」的解析入口、复制 |
| `AskQuickResultsView.swift` | 启动器里的列表视图，`height(for:)` 和提示文案是纯函数 |
| `Calculator/AskCalculatorLexer.swift` | 规范化 + 词法 |
| `Calculator/AskCalculatorParser.swift` | 递归下降解析，产出 AST，区分「没写完」和「不是算式」 |
| `Calculator/AskCalculatorEvaluator.swift` | 求值（`Decimal` / `Double`）与错误类型 |
| `Calculator/AskCalculatorNumber.swift` | 15 位有效数字取整，以及原始值、千分位、科学计数几种写法 |
| `Calculator/AskCalculatorFormats.swift` | 中文大写、英文金额、进制，以及格式行的排序 |
| `Calculator/AskCalculator.swift` | 入口：识别（含日期 / 电话排除规则）+ 计算 + 算式显示 |

另有 `Ask/AskConversationModel+QuickResults.swift`（开关读取、执行后清空草稿）。

### 5.2 接口（第一个异步来源时引入）

计算器和应用搜索都是同步的：应用列表常驻内存，逐键查询只要几十微秒。所以 `AskQuickResults.resolve` 直接调用这两个来源，没有提前抽象。第一个需要异步的来源（翻译或文档搜索）加入时，按下面的接口拆出来：

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

- `AskComposer`（`AskComposerViews.swift`）：
  - `@State quickResults`，随草稿文字变化由 `AskQuickResults.resolve` 重算；
  - `showsQuickResults`（条件见 2.1），只在 `launcher` 下生效；
  - `card` 里在 `AskLauncherSuggestions` 的位置渲染 `AskQuickResultsView`，录音时同样变暗、禁用；
  - 键盘：复用编辑器已有的 `onCommandKey` 通道，命令面板没打开时交给 `quickResultsKey` 处理 ↑ / ↓ / ↩ / ⇥ / ⌘↩；
  - 高度上报：`reportHeight()` 加上 `AskQuickResultsView.height(for:)`。
- `AskCommandKey`：新增 `.commandEnter`（⌘↩）。没有快捷结果时它照旧落到发送。
- `AskConversationModel+QuickResults.swift`：`quickResultsEnabled`；`finishQuickResult()` 清空启动器文字并保存草稿。
- 设置：`SettingsStore.askQuickCalculatorEnabled`（默认开），Agent 设置「内置工具」页（`AskToolsSettingsView+Tools.swift`）新增「启动器计算器」开关。
- 本地化：新增 `ask.quick.*`、`ask.settings.quick.*` 文案，5 种语言（en / zh-Hans / zh-Hant / ja / ko）。

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

## 6. 测试

单元测试在 `Tests/TypefluxTests/`：

- `AskCalculatorTests.swift`：识别（应识别 / 不应识别的表驱动用例、没写完、超长、嵌套上限、算式显示、进制）、求值（精度、百分比、乘方、取模、函数、三角、各类错误）、词法（全角规范化、千分位与函数参数的逗号、数字原样保留）。
- `AskCalculatorFormatsTests.swift`：中文大写（`2` → `贰元整`、`100.05` → `壹佰元零伍分`、`1005` → `壹仟零伍元整`、`10000` → `壹万元整`、`100000000` → `壹亿元整`、`0.5` → `伍角整`、`1000000000000` → `壹万亿元整`、负数加「负」）、英文金额、格式行顺序与上限、进制；`AskCalculatorNumber` 的取整与各种写法。
- `AskQuickResultsTests.swift`：行与默认高亮、没写完时保留结果、错误时高亮「问 AI」、移动与跳过、选中行在输入时保持、复制、视图高度、提示文案、设置开关。
- `AskQuickResultsInteractionTests.swift`：用真实的启动器视图按键：↩ 复制并关闭、↑ / ↓ 换行后复制、⇥ 写回、⌘↩ 问 AI、错误时 ↩ 问 AI、esc 关闭、关闭开关后算式照常发给 AI。复制写入测试专用剪贴板，不碰用户剪贴板。
- `AskQuickResultsVisualTests.swift`：设置 `TYPEFLUX_ASK_SNAPSHOTS` 时渲染启动器截图（见下）。
- `AskCommandTests.swift`：⌘↩ 映射为 `.commandEnter`。

实际渲染（`AskQuickResultsVisualTests` 生成）：`ask-launcher-quick-results/quick-calculator-light.png`、`quick-calculator-dark.png`、`quick-error-light.png`、`quick-radix-dark.png`。

## 7. 里程碑

| 阶段 | 内容 |
|------|------|
| M1 | 快捷结果框架（同步档）+ 计算器 + 结果视图 + 键盘 + 设置开关 + 测试 |
| M2 ✅ | 应用搜索（中英文名、首字母、拼音）、↩ 打开、按启动次数排序、设置开关（异步档与 ⌥↩ 写回随翻译 / 文档一起做） |
| M3 | 文档搜索、历史对话 |
| M4 | 单位 / 日期 / 汇率换算、语音算式 |

## 8. 已确认的决定

1. ↩ 复制结果并关闭；⇥ 把结果写回输入框接着算。
2. `200+10%` 按日常计算器语义算作 220。
3. 中文大写金额用「元角分」形式；只有角没有分时以「整」结尾（`伍角整`）。

## 9. M2 应用搜索（已实现）

### 9.1 行为

- 输入不是算式时，在本机应用里查找。最多列 5 个，每行显示图标、名称和安装位置。
- **谁占回车**：查询短（2 个字符以上，最多 3 个词）、不含问号或句读，并且第一名明确匹配（得分 ≥ 0.8，即名称前缀、首字母或拼音命中）时，应用排在第一、默认高亮，↩ 打开它。否则「问 AI」排在第一、保持默认，应用列在下面，用 ↓ 选中后按 ↩ 打开。
  - `wx` → 微信，↩ 打开。
  - `wechat?` → ↩ 问 AI，微信列在下面。
- ⌘↩ 始终问 AI；⇥ 只对计算结果有效。
- 打开应用后关闭启动器、清空输入，并记一次启动次数；常用的应用排在前面。
- 设置 → Agent → 内置工具 →「启动器应用搜索」，默认开启。

### 9.2 匹配与排序（`AskAppMatcher`）

| 命中方式 | 得分 | 例子 |
|---------|------|------|
| 名称完全相同 | 1.0 | `wechat` |
| 拼音全拼完全相同 | 0.95 | `weixin` → 微信 |
| 名称前缀 | 0.9 | `calc` → 计算器（Calculator） |
| 首字母或拼音首字母完全相同 | 0.88 | `vsc`、`wx`、`jsq` |
| 拼音全拼前缀 | 0.86 | `weix` |
| 名称中某个词的前缀 | 0.82 | `studio` |
| 首字母前缀 | 0.8 | `vs` |
| 名称包含 | 0.6 | `hat` → WeChat |
| 字母按顺序出现 | 0.45 | `tbpls` → TablePlus |

- 单个字母只匹配名称或其中某个词的开头。
- 查询里的标点会被忽略（只影响谁占回车）。
- 启动次数每次加 0.005，最多加 0.05；同分时名称短的排在前面。

### 9.3 应用列表（`AskAppIndex`）

- 扫描 `/Applications`、`/System/Applications`、`/System/Library/CoreServices/Applications`、`~/Applications`（各自往下一层，例如 `Utilities`）以及 Finder。跳过 `LSBackgroundOnly` 的后台程序；同一个 bundle ID 只保留先找到的那个。
- 每个应用收集这些名字：Finder 显示名、本地化名、`CFBundleDisplayName` / `CFBundleName`、文件名，以及简体中文名。中文名来自第三方应用的 `zh-Hans.lproj/InfoPlist.strings`，或苹果自带应用的 `InfoPlist.loctable`。因此系统是英文时，输入「微信」或 `jsq` 也能找到。
- 拼音用 `CFStringTransform`（Mandarin → Latin，去掉声调）生成，只在扫描时计算一次。系统转换按单字读音，没有词的上下文（音乐 → yin le，银行 → yin xing），所以应用名里常见的多音词（音乐、银行等）先用一张小表校正。
- 启动器构建时（App 启动后）和每次打开时，如果列表超过 5 分钟，就在后台重新扫描；查询从不等待扫描。启动次数存在 `UserDefaults`。

### 9.4 测试

- `AskAppSearchTests.swift`：名称、首字母、拼音的生成；匹配表与边界（单字母、超长、换行、标点）；排序与启动次数；谁占回车；用临时目录里的假 `.app` 扫描（中文 `.strings` / `.loctable`、后台程序、重复 bundle ID、嵌套文件夹）；后台刷新与过期；`resolve` 与计算器的优先级；记住用户选中的行；视图高度与提示。
- `AskQuickResultsInteractionTests.swift`：真实启动器按键，覆盖 ↩ 打开、问句仍发给 AI、↓ 选中应用、⌘↩、关闭开关，以及按设置决定是否刷新列表。打开应用由假实现记录，不会真的启动应用。

