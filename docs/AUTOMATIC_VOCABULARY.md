# 自动词库（Automatic Vocabulary Collection）设计文档

本文梳理 Typeflux「自动添加词条」功能的整体设计、关键实现、当前存在的问题与修复方向。
本文档仅描述现状分析与建议，不包含任何代码变更。

---

## 1. 功能目标

在用户使用语音听写并将文本插入到宿主 App 后，如果用户对插入的文本做了小范围的手动修改（例如把 `type flux` 改成 `Typeflux`、把 `Open AI Realtime` 改成 `OpenAI Realtime`），Typeflux 希望：

1. 观察一段时间内用户在该输入框中的最终文本变化；
2. 通过 LLM 判断新出现的"词"是否值得加入语音识别词库；
3. 把合格的词条写入 `VocabularyStore`，后续听写可把它作为 prompt/hints 提高识别准确率。

整个链路**完全后台运行、无需用户显式操作**，由设置项 `automaticVocabularyCollectionEnabled` 总开关控制，默认开启。

---

## 2. 架构概览

```
applyText()
   └── textInjector.insert / replaceSelection   (AX / 粘贴回退)
   └── scheduleAutomaticVocabularyObservation(for: insertedText)
            │
            ▼
       Task (观察会话)
            ├── readInitialEditableSnapshot()          // 判定当前焦点可编辑
            ├── automaticVocabularyStartupDelay (600ms)
            ├── readAutomaticVocabularyBaselineWithRetry()   // 捕获 baseline
            ├── polling loop（interval=1s, window=30s）
            │     ├─ textInjector.currentInputTextSnapshot()
            │     ├─ 校验焦点 App 未切换
            │     ├─ observe(text, state) → 更新 latestObservedText / lastChangedAt
            │     └─ shouldTriggerAnalysis? (idleSettleDelay = 8s)
            ▼
       runAutomaticVocabularyAnalysis(insertedText, baselineText, finalText)
            ├── AutomaticVocabularyMonitor.detectChange
            │       (oldFragment / newFragment / candidateTerms)
            ├── changeIsJustInitialInsertion?   → 跳过
            ├── isEditTooLarge? (ratio > 0.6)    → 跳过
            ├── evaluateAutomaticVocabularyCandidates
            │       → LLMRouter.completeJSON (structured JSON schema)
            ├── parseAcceptedTerms
            └── addAutomaticVocabularyTerms → VocabularyStore.add(source:.automatic)
                   └── overlayController.showNotice
```

关键源文件：

- [Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift](Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift) — 纯算法层：diff、分词、编辑比例、JSON 解析、候选/接受词合法性校验
- [Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift](Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift) — 编排层：调度观察 Task、轮询 AX、调用 LLM、落库
- [Sources/Typeflux/Workflow/WorkflowController+Processing.swift:273](Sources/Typeflux/Workflow/WorkflowController+Processing.swift) — `applyText` 成功后调度观察
- [Sources/Typeflux/Settings/VocabularyStore.swift](Sources/Typeflux/Settings/VocabularyStore.swift) — 词库存储（UserDefaults + JSON）
- [Sources/Typeflux/LLM/PromptCatalog.swift:303](Sources/Typeflux/LLM/PromptCatalog.swift) — `automaticVocabularyDecisionPrompts`
- [Sources/Typeflux/Settings/SettingsStore.swift:475](Sources/Typeflux/Settings/SettingsStore.swift) — 开关 `automaticVocabularyCollectionEnabled`

---

## 3. 关键参数

| 参数 | 取值 | 含义 |
|------|------|------|
| `automaticVocabularyObservationWindow` | 30 s | 一次会话最长观察时长 |
| `automaticVocabularyPollInterval` | 1 s | 轮询 AX 的间隔 |
| `automaticVocabularyStartupDelay` | 600 ms | 插入完成后、读取 baseline 前的等待时间 |
| `automaticVocabularyBaselineRetryDelay` | 400 ms | baseline 读取重试间隔 |
| `automaticVocabularyBaselineRetryCount` | 6 | baseline 读取重试次数（最多 ~2.4 s） |
| `automaticVocabularyIdleSettleDelay` | 8 s | 最近一次变更后，若 ≥ 8 s 无新变更则视为"稳定"，提前结束观察 |
| `automaticVocabularyEditRatioLimit` | 0.6 | `(Levenshtein(baseline, final)) / insertedLen > 0.6` 则判为"用户大范围重写"，跳过 |

候选词与合法词的关键校验：

