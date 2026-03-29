# 外行开发者入门（把 Typeflux 当作 Swift/macOS 教程）

> 适用人群：你会写代码，但 **完全不会 Swift / iOS / macOS 开发**；你更熟悉 Flutter / Go / Python 等。
>
> 目标：把本项目当成一个可运行的“小而全”示例，引导你从 0 到 1：
>
>- 能在本机跑起来
>- 能读懂主流程
>- 能完成一次“小改动并跑通”
>- 顺带掌握本项目用到的 Swift 与 macOS 基础概念

---

## 0. 学习策略（非常重要）

你不需要先把 Swift 语言、Cocoa/AppKit、SwiftUI 全学完再来看项目。

更高效的路径是：

- **先跑起来**（建立反馈回路）
- **只学本项目用到的 Swift 子集**（边用边学）
- **对比式学习**：把 Swift 的概念映射到你熟悉的 Go/Python/Flutter
- **每学一个概念立刻动手改一点点**（避免“看懂了但写不出来”）

下面的内容就是按这条路线写的。

---

## 1. Typeflux 是什么？（用一句话理解）

Typeflux 是一个 macOS 菜单栏常驻工具：

- 按住快捷键开始录音
- 松开结束录音并转写（STT）
- 若你当时选中了文本：把“选中文本 + 语音指令”交给 LLM 生成替换文本并替换
- 否则：把转写结果插入光标位置
- 注入失败也没关系：会写入剪贴板兜底并提示你 `⌘V` 粘贴

你把它当成一个“练习项目”很合适，因为它覆盖了 macOS 开发的很多典型问题：

- 菜单栏应用（不出现在 Dock）
- 全局快捷键监听（Input Monitoring 权限）
- 麦克风/辅助功能等权限
- 音频录制
- 网络请求（OpenAI-compatible）
- UI（SwiftUI + AppKit 混用）
- 用协议隔离模块实现（可替换、可测试）

---

## 2. 先跑起来：你必须知道的 3 件事

### 2.1 为什么不能直接 `swift run`？（macOS 隐私权限系统）

在 Go/Python 里你可以直接跑可执行文件。但 macOS 的隐私权限（TCC）对“命令行可执行程序”非常苛刻：

- 可能不弹权限框
- 可能在访问麦克风/语音识别时被系统直接终止

因此本项目采用了开发态最佳实践：**稳定路径 `.app`**。

### 2.2 正确启动方式

运行：

- `scripts/run_dev_app.sh`

脚本做了什么（你不需要背，但需要知道原因）：

- `swift build -c debug`
- 生成 `.build/Typeflux.app`（路径固定，避免反复授权）
- 复制 `app/Info.plist` 到 `.app`（里面有权限说明 key）
- 默认不做 ad-hoc `codesign`，避免 Accessibility 把每次重编译后的 app 识别成新应用
- 如果确实需要签名，可传 `DEV_CODESIGN_IDENTITY` 使用固定签名身份
- `open` 启动并传 `--prompt-accessibility`（尽早触发辅助功能授权）

### 2.3 首次运行要授予哪些权限？

你会遇到 4 类权限：

- **Microphone**：录音必须
- **Speech Recognition**：Apple Speech fallback 需要
- **Accessibility**：读取选区/注入文本（或至少能弹框提示）
- **Input Monitoring**：全局快捷键监听更稳定

如果你只想先看到“录音→转写→写剪贴板”的闭环：

- 最少需要 **Microphone**
- 其他权限缺失时会降级或提示

### 2.4 你应该如何“确认已经跑通”？（给你一个明确的验收标准）

把“能跑起来”定义成一个可验收的目标，会让你学习效率更高。

- **验收 1**：运行 `scripts/run_dev_app.sh` 后，菜单栏右上角出现 `VI`。
- **验收 2**：按下/松开快捷键后（默认可能是 Fn 或自定义键），菜单栏图标会短暂变成 `VI●`（录音）→ `VI…`（处理中）→ `VI`（回到空闲）。
- **验收 3**：无论是否成功自动注入，你都能在剪贴板里拿到文本：打开任意文本编辑器，手动 `⌘V` 能粘贴出刚才的转写结果。

