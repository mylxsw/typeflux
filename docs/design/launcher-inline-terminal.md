# 启动器内置终端：在启动器里直接运行、多轮交互（GUL-697）

> 状态：已确认（↩ 默认启动器内运行、空闲会话保留 30 分钟、AI 解释在 P2）。文案按 GUL-699 精简，§9 是逐状态的最终文案清单。配套可交互设计稿：`docs/design/launcher-inline-terminal.html`（`?s=<id>` 打开某一屏，`?light=1` 浅色，`?solo=1` 只显示一屏）。截图在 `docs/design/launcher-inline-terminal/`。
>
> 设计稿里的 shell 是模拟的：内置了一个小文件系统和 `ls` `cd` `cat` `git` `make test` `go test` `npm init` `npm run dev` `ping` `brew upgrade` `sudo` `python3` `htop` `vim` `rm -rf` 等命令，足够把各种交互走一遍。

## 0. 一页结论

| | 方案 |
|---|---|
| 入口 | 不变：`>` 或 `cmd ` 进入终端模式。输入框换成等宽字体，灰色字是历史命令的建议（`→` / `⇥` 接受）|
| 文案 | **不写副标题、说明行、快捷键底栏和提示文字**：靠布局、图标、颜色和标准快捷键表达；快捷键放在按钮的悬停提示里（§4 是完整列表）|
| ↩ | **默认在启动器里直接运行**（原来是关掉启动器、另开一个窗口）。`⌘↩` 独立窗口，`⌥↩` 外部终端（Terminal / iTerm2）|
| 形态 | 启动器原地展开成终端：顶部是目录 + Git 分支，中间是一条条「命令块」，底部是常驻提示符 |
| 多轮 | 背后是**一个持续的 zsh 会话**：`cd`、`export`、别名、函数在下一条命令里仍然有效；`↑` 历史、`⇥` 补全 |
| 交互 | 命令读输入时提示符变蓝、左侧是程序名（`npm ›`）；读密码时不回显、不进历史；`python3` 等 REPL 可以多轮；`htop` / `vim` 等全屏程序接管画面 |
| 单独打开 | `⌘O` 把会话**原样搬到独立窗口**（同一个进程、同一份输出，不重跑）；窗口有标签页、置顶，可以「收回到启动器」|
| 后台 | `esc` 隐藏启动器，命令继续跑，出现在状态菜单的「后台任务」里；启动器首页顶部列出终端会话；长命令结束发通知 |
| 输出 | 每个块可以复制输出、`⌘↩` 插入回原来的应用、重新运行、折叠；失败的块可以让 AI 解释并给出下一条命令 |
| 安全 | `rm -rf`、`git push --force`、`git reset --hard`、`sudo rm`、`dd` 等先说明影响再要求 `⌘↩` 确认 |

## 1. 现状与问题

现在的实现（GUL-431）：

- `AskTerminalCommandPlugin`：`>` / `cmd` 关键字，只生成一个「运行」计划；按 ↩ 后 `AskConversationModel.submitTerminalCommand` 关闭启动器，交给 `TerminalRunnerCenter.present` 打开一个新的浮动窗口。
- `TerminalRunnerWindowController` + `TerminalRunnerView`：每条命令一个窗口，标题栏是命令和状态，下面是 SwiftTerm 的 `TerminalRunnerTerminalView`，底部是复制、重新运行、在外部终端打开、插入。
- `TerminalShellLaunch` 用 `zsh -l -i -c '<command>'` 启动；`TerminalRunModel` 管一条命令的生命周期（运行 / 结束 / 无法启动、Ctrl-C 两段式中断、隐藏输入检测、备用屏幕）。
- 设置：运行方式（内置 / 外部）、运行结束后（智能 / 保持打开 / 自动关闭）、加载配置、工作目录、置顶、通知。

问题：

