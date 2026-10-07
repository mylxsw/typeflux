# 翻译：查词记录与单词收藏 设计方案

> 状态：设计稿第二版，待确认后开发（GUL-237）。第二版按反馈改为：单词本是从翻译里打开的**独立对话框**，不在工作台侧栏加页面。可交互设计稿：`docs/design/translation-word-book.html`，截图见 `docs/design/translation-word-book/`。前置：AI 单词卡已合入（GUL-221，`docs/design/ask-launcher-position-word-card.md`）。

## 0. 一页结论

1. **查过即记录**：在启动器里翻译单词 / 短语（`fy` / `tr` / `翻译`、选中即译），结果「落定」后自动记进本机的「单词本」。句子不记。同一个词再查只累加次数。
2. **⌘S 收藏**：单词卡右上角新增 ☆，⌘S 收藏 / 取消。本机译文也能收藏，之后 ⌘R 生成单词卡时升级同一条记录。
3. **查过的词再查不花钱**：单词本里已有 AI 单词卡的词，直接显示存下来的卡（「来自单词本」），不再请求模型；⌘R 才重新生成。现在的 50 条内存缓存（App 退出即丢）由它取代。
4. **`fy` 留空列出最近查过的词**：没有输入、没有选中文字时，显示最近 8 个词，⇥ 切到「只看收藏」，↩ 打开卡片，最后一行「打开单词本…」。
5. **单词本是独立对话框，只从翻译里打开**：翻译结果底栏「📖 单词本 ⌘B」、`fy` 留空列表的「打开单词本…」、收藏提示里的 ⌘B。对话框里有收藏 / 查词记录两个视图，搜索、按语言筛选、排序，详情复用单词卡视图，可删除（带撤销）、重新生成；导出和记录设置收在「⋯」菜单里。**不改工作台**。
6. **数据只在本机**（`word-book.sqlite`），可关闭记录、设置保留期（只清未收藏的）、一键清空。云同步收藏作为后续阶段，需要后端配合。
7. **分 3 个 PR**：P1 存储 + 记录 + 收藏 + 缓存；P2 单词本对话框 + ⌘B 入口；P3 启动器最近列表。P4（可选）云同步。

## 1. 现状

| 能力 | 现状 | 位置 |
|------|------|------|
| 翻译入口 | `fy` / `tr` / `翻译` 关键词、选中即译；本机（Apple Translation，macOS 26）优先，AI 兜底 | `AskTranslatePlugin` |
| 单词判断 | 1 个词或 ≤4 词无句读；中日文 ≤6 字无标点；≤64 字符 | `AskWordCard.isLookup` |
| AI 单词卡 | 音标、词性释义、词形、例句、近义词；⌘R 重新生成 | `AskWordCard`、`AskWordCardView`、`AskAITranslationEngine.lookUp` |
| 本机查词 | 只有一个简短译文，提示「⌘R 用 AI 生成单词卡」 | `AskTranslatePlugin.run` |
| 缓存 | **内存** LRU 50 条，键含模型名和 generation；App 退出即丢 | `AskAITranslationEngine.cards` |
| 查词历史 | **没有**。翻译结果不进 `history.sqlite`（那里只有语音输入记录） | — |
| 收藏 | **没有** | — |
| 独立窗口 | 启动器里已有从结果打开独立窗口的先例：工作流 ⌘E 打开工作流编辑器 | `AskWorkflowEditorWindowController` |
| 命名 | 工作台已有「词库」，是语音识别的自定义词汇，与翻译无关；新功能叫「单词本」以示区分 | `StudioSection.vocabulary` |

结论：单词卡已经很完整，缺的是「查过的东西留得住、找得回来」。这次只补这条链路，不改单词卡本身的生成逻辑。

## 2. 记录规则

### 2.1 记什么

| 结果 | 记录 | 可收藏 | 说明 |
|------|------|--------|------|
| 单词 / 短语，AI 单词卡（`.card`） | ✅ | ✅ | 存整张卡（`AskWordCard` 是 `Codable`） |
| 单词 / 短语，本机译文 | ✅ | ✅ | 存简短译文，`kind = text` |
| 句子、选中的多行 | ❌ | ❌ | 翻译不是查词 |
| AI 判断为句子（`.translation`） | ❌ | ❌ | 模型说它不是词 |
| 读不出的回复（`.unreadable`） | ❌ | ❌ | 不保存坏数据 |
| 失败 / 取消 | ❌ | ❌ | — |
| 关闭了「记录查词历史」 | ❌ | ✅ | 收藏时才写入一条 |

