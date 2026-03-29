# 开发者入门（Onboarding Guide）

> 目标：让第一次接触本仓库的新同学能够在 30 分钟内完成“本地跑起来 + 理解主流程 + 能修改一个功能点”的闭环。

## 1. 你将会做什么

- **本地运行**：使用 `scripts/run_dev_app.sh` 启动一个稳定路径的 `.app`，避免 macOS 隐私权限反复弹窗。
- **理解主链路**：`Hotkey -> Audio -> STT -> (可选 LLM) -> TextInjection/Clipboard -> History`。
- **学会扩展**：新增 STT Provider / 修改 LLM prompt / 增加设置项 / 替换注入策略。

## 2. 技术栈与运行环境

- **OS**：macOS 13+（`Package.swift` 指定 `macOS(.v13)`）
- **语言/构建**：SwiftPM（`swift build` / `swift run`）
- **UI**：AppKit（菜单栏、Overlay）+ SwiftUI（Settings/History 窗口）
- **音频**：AVFoundation（录音与音量采样）
- **STT**：
  - Whisper/OpenAI-compatible `/audio/transcriptions`
  - Apple Speech `SFSpeechRecognizer`（作为 fallback）
- **LLM**：OpenAI-compatible `/chat/completions`（SSE streaming）
- **文本注入**：Accessibility（AX）+ 剪贴板降级

## 3. 项目结构（目录导览）

仓库根目录：

- **`Package.swift`**：SwiftPM 配置，生成可执行程序 `Typeflux`。
- **`Sources/VoiceInput/`**：主 Target 源码（按领域目录拆分）。
- **`scripts/run_dev_app.sh`**：开发态启动脚本（构建 + 生成 `.build/Typeflux.app` + `open` 启动）。
- **`app/Info.plist`**：`.app` 的 Info.plist（包含隐私权限 key，且 `LSUIElement = true` 作为菜单栏常驻应用）。
- **`docs/`**：设计文档与本入门文档。

`Sources/VoiceInput/` 内部结构：

- **`main.swift`**：应用入口（`NSApplication` + `AppDelegate`）。
- **`App/`**：组装与生命周期（`DIContainer`、`AppCoordinator`、菜单栏控制器、状态与错误日志）。
- **`Workflow/`**：核心用例编排（按住录音、松开处理、注入/替换、落库）。
- **`Hotkey/`**：全局按键监听（CGEventTap + NSEvent monitor 组合策略）。
- **`Audio/`**：录音实现（当前为 `AVFoundationAudioRecorder` 输出 m4a）。
- **`STT/`**：转写协议与实现（Whisper API、Apple Speech、路由）。
- **`LLM/`**：编辑模式的 LLM 生成（OpenAI-compatible streaming）。
- **`TextInjection/`**：选区读取与注入/替换（当前实现走“写剪贴板 + 模拟 ⌘V”）。
- **`Clipboard/`**：剪贴板写入。
- **`Overlay/`**：录音/处理状态的浮层 UI。
- **`History/`**：历史落盘（JSON 索引 + 音频文件路径）与导出。
- **`Settings/`**：设置存储（UserDefaults）与设置窗口 UI。
- **`Dev/`**：开发态启动辅助（从 `swift run` 自动重启到 `.app`）。
- **`Privacy/`**：运行形态检查（是否在 `.app` 内运行）。

## 4. 快速开始：本地跑起来

### 4.1 推荐启动方式（必须）

由于 macOS 的 TCC（隐私权限系统）对“无 `.app` 的命令行可执行程序”行为不稳定，本项目默认会把你从 `swift run` 重新拉起到 `.app`。

- **推荐**：直接运行脚本
  - `scripts/run_dev_app.sh`

脚本做了什么：

- **构建**：`swift build -c debug`
- **生成稳定路径 `.app`**：`.build/Typeflux.app`
- **复制 Info.plist**：使用 `app/Info.plist`（包含权限描述 key）
- **默认不签名**：开发态保持固定 `.app` 路径，避免 TCC/Accessibility 因 ad-hoc 签名变化而把它当成新应用
- **可选稳定签名**：如需签名，传 `DEV_CODESIGN_IDENTITY` 使用固定 identity
- **启动**：`open .build/Typeflux.app --args --prompt-accessibility`

### 4.2 `swift run` 的行为（了解即可）

`main.swift` 顶部会调用 `DevLauncher.relaunchAsAppBundleIfNeeded()`：

- **如果你不是在 `.app` 内运行**：会尝试执行 `scripts/run_dev_app.sh`，随后 `exit(0)`。
- **如果你已经在 `.app` 内运行**：不做任何事。

### 4.3 首次运行需要授权的权限