1. **离开了启动器**。每次 ↩ 都关掉启动器、弹出一个新窗口，焦点和视线都要跳一次。看一眼 `git status` 这种小事成本太高。
2. **不能多轮**。每条命令是独立的 `zsh -c`：`cd` 后再跑下一条，目录又回去了；`export` 的变量也没了。想连续操作只能一次次重新输入 `>`。
3. **窗口越开越多**。每条命令一个窗口，没有合并和切换的地方；想回看上一条的输出要去找窗口。
4. **交互能力在，但入口不清楚**。PTY 其实支持输入（`npm init`、`sudo`），但用户在启动器里时看不到这件事，只能在弹出的窗口里摸索。

## 2. 需求理解

- 在启动器窗口里直接运行命令行命令，**结果就地显示**。
- 内嵌一个真正的终端：**可以多轮交互**（连续命令、程序问答、密码、REPL、全屏程序）。
- **可以单独打开**：一个会话随时变成独立窗口，也能收回来。
- 本阶段交付：基于现状的、可交互的高保真设计稿。

## 3. 交互

### 3.1 输入 `>`（截图 `hint`）

- 启动器首页输入 `>`（或 `cmd ` / 关键字设置里配置的其他触发词）变成绿色「终端」标签，输入框改为等宽字体，占位文字沿用现有的「输入 Shell 命令」。
- 输入时，历史里以它开头的最近一条命令以灰字补在后面，`→` 或 `⇥` 接受。下方列表（行只有标题，没有副标题；列表下面没有快捷键底栏）：
  - 第一行是命令本身，右侧是它将要运行的目录和 `↩`（没输入命令时标题是「打开终端」）；输入了命令时再多两行「在窗口中运行 `⌘↩`」「在 Terminal 中运行 `⌥↩`」。
  - **最近**：按输入过滤，命中部分高亮；`↑↓` 选中、`⇥` 填入、↩ 直接运行。
  - **终端会话**：已有会话时列出来，↩ 回到它。
- 空输入时 `⌫` 退出终端模式，和其他关键字一致。

### 3.2 启动器内运行（截图 `inline`）

按 ↩ 后启动器**原地向下展开**（宽度 680 不变，高度跟内容增长，最高约 560）：

1. **头部**：`终端` 小标签 · 目录胶囊（`~/Projects/typeflux ⎇ feat/inline-terminal*`，`*` 表示有未提交改动）· 会话标签（多于一个时出现）· `+` 新会话 · `⧉`（悬停提示「移到窗口 ⌘O」）。按钮只有图标。
2. **命令块列表**（终端底色，比玻璃深一点）：每条命令一个块。
   - 块头：`❯ 命令`，不在当前目录执行的块显示它的目录；右侧是耗时和结果（运行中转圈、`✓`、`✗ 1` 红色、`⌃C`、`已取消`）。等待输入时不加徽标，由提示符的颜色表达。
   - 输出：等宽、保留 ANSI 颜色、链接可点。失败块左侧有红色细边。
   - 悬停或选中块时出现图标按钮：复制输出、插入到 <来源应用>、重新运行、`✦` AI 解释（仅失败块）、折叠；名称和快捷键只在悬停提示里。运行中的块只有「中断」。折叠后显示 `⋯ 12 行`。
   - 新输出到来时，如果用户停在底部就自动跟随滚动；往上翻看时不打断。
3. **提示符**（常驻底部）：`❯` + 输入框，没有占位文字、没有右侧提示。运行中整行变淡。会话结束（`exit`）时占位文字是「会话已结束 · ↩ 新会话」——这是唯一保留的提示，因为布局表达不了「再按 ↩ 会起一个新 shell」。
4. **没有底栏**。快捷键见 §4；空会话不显示欢迎文字。

> 为什么输入框从顶部移到底部：多轮之后，输出是从上往下长的，提示符跟在最后一个输出下面，眼睛不用来回跳——这是所有终端的习惯。首页 / 提示阶段仍然在顶部输入，和启动器其他功能一致；按下 ↩ 的那一刻，启动器展开、提示符落到底部。

### 3.3 多轮会话（截图 `session`）