如果你发现“流程断在某一步”，先不要着急看全部代码，直接跳到本文的“常见坑与排错”章节按现象排查。

### 2.5 建议的开发工具与调试方式（非常推荐）

你可以用任何编辑器，但如果你从零学习 macOS/Swift，**强烈建议用 Xcode** 作为辅助：

- **Xcode**：用于代码跳转、断点调试、查看控制台日志、查看崩溃堆栈。
- **Console.app（系统自带）**：用于查看 `NSLog` 输出（本项目大量用 `NSLog`）。

一个很实用的方式：

- 平时用你喜欢的 IDE 写代码
- 遇到“为什么没走到某行/为什么权限不弹/为什么事件没回调”，用 Xcode 打断点定位

---

## 3. 你需要掌握的 Swift 子集（对照 Go/Python/Flutter）

这一章只讲本项目里真正用到的。

### 3.1 `let` / `var`（类似 Go 的“是否可变”）

- `let`：常量（不可重新赋值）
- `var`：变量（可重新赋值）

类比：

- Go：都用 `:=` / `var` 声明，但是否可变更多靠习惯/约定；Swift 用语法强制你区分。
- Dart：`final` 类似 `let`，普通变量类似 `var`。

### 3.2 类型系统（Swift 更严格）

Swift 静态类型，很多时候你不用写类型，编译器能推导：

- `let x = 1` 推导为 `Int`
- `let s = "hi"` 推导为 `String`

### 3.3 Optional（可空类型）是 Swift 入门最大坎

Swift 用 `?` 表示“可能为空”。

- `String`：一定有值
- `String?`：可能为 `nil`

你会频繁看到：

- `if let value { ... }`：安全解包（类似 Go 的 `if v != nil` + 取值）
- `guard let value else { return }`：早退出风格（项目里很常用）

本项目例子：

- `guard let baseURL = URL(string: settingsStore.llmBaseURL), !settingsStore.llmAPIKey.isEmpty else { throw ... }`

你可以把 `guard` 理解成 Swift 的“**失败就立刻返回/抛错**”风格：

- Go 里常见：
  - `if err != nil { return err }`
- Swift 里常见：
  - `guard condition else { return }`

Optional 还有两个你会经常见到的写法：

- **可选链**：`obj?.foo?.bar`（其中任意一段为 `nil`，整体就是 `nil`）
- **合并运算符**：`x ?? defaultValue`（如果 `x` 是 `nil`，就用默认值）

在本项目里它们大量出现在“读配置/读系统 API 返回值”这种场景。

### 3.4 `struct` vs `class`（值类型 vs 引用类型）

非常粗暴的理解：

- `struct`：更像 Go 的 struct（值语义，拷贝时复制）
- `class`：引用语义（多个变量可能指向同一对象）

本项目：

- `HistoryRecord` 是 `struct`（数据模型）
- `WorkflowController`、`DIContainer` 等是 `class`（有生命周期、内部状态）

### 3.5 Protocol（接口）= 你在 Go 里最熟悉的东西

Swift 的 `protocol` 和 Go 的 interface 很像。

本项目用协议把“依赖”抽象出来：

- `AudioRecorder`
- `Transcriber`
- `LLMService`
- `ClipboardService`
- `HistoryStore`

理解了这一点，你就能理解 DI（依赖注入）为什么在 `DIContainer` 里做。

### 3.6 闭包（Closure）= 你在 Dart/JS 里写的函数对象

你会看到大量类似：

- `hotkeyService.onPressBegan = { [weak self] in ... }`
- `audioRecorder.start(levelHandler: { level in ... })`

`[weak self]` 是为了避免循环引用（初期不用深究，记住“经常这么写”）。

你可以先用一个“够用就行”的理解：

- **闭包会被保存**：比如 `hotkeyService` 把你传给它的回调保存起来，等事件发生再调用。
- **闭包里又引用了 `self`**：你在回调里要调用 `self?.handlePressBegan()` 等。
- 如果双方互相强引用（`self` 强引用 `hotkeyService`，`hotkeyService` 强引用闭包，闭包又强引用 `self`），就可能出现“互相抓住不释放”的情况。

