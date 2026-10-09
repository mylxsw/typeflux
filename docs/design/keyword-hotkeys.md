# 独立的快捷键管理：关键字快捷键（GUL-291）

> 状态：设计稿，待确认。配套可交互设计稿：`docs/design/keyword-hotkeys.html`（`?solo=<id>` 只显示一屏，`?light=1` 浅色，`?s=<id>` 打开某一屏）。截图在 `docs/design/keyword-hotkeys/`：`page` `edit` `add` `conflict` `launcher` `direct-replace` `kwpage`，以及 `light-*`。
>
> 这一阶段只出设计，不改代码。

## 0. 一页结论

| | 现在 | 方案 |
|---|---|---|
| 入口 | 5 个全局快捷键放在「设置 → 语音快捷键」，每个一张大卡片 | 侧边栏新增 **「快捷键」** 页，所有全局快捷键都在这里管理 |
| 关键字 | 只能打开启动器 → 输入 `rw` → 空格/↩ | 可以给任意关键字绑一个**全局快捷键**：选中文字按 `⌃⌥R` 直接润色 |
| 执行方式 | — | 每个快捷键二选一：**在启动器中打开**（打开启动器并自动运行），或**直接执行**（不打开启动器，完成后替换 / 复制 / 浮窗显示） |
| 冲突 | 5 个内置快捷键互相检查 | 内置 + 关键字快捷键统一检查；和 macOS 常用快捷键重复时提醒 |
| 联动 | — | 关键字页加一列「快捷键」，和快捷键页是同一份数据；关键字改名时快捷键跟着走 |

## 1. 现在是怎么工作的

### 1.1 全局快捷键

- 「设置」页的「语音快捷键」区有 5 个固定的快捷键：语音输入 `fn`、辅助快捷键 `fn ⇧`、随便问（启动器）`⌘Space`、人设切换器 `⌥⌘P`、历史记录 `⌥⌘O`（`StudioView.shortcutConfigurationRow`）。每个快捷键占一张大卡片，有录制、恢复默认、取消三个按钮。语音输入卡片下面有「快速录入」，随便问卡片下面有「打开位置」。
- 存储：每个快捷键是 `SettingsStore` 里的一个 JSON 键（`hotkey.activation.json` 等），值是 `HotkeyBinding`（`keyCode`、`modifierFlags`、`pressCount`、`modifierKeyCodes`），`__unset__` 表示取消。改了以后发 `hotkeySettingsDidChange`。
- 监听：`EventTapHotkeyService` 用 CGEventTap 监听这 5 个 binding，`HotkeyAction` 是一个固定的枚举。冲突检查写在 `SettingsViewModel.setXxxHotkey` 里，每个快捷键各写一遍。

### 1.2 启动器关键字

- 在启动器开头输入「关键字 + 空格/冒号」就会进入对应的插件（`AskKeywordMatcher`）。只输入关键字时按 ↩，会处理选中的文字。
- 插件：翻译 `translate`、AI 指令 `prompt`、网页搜索 `web`、文件搜索 `files`、打开聊天 `chat`、单词本、历史、设置，以及每个工作流（`AskWorkflowPlugin`）。插件会声明 `usesSelectionInput`、`runsWithoutInput`、`entersOnReturn` 这几项能力。
- 关键字存在 `settings.askLauncherKeywords` 里，类型是 `[AskKeyword]`（`keyword`、`pluginID`、`options`、`enabled`）。`id` 就是小写的关键字，**没有单独的稳定 ID**。工作流关键字和这些关键字共用一个命名空间。
- 已经有「替用户运行一个关键字」的路径：工作流的 `runKeyword` 动作会调用 `AskConversationModel.runLauncherKeyword`，把关键字和文字放进启动器再运行。

### 1.3 缺什么

1. 常用的关键字（润色、翻译）每次都要「打开启动器 → 输入关键字 → ↩」，至少 3 步。
2. 快捷键分散在「设置」页里，而且只有固定的 5 个，没法扩展；以后再加快捷键，只能接着往设置页里塞大卡片。
3. 冲突检查是每个快捷键单独写的，加入数量不固定的快捷键后，这种写法没法维护。

## 2. 需求理解

- **独立**：快捷键单独成一页，不再放在「设置」里。原来的 5 个也挪过来，所有全局快捷键在同一个地方看和改。
- **快速触发关键字动作**：用户可以给任意已有的关键字（内置的、自定义的、工作流的）绑一个全局快捷键。在任何应用里按下，就用当前选中的文字运行这个关键字。
- 不改关键字本身的配置：快捷键只是关键字的另一个入口，预设参数（比如 `fyja` 的目标语言）都沿用关键字自己的。

## 3. 方案

### 3.1 「快捷键」页（截图 `page`）

