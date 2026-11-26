# Typeflux Classic 与语音核心包设计稿

- 状态：已搁置（2026-11-26），改为基于 0.4.0 分支独立维护，见 [CLASSIC_FORK_EXECUTION_PLAN.zh-CN.md](CLASSIC_FORK_EXECUTION_PLAN.zh-CN.md)
- 日期：2026-11-26
- 范围：从主仓库抽出语音核心包 `TypefluxVoiceCore`，供 Typeflux 与 Typeflux Classic 共用；同时定义两个 App 共享数据的兼容约定，以及产品标识。

---

## 0. 已确定的决策

| 项目 | 决策 |
|---|---|
| 产品形态 | 两个产品：Typeflux（全功能）、Typeflux Classic（仅语音输入，对齐 0.4 的功能集）|
| 代码组织 | 核心包放在主仓库 `mylxsw/typeflux`；新建 `typeflux-classic` 仓库，只放 Classic 的 App 外壳 |
| 应用身份 | 两个 App 都使用 bundle ID `ai.gulu.app.typeflux`，文件名都是 `Typeflux.app`，界面上加以区分；同一时间只装一个 |
| 切换 | 复用现有更新器的原地替换流程，双向切换，保留权限、登录和数据 |
| 升级路由 | 0.x → Classic；1.0.x → Typeflux（1.0.1 对所有从 1.0.0 升级来的用户弹一次 Classic 说明）|
| 账号、会员、支付 | 两端完全通用 |
| 产品标识 | 所有请求、统计、日志都带上产品标识 |
| 共享数据 | 同一份数据；真正不兼容时才提示用户，兼容时不打扰 |
| 暂不处理 | 单实例保护（同 bundle ID 的两份拷贝同时运行）|

## 1. 目标与非目标

**目标**
1. 两个 App 共用同一份语音核心代码：修一次 bug，两边同时受益。
2. Typeflux 不出现任何功能回归，多进程架构保持不变。
3. Classic 以单进程运行，不包含启动器、Agent 对话、截图、剪贴板、圆环的任何代码。
4. 共享数据有一份明确的、机器可检查的兼容约定。
5. 产品标识贯穿请求头、更新检查、统计和日志。

**非目标**
- 不重构 Typeflux 的多进程架构（`FeatureProcess`）。
- 第一期不拆 `SettingsViewModel` / `SettingsView` 这两个巨型对象，只做到让 Classic 能复用语音设置页（第四阶段）。
- 不做单实例保护，也不做数据清理。

## 2. 现状（基于依赖分析）

分析方法：用脚本建立"顶层类型 → 定义文件"的索引，再统计每个文件引用了哪些外部类型。脚本原型见第 10 节。它基于正则，有已知的误报（例如 `PromptCatalog` 中有一个与 `Ask/Local/AskPromptContext` 同名的私有嵌套类型），最终以编译器为准。

| 指标 | 数值 |
|---|---|
| `Sources/Typeflux` 总量 | 1470 个文件，约 29 万行 |
| 候选核心（第 4 节清单）| 209 个文件，约 5.3 万行，598 个顶层类型 |
| 核心外部引用核心类型的文件 | 约 500 个（Ask 249、Settings 86、App 29 …）|
| 引用核心类型的测试文件 | 587 / 1104 |
| 核心 → 外部的接缝 | 约 60 个类型，归并为 17 类（第 5 节）|
| 核心代码中使用的本地化 key | 293 个（总计 7116 个）|

关键事实：
- `FeatureProcess` 在核心候选中被调用约 35 处，只有 `enabled`、`role`、`owns(_:)`、`send(_:)`、`route(_:)` 五种形态。
- 语音提问用的是 `LLMAgentService.runTool` 强制调用单个工具（`AskSelectionDecision`），**不依赖 MCP**。`WorkflowController.mcpRegistry` 被注入了，但从未被调用。
- `AskModelLibrary`、`ResponsesLLMClient`、`MemoryProvenance` 是"枢纽类型"：如果原样拉进核心，会连带进约 700 个文件（整个 Ask 模块），必须在类型层面切开。
- 历史热键打开的是剪贴板面板（`ClipboardPanelController`）。面板的状态以存储属性的形式放在 `WorkflowController` 上（`historyPanelModel` 等）。
- 客户端请求头统一在 `TypefluxCloudRequestHeaders.applyClientInfo` 中组装，统计的公共属性在 `AppAnalyticsReporter.clientProperties()` 中组装。产品标识只需要加在这两处。
- `SQLiteHistoryStore` 没有版本号，迁移方式是用 `ensureColumnExists` 只加列，天然向后兼容。