- 一个会话对应**一个持续运行的交互式 zsh**（见 §5.1）。`cd`、`export`、`source`、函数、别名都会留到下一条命令。
- 头部目录胶囊和 Git 分支随 `cd` 实时更新。
- `↑ ↓` 翻历史（跨会话共享，和 zsh 的 `HISTFILE` 分开存，见 §5.4）；`⇥` 补全命令、子命令和路径，多个候选时在提示符上方列出、再按 `⇥` 循环。
- `⌥↑ ⌥↓` 在块之间移动选择（选中块蓝色左边），选中后：`⌘C` 复制输出、`⌘↩` 插入回原来的应用、`⌘R` 重新运行、`⌘E` AI 解释；`esc` 取消选择。没有选中时 `⌘↩` 插入最近一条有输出的块。
- `⌘K` 清屏（只清掉块，不影响会话状态）。
- **AI 解释**：失败块上点 `✦`（或 `⌘E`），在块下方出现解释卡片：`✦` + 解释正文，下面一条建议命令（带 `⇥` 键帽）和「在 Ask 中继续」按钮；卡片没有标题，加载中只有 `✦` 和三个点。点建议命令或 `⇥` 填入提示符（**不自动运行**）；「在 Ask 中继续」把命令、输出和解释带进一个新对话。

### 3.4 交互输入（截图 `stdin`、`x-password`）

PTY 本来就支持输入，这里要做的是**让用户知道现在键入的东西去哪儿了**：

- 命令在等标准输入（如 `npm init` 的一连串问题、`[y/N]` 确认）时，提示符变蓝，左侧是程序名（`npm ›`）；程序的问题已经在输出最后一行，提示符不再重复。↩ 把这一行发给进程。
- 读密码（`sudo`、`ssh`；沿用 `TerminalRunModel.readsHiddenInput` 的检测）时提示符变橙、左侧是程序名和锁，输入框是密码框：**不回显、不进历史、不进补全**。不写「输入不会显示」之类的说明。
- `python3`、`node`、`psql` 这类 REPL 同理，可以一直交互，直到退出。
- `⌃C` 中断，`⌃D` 发送 EOF。中断仍然两段式：第一次 Ctrl-C，再按一次「强制结束」挂断进程组（沿用现有行为）。

> 实现上提示符就是终端的行编辑：未运行时由 Typeflux 编辑（补全、建议、历史），运行时把按键原样写进 PTY。见 §5.2。

### 3.5 全屏程序（截图 `tui`）

- 程序切到备用屏幕（`htop`、`vim`、`less`、`top`、`man`……，沿用 `alternateScreen` 检测）时：启动器长到最高，命令块让位给程序画面，提示符隐藏，**所有按键都发给程序**（包括 `esc`，所以隐藏启动器改用全局快捷键或点外面）。
- 没有提示条；头部的 `⧉` / `⌘O` 照常可以移到窗口。程序退出后回到块列表，这个块不留输出（和真实终端一样）。

### 3.6 高风险命令确认（截图 `danger`）

- 运行前按规则匹配；命中时不运行，块里出现一行红色卡片：`⚠` + 影响（例：「永久删除 `build .build`（约 1,285 个文件），不进废纸篓」）+ 同一行右侧的「取消 esc」「仍然运行 ⌘↩」。没有标题和脚注；目录看头部胶囊。
- `⌘↩` 仍然运行，`esc` 取消（块标记「已取消」）。普通命令完全不打扰。
- 初始规则：`rm -r/-f`、`sudo rm`、`git push --force/-f`、`git reset --hard`、`git clean -f`、`dd if=`、`mkfs`、`diskutil erase`、`chmod -R 777`、`chown -R`。规则只是提醒，不是安全边界；设置里可关。

### 3.7 隐藏与后台（截图 `bg`）

- `esc` / 点启动器外面 / 再按启动器快捷键：启动器隐藏，**会话和正在运行的命令都保留**。toast：「npm run dev 继续运行」。
- 运行中的命令通过 `BackgroundActivitySource` 出现在状态菜单顶部的「后台任务」区（`终端 · npm run dev · 2m 14s`，点按回到会话）。按项目约定，菜单栏图标本身不变。
- 再次打开启动器：
  - 首页顶部多一组「终端会话」，每行标题是会话最后一条命令、副行是目录（数据，不是说明）、右侧是状态徽标（运行中显示耗时 `2m 14s`、`等待输入`、失败显示 `✗ 1`、空闲不显示）；在窗口里的会话用窗口图标。↩ 回到会话。
  - 直接输入 `>` 也会继续最近的会话。