- 侧边栏「启动器」下面新增「快捷键」（`keyboard` 图标）。
- 顶部：分段筛选（全部 · Typeflux · 关键字，带数量）、搜索框（匹配功能名、关键字和按键）、主按钮「＋ 添加关键字快捷键」。
- **Typeflux 区**：原来的 5 个快捷键改成紧凑的列表行，每行是：图标 · 名称 + 一行说明 · 按键 · `···`。
  - 点按键可以直接重录，Esc 取消，⌫ 清除。`···` 里有「重新录制 / 恢复默认 / 取消快捷键」。改过的快捷键旁边标「已修改」。区标题右边有「全部恢复默认」。
  - 「快速录入」和「打开位置」是这两个功能的设置，不是快捷键本身的设置，所以**留在原来的设置页**；行里只用一行灰字显示它们当前的值，作为提示。
- **关键字快捷键区**：每行四列：按键 · 关键字 + 功能 · 执行方式摘要 · 启用开关。
  - 点一行打开编辑对话框；点按键直接重录；右键菜单里有「编辑 / 重新录制 / 复制一份 / 在关键字页中查看 / 删除」。
  - 关键字被删除、停用，或者对应的工作流被停用时，这一行标出橙色或红色的原因，快捷键暂停生效，但保留配置。
- 空状态：给出 3 个一键模板（润色并替换、翻译选中文字、Google 搜索），点了以后打开预填好的对话框。
- 「设置」页原来的「语音快捷键」区改成一行链接「快捷键已移到『快捷键』页 →」，保留一个版本。

### 3.2 添加 / 编辑对话框（截图 `edit` `add` `conflict`）

| 字段 | 说明 |
|---|---|
| 关键字 | 下拉选择器，按插件分组，可以搜索。已经绑了快捷键的关键字直接显示它的按键，停用的标「已停用」。最下面是「＋ 新建关键字…」，跳到关键字页。 |
| 快捷键 | 录制框，实时检查冲突（规则见 3.4）。和其他关键字快捷键冲突时，可以选「改为给这里用」，保存时会清掉对方的快捷键。 |
| 按下后 | 单选：**在启动器中打开** / **直接执行**。只能在启动器里用的插件（文件搜索、聊天、单词本、历史、设置）不能选「直接执行」，会写明原因。 |
| 结果 | 只在选「直接执行」时出现，选项由插件决定：翻译、AI 指令可以选「替换选中文字 / 在浮窗中显示 / 复制到剪贴板」；网页搜索固定是「在浏览器中打开」；工作流固定是「按工作流的输出动作」。 |
| 没有选中文字时 | 打开启动器等待输入（默认）/ 使用剪贴板内容 / 什么都不做（只在「直接执行」时提供）。插件不需要输入时，不显示这一项。 |
| 效果 | 用一句话说明按下后会发生什么，随上面的选择实时变化。 |

底部和关键字编辑对话框一样：删除（左）· 启用开关 · 取消 · 保存。有错误时「保存」不可用，Esc 关闭，⌘↩ 保存。

默认值：新建时选「直接执行」。翻译默认结果是「在浮窗中显示」（翻译通常是为了看懂，不是替换原文），AI 指令默认是「替换选中文字」。

### 3.3 触发时发生什么（截图 `launcher` `direct-replace` `light-direct-panel`）

1. 按下快捷键后，和启动器快捷键一样，先记下当前最前面的应用，再读取选中的文字（`makeLauncherSelectionRequest`）。
2. **在启动器中打开**：调用 `showLauncher()`，然后执行和 `runLauncherKeyword` 相同的逻辑：进入关键字，带上选中的文字，有文字时立刻运行（相当于替用户按了 ↩）。之后的操作和平时一样（↩ 写回、⌘C 复制、⌘↩ 问 AI）。底栏左侧标出「⌃⌥S 由快捷键打开」，点一下跳到这个快捷键的设置。
3. **直接执行**：不打开启动器，在选中文字旁边（拿不到位置时就在鼠标旁边）显示一个小 HUD「`rw` 润色中… esc 取消」。
   - 替换：完成后写回原来的应用（复用 `writeBack` / `AXTextInjector`），HUD 显示「✓ 已替换选中文字」。写回失败或者目标不可编辑时，自动改为在浮窗中显示。
   - 浮窗：在选中文字下方显示一个结果卡片，↩ 替换、⌘C 复制、⌘O 在启动器里继续、esc 关闭。
   - 复制：完成后 HUD 显示「已复制」。
   - 网页搜索直接打开浏览器；工作流按它在 `workflow.json` 里配置的输出动作处理。工作流需要确认的事（访问新的网站等）没法在 HUD 里问，这时转到启动器里继续。
   - 失败时（没有模型、网络错误）：HUD 变成红色，显示原因和「在启动器中打开 ⌘O」。
4. 没有选中文字时，按「没有选中文字时」的设置处理；选「什么都不做」时，HUD 只提示「没有选中文字」。
5. 同一个快捷键在上一次还没跑完时又按了一次：取消上一次，用新选中的文字重新跑。

### 3.4 冲突与按键规则