## 3. 包结构

在主仓库的 `Package.swift`（swift-tools-version 5.9）中新增两个 target，并作为 library product 导出：

```
Typeflux (app target) ──► TypefluxVoiceCore ──► TypefluxDesign
                     └──────────────────────────► TypefluxDesign
typeflux-classic ─(SwiftPM, 按 tag/revision)─► TypefluxVoiceCore, TypefluxDesign
```

| Target | 内容 | 外部依赖 |
|---|---|---|
| `TypefluxDesign` | 设计 token 与基础组件：`UI/StudioTheme`、`UI/Components/TF*`，以及从 Ask 中拆出的 `AskTheme` 基础 token 和 `StyledGlassShapeBackground` | 无 |
| `TypefluxVoiceCore` | 语音逻辑、悬浮胶囊、语音答案窗口、登录与鉴权状态、更新器、共享存储 | `TypefluxDesign`、`TypefluxAudioSafety`、`TypefluxInferenceProtocol`、`PermissionFlow`、`OpenCCSwift`、`GRPC`/`SwiftProtobuf`（Google STT）|
| `TypefluxVoiceUI`（第四阶段）| 账户与登录视图、语音设置页、语音引导页 | `TypefluxVoiceCore` |

**访问控制**
- 默认 `internal` 跨 module 后会不可见。核心包内的声明统一加上 `package` 访问级别（swift-tools 5.9 已支持），这样 Typeflux 作为同一个 package 内的 target 可以直接使用。这一步通过 codemod 机械完成。
- Classic 是另一个 package，只有它真正用到的入口才升级为 `public`。这个面很小，按需逐步开放。
- 测试 target 增加 `@testable import TypefluxVoiceCore`（587 个文件，机械修改）。

**资源与本地化**
- 核心包有自己的资源 bundle（`Typeflux_TypefluxVoiceCore.bundle`），用于存放核心代码使用的 293 个 key。
- `L()` 改为按顺序查找：先查 App 的 bundle，再查核心包的 bundle。
- bundle 访问器沿用 `AppResourceBundle` 的做法（先找 `Contents/Resources`，再回退到 `Bundle.module`）。
- `scripts/build_release.sh` 和 `scripts/run_dev_app.sh` 需要把新 bundle 复制进 `.app`。

## 4. 核心包边界

**整目录进入核心**：`Audio/`、`STT/`、`TextInjection/`、`History/`、`Networking/`、`Privacy/`、`Stats/`、`Overlay/`

**部分进入核心**

| 来源 | 进核心 | 留在 App |
|---|---|---|
| `Workflow/` | 除右列外的全部 | `+History`、`+Snippets`、`ClipboardPanelSnapshot`、`WorkflowComposerRecording` |
| `Hotkey/` | 事件 tap、绑定、手势仲裁、冲突检查、`HotkeyTarget`/`AppHotkeyAction`（仅作数据类型）| `KeywordHotkey` |
| `LLM/` | 改写链路、Agent 单工具调用（`LLMAgent`、`LLMAgentRouter`、`OpenAICompatibleAgentService`、`LLMAgentResponseSupport`、`Agent/`）、Ollama、免费模型、诊断 | `MCP/` |
| `Auth/` | `AuthState*`、`AuthService`、鉴权与计费模型、Keychain、`BillingAPIService`、`CloudUsageAPIService`、`AccessTokenClaims`、OAuth 服务 | 账户与登录视图（第四阶段移入 `TypefluxVoiceUI`）|
| `Settings/` | `SettingsStore`（主文件）、`AppPreferences`、`VocabularyStore`、`VoiceCapsuleStyle`、`InterfaceStyle`、`LiquidGlassIntensity`、`ModelRegistry`、`OpenAIAudioModelCatalog`、`SettingsChangeObserver`、`AppIconStyle`、`SettingsPermission` | 所有视图与 ViewModel；`SettingsStore+Agent/+Clipboard/+Ring/+LauncherInputHistory/+BackgroundActivity` 等功能扩展 |
| `App/` | `NetworkDebugLogger`、`ErrorLogStore`、`TypefluxDataDirectories`、`AppLocalization`、`AppServerConfiguration`、`ProcessCommandRunner`、`AppStateStore`、`LocalNotificationService`、`TypefluxWindowIdentity`、`AutoUpdater`、`UpdateAlertWindowController`、`AskAnswerWindowController`（改名为 `VoiceAnswerWindowController`）| `DIContainer`、`AppCoordinator`、`StatusBarController`、`Isolation/` 等 |
| `Stability/` | `ShortcutLatency`、`ModuleHealth*`、`ModuleHandle`、`ModuleSupervisor`、`ModuleRecoveryBudget`、`ModuleWorkerGate`、`LatestBackgroundWork`、`WhisperInferenceModule` | 各功能的模块注册（`FileIndexModule`、`Semantic*`、`StorageModules`、`NativeSystemModule`、`PlaybackModule`、`MediaExtraction*`）|
| `Analytics/` | 上报器、语音相关事件 | `FeatureAnalyticsMetadata` 中涉及 Ask 插件和截图的部分 |
| `Ask/Execution/` | `ManagedProcess`、`OwnedProcessReaper`、`AskSecureDirectory`（共 752 行，进程管理基础设施）| — |