所以 Swift 里经常写 `[weak self]`，并在闭包里用 `self?` 安全调用。

### 3.7 `throws` / `try`（错误处理）

Swift 里函数可以声明 `throws`，调用方用 `try`：

- `func stop() throws -> AudioFile`
- `let audioFile = try audioRecorder.stop()`

类比：

- Go：`return v, err`
- Python：`raise/try-except`

### 3.8 并发：`async/await` + `Task` + `MainActor`

本项目是现代 Swift 并发风格：

- STT 调用是 `async`
- LLM streaming 用 `AsyncThrowingStream`
- UI 更新必须回主线程（`MainActor` / `DispatchQueue.main`）

你会看到：

- `Task.detached { ... }`：开启后台任务
- `await MainActor.run { ... }`：回主线程更新 UI / 状态

类比：

- Dart：`Future` / `async` / `await` + `Isolate`（更重）
- Go：goroutine + channel（Swift 没这么直接的 channel，但有 stream/async sequence）

你可以先记住一条粗暴规则（足够你在本项目里写出正确的代码）：

- **跟 UI/状态显示相关的修改**（Overlay、菜单栏状态、SwiftUI 的 `@Published`）尽量放在主线程
- **跟 IO/网络/计算相关的工作**（录音结束后的 STT/LLM 调用）放后台任务

本项目的 `WorkflowController` 基本就是按这个思路组织的：

- `Task { @MainActor in ... }` / `await MainActor.run { ... }`：更新 UI
- `Task.detached { ... }`：做耗时处理

### 3.9 一个“够用就行”的 Swift 语法速查（本项目高频）

下面这些写法你看懂，就能读懂并修改大部分代码：

```swift
// guard：不满足条件就提前 return / throw
guard condition else { return }

// if let：安全解包 optional
if let value = maybeValue {
    print(value)
}

// ??：nil 时使用默认值
let v = maybeValue ?? "default"

// do/try/catch：错误处理
do {
    let audio = try audioRecorder.stop()
    print(audio.fileURL)
} catch {
    print("stop failed: \(error)")
}

// async/await：异步调用
let text = try await sttRouter.transcribe(audioFile: audio)

// 回主线程更新 UI
await MainActor.run {
    overlayController.updateStreamingText(text)
}
```

---

## 4. macOS 开发最小知识（只讲本项目用到的）

### 4.1 `.app` 是什么？为什么它重要？

macOS 应用通常是一个目录结构（bundle），里面包含：

- `Contents/MacOS/Typeflux`：可执行文件
- `Contents/Info.plist`：权限说明、Bundle ID、是否菜单栏应用等

隐私权限（麦克风、辅助功能等）通常是按 `.app` 身份管理的，所以脚本要生成 `.app`。

### 4.2 `NSApplication` / `AppDelegate`（应用入口）

`Sources/VoiceInput/main.swift` 做了：

- 创建 `NSApplication.shared`
- 设置 `AppDelegate`
- `app.run()` 进入事件循环

这有点像：

- Flutter：`runApp(MyApp())`（进入 UI/event loop）

### 4.3 菜单栏应用（Status Bar App）

核心点：

- `StatusBarController` 创建 `NSStatusItem`
- `Info.plist` 里 `LSUIElement = true`（不显示 Dock 图标）

### 4.4 SwiftUI + AppKit 混用

- 设置窗口和历史窗口：SwiftUI View
- 菜单栏、Overlay（`NSPanel`）：AppKit

SwiftUI View 通过 `NSHostingView(rootView:)` 放进 AppKit window。

### 4.5 你需要知道的 2 个“系统级现实”

这两个点会解释很多“为什么我按了没反应/为什么权限这么麻烦”：

- **现实 1：权限是 macOS 的强约束**
  - 你的代码写得再正确，没有授权就不会工作。
  - 本项目已经尽量把权限提示前置（例如 `--prompt-accessibility`）。

- **现实 2：全局键盘事件不是 100% 可靠**
  - 不同系统版本、不同输入法、不同安全输入模式（比如密码框）都会影响事件监听。
  - 所以项目提供了“Fn + 自定义快捷键”的组合策略，并且实现了多种监听方式（CGEventTap + NSEvent monitor）。