- 拉丁/数字 token：长度 ∈ [4, 32]，必须含字母；`[A-Za-z0-9]+(?:[._+\-'][A-Za-z0-9]+)*`
- 汉字 token：长度 ∈ [2, 12]
- LLM 接受后进一步过滤：`^[\p{Han}A-Za-z0-9](?:[\p{Han}A-Za-z0-9 ._+\-/']{0,38}[\p{Han}A-Za-z0-9])?$`

---

## 4. 当前实现的若干隐含假设

1. 插入完成后 ~600 ms 内，宿主 App 的 AX 值能够稳定反映已插入文本；若不能，靠 `expectedSubstring` 重试（≤ 2.4 s）兜底。
2. 用户修改行为发生在同一焦点元素、同一 App 内；一旦焦点切换（bundleId/pid/processName 不匹配），立即放弃该会话。
3. 用户会在修改后**静默 8 s** 让观察结束；否则最多观察 30 s 就强行结束。
4. 修改后的文本规模与听写文本规模相当（编辑比例 ≤ 0.6），否则视为"大改写"放弃。
5. 同一时间只有一个观察会话——新的 `scheduleAutomaticVocabularyObservation` 会 `cancel` 上一个 Task。
6. 宿主 App 的 `focusedElement()` AX 值会随用户手动编辑而更新（否则 final == baseline，等同于没改动）。

---

## 5. 已排查到的潜在失效原因（按概率由高到低）

### 5.1 连续听写导致上一次观察会话被提前取消 ★★★★

[WorkflowController+AutomaticVocabulary.swift:12-13](Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift)

```swift
automaticVocabularyObservationTask?.cancel()
automaticVocabularyObservationTask = nil
```

`scheduleAutomaticVocabularyObservation` 在函数开头无条件取消上一次会话。这意味着：

- 用户 A 时刻听写 → 插入 → 启动观察会话 1（最长 30 s）
- 用户在同一会话窗口内（30 s 以内）再次按热键做第二次听写 → 插入 → **会话 1 被直接 cancel，分析从未执行**

对于"经常连续短句听写 + 小修改"的用户（也就是绝大多数真实用例），会话 1 几乎没有机会走完 8 s 静默期或 30 s 窗口。结果：**尽管真正修改了文本，词库始终为空**。

这是与用户反馈（"长期使用，没有任何词条被自动加入"）最吻合的失效模式。

### 5.2 很多宿主 App 的 AX 值读取不可用 ★★★★

[AXTextInjector.swift:383-497](Sources/Typeflux/TextInjection/AXTextInjector.swift) 的 `readCurrentInputTextSnapshot` 里，以下情况都会返回 `text == nil`：

- `AXIsProcessTrusted() == false`（尚未授权辅助功能）
- 没有 `focusedElement`
- 焦点元素不可编辑（`isEditable == false`）
- `kAXValueAttribute` 读不到（Electron、contenteditable、Chrome 地址栏、部分富文本视图都会命中）
- AX value 等于 placeholder 或 title

一旦：

- 初始快照读不到 → `readInitialEditableSnapshot` 等 400 ms 再试一次，仍不可读则整个会话放弃；
- baseline 读不到 → `baselineText` 为 `nil`，直接 abort；
- baseline 虽有但不含 `expectedSubstring` → 走 6 次重试后仍然以"stale baseline"返回，轮询中如果最终文本与这个 stale 基线差异过大会被 `isEditTooLarge` 跳过。

常见 AX 值读取不稳定 / 不可读的典型 App：Slack、Discord、VS Code、Chrome 的 contenteditable、Logseq、Notion、Obsidian 等 Electron/自绘类 App。如果用户主要在这类 App 里做修改，**观察会话几乎每次都在 `readInitialEditableSnapshot` 或 baseline 读取阶段就已经退出**。

### 5.3 粘贴回退路径带来的焦点/AX 时序问题 ★★★

[AXTextInjector+Paste.swift:8](Sources/Typeflux/TextInjection/AXTextInjector+Paste.swift) 在 AX 直写失败时会走剪贴板粘贴路径。粘贴涉及：

- 临时写剪贴板 → 发送 ⌘V → 等待 App 处理 → 还原剪贴板

这个过程中：

- `scheduleAutomaticVocabularyObservation` 被**同步**调用在 `applyText` 末尾，但 paste 路径本身异步；
- Task 立即 `readInitialEditableSnapshot`，此时焦点可能还在瞬时的还原过程中；
- 600 ms startup delay 对有的 App 太短，baseline 读到的仍然是插入前的状态，`expectedSubstring` 检查失败，重试完后落到"stale baseline"分支。

组合起来：粘贴路径下会话启动鲁棒性较差。

### 5.4 候选词被过于严格的长度阈值过滤 ★★★