`SettingsStore` 的功能扩展可以继续以 `extension SettingsStore` 的形式留在 App 中。前提是 `defaults` 等底层成员为 `package` 可见，因为跨 module 的扩展只能添加计算属性和方法。

## 5. 接缝处理

原则：**数据类型下沉，行为通过协议注入**。核心包只定义协议，Typeflux 和 Classic 各自提供实现。

| # | 接缝 | 处理方式 |
|---|---|---|
| S1 | `FeatureProcess`（约 35 处）| 定义 `VoiceRuntimeBridge` 协议（见下）。Classic 用 `SingleProcessBridge`；Typeflux 在 `App/Isolation/` 中写一个适配器，转发给 `FeatureProcess` |
| S2 | `AuthState` 的跨进程同步（`FeatureAuth`）| `FeatureAuth` 快照是纯数据，下沉到核心；"谁是权威进程"、"把登录/登出转发给 host"并入 `VoiceRuntimeBridge` |
| S3 | 历史面板和剪贴板 | 把 `+History`、`+Snippets` 及面板相关的存储属性迁出 `WorkflowController`，放进 App 侧的 `HistoryPanelCoordinator`。核心只定义 `VoiceHistoryPresenting`（历史热键触发时调用）。Typeflux 的实现是现有剪贴板面板；Classic 的实现是只显示语音历史的列表。`ClipboardService`（系统剪贴板读写）和 `ClipboardCaptureSuppression` 下沉到核心，因为文字注入的粘贴兜底依赖它们 |
| S4 | 片段命令（`ClipboardSnippetCommand`）| 定义可选的 `VoiceSnippetProviding` 协议；Classic 传 nil，语音不触发片段 |
| S5 | 语音答案窗口 | `AskAnswerWindowController` 整体下沉并改名为 `VoiceAnswerWindowController`。它的依赖 `MarkdownSwiftUIView`、`DockVisibilityController`、`AppAppearance`、`ClipboardService` 随之下沉（这几个的依赖都已在核心范围内）。唯一的例外是 `AskWindowBackdrop`：它定义在 `Ask/AskDesign.swift` 这个枢纽文件中，需要和 `AskGlass` 的玻璃背景原语一起拆到 `TypefluxDesign`（见 S16）|
| S6 | 窗口跳转（`SettingsWindowController`、`LoginWindowController`、`StudioSection`、`AccountBillingFlow`、`FeatureSetupStatus`）| 定义 `VoiceAppNavigator` 协议：`openSettings(_ VoiceSettingsDestination)`、`openLogin()`、`openBilling()`、`setupStatus()`。`VoiceSettingsDestination` 是核心包里只含语音相关页面的枚举，Typeflux 侧映射到 `StudioSection` |
| S7 | Agent 与 MCP | 删除 `WorkflowController` 上未被使用的 `mcpRegistry`；Agent 单工具调用链路进入核心 |
| S8 | 模型配置（`AskModelLibrary`）| 拆成两部分：核心的 `ModelProfileStore`，负责 profile 的持久化、Keychain 中的 key、改写模型的选择（`SettingsStore` 只用到 `readProfiles`、`readRewriteModels`、`key(for:)` 这几个静态读取）；App 的 `AskModelLibrary`，负责云端目录拉取、价格和 Ask 专用逻辑，内部改为依赖 `ModelProfileStore`。`ModelRegistry` 对 `AskModelProfile`、`CloudModelPricing` 的引用同样处理 |
| S9 | Responses 流式传输（`ResponsesLLMClient`）| 把通用的流式原语（`ResponsesAPI`、`ResponsesStream`、SSE 帧、token 用量、流错误）下沉到核心的 `LLM/Transport/`。Ask 专属的预算控制、上下文压缩、自定义推理，通过可选 hook 注入。**这是 LLM 层最复杂的接缝**，实施时需要先单独评估 |
| S10 | 记忆（`MemoryProvenance`、`AskMemoryNoteFileStorage`）| 定义 `MemoryInvalidationSink` 协议：Typeflux 桥接到 Ask 的记忆模块，Classic 用空实现。`AskPrivateFile`（很小）下沉 |
| S11 | 热键 | 圆环修饰键手势目前写在 `EventTapHotkeyService` 内部，改为 App 注册的 `ModifierGestureExtension`；`KeywordHotkey` 留在 App。`HotkeyTarget` 和 `AppHotkeyAction` 作为纯数据类型留在核心（有意识的例外：它们没有行为、没有依赖）；Classic 只注册语音相关的内置热键 |
| S12 | 启动器输入框里的语音输入（`WorkflowComposerRecording`、`AskVoiceInput`）| 留在 App |
| S13 | 稳定性 | 健康度基础设施下沉；各功能的模块注册留在 App（见第 4 节）|
| S14 | 统计 | 核心保留上报器和语音事件；`FeatureAnalyticsMetadata` 中引用 Ask 插件和截图类型的部分迁回 App；产品标识由上报器统一附加 |
| S15 | 权限引导 | `PermissionGuidanceService` 改为由 App 注册额外的权限项（屏幕录制、完全磁盘访问），核心只内置麦克风、辅助功能、语音识别 |
| S16 | UI token | `StudioTheme`、`TF*`、`AskTheme` 中悬浮胶囊用到的部分、`StyledGlassShapeBackground`、`AskWindowBackdrop` 与 `AskGlass` 的玻璃背景原语 → `TypefluxDesign`。另外，`InterfaceStyleObserver` 引用了圆环的 `RingStyle`：把 `RingStyle` 作为纯数据枚举下沉，或者把圆环样式的观察逻辑移回 App，二选一 |
| S17 | 数据目录 | `TypefluxDataDirectories.inheritFeatureLayout`（依赖 `FeatureRPC`）留在 App；目录布局和迁移逻辑进入核心，两个 App 使用同一套 |