---

## 5. 按文件带你读懂本项目（从入口一路走到注入）

这一段是“最重要的导览”。你可以跟着打开文件看。

### 5.1 `main.swift`：启动与权限提示

关键逻辑：

- `DevLauncher.relaunchAsAppBundleIfNeeded()`：如果你不是在 `.app` 内运行，会拉起脚本并退出当前进程
- `--prompt-accessibility`：尽早触发辅助功能授权
- 启动 `AppCoordinator`

### 5.2 `AppCoordinator`：启动两个子系统

- `StatusBarController`：菜单栏 UI + Settings/History 菜单
- `WorkflowController`：核心业务流程

### 5.3 `DIContainer`：把所有依赖组装好

你可以把它理解成“构造函数集中地”。

这里决定：

- 用哪个 `AudioRecorder`
- 用哪个 `LLMService`
- STT 是 Whisper 还是 Apple Speech
- TextInjection 用哪个实现

新手改功能时，经常需要来这里“换一个实现”。

### 5.4 `WorkflowController`：核心 pipeline（按住→录音→松开→处理）

只要理解这条链路，你就理解了整个项目：

- 按下：
  - `audioRecorder.start(levelHandler:)`
  - `overlayController.show()`
  - 尝试读取选区 `textInjector.getSelectedText()`

- 松开：
  - `audioRecorder.stop()` 得到音频文件
  - `sttRouter.transcribe(...)` 得到 `instructionText`
  - 若有选区：`llmService.streamEdit(...)` 得到 `finalText`，再替换
  - 否则：直接插入
  - 无论如何：`clipboard.write(text:)` 保底

### 5.5 `STTRouter`：根据配置选择 STT 实现

策略（代码真实行为）：

- 如果 `whisperBaseURL` 非空：走 `WhisperAPITranscriber`
- 否则如果启用了 Apple Speech fallback：走 `AppleSpeechTranscriber`
- 否则报错

### 5.6 `OpenAICompatibleLLMService`：LLM streaming 的实现

它会请求：

- `{llmBaseURL}/chat/completions`

并按 SSE `data:` 逐行解析增量内容。

### 5.7 `AXTextInjector`：名字叫 AX，但写入走“剪贴板 + ⌘V”

读选区是真 AX：

- `kAXSelectedTextAttribute`

写入/替换目前统一走：

- 写剪贴板
- 发送 `⌘V` 事件

这意味着：

- 兼容性通常更好
- 但会覆盖用户剪贴板内容（这是后续可以改进的点）

---

## 6. 跟着做：给你一条“练习路线”（建议按顺序）

每个练习都包含：目标、改哪些文件、你会学到什么。

### 练习 1：改 Overlay 的文案（最简单）

- **目标**：把录音开始时的文案从 `正在输入中` 改成你喜欢的提示
- **改动文件**：`Sources/VoiceInput/Overlay/OverlayController.swift`
- **你会学到**：SwiftUI 文本渲染 + MVC/VM（`OverlayViewModel`）的最小用法

提示：`show()` 里有 `model.statusText = "正在输入中"`。

建议你按以下步骤做（给你一个明确的操作路径）：

- **步骤 1**：打开 `Sources/VoiceInput/Overlay/OverlayController.swift`
- **步骤 2**：找到 `func show()` 里设置 `model.statusText` 的那一行
- **步骤 3**：改成你自己的文案（例如：`"Listening..."` 或 `"正在聆听"`）
- **步骤 4**：运行 `scripts/run_dev_app.sh` 重新启动 app
- **验收**：按住快捷键时 Overlay 显示你改过的文案

你第一次接触 SwiftUI/ObservableObject 时，先把它当成：

- `OverlayViewModel` 是一个“可观察的状态对象”
- SwiftUI View 会自动根据它的字段变化刷新 UI

### 练习 2：把录音超时时间从 60s 改成 15s

- **目标**：更快自动停止
- **改动文件**：`Sources/VoiceInput/Workflow/WorkflowController.swift`
- **你会学到**：`Task.sleep`、异步任务取消

建议步骤：