- 运行超过 10 秒的命令在启动器隐藏时结束：发系统通知，一行正文「✓ make test · 38.2s」（失败「✗ 1 go test ./... · 1.8s」），点按通知回到它的输出（沿用 `notifyUser` 和 `notificationThreshold`）。
- 空闲会话保留多久由设置决定（默认空闲 30 分钟后结束 shell）；**运行中的命令不会因为超时被杀**。

### 3.8 独立窗口（截图 `window`、`x-popout`）

- `⌘O`（或头部 `⧉`）：启动器缩向窗口位置，同一个会话出现在独立窗口里。**进程、输出、历史都不变，命令不中断、不重跑**。
- 窗口：
  - 标题栏是会话标签（状态点 + 目录 + 正在跑的命令），`+` / `⌘T` 新会话，`⌘1…9` 切换，`⌘W` 关闭会话（有命令在跑时先确认）。
  - 标题栏右侧：目录胶囊、置顶（默认开，沿用 `pinned`）、收回到启动器（`⌘O`），都是图标按钮。
  - 主体和启动器完全一样的块 + 提示符。没有状态栏。
- 窗口适合：开发服务器、`tail -f` 日志、长时间构建、全屏程序。
- 关闭窗口：有命令在跑时沿用现在的确认文案（「“%@” 仍在运行……」），确认后挂断。
- 从提示阶段直接 `⌘↩` 也会在窗口里开一个新会话运行这条命令。

### 3.9 设置（截图 `settings`）

关键词设置页「终端命令」。行只有标题和控件，**没有说明行、没有「新」标记**，页面顶部也不写触发词说明（标题旁的标签显示 `>`）。下表的「说明」列是给实现者的，不进界面：

| 设置 | 选项 | 说明 |
|---|---|---|
| ↩ 在哪里运行 **新** | **启动器内**（默认）/ 独立窗口 / 外部终端 | 取代现在的「运行方式」（内置 / 外部）。原「内置」用户迁移为「启动器内」；`⌘↩` 总是另一种内置方式 |
| 新会话的起始目录 **新** | **上次的目录**（默认）/ 跟随访达 / 固定目录 | 「固定目录」就是现在的「工作目录」 |
| 加载配置 | 登录 + 交互 / 仅登录 | 不变 |
| 空闲会话保留 **新** | **30 分钟** / 一直 / 不保留 | 只影响空闲会话；运行中的命令不受影响 |
| 运行前确认高风险命令 **新** | 开（默认）| |
| 后台命令完成时通知 | 开 | 不变 |
| 插入的内容 **新** | **仅输出** / 命令 + 输出 | |
| 独立窗口 · 运行结束后 | 智能 / 保持打开 / 自动关闭 | 只对「独立窗口」方式的单条命令生效 |
| 外部终端 | Terminal / iTerm2 | 不变 |

## 4. 快捷键

| 场景 | 按键 | 作用 |
|---|---|---|
| 提示阶段 | ↩ / ⌘↩ / ⌥↩ | 启动器内运行 / 独立窗口 / 外部终端 |
| | → 、⇥ | 接受灰字建议；⇥ 也做补全 |
| | ⌫（空输入）| 退出终端模式 |
| 会话 | ↩ | 运行；会话已退出时开新会话 |
| | ↑ ↓ | 历史 |
| | ⇥ | 补全（多个候选时列出，再按循环）|
| | → | 接受灰字的历史建议 |
| | ⌥↑ ⌥↓ | 选择命令块 |
| | ⌘C / ⌘↩ / ⌘R / ⌘E | 复制输出 / 插入到来源应用 / 重新运行 / AI 解释（对选中块；⌘↩ 没选中时取最近一块）|
| | ⌘K | 清屏 |
| | ⌘T / ⌘W / ⌘1…9 | 新会话 / 关闭会话 / 切换会话 |
| | ⌘O | 移到独立窗口 / 收回到启动器 |
| | ⌃C / ⌃D | 中断（再按强制结束）/ EOF |
| | esc | 关闭补全 → 取消选择 → 隐藏启动器（会话保留）|
| 确认 | ⌘↩ / esc | 仍然运行 / 取消 |
| 全屏程序 | 全部按键 | 发给程序；⌘O 移到窗口 |