- **麦克风（Microphone）**：录音必须。
- **语音识别（Speech Recognition）**：仅 Apple Speech fallback 需要。
- **辅助功能（Accessibility）**：用于读取选区文本/注入文本。
- **输入监控（Input Monitoring）**：全局快捷键监听更稳定。

权限相关 key：

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

这些 key 目前在：

- `app/Info.plist`
- `Sources/VoiceInput/Resources/Info.plist`（注意：当前 SwiftPM target exclude 了该文件，运行时主要以 `.app` 的 Info.plist 为准）

## 5. 核心架构与数据流（从入口开始）

### 5.1 入口与生命周期

- **入口**：`Sources/VoiceInput/main.swift`
  - 创建 `NSApplication.shared`
  - 设置 `AppDelegate`
  - `app.setActivationPolicy(.accessory)`（不显示 Dock 图标，菜单栏应用）
  - `applicationDidFinishLaunching`：
    - 可选参数 `--prompt-accessibility`：尽早触发 Accessibility 授权弹窗
    - 创建并启动 `AppCoordinator`

### 5.2 依赖注入（组装点）

- **组装**：`App/DIContainer.swift`
  - `hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)`
  - `audioRecorder = AVFoundationAudioRecorder()`
  - `overlayController = OverlayController(appState: appState)`
  - `clipboard = SystemClipboardService()`
  - `textInjector = AXTextInjector()`
  - `historyStore = FileHistoryStore()`
  - `llmService = OpenAICompatibleLLMService(settingsStore: settingsStore)`
  - `sttRouter = STTRouter(settingsStore:..., whisper: WhisperAPITranscriber(...), appleSpeech: AppleSpeechTranscriber())`

你要扩展某个能力（例如新增 STT Provider / 换录音实现），最直接的入口就是这里。

### 5.3 主控制器

- **`AppCoordinator`**：启动两件事
  - **菜单栏**：`StatusBarController`
  - **主工作流**：`WorkflowController`

### 5.4 主工作流（最重要）

- **文件**：`Workflow/WorkflowController.swift`
- **状态机**：`AppStatus`（`idle/recording/processing/failed`）
- **事件来源**：`HotkeyService.onPressBegan/onPressEnded`

执行链路（按住说话、松开处理）：

- **按下**（`handlePressBegan`）
  - 检查是否在 `.app` 内运行（否则提示必须用脚本启动）
  - 设置状态为 `recording`，展示 `Overlay`
  - 读取选区文本：`textInjector.getSelectedText()`，用于判断是否进入编辑模式
  - 开始录音：`audioRecorder.start(levelHandler:)`，并用 level 更新 Overlay
  - 启动 60s 自动停止的超时任务（防止一直录音）

- **松开**（`handlePressEnded`）
  - 设置状态为 `processing`，Overlay 显示“转写中”
  - `audioRecorder.stop() -> AudioFile`
  - `sttRouter.transcribe(audioFile:) -> instructionText`
  - 如果有选区文本：
    - `llmService.streamEdit(selectedText:, instruction:)` streaming 拼接为 `finalText`
    - `textInjector.replaceSelection(text:)`
  - 否则：
    - `textInjector.insert(text:)`
  - 无论是否注入成功：都会 `clipboard.write(text:)`
  - 写入历史：`historyStore.append(...)`，并 `purge(olderThanDays: 7)`
  - 完成后回到 `idle`，Overlay 延迟消失

降级策略（非常关键）：

- **注入失败**：catch 后仅提示“已复制到剪贴板 (⌘V 粘贴)”，保证可用性。

## 6. 关键模块详解（面向改功能）

### 6.1 Hotkey：按住/松开的全局监听

- **接口**：`Hotkey/HotkeyService.swift`
- **实现**：`Hotkey/EventTapHotkeyService.swift`
- **配置来源**：`SettingsStore`（`enableFnHotkey`、`customHotkeys`）

实现策略（你需要知道的点）：

- **CGEventTap**：更接近“全局监听”，但受系统权限与环境影响较大。
- **NSEvent global/local monitor**：作为 fallback（某些环境更可靠）。
- **失败提示**：如果 event tap 创建失败，会引导你到系统设置里开启 Input Monitoring。

扩展建议：

- **新增快捷键绑定逻辑**：优先在 `SettingsStore` 增加配置项，再在 `EventTapHotkeyService` 中读取并生效。
- **即时生效**：目前实现是 `EventTapHotkeyService` 在运行期读取 `settingsStore`；如果要做到“设置变更立即刷新”，可以引入通知/Combine publisher。

### 6.2 Audio：录音与音量

- **接口**：`Audio/AudioRecorder.swift`
- **实现**：`Audio/AVFoundationAudioRecorder.swift`

关键点：

- **输出格式**：m4a(AAC)
- **临时文件目录**：`FileManager.default.temporaryDirectory/typeflux/`
- **音量**：通过 `AVAudioRecorder.averagePower(forChannel:)` 归一化为 0~1