- **步骤 1**：打开 `Sources/VoiceInput/Workflow/WorkflowController.swift`
- **步骤 2**：搜索 `60_000_000_000`（60 秒的纳秒数）
- **步骤 3**：改成 `15_000_000_000`
- **验收**：按住不放超过 15 秒会自动触发停止并进入处理

### 练习 3：新增一个设置项：录音超时时间

- **目标**：把“超时时间”做成可配置
- **改动文件**：
  - `Sources/VoiceInput/Settings/SettingsStore.swift`
  - `Sources/VoiceInput/Settings/SettingsWindowController.swift`
  - `Sources/VoiceInput/Workflow/WorkflowController.swift`
- **你会学到**：UserDefaults、SwiftUI 双向绑定（`@State` + `.onChange`）

建议做法：

- `SettingsStore` 增加 `var recordingTimeoutSeconds: Int`
- Settings UI 用 `TextField` 或 `Stepper`
- Workflow 读取 `settingsStore.recordingTimeoutSeconds`

更细一点的拆解（新手建议按这个做）：

- **步骤 1（存储）**：在 `SettingsStore` 增加一个 Int 配置，读写 `UserDefaults`。
- **步骤 2（UI）**：在 `SettingsWindowController` 的 SwiftUI View 里加一个控件。
  - 新手推荐 `Stepper`（不用处理字符串转数字）
- **步骤 3（消费）**：在 `WorkflowController` 里把 `Task.sleep` 的数值改为读取配置
- **验收**：你修改设置值后，下一次录音就按新超时生效

你会在这个练习里真正“吃透”三件事：

- UserDefaults 的读写模式
- SwiftUI 的 `@State` + `.onChange`
- 业务逻辑如何读配置并生效

### 练习 4：把“注入失败提示”从中文改成双语

- **目标**：失败提示显示中英双语
- **改动文件**：`WorkflowController.applyText(...)`
- **你会学到**：错误捕获与 UI 更新时机

### 练习 5：新增一个 STT Provider（伪实现也可以）

- **目标**：让你熟悉 `protocol` 与路由
- **改动文件**：
  - 新建 `Sources/VoiceInput/STT/MyTranscriber.swift`（实现 `Transcriber`）
  - 改 `STTRouter`：在某个配置开关下走你的实现
  - 改 `DIContainer` 注入
- **你会学到**：接口（protocol）+ 依赖注入 + 路由

新手可以先做一个“假的 provider”来练手：

- 返回固定字符串（例如 `"hello from my transcriber"`）
- 跳过网络请求

这样你可以先把“接口接线”打通：

- `Transcriber` 协议实现
- `STTRouter` 路由逻辑
- `DIContainer` 注入

等你跑通了，再替换成真实的 HTTP 调用。

### 练习 6：不覆盖用户剪贴板（进阶）

- **目标**：粘贴完成后恢复剪贴板
- **改动文件**：`Sources/VoiceInput/TextInjection/AXTextInjector.swift`
- **你会学到**：系统 API（NSPasteboard）、边界情况处理

注意：恢复剪贴板会遇到“用户在你粘贴期间也修改了剪贴板”的竞态问题，你需要先定义策略。

---

## 7. 常见坑与排错（新手最常遇到）

### 7.1 现象：按快捷键没反应

- **原因 1**：Input Monitoring 没授权
- **原因 2**：Fn 本身在 macOS 上就不稳定（这是产品风险点）
- **处理**：
  - System Settings -> Privacy & Security -> Input Monitoring
  - 或在 Settings 里添加一个自定义快捷键（比如 `⌥Space`）

快速定位建议：

- 先打开 Settings -> Errors 看是否有 `Hotkey: failed to create event tap` 之类的错误
- 再看系统设置权限是否把 `.build/Typeflux.app` 勾选上

### 7.2 现象：录音失败/无声音

- **原因**：Microphone 未授权
- **处理**：System Settings -> Privacy & Security -> Microphone

### 7.3 现象：无法替换选区、无法读选中文字

- **原因**：Accessibility 未授权
- **处理**：System Settings -> Privacy & Security -> Accessibility

### 7.4 现象：Whisper/LLM 报错

你需要检查配置：

- BaseURL 是否正确（是否需要带 `/v1` 取决于你的服务）
  - LLM 请求 `{baseURL}/chat/completions`
  - Whisper 请求 `{baseURL}/audio/transcriptions`