## 5. 实现方案

### 5.1 持续会话：一个交互式 zsh + shell integration

- 每个会话启动一次 `zsh -l -i`（遵守「加载配置」），不再每条命令 `zsh -c`。复用 `TerminalPTYProcess` 和 `TerminalShellLaunch` 的环境构造，`TYPEFLUX_TERMINAL=launcher` 方便用户在 `.zshrc` 里区分。
- 用 `ZDOTDIR` 指向 Typeflux 的一个小目录：它的 `.zshrc` 先 `source` 用户原来的 `.zshrc`，再追加 shell integration（`precmd` / `preexec` 钩子），发出：
  - OSC 133 `A/B/C/D;<exit>` —— 提示符开始、命令开始、输出开始、命令结束和退出码，用来**切分命令块**；
  - OSC 7 `file://host/path` —— 当前目录，用来更新目录胶囊；
  - 自定义 OSC（如 `1337;TypefluxGit=branch,dirty`）或在 Swift 里按目录异步读 `.git/HEAD` 得到分支。
- 命令通过 PTY 写入 `<command>\n`（bracketed paste 包裹，避免多行粘贴被逐行执行）。现有的单行、16 KiB 校验（`TerminalCommandRequest.problem`）保留。
- 没有装 zsh 或用户的 shell 是 bash / fish：bash 用 `PROMPT_COMMAND` + `PS0` 发同样的标记；fish 用 `fish_prompt` / `fish_preexec` 事件。拿不到标记时退化为「整屏一块」，功能可用，只是没有块切分。

### 5.2 渲染：已完成的块是静态文本，正在运行的块是 SwiftTerm

- 每个会话仍然有一个 SwiftTerm `Terminal`（解析 ANSI、备用屏幕、光标）。
- 收到 OSC 133 `D` 时，把这一块在缓冲区里的行（带颜色属性）**快照成 `AttributedString`**，放进 SwiftUI 的块列表；之后这块不再依赖终端缓冲区，可以随意折叠、复制、选择。
- 正在运行的块用 `TerminalRunnerTerminalView` 渲染在列表最后（高度跟随内容，最多到可视区）；进入备用屏幕时它占满整个区域（§3.5）。
- 提示符：命令未运行时是 Typeflux 自己的 `NSTextField`（补全、灰字建议、历史）；运行时焦点交给 SwiftTerm 视图，或者把提示符输入逐行写入 PTY（等待输入状态）。是否在读密码沿用 `readsHiddenInput`（检测终端 `ECHO` 标志）。
- 每个块的输出上限（例如 5,000 行），超出部分折叠（`⋯ 1,234 行`，点按展开），避免启动器卡顿。

### 5.3 会话归属与搬家

- 新增 `TerminalSessionCenter`（取代 `TerminalRunnerCenter` 的职责）：持有所有会话和它们的 `TerminalSessionModel`（由 `TerminalRunModel` 演进而来：一个 shell 进程 + 块列表 + 当前块状态）。
- 会话有一个 `host`：`.launcher` 或 `.window(id)`。`⌘O` 只是改 host，把同一个 model 交给另一个视图层级；进程和 SwiftTerm `Terminal` 不重建。
- 启动器视图：在 `AskComposerViews` 里按 `isTerminalCommandMode` 渲染 `TerminalLauncherView`（和系统监控、日历的「插件自带一块启动器界面」同一条路）；按键交给会话 model。
- `allowsLauncherOutsideDismissal`：点外面隐藏启动器，但确认卡出现时保留（与现在「授权对话框期间保留」同理）。
- 退出 App：`terminateAll` 挂断所有会话（沿用）。

### 5.4 历史、补全