### 2.2 什么时候记（「落定」）

本机引擎是边输边译的（`.live`），输入 `s → se → ser…` 每一步都有结果，不能每步都记。规则：

- **AI 单词卡**（`.onSubmit`，用户按了 ↩）：结果出来即记。
- **本机结果**：用户对它做了任何操作（↩ 复制、⌥↩ 插入、朗读、⌘S、⌘R、点释义复制），或者它停留 ≥ 1.5 秒后启动器关闭时，记一次。
- 同一次打开启动器里，同一个词只计一次。

实现：`AskPluginSession` 在结果完成和执行动作时调用 `AskWordBookRecorder.settle(...)`；关闭启动器时对最后一个停留够久的结果补记。记录逻辑放在插件外面，插件本身保持无状态。

### 2.3 去重键

`normalize(headword) | base(source) | base(target)`：

- 词头：去首尾空白、合并连续空白、小写（`Take  Off` = `take off`）。
- 语言：复用 `AskTranslationLanguages.sameLanguage` 的归一（`en-US` = `en`，简繁分开）。
- **不含模型**：换模型不产生重复；⌘R 覆盖卡片。
- 源语言没识别出来（`nil`）时记为空；之后同词同目标识别出源语言时合并进那一条。

## 3. 数据与存储

新文件 `~/Library/Application Support/Typeflux/word-book.sqlite`（不混进 `history.sqlite`：生命周期、保留策略、未来的同步都不同）。沿用 `SQLiteHistoryStore` 的做法：WAL、串行队列、读同步写异步、变更通过 `NotificationCenter`（`.wordBookDidChange`）广播。

```sql
CREATE TABLE IF NOT EXISTS word_book_entries (
    id TEXT PRIMARY KEY NOT NULL,          -- UUID (stable id for sync later)
    lookup_key TEXT NOT NULL UNIQUE,       -- normalized headword|source|target
    headword TEXT NOT NULL,                -- as the card shows it
    source_language TEXT,                  -- BCP 47, NULL when unknown
    target_language TEXT NOT NULL,
    kind TEXT NOT NULL,                    -- card | text
    card_json BLOB,                        -- AskWordCard when kind = card
    translation TEXT,                      -- short translation when kind = text
    summary TEXT NOT NULL,                 -- one line, for list and search
    model TEXT,                            -- who wrote the card, for display only
    lookup_count INTEGER NOT NULL DEFAULT 1,
    first_looked_up_at REAL NOT NULL,
    last_looked_up_at REAL NOT NULL,
    starred_at REAL                        -- NULL = not starred
);
CREATE INDEX IF NOT EXISTS idx_word_book_last ON word_book_entries(last_looked_up_at DESC);
CREATE INDEX IF NOT EXISTS idx_word_book_starred ON word_book_entries(starred_at DESC) WHERE starred_at IS NOT NULL;
```

- 查词记录和收藏是 **同一张表**：收藏只是 `starred_at` 非空。这样「查过 3 次」「收藏于」在两个视图里一致，取消收藏不丢历史。
- 搜索：`headword LIKE ? OR summary LIKE ?`，单用户几千条足够，不上 FTS。
- 保留期：`DELETE … WHERE starred_at IS NULL AND last_looked_up_at < ?`，启动时和设置变更时执行。
- 卡片升级：`kind` 从 `text` 变成 `card` 时原地更新，`starred_at` / 计数不变。

```swift
protocol AskWordBookStore: Sendable {
    func entry(forKey key: String) -> AskWordBookEntry?
    func record(_ lookup: AskWordBookLookup, at date: Date)           // upsert + count
    func setStarred(_ starred: Bool, key: String, lookup: AskWordBookLookup?, at date: Date)
    func list(_ query: AskWordBookQuery) -> [AskWordBookEntry]        // starred/all, text, language pair, sort, limit
    func delete(ids: [UUID])
    func restore(_ entries: [AskWordBookEntry])                       // undo
    func purgeHistory(before date: Date?)                             // nil = all unstarred
    func counts(since date: Date) -> AskWordBookCounts
}
```

`SettingsStore` 新增：`wordBook.recordHistory: Bool`（默认开）、`wordBook.retention`（7 / 30 / 90 天 / 永久，默认 90 天）。

## 4. 启动器