| 情况 | 处理 |
|---|---|
| 和 Typeflux 内置快捷键重复 | 红色，不能保存。提示「已被 Typeflux『人设切换器』使用」 |
| 和另一个关键字快捷键重复 | 红色；可以选「改为给这里用」，保存时清掉对方的 |
| 只有修饰键，或者是连按两次 | 不允许。这类手势留给语音输入，由 `HotkeyGestureArbiter` 处理 |
| 没有 ⌘ / ⌥ / ⌃（只有字母，或者 ⇧ + 字母） | 不允许，否则正常打字时会误触发。F1–F19 除外 |
| macOS 常用快捷键（⌘C、⌘V、⌃Space…） | 橙色警告，可以保存（用户可能就是想覆盖） |
| 内置快捷键改成了和关键字快捷键一样的按键 | 拒绝，toast 说明和谁冲突 |

所有快捷键共用一个冲突检查函数（纯逻辑，方便测试），替换现在 `SettingsViewModel` 里分散的 5 份检查。

### 3.5 关键字页联动（截图 `kwpage`）

- 关键字列表加一列「快捷键」：已经绑了的显示按键，点击打开编辑对话框；没有绑的显示「＋ 快捷键」，点击打开添加对话框，并预选这个关键字。
- 关键字编辑对话框里加一行「快捷键」，显示按键和执行方式，旁边是「编辑快捷键…」按钮。
- 工作流页的每个工作流也加同样的入口。
- 启动器的关键字目录（`prefix`）里，有快捷键的关键字在右侧显示按键，方便用户发现这个功能。

## 4. 数据与实现（确认设计后）

### 4.1 数据

```swift
struct KeywordHotkey: Codable, Equatable, Identifiable {
    enum Mode: String, Codable { case launcher, direct }
    enum Result: String, Codable { case replace, panel, copy }   // web/workflow ignore it
    enum NoSelection: String, Codable { case launcher, clipboard, skip }

    var id: UUID
    var binding: HotkeyBinding?        // nil = unset, kept for re-recording
    var keyword: String                // AskKeyword.id at save time
    var pluginID: String               // disambiguates renames and workflow keywords
    var workflowID: String?            // set for workflow keywords
    var mode: Mode
    var result: Result?
    var noSelection: NoSelection
    var enabled: Bool
}
```

- 存储：`SettingsStore.keywordHotkeys`，JSON 键 `hotkey.keywords.json`。改了以后照常发 `hotkeySettingsDidChange`。
- 关键字没有稳定的 ID，所以在 `AskKeywordList` 改名时，同步改掉引用它的快捷键（同一个保存动作里完成）。删除关键字时，快捷键保留，标「关键字已删除」，由用户自己决定是删掉还是换一个关键字。
- 原来 5 个快捷键的存储不变。

### 4.2 实现步骤

| 步骤 | 改动 | 主要文件 |
|---|---|---|
| H1 冲突检查 | 纯逻辑 `HotkeyConflictChecker`：内置 + 关键字快捷键 + macOS 常用快捷键表 + 按键规则；`SettingsViewModel` 的 5 份检查改成调用它 | `Hotkey/` 新文件 |
| H2 数据 | `KeywordHotkey` + `SettingsStore.keywordHotkeys`；关键字改名、删除时同步 | `Settings/SettingsStore+Hotkeys.swift`、`AskKeywordList` |
| H3 监听 | `HotkeyAction.keyword(UUID)`；`EventTapHotkeyService` 在固定的 5 个之外，再按字典匹配普通组合键（只匹配 keyDown，不进入手势仲裁） | `HotkeyService.swift`、`EventTapHotkeyService.swift` |
| H4 执行 | `KeywordHotkeyRunner`：读取选中的文字 → 启动器模式调用 `showLauncher` + `runLauncherKeyword`；直接模式在后台跑插件的 `plan` / `run` → 写回 / 复制 / 浮窗；HUD 和浮窗是新的非激活面板 | `Ask/KeywordHotkey/` 新目录、`AppCoordinator` 接线 |
| H5 设置页 | `StudioSection.hotkeys`、`HotkeySettingsView`（列表 + 行内录制）、`KeywordHotkeyEditorSheet`、草稿模型 `KeywordHotkeyDraft`；设置页原来的区域改成链接 | `Settings/` |
| H6 联动 | 关键字页的「快捷键」列、关键字对话框里的「快捷键」行、工作流页入口、启动器底栏和关键字目录里的提示 | `AskKeywordListComponents`、`AskKeywordEditorSheet` 等 |

- 新的纯逻辑类型（冲突检查、草稿校验、默认值、摘要文字、改名同步、执行决策）都写单元测试，覆盖率按项目要求（≥ 90%）。中、繁、英、日本地化同步。
- UI 按 `LauncherSettingsPolishTests` 的方式出深色、浅色截图。

## 5. 待确认

1. **范围**：第一版是否包含「直接执行」？如果只做「在启动器中打开」，H4 只需要复用现有的启动器，工作量大约减半。建议两种都做，因为「直接执行」才是这个功能真正省事的地方。
2. **原来的 5 个快捷键挪到新页**，设置页只留一个链接。是否同意？
3. **按应用生效**（比如只在 VS Code 里启用 `⌃⌥E`）：这一版不做，等有需求再加。
4. **同一个关键字绑多个快捷键**：允许（比如一个替换、一个用浮窗显示）。是否需要限制？
5. **默认是否预置快捷键**：建议不预置，避免和用户自己的快捷键冲突，只在空状态里给模板。