- 历史：Typeflux 自己的 `TerminalCommandHistory`（SQLite 或 JSON，最多 1,000 条，按目录加权），复用 `LauncherInputHistory` 的去重和隐私处理；**密码输入永不进入**。不读用户的 `~/.zsh_history`（避免意外暴露），但可以作为一个可选导入。
- 补全：第一版做 Typeflux 本地补全（`$PATH` 里的可执行文件、常见子命令、目录 / 文件）。后续可以借 zsh 的 `compsys`（`zpty` 捕获补全结果），成本较高，放到后续。

### 5.5 安全

- 高风险规则在提交前对**原始命令字符串**匹配，只提示不拦截；不做 shell 解析，不承诺完整。
- AI 解释只发送这个块的命令、退出码和输出末尾（截断到 4 KB），并在第一次使用时说明；密码块没有 AI 入口。
- 现有的外部终端自动化授权（`TerminalCommandDispatcher.authorize`）不变。

## 6. 分期

| 阶段 | 内容 |
|---|---|
| P1 | 启动器内运行 + 持续会话（OSC 133/7）+ 命令块 + 历史 / 建议 + 交互输入 / 密码 + 隐藏后台 + 通知 + `⌘O` 搬到窗口（单会话）|
| P2 | 多会话标签（启动器和窗口）、全屏程序在启动器内、Tab 补全、高风险确认、插入格式、AI 解释 / 建议命令 |
| P3 | zsh 原生补全、从 `.zsh_history` 导入、bash / fish 支持 |

## 7. 已确认

1. ↩ 默认「启动器内运行」，老用户的「内置」迁移过来。
2. 空闲会话默认保留 30 分钟。
3. AI 解释提前到 P2。

## 8. 截图

| 文件 | 内容 |
|---|---|
| `hint.png` | 输入 `>`：等宽输入、历史建议、运行方式 |
| `inline.png` / `inline-light.png` | 启动器内运行，`make test` 流式输出 |
| `session.png` / `session-light.png` | 多轮会话、失败块的 AI 解释 |
| `stdin.png` / `stdin-light.png` | `npm init` 交互输入 |
| `x-password.png` | `sudo` 密码输入 |
| `tui.png` | `htop` 全屏程序 |
| `danger.png` | 高风险命令确认 |
| `bg.png` | 后台运行：首页终端会话 + 完成通知 |
| `window.png` / `window-light.png` | 独立窗口、多标签 |
| `x-popout.png` | `⌘O` 把运行中的会话搬到窗口 |
| `x-selected.png` | `⌥↑` 选中命令块 |
| `x-inserted.png` | `⌘↩` 把输出插入回备忘录 |
| `settings.png` / `settings-light.png` | 关键词设置 |

## 9. 文案清单（最终）

实现以这张表为准，`en` 列是建议译文。表里没有的文字不要加：不加副标题、说明行、快捷键底栏、占位提示、「新」标记。按钮名称和快捷键放在悬停提示（tooltip）里。