- API Key 是否为空

如果你想快速定位“到底请求发到了哪里”，你可以：

- 在对应 transcriber/service 里临时加 `NSLog` 输出 URL
- 或者在错误消息里把 HTTP body 打印出来（注意不要打印密钥）

### 7.5 去哪里看错误日志？

- Settings 窗口有 `Errors` Tab
- 实现：`ErrorLogStore.shared` 会记录错误并 `NSLog` 输出

---

## 8. 读懂这个项目后，你就读懂了哪些 macOS/Swift 能力？

当你走完练习路线，你会自然掌握：

- Swift 的基本语法（let/var、optional、protocol、closure）
- Swift 并发基础（async/await、Task、MainActor）
- SwiftUI 的最小用法（表单、状态绑定）
- AppKit 的关键概念（NSApplication、NSStatusItem、NSWindow/NSPanel）
- macOS 权限系统与工程实践（稳定路径 app、Info.plist、授权提示）

---

## 9. 下一步建议（如果你想继续深入）

- **把 History UI 做完整**：让 History 窗口真正展示 `FileHistoryStore` 的记录
- **引入 Keychain**：把 API Key 从 UserDefaults 迁移到 Keychain（更符合安全实践）
- **优化 TextInjection**：
  - 尝试真正 AX 写入（复杂但更“纯”）
  - 或实现剪贴板恢复（更实用）
- **为 STT/LLM 增加更多容错信息**：把 HTTP 错误体显示到 Error Log

如果你愿意，我可以按你当前的学习偏好（“先做 UI”/“先做网络”/“先做系统权限”）给你定制一条更细的练习路线。

---

## 10. 附录：Xcode 调试最短路径（新手友好）

如果你以前主要做 Flutter/Go/Python，可能没怎么用过 Xcode 断点。这里给你一个“够用就行”的流程。

### 10.1 如何在 Xcode 里打开项目

本项目是 SwiftPM 项目，你可以用 Xcode 直接打开：

- Xcode -> File -> Open... -> 选择仓库根目录

（如果你更喜欢命令行方式，也可以用 SwiftPM 生成 Xcode 工程，但对本项目不是必须。）

### 10.2 你最值得打断点的 4 个位置

- `WorkflowController.handlePressBegan()`：确认按键事件是否到达
- `audioRecorder.start(...)`：确认是否开始录音
- `STTRouter.transcribe(...)`：确认 STT 路由走到了哪个 provider
- `WorkflowController.applyText(...)`：确认最终文本是如何注入/写剪贴板

### 10.3 你如何确认“主线程/后台线程”问题

你可以先只记住：

- Overlay/UI 更新最好在主线程
- 录音结束后的处理可以在后台

如果你看到类似 `await MainActor.run { ... }` 或 `DispatchQueue.main.async { ... }`，它们的目的都是一样的：回到主线程。

---

## 11. 附录：常用排错清单（按现象查）

### 11.1 菜单栏没有 `VI`

- 你是否是通过 `scripts/run_dev_app.sh` 启动？
- `.build/Typeflux.app` 是否成功生成并被 `open` 启动？

### 11.2 有 `VI`，但按键无反应

- Input Monitoring 是否授权给 `.build/Typeflux.app`？
- Settings 里添加一个自定义快捷键（比如 `⌥Space`）试试

### 11.3 能进入录音，但松开后一直处理中

- STT 配置是否正确？
- 是否网络不可达/服务端返回非 2xx？（可在 Errors 里看）

### 11.4 没有自动输入，但剪贴板有内容

- 这通常是“注入失败降级”在工作。
- 解决：授权 Accessibility，或改进 TextInjection 策略。

---

## 12. 附录：术语表（你会在代码里频繁遇到）

- **TCC**：macOS 隐私权限系统（麦克风、辅助功能等）
- **AX / Accessibility**：辅助功能 API，允许读取/操作当前 UI 元素
- **SSE**：Server-Sent Events，LLM streaming 常用的传输方式
- **DI（依赖注入）**：把“用到什么实现”集中在一个地方组装（这里是 `DIContainer`）