`VoiceRuntimeBridge` 草图：

```swift
/// Supplies the process topology the voice core runs in. Classic runs everything
/// in one process; Typeflux forwards to its feature processes.
package protocol VoiceRuntimeBridge: AnyObject, Sendable {
    /// True when this process owns session state (auth, settings sync).
    var isAuthority: Bool { get }
    /// True when this process captures audio and runs the voice pipeline.
    var ownsVoiceCapture: Bool { get }

    func claimVoiceCapture() async throws
    func publishVoiceState(_ state: VoiceStateSnapshot)
    func forwardWorkflowPress(_ press: VoiceWorkflowPress)
    func requestLogin()
    func requestLogout()
    func applyAuthSnapshot(_ snapshot: AuthSnapshot)
}

package final class SingleProcessBridge: VoiceRuntimeBridge { /* everything local */ }
```

**装配**：核心包提供 `VoiceCoreContainer`，负责构造 STT、LLM、录音、注入、历史、鉴权、悬浮胶囊和 `WorkflowController`，并接收上述协议的实现作为参数。Typeflux 的 `DIContainer` 持有它并补充其他功能的服务；Classic 的 `ClassicContainer` 只持有它。

## 6. 产品标识

```swift
public enum ProductVariant: String, Sendable {
    case typeflux, classic
    /// Read from Info.plist key `TFProductVariant`; missing means Typeflux.
    public static let current: ProductVariant = …
}
```