### 6.3 STT：转写

- **接口**：`STT/Transcriber.swift`（`transcribe(audioFile:) async throws -> String`）
- **路由**：`STTRouter`
  - 如果 `SettingsStore.whisperBaseURL` 非空：走 `WhisperAPITranscriber`
  - 否则如果启用 Apple fallback：走 `AppleSpeechTranscriber`
  - 否则抛错

- **Whisper 实现**：`STT/WhisperAPITranscriber.swift`
  - 走 `POST {baseURL}/audio/transcriptions`
  - multipart：`model` + `file`

- **Apple Speech 实现**：`STT/AppleSpeechTranscriber.swift`
  - 授权必须在主线程触发（避免 TCC crash）

扩展点（最常见改动之一）：

- **新增一个 STT Provider**：
  - 新建一个实现 `Transcriber` 的类型，例如 `FooTranscriber`
  - 在 `SettingsStore` 增加对应配置项（baseURL / key / model / enable 等）
  - 扩展 `STTRouter.transcribe(...)` 的路由策略
  - 在 `DIContainer` 里注入新 transcriber

### 6.4 LLM：编辑模式生成

- **接口**：`LLM/LLMService.swift`（streaming 输出 delta）
- **实现**：`LLM/OpenAICompatibleLLMService.swift`

关键点：

- **配置**：来自 `SettingsStore`（`llmBaseURL/llmAPIKey/llmModel`）
- **默认模型**：当 `llmModel` 为空时使用 `gpt-4o-mini`
- **协议**：`POST {baseURL}/chat/completions`，SSE streaming
- **SSE 解析**：`SSEClient.lines(for:)` 从 `URLSession.shared.bytes(for:)` 逐行读取 `data:`

要修改“编辑模式的行为”通常改两处：