`isValidLatinOrNumberToken` 要求 **≥ 4 个字符**，所以 `GPT`、`API`、`iOS`、`AI`、`ASR`、`LLM`、`AST`、`AX`、`UI`、`gRPC`、`npm`、`pip`、`YAML` 等**用户最容易修正**的专业缩写全部被 diff 算法丢弃——即使用户确实把 `A.I.` 改成 `AI`、把 `api` 改成 `API`，它们也根本进不了候选列表，自然也就永远不会被加入词库。

汉字要求 ≥ 2 个字符相对合理；但对英文专业术语来说，4 字符下限过于保守。

### 5.5 "新片段与插入文本的归一化后相等" 判定过严 ★★

[AutomaticVocabularyMonitor.swift:204-215](Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift) 的 `changeIsJustInitialInsertion`：

```swift
if normalizedNew == normalizedInserted { return true }
let insertedTokens = Set(tokenize(insertedText).map(normalize))
return change.candidateTerms.allSatisfy { insertedTokens.contains(normalize($0)) }
```

- 第一条（完全相等）防止 baseline 捕获滞后、把整段新插入的文本当成"用户修改"。没问题。
- 第二条（所有候选词都出现在 insertedText 的 token 里）更激进。场景：用户听写的就是 "OpenAI"，被误识别成 "Open AI"，插入后用户手动删除空格合并为 "OpenAI"。修改后 newFragment = "OpenAI"，候选 = ["OpenAI"]，`tokenize("Open AI")`（输入给 insertText 的是识别后的 "OpenAI"？还是 "Open AI"？）需要具体看。

更常见的问题场景：用户听写 "typeflux"，识别为 "type flux"（两个词），插入文本 = "type flux"（insertedText），用户改为 "Typeflux"。这时候 insertedTokens = {"type", "flux"}（"flux" 4 字符恰好过阈值），candidateTerm = "Typeflux"，normalized = "typeflux" ∉ {"type", "flux"} → 不会被拦截。**这一条在大多数情况是安全的**，但与 §5.4 结合会显著降低召回。

### 5.6 编辑比例 0.6 对"删除+重写"场景偏严 ★★

如果用户的修改是"把 baseline 中的一整个片段删掉再重写"（经常发生在尝试替换比较啰嗦的表达时），Levenshtein 距离容易超过 insertedText 长度的 60%，直接走 `analysis skipped: edit too large`。对于很短的听写（<20 字符），阈值效应尤其明显。

### 5.7 LLM 的 decision prompt 过于保守 ★★

`automaticVocabularyDecisionPrompts` 指令包括：

- "If uncertain, return an empty list."
- "Prefer precision over recall"
- 一大串 reject 清单

在候选词本身就不多的前提下，LLM 很容易因为"不确定"直接返回 `{"terms": []}`。配合 §5.4、§5.6，端到端新增词条的概率被进一步压低。

### 5.8 无观察结果时完全静默 ★

整个流程只通过 `NetworkDebugLogger.logMessage("[Auto Vocabulary] ...")` 输出日志，**没有任何用户可见的状态指示**。用户完全无法区分：

- 开关是否真的被打开（但默认就是 true）
- 焦点 App 是不是在黑名单 / AX 不可读
- 是不是会话被新的听写取消了
- 是不是 LLM 拒绝了所有候选

这是"为什么用户无法自检"的元原因。

### 5.9 极小的可能：数据写入后未被读到 ★

`VocabularyStore.add` → `save` → `UserDefaults.set` 是同步的；`load()` 立即回读也正常工作。从代码上看数据路径本身没问题，除非多端同时写 UserDefaults（应用本身是单进程，不会发生）。可以通过查看 `~/Library/Preferences/com.typeflux.plist` 中 `vocabulary.entries` 键验证。

---

## 6. 推荐的排障步骤（不改代码也能验证）

1. **看日志**：Typeflux 以 `[Auto Vocabulary]` 前缀打印了完整事件流。开启 Console.app 或通过 `make dev` 终端日志抓取最近几次听写 + 修改会话，就能直接看到是在 `session scheduled / session aborted / analysis skipped / llm decision received` 哪一阶段断掉的。
2. **检查 UserDefaults**：`defaults read com.typeflux vocabulary.entries`（或读 plist 文件）看是否有 `source: automatic` 的条目。
3. **确认焦点 App**：重点区分两类场景 —— 原生 App（Notes、Mail、Safari 地址栏）和 Electron/Web App（Slack、Chrome、VS Code）。如果只在前者出现词条、后者从不出现，说明 §5.2 是主因。
4. **单次测试**：刻意做一次「听写 → 停止听写 → 等 15 秒再修改 → 再等 15 秒什么都不做」，看会不会触发 `terms added` 日志。如果这种拉长间隔的单次测试有效，而平常连续使用无效，说明 §5.1 是主因。