| 位置 | 改动 |
|---|---|
| `TypefluxCloudRequestHeaders.applyClientInfo` | 新增请求头 `x-client-product`。`User-Agent` 继续用 `CFBundleName`，两个产品都保持为 `Typeflux` |
| `AppAnalyticsReporter.clientProperties()` | 新增属性 `product` |
| `AutoUpdater` | 更新请求带上 `product`；新增"切换产品"动作，请求另一个产品的安装包，复用原地替换流程 |
| 关于页、反馈、诊断、错误日志 | 显示或附带产品标识 |
| Info.plist | Classic 设置 `TFProductVariant=classic`、`CFBundleDisplayName=Typeflux Classic`，并使用带角标的图标；Typeflux 不设置该键 |

后端约定：没有 `product` 参数或请求头时，版本 < 1.0 的视为老客户端，路由到 Classic；版本 ≥ 1.0 的按 Typeflux 处理。Classic 必须始终上报产品标识，这一条写进测试。

## 7. 共享数据兼容约定

### 7.1 数据清单

| 类别 | 内容 | 谁会写 |
|---|---|---|
| 共享 | `history.sqlite` 与录音目录、UserDefaults 中的语音设置/人设/词汇/使用统计、最近输入记忆与全局记忆文件、本地语音模型、Keychain 中的令牌与 API Key | 两端 |
| Typeflux 独有 | 剪贴板库与图片、笔记、单词本、对话、文件与语义索引、工作流 | 仅 Typeflux；Classic 不读不写 |

目录布局：两端都使用核心包中的 `TypefluxDataDirectories`（`~/.typeflux/data` 等，旧路径保留软链接）。0.4 用户首次启动 Classic 时，执行的是同一套迁移。

### 7.2 版本号与读者兼容

每个共享 SQLite 库新增一张 `store_meta` 表：

| 字段 | 含义 |
|---|---|
| `schema_version` | 每次结构变更都加 1 |
| `min_reader_version` | 只在出现破坏性变更时提高（删列、改列含义、改编码）|
| `last_writer` | 最后一次写入的产品和版本，用于诊断 |

**打开库时的判断**
- `min_reader_version` ≤ 当前 App 支持的版本：正常读写，不提示。
- `min_reader_version` > 当前 App 支持的版本：不写入，提示用户："更新 Classic"或"切换回 Typeflux"，后者一键走更新器。

`history.sqlite` 现有的迁移全部是加列，所以首次引入时回填 `schema_version=1`、`min_reader_version=1`。

### 7.3 规则

1. 新增列必须可空或带默认值。
2. 读取时容忍新列为空，因为这些行可能是另一个产品写的。
3. 枚举字段（例如 `history_records.mode` 和各个 status）遇到不认识的值时，解码为 `.unknown(raw)`：按通用样式展示，原样保留，不丢弃这一行。
4. UserDefaults 遇到不认识的枚举值（例如 Classic 不认识的 STT 供应商）时，运行时回退到默认值，**但不回写**，以免抹掉用户在另一个产品里的选择。核心包提供一个统一的容错读取工具。
5. 每次迁移必须声明自己是"增量"还是"破坏性"，由测试强制检查。
6. 契约测试：用"未来版本"的样例库（多出列、多出枚举值）验证当前读取逻辑。

## 8. Classic 外壳（`typeflux-classic` 仓库）

- **依赖方式**：通过 SwiftPM 依赖主仓库。主仓库的语义化版本 tag 就是 App 版本（`v1.0.1` 等），Classic 按精确版本或 revision 固定，升级时手动调整。SwiftPM 按目标解析依赖，所以不会拉取 Classic 用不到的 SwiftTerm、Yams 等。
- **内容**：入口、`ClassicContainer`、状态栏、精简引导（权限、语音模型、热键、试用、可选登录）、设置页、"了解完整版"（走更新器切换）、Info.plist、图标、签名与公证脚本。
- **本地推理 helper**：Classic 同样需要 `TypefluxInferenceHelper`。需要验证从依赖 package 构建 executable product 的可行性；如果不可行，就在主仓库的发布流程中单独产出 helper 制品。
- **引导完成标记**：使用独立的 key `classic.onboarding.completedVersion`，不影响 Typeflux 的 `onboarding.completedVersion`。