| 状态 / 位置 | zh-Hans | en |
|---|---|---|
| 终端模式标签 | 终端 | Terminal |
| 终端模式输入框占位（沿用 `terminal.command.placeholder`）| 输入 Shell 命令 | Enter a shell command |
| 提示阶段 · 第一行（空输入）| 打开终端 | Open Terminal |
| 提示阶段 · 第一行（有输入）| 命令本身 + 右侧目录 + `↩` | command + directory + `↩` |
| 提示阶段 · 第二行 | 在窗口中运行 `⌘↩` | Run in Window `⌘↩` |
| 提示阶段 · 第三行（沿用 `terminal.command.runIn`）| 在 %@ 中运行 `⌥↩` | Run in %@ `⌥↩` |
| 提示阶段 · 分组 | 最近 / 终端会话 | Recent / Terminal Sessions |
| 首页建议行 | 终端命令 + `>` 徽标 | Terminal Command + `>` badge |
| 首页会话行 | 标题：最后一条命令；副行：目录 | title: last command; subtitle: directory |
| 会话行 / 块头状态 | `2m 14s`（运行中）· 等待输入 · `✗ 1` · `✓` · `⌃C` · 已取消 | `2m 14s` · Waiting for Input · `✗ 1` · `✓` · `⌃C` · Cancelled |
| 头部按钮 tooltip | 新会话 ⌘T · 移到窗口 ⌘O | New Session ⌘T · Move to Window ⌘O |
| 块操作 tooltip | 复制输出 ⌘C · 插入到 %@ ⌘↩ · 重新运行 ⌘R · 让 AI 解释 ⌘E · 折叠 / 展开 · 中断 ⌃C | Copy Output ⌘C · Insert into %@ ⌘↩ · Rerun ⌘R · Explain with AI ⌘E · Collapse / Expand · Interrupt ⌃C |
| 折叠的块 | ⋯ %d 行 | ⋯ %d lines |
| 提示符 · 空闲 / 运行中 | （无占位）| (no placeholder) |
| 提示符 · 等待输入 | 程序名 + `›` | program name + `›` |
| 提示符 · 读密码 | 程序名 + 锁图标 | program name + lock icon |
| 提示符 · 会话已结束 | 会话已结束 · ↩ 新会话 | Session ended · ↩ New Session |
| 高风险卡片 | `⚠` + 影响 + 取消 `esc` + 仍然运行 `⌘↩` | `⚠` + impact + Cancel `esc` + Run Anyway `⌘↩` |
| 高风险 · 影响 | 永久删除 %@（约 %d 个文件），不进废纸篓 / 强制覆盖远端分支 / 丢弃 %d 个未提交的改动 / 删除所有未跟踪的文件 / 直接写入或抹掉磁盘 / 批量修改或删除文件 | Permanently deletes %@ (about %d files), skipping the Trash / Force-overwrites the remote branch / Discards %d uncommitted changes / Deletes all untracked files / Writes to or erases a disk / Changes or deletes files in bulk |
| AI 卡片 | `✦` + 正文 + 建议命令 `⇥` + 在 Ask 中继续 | `✦` + text + suggested command `⇥` + Continue in Ask |
| AI 卡片 · 加载中 | `✦` + 三个点 | `✦` + three dots |
| 全屏程序 | （无提示条）| (no banner) |
| 隐藏时 toast | %@ 继续运行 | %@ is still running |
| 复制 toast（沿用 `terminal.runner.copied`）| 已复制 | Copied |
| 系统通知 | 标题 Typeflux 终端；正文 `✓ make test · 38.2s` / `✗ 1 go test ./... · 1.8s` | title Typeflux Terminal; body as left |
| 窗口标题栏 tooltip | 置顶 · 收回到启动器 ⌘O | Keep on Top · Back to Launcher ⌘O |
| 关闭仍在运行的会话 / 窗口（沿用 `terminal.runner.close.*`）| “%@” 仍在运行 + 现有说明 | existing strings |
| 设置 · 标题 | 终端命令（标签显示 `>`）| Terminal Command (badge `>`) |
| 设置 · 分组 | 运行 / 会话 / 独立窗口 | Run / Sessions / Standalone Window |
| 设置 · 行 | ↩ 在哪里运行（启动器内 / 独立窗口 / 外部终端）· 新会话的起始目录（上次的目录 / 跟随访达 / 固定目录）· 加载配置（登录 + 交互 / 仅登录）· 空闲会话保留（30 分钟 / 一直 / 不保留）· 运行前确认高风险命令 · 后台命令完成时通知 · 插入的内容（仅输出 / 命令 + 输出）· 运行结束后（智能 / 保持打开 / 自动关闭）· 外部终端（Terminal / iTerm2）| ↩ Runs In (Launcher / Window / External Terminal) · Start New Sessions In (Last Folder / Finder Folder / Fixed Folder) · Shell Profile (Login + Interactive / Login Only) · Keep Idle Sessions (30 Minutes / Always / Never) · Confirm Risky Commands · Notify When Background Commands Finish · Insert (Output Only / Command + Output) · After Running (Smart / Keep Open / Close) · External Terminal (Terminal / iTerm2) |

现有设置里的 `terminal.runner.shell.*.hint`、`terminal.runner.finish.*.hint` 说明行不再显示；需要时由实现子任务删除或保留为 tooltip。