---

## 7. 修复建议（待确认后再实现）

按影响面和实现成本排序：

### 7.1 改变"连续听写即取消"的策略（对应 §5.1）★★★★

当前：新听写会立即取消上一次观察会话。
建议：新听写到来时，对上一次会话做**即时 finalize**，而不是直接 `cancel()`。具体做法：

- 把"取消"改成"立即截断观察并跑分析"：使用已收集的 `state.latestObservedText` 立刻调 `runAutomaticVocabularyAnalysis`，即便 idle 还没达到 8s；
- 或者引入一个轻量的"快速结算"路径：只要观察期间曾有过变更（`lastChangedAt != nil`），就允许打断后分析。

实现难度：低（在 `scheduleAutomaticVocabularyObservation` 入口加一段"先 finalize，再调度"的逻辑），覆盖的用户场景最广。

### 7.2 放宽英文候选词的最短长度（对应 §5.4）★★★

把 `isValidLatinOrNumberToken` 的下限从 4 降到 2 或 3，同时保留 LLM 端的"最小 4 字符 / 必须含字母"要求。即使 diff 阶段多放进几个短词，最终也会由 LLM 过滤掉绝大部分噪声。

或者更保守：把长度判定区分"纯字母术语（3 起）"与"含数字术语（4 起）"。

### 7.3 降低 idle settle delay / 引入多重触发（对应 §5.1 + §5.3）★★★

8s 静默期在实际使用中偏长。建议：

- 保留 8s 作为上限；
- 当观察到的 `state.latestObservedText` 与 baseline 的差异已经"足够明显"（出现长度 ≥ N 的新 token）时，尝试触发一次**预分析**（不落库，只做前置校验），减少"刚修改完就被下一次听写打断"的概率。

或者最简单：idle delay 从 8s 降到 3-4s。

### 7.4 改善 AX 值读取鲁棒性（对应 §5.2 / §5.3）★★★

- 把 `readInitialEditableSnapshot` 的重试次数从 1 增加到 2-3；
- 当 `failureReason == "missing-ax-value"` 时，在开关 UI 中加"当前 App 不支持自动词库"的状态提示，帮助用户建立预期；
- 粘贴路径下，把 `automaticVocabularyStartupDelay` 从 600 ms 提升到 900-1200 ms（或改为粘贴路径专属的延迟）。

### 7.5 放宽 LLM 决策 prompt（对应 §5.7）★★

- 移除 "Prefer precision over recall" / "If uncertain, return an empty list" 这一对保守指令；
- 保留必须拒绝的负面清单，但对**正面判定**给出更明确的信号（"prefer keeping any capitalization/spacing correction that spans two or more tokens"）。
- 可选：对 LLM 响应做"宽容模式"，把 LLM 返回的 terms 作为提名，但只入库那些同时通过确定性规则（如 `acceptedTermRegex` 且 normalizedCandidateTerms 中也存在）的词。

### 7.6 可观察性（对应 §5.8）★★

- 在设置页 > 词库 Tab 增加一个折叠区域"最近 10 次自动词库会话"，列出每次会话的退出原因（`session aborted (focused-element-not-editable)` / `analysis skipped (edit too large, ratio=0.72)` / `terms added`），让用户能自助排障；
- Console log 的 `[Auto Vocabulary]` 前缀改为带 session id，便于跨行关联。

### 7.7 编辑比例阈值（对应 §5.6）★

把 `automaticVocabularyEditRatioLimit` 从 0.6 放宽到 0.8-1.0，或改为"插入较短时（< 20 字符）使用绝对字符上限而非比例"。保留"大规模重写直接跳过"的兜底语义。

---

## 8. 建议的落地顺序

1. **先加日志/埋点**（§7.6），在不改语义的情况下，把端到端失败原因暴露出来，用户和我们都能确认主因。
2. **合并 §7.1（最大效果）+ §7.2（最小侵入）两项改动**：这两项合计能覆盖预计 60%+ 的"自动词库无动于衷"场景，风险可控。
3. 其余 §7.3 / §7.4 / §7.5 视上一步的日志结论再决定。

以上改动均有对应单元测试可复用（`AutomaticVocabularyMonitorTests`, `WorkflowControllerAutomaticVocabularyTests`）。修改 §7.1 时要重点覆盖"新会话立即打断旧会话 → 旧会话已有 change → 必须 finalize 并入库"的新路径。