- **Prompt**：`systemPrompt` / `userPrompt`
- **输出清洗**：目前基本只做 trim；如果你要更强约束，可在 `WorkflowController.generateEdit(...)` 末尾增加清洗逻辑（例如去掉 ``` 包裹），但要注意不要误删正常内容。

### 6.5 TextInjection：选区读取与注入

- **接口**：`TextInjection/TextInjector.swift`
- **实现**：`TextInjection/AXTextInjector.swift`

当前实现的事实：

- **读选区**：走 AX attribute `kAXSelectedTextAttribute`
- **写入/替换**：统一走 `setTextViaPaste`：
  - 把文本写入 `NSPasteboard`
  - 模拟 `⌘V`（`CGEvent`）

注意：这里名字叫 `AXTextInjector`，但“写入”并不是 AX set attribute，而是“剪贴板 + 粘贴”。这是一个工程取舍：

- **优点**：兼容性通常更好（大量控件都支持粘贴）
- **缺点**：会覆盖用户剪贴板内容（目前没有恢复机制）

如果你要优化：

- **剪贴板恢复**：在写入前读取并缓存当前 pasteboard 内容，粘贴后恢复。
- **真正 AX 写入**：尝试设置 `kAXValueAttribute` / `kAXSelectedTextAttribute` 等（但兼容性更复杂）。

### 6.6 Overlay：录音/处理浮层

- **实现**：`Overlay/OverlayController.swift`
- **窗口**：`NSPanel`（`.nonactivatingPanel` + `.borderless`），置顶并忽略鼠标
- **更新机制**：所有更新都切回主线程

常见改动：

- **增加计时显示**：目前 Overlay 只显示状态+detail+音量条；若要计时，可在 `OverlayViewModel` 加字段并在 `WorkflowController` 的录音周期内定时更新。

### 6.7 Settings：配置存储与 UI

- **存储**：`Settings/SettingsStore.swift`（`UserDefaults.standard`）
- **窗口**：`Settings/SettingsWindowController.swift`

当前配置项（代码真实实现）：

- **LLM**：`llm.baseURL` / `llm.model` / `llm.apiKey`
- **Whisper(STT)**：`stt.whisper.baseURL` / `stt.whisper.model` / `stt.whisper.apiKey`
- **Apple Speech fallback**：`stt.appleSpeech.enabled`
- **Hotkey**：`hotkey.fn.enabled` / `hotkey.custom.json`（JSON 数组）

新增设置项的标准步骤：

- **步骤 1**：在 `SettingsStore` 加 `var`（读写 UserDefaults）
- **步骤 2**：在 `SettingsWindowController.SettingsView` 加对应 `@State` 与 UI 控件
- **步骤 3**：在 `.onChange` 回调中写回 `settingsStore`
- **步骤 4**：在消费方（例如 `STTRouter/LLMService/HotkeyService`）读取并生效

### 6.8 History：历史记录落盘与导出

- **接口**：`History/HistoryStore.swift`
- **实现**：`History/FileHistoryStore.swift`

行为：

- **目录**：`~/Library/Application Support/Typeflux/`
- **索引**：`history.json`
- **导出**：`exportMarkdown()` 生成 `history-<ts>.md`
- **清理**：`purge(olderThanDays:)` 会删除索引与对应音频文件

当前 History UI：

- `HistoryWindowController` 里的 `HistoryView` 仍是占位文本。

如果你要补齐 History UI：

- 需要将 `FileHistoryStore` 注入到 History 窗口（目前 `HistoryWindowController.shared.show()` 没带参数）。

## 7. 常见需求：怎么改（按场景）

### 7.1 新增一个“处理后自动加标点/格式化”的能力

建议落点：

- **普通输入模式**：在 `WorkflowController` 得到 `instructionText` 后、调用 `applyText` 前做处理。
- **编辑模式**：可在 `generateEdit` 之前修改 prompt，或在输出后做清洗。

### 7.2 新增一个 LLM Provider（非 OpenAI-compatible）

- 新增实现 `LLMService` 的类型
- 在 `SettingsStore` 增加 provider 选择与对应配置
- 在 `DIContainer` 根据配置选择注入哪种 `LLMService`

### 7.3 新增一个 STT Provider

见上文 6.3 的扩展点。

### 7.4 不想覆盖用户剪贴板

建议实现：

- 在 `AXTextInjector.setTextViaPaste` 中：
  - 读出当前 `NSPasteboard.general` 内容（常见类型：string）
  - 粘贴后恢复

注意：恢复剪贴板会引入更多边界情况（比如用户在粘贴期间修改了剪贴板），建议先定义清晰策略。

### 7.5 History 窗口补齐

- 扩展 `HistoryWindowController.show(historyStore:)`
- 从 `DIContainer` 传入 `historyStore`
- SwiftUI View 里展示 `historyStore.list()` 的内容，并提供：复制、导出、清空、播放音频（后续可加）。

## 8. 调试与排错指南

### 8.1 无法启动/一直提示要用脚本运行

- **现象**：按下快捷键提示必须用 `scripts/run_dev_app.sh`。
- **原因**：当前进程不是 `.app`（`PrivacyGuard.isRunningInAppBundle == false`）。
- **处理**：用 `scripts/run_dev_app.sh` 启动。

### 8.2 录音失败

- **检查**：系统设置是否给了麦克风权限
- **定位**：`WorkflowController.handlePressBegan` 的 `audioRecorder.start` catch 会写入 `ErrorLogStore`

### 8.3 Hotkey 不生效 / CGEventTap 创建失败

- **检查**：System Settings -> Privacy & Security -> Input Monitoring
- **提示**：`EventTapHotkeyService` 会尝试打开系统设置页面，并把说明写到错误日志

### 8.4 无法读取选区/无法自动注入

- **检查**：System Settings -> Privacy & Security -> Accessibility
- **降级行为**：注入失败时文本已写入剪贴板，Overlay 会提示“已复制到剪贴板 (⌘V 粘贴)”

### 8.5 Whisper/LLM 请求失败

- **检查**：`Settings…` 配置是否完整（BaseURL、API Key、Model）
- **检查**：BaseURL 是否需要带 `/v1`（取决于你的服务端实现）
  - 例如 LLM 会请求 `{baseURL}/chat/completions`
  - Whisper 会请求 `{baseURL}/audio/transcriptions`

### 8.6 Error Log

- Settings 窗口有 `Errors` tab，来自 `ErrorLogStore.shared`。

## 9. 贡献与代码约定（建议）

- **模块边界**：优先以协议（`AudioRecorder/Transcriber/LLMService/TextInjector/...`）隔离变化。
- **线程**：UI 更新必须回到主线程（Overlay、AppState）。
- **可用性优先**：任何情况下都要保证最终文本写入剪贴板。
- **权限提示尽早**：启动参数 `--prompt-accessibility` 用于尽早触发弹窗，减少用户在第一次按键时的困惑。

## 10. 下一步阅读建议

- **核心必读**：
  - `Sources/VoiceInput/main.swift`
  - `Sources/VoiceInput/App/DIContainer.swift`
  - `Sources/VoiceInput/Workflow/WorkflowController.swift`

- **按功能选读**：
  - Hotkey：`Hotkey/EventTapHotkeyService.swift`
  - STT：`STT/Transcriber.swift`、`STT/WhisperAPITranscriber.swift`、`STT/AppleSpeechTranscriber.swift`
  - LLM：`LLM/OpenAICompatibleLLMService.swift`
  - 注入：`TextInjection/AXTextInjector.swift`
  - 历史：`History/FileHistoryStore.swift`
  - 设置：`Settings/SettingsStore.swift`、`Settings/SettingsWindowController.swift`