### 4.1 单词卡上的收藏

- `AskWordCardView` 词头行右侧加 ☆ / ★ 按钮；操作行加「收藏 ⌘S」。
- `AskPluginAction.Shortcut` 新增 `.commandS`（`AskCommands` 里 keyCode 1；启动器里目前没有占用）；`Kind` 新增 `.toggleStar(key: String)`。
- `AskPluginOutput` 新增 `wordBookKey: String?` 与 `starred: Bool`。会话执行 `.toggleStar` 时直接改存储并就地更新输出，**不重新运行插件**。
- 反馈出现在底栏左侧（短暂替换来源文字），不遮挡卡片；再按 ⌘S 即撤销。
- 结果组标题右侧显示「查过 N 次 · 首次 X 天前」（第一次查不显示）。
- **单词本入口**：翻译插件的每个结果（单词卡、译文、句子都算）底栏右侧固定「📖 单词本 ⌘B」。`Shortcut` 新增 `.commandB`（keyCode 11，启动器里没有占用），`Kind` 新增 `.openWordBook(key: String?)`：关闭启动器，打开对话框并选中这个词（句子没有 key，就只打开）。收藏提示写「已收藏 · ⌘B 打开单词本」。

### 4.2 持久缓存

`AskAITranslationEngine.lookUp` 先查单词本：同键已有 `kind = card` 且 `generation == "0"` 时直接返回，来源标为「单词本」（底栏「单词本 · 未请求模型」）。⌘R（generation > 0）照旧请求模型，成功后覆盖存储。删除内存缓存 `cards` / `cardOrder`。

关闭「记录查词历史」只停止写入新记录，已存的卡片照样复用。

### 4.3 `fy` 留空：最近查过的词

- 条件：关键词后面没有内容，**并且** 没有选中文字（有选中文字时照旧「翻译选中的 N 行」）。
- 内容：最近 8 条，★ 标出收藏；⇥ 在「最近 / 只看收藏」间切换（留空时换语言没有意义）。
- 复用工作流已有的结果列表 `AskPluginOutput.items`：↩ 打开卡片（从单词本读取，不请求 AI），⌥↩ 插入第一条释义，⌘S 收藏 / 取消，⌘B 打开单词本并选中这个词。列表末尾固定一行「打开单词本… ⌘B」，方便鼠标用户。
- 插件声明 `runsWithoutInput = true`（会话已支持，工作流在用），空参数时 `plan` 返回 `.live`，`run` 只读存储，不访问网络。

## 5. 单词本对话框

不进工作台，做成一个从翻译里打开的轻量独立窗口。

### 5.1 窗口

- `AskWordBookWindowController`（参照 `AskWorkflowEditorWindowController`）：普通 `NSWindow` + `NSHostingView(AskWordBookView)`，标题「单词本」，默认约 900×620，可缩放（最小 720×480），记住大小和位置（`setFrameAutosaveName`）。
- **单实例**：已打开时 `open(selecting:)` 只前置窗口并选中传入的词；关闭后释放视图模型。
- 打开时先关掉启动器，再 `NSApp.activate`（菜单栏应用需要主动激活）并 `makeKeyAndOrderFront`。
- 入口只有翻译（§4.1、§4.3）。不加菜单栏项、不加工作台页；如果之后需要，菜单栏加一项「单词本…」只是一行代码。
- 键盘：↑↓ 选择、⌘F 搜索、⌘S 收藏、⌘C 复制释义、⌫ 删除（可撤销）、esc 关闭。

### 5.2 内容

- 标题栏：居中「单词本 · N 个收藏」；右侧「⋯」菜单：导出 CSV / Markdown / Anki（TSV）、记录设置…。
- 工具栏：`收藏 | 查词记录` 分段（默认收藏）、搜索（单词 + 释义）、语言方向筛选、排序（最近查询 / 查询次数 / 字母 / 收藏时间）。
- 左侧列表：词头 + 首个音标 + 一行释义；本机译文带「本机译文」标签；右侧 ☆ 与「×N」。查词记录按 今天 / 昨天 / 本周 / 本月 / 更早 分组。
- 右侧详情：复用 `AskWordCardView`（点释义复制、朗读）；元数据（次数、首次、最近、收藏于）；操作：收藏 / 取消、朗读、复制释义、重新生成 / 用 AI 生成单词卡（确认框写明会发送到哪个模型）、删除记录（已收藏的先确认；删除后可撤销）。
- 底栏：快捷键提示 + 「近 7 天查了 N 个词」。
- 导出当前视图（受搜索筛选影响）：CSV（`headword,phonetic,meanings,source,target,count,starred_at`）、Markdown（复用 `AskWordCard.markdown`）、Anki TSV（正面词头 + 音标，背面释义 + 例句）。走 `NSSavePanel`。
- 记录设置（sheet）：记录查词历史开关、保留期、清空查词记录（收藏保留，二次确认）。设置值存在 `SettingsStore`，不在工作台设置页重复出现。
- 空状态：无收藏时提示「在翻译结果上按 ⌘S 收藏」；记录关闭时「查词记录」顶部提示已暂停。
- 列表大时分页加载（每页 100），监听 `.wordBookDidChange` 刷新——对话框开着时在启动器里收藏，列表即时更新。