## 9. 实施阶段

| 阶段 | 内容 | 验收标准 | 粗估 |
|---|---|---|---|
| P0 准备 | `ProductVariant`、请求头与统计属性、更新请求带 `product`、`history.sqlite` 加 `store_meta`、删除未使用的 `mcpRegistry` | Typeflux 1.0.1 可以随这一步发版；后端能按产品统计 | 2–3 天 |
| P1 原地切接缝 | 仍在同一个 target 内完成 S1–S17：引入协议，迁出历史面板，拆分 `ModelProfileStore` 和流式传输。加入边界检查脚本（第 10 节），保证核心目录清单内零外部引用 | 边界检查通过；Typeflux 回归测试通过；行为不变 | 1.5–2.5 周 |
| P2 物理迁移 | 新建 target，用 `git mv` 迁移文件（保留 blame），codemod 加 `package`，测试加 import，拆分资源，更新构建脚本和 Xcode 工程 | `swift build`、开发版 App、发布构建都正常；测试通过 | 3–5 天 |
| P3 Classic MVP | `typeflux-classic` 外壳、精简引导、最简设置、切换入口、签名公证 | 0.4 数据可以直接打开；与 Typeflux 双向切换后，数据、权限、登录都保留 | 1–1.5 周 |
| P4 `TypefluxVoiceUI` | 抽出账户与登录视图、语音设置页、语音引导页，两端共用 | Classic 设置页与 Typeflux 对应页面一致 | 1.5–2 周 |

粗估按一名工程师配合 AI 计算，P1 的 S9（流式传输）不确定性最大。P2 会改动数百个文件，**需要一个短暂的合并冻结窗口**。

**测试范围**（遵循 `docs/TESTING.md`，只跑聚焦测试）
- P0：`TypefluxCloudRequestHeaders`、`AppAnalyticsReporter`、`AutoUpdater`、`SQLiteHistoryStore` 相关测试。
- P1：`WorkflowController*`、`AuthState*`、`EventTapHotkeyService`、`LLMRouter`、`OpenAICompatible*`、剪贴板面板相关测试，以及新增协议的测试替身。
- P2：构建、测试发现（`make test-plan`），加上 P1 的测试范围。`scripts/test_groups.py` 中引用源码路径的配置（悬浮胶囊、重试等精简 source closure）需要同步更新。

## 10. 边界检查工具

P1 会把分析脚本整理为 `scripts/check_voice_core_boundary.py`，并加入 `make` 目标：
- 输入：核心文件清单（与第 4 节一致）。
- 输出：核心文件对清单外类型的所有引用。非空即失败。
- 作用：P1 在不移动文件的情况下先把边界做干净；P2 之后由编译器接管，脚本可以退役。

## 11. 风险与待验证

| 风险 | 应对 |
|---|---|
| S9 流式传输的拆分比预期复杂 | P1 先做它的独立评估；如果不划算，Classic 第一期只走 Chat Completions，Responses 路径留在 App |
| 跨 module 后 `package`/`public` 改动量大 | codemod 机械处理；Classic 需要的 `public` 面按需开放 |
| 本地化 key 拆分遗漏，界面显示 key 本身 | `L()` 按顺序查多个 bundle；增加测试检查核心代码中使用的 key 都在核心 bundle 中 |
| 从依赖 package 构建 executable | P3 开始前验证；备选方案是由主仓库产出 helper 制品 |
| `CFBundleDisplayName` 在 Finder、启动台、权限弹窗中的实际显示 | 真机验证；图标角标作为可靠的区分手段 |
| 迁移期间与日常开发冲突 | P1 分小 PR 合并；P2 安排冻结窗口 |
| 两份同 bundle ID 拷贝同时运行 | 已决定暂缓，记录在待办中 |

## 12. 待决问题

1. 第一期 Classic 的设置页：P3 先做最简版（模型、人设、热键、账户），P4 再与 Typeflux 共用？还是等 P4 完成后再发 Classic？
2. Classic 第一期是否保留 Responses API 路径（取决于 S9 的评估）？
3. 片段命令（语音说出别名插入片段）是否属于 Classic 的范围？0.4 没有这个功能，本稿默认不包含。