## 6. 隐私与同步

- 全部数据在本机，不上传。单词本对话框里的「重新生成」是唯一会发送内容的操作，且需确认。
- 选中即译查到的词同样会被记录（用户主动按了 ⌥Space）；不想留痕可关闭记录或清空。
- **云同步（P4，可选）**：`CloudSyncEntityType` 增加 `wordBookEntry`，只同步 **收藏**（`starred_at` 非空的行，载荷为卡片 JSON + 时间），查词记录保留本机。需要 typeflux-api 新增实体类型，单独立项。

## 7. 实施计划

| PR | 内容 | 主要改动 | 测试 |
|----|------|----------|------|
| **P1** 存储 + 记录 + 收藏 | 单词本 SQLite、落定记录、⌘S、持久缓存、设置项 | `AskWordBookStore` / `SQLiteAskWordBookStore`、`AskWordBookRecorder`、`AskPluginSession`、`AskPluginAction`（`.commandS` / `.toggleStar`）、`AskWordCardView`、`AskAITranslationEngine`、`SettingsStore`、`DIContainer`、五种语言文案 | 存储：upsert / 去重键归一 / 计数 / 收藏 / 升级 `text→card` / 保留期只删未收藏 / 搜索；记录器：live 中间态不记、操作即记、1.5 秒规则、同会话只计一次、各种 lookup 结果是否记；插件：⌘S 输出与就地更新；缓存命中、⌘R 跳过并覆盖 |
| **P2** 单词本对话框 + 入口 | 独立窗口；列表 / 搜索 / 筛选 / 排序 / 详情 / 删除撤销 / 重新生成 / 导出 / 记录设置；结果底栏 ⌘B 入口 | `AskWordBookWindowController`、`AskWordBookViewModel`、`AskWordBookView` 及子视图、`AskWordBookExporter`、`AskPluginAction`（`.commandB` / `.openWordBook`）、`AskCommands` | ViewModel：筛选排序搜索分组、选中传入的词、删除与撤销、空状态、外部变更刷新；导出三种格式（转义、多义、无音标）；控制器单实例与再次打开时选中；⌘B 动作 |
| **P3** 启动器最近列表 | `fy` 留空显示最近 / 收藏，↩ 打开存储的卡，「打开单词本…」行 | `AskTranslatePlugin`（空参数分支） | 有 / 无选中文字、⇥ 切换、空列表、打开卡片不调用 AI、末行打开对话框 |
| P4（可选） | 收藏云同步 | `CloudSyncEntityType`、typeflux-api | 同步冲突与删除 |

每个 PR 新增代码单测覆盖率 ≥ 90%（项目要求），`swift test` 全绿；UI 改动附截图。

## 8. 待确认

1. **命名**：「单词本」可以吗？（备选：生词本、收藏夹。需避开已有的「词库」。）
2. **快捷键 ⌘B** 打开单词本可以吗？（B = Book；启动器里没有占用。）
3. **菜单栏**要不要也加一项「单词本…」？本稿按要求只在翻译里放入口。
4. **句子收藏**：本稿只收藏单词 / 短语。是否也要能收藏整句翻译（做成「翻译收藏」）？会让单词本变杂，建议不做。
5. **保留期默认 90 天** 是否合适？还是默认永久？
6. **复习功能**（卡片翻面 / 间隔重复）本稿不做，只提供 Anki 导出。是否需要排进后续？
7. **云同步收藏**（P4）是否需要？需要的话要另开 typeflux-api 的任务。
8. **备注**：要不要允许给收藏的词写一句备注（例如出处）？本稿未加。
