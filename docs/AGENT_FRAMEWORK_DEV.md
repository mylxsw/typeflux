# Agent 框架重构开发文档

## 目标

将「随便问」功能从当前固定的两步流程（意图判断 → 执行）重构为一个功能完整的 Agent 框架，支持：
- **循环执行**：Agent 可多轮推理，限制最大执行步数（默认 10）
- **工具调用**：内置工具（终止工具、中间工具）+ 外部 MCP 工具
- **MCP 支持**：Model Context Protocol，支持 Stdio（本地进程）和 HTTP/SSE（远程服务器）两种传输方式
- **中间状态可见性**：保留工具调用步骤记录，供后续 UI 展示

---

## 一、架构概览

### 1.1 现有架构 vs 目标架构

**现有（两步流程）**：
```
用户输入 → STT → [LLM Call 1: 强制 answer_or_edit_selection 工具] → [LLM Call 2: answer 或 rewrite]
```

**目标（Agent 循环）**：
```
用户输入 → STT → AgentLoop {
    for step in 0..<maxSteps:
        LLM 推理 → 选择工具 → 执行工具 → 结果反馈给 LLM
    终止条件: 调用终止工具 / 纯文本回复 / 达到最大步数
}
```

### 1.2 目录结构

```
Sources/Typeflux/
├── LLM/
│   ├── Agent/
│   │   ├── AgentMessage.swift          # 多轮对话消息结构
│   │   ├── AgentTool.swift              # 工具协议 + 注册表
│   │   ├── AgentConfig.swift            # 配置（最大步数等）
│   │   ├── AgentResult.swift            # 执行结果
│   │   ├── AgentLoop.swift              # 核心执行引擎
│   │   ├── AgentToolRegistry.swift      # 工具注册表 actor
│   │   ├── AgentToolCallMonitor.swift   # 步骤监控（保留中间状态）
│   │   └── BuiltinAgentTools.swift      # 内置工具实现
│   ├── MCP/
│   │   ├── MCPClient.swift              # MCP 客户端协议
│   │   ├── MCPMessage.swift             # MCP JSON-RPC 消息结构
│   │   ├── StdioMCPClient.swift         # Stdio 传输实现
│   │   ├── HTTPMCPClient.swift          # HTTP/SSE 传输实现
│   │   ├── MCPRegistry.swift            # MCP 服务器管理
│   │   └── MCPToolAdapter.swift         # MCP → AgentTool 适配器
│   ├── LLMMultiTurnService.swift        # 多轮 LLM 协议
│   ├── OpenAICompatibleAgentService+MultiTurn.swift  # 多轮扩展
│   └── AgentPromptCatalog.swift         # Agent 专用提示词
├── Settings/
│   └── MCPSettings.swift                # MCP 配置存储
└── Workflow/
    └── WorkflowController+Agent.swift   # Agent 集成（扩展而非修改）
```

---

## 二、核心数据结构

### 2.1 AgentMessage — 多轮对话消息

**文件**: `LLM/Agent/AgentMessage.swift`

```swift
/// 消息角色
enum AgentMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool  // 工具返回结果
}

/// 单个工具调用
struct AgentToolCall: Equatable, Codable, Sendable {
    let id: String          // 唯一 ID，用于关联调用和结果
    let name: String
    let argumentsJSON: String
}

/// 工具执行结果
struct AgentToolResult: Equatable, Codable, Sendable {
    let toolCallId: String
    let content: String     // 工具返回的内容（文本或 JSON 字符串）
    let isError: Bool
}

/// 助手消息（文本 + 工具调用）
struct AgentAssistantMessage: Equatable, Codable, Sendable {
    let text: String?
    let toolCalls: [AgentToolCall]
}

/// 单条消息联合类型
enum AgentMessage: Equatable, Sendable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantMessage)
    case toolResult(AgentToolResult)

    /// 序列化为 provider 特定的字典格式
    func toProviderFormat(role: AgentMessageRole, apiStyle: LLMRemoteAPIStyle) -> [String: Any]
}
```

### 2.2 AgentTool — 工具协议

**文件**: `LLM/Agent/AgentTool.swift`

```swift
/// Agent 工具协议
protocol AgentTool: Sendable {
    /// 工具定义（名称、描述、输入 Schema）
    var definition: LLMAgentTool { get }
    /// 执行工具
    /// - Parameter arguments: JSON 字符串参数
    /// - Returns: 执行结果（文本或 JSON 字符串）
    func execute(arguments: String) async throws -> String
}

/// 终止工具标记协议
protocol TerminationTool: AgentTool {}

/// 内置工具标识
enum BuiltinAgentToolName: String, CaseIterable {
    case answerText = "answer_text"
    case editText = "edit_text"
    case getClipboard = "get_clipboard"
}
```

### 2.3 AgentToolRegistry — 工具注册表

**文件**: `LLM/Agent/AgentToolRegistry.swift`

```swift
actor AgentToolRegistry {
    private var tools: [String: any AgentTool] = [:]
    private var terminationToolNames: Set<String> = []

    func register(_ tool: any AgentTool)
    func registerAll(_ tools: [any AgentTool])
    func unregister(name: String)

    /// 执行工具
    func execute(name: String, arguments: String, toolCallId: String) async throws -> AgentToolResult

    /// 获取所有工具定义（用于 LLM 调用）
    var definitions: [LLMAgentTool] { get }

    /// 检查是否为终止工具
    func isTerminationTool(name: String) -> Bool

    /// 检查工具是否存在
    func hasTool(name: String) -> Bool
}
```

### 2.4 AgentConfig — 配置

**文件**: `LLM/Agent/AgentConfig.swift`

```swift
struct AgentConfig: Sendable {
    /// 最大执行步数（默认 10）
    let maxSteps: Int
    /// 是否允许 LLM 并行调用多个工具（默认 false）
    let allowParallelToolCalls: Bool
    /// 温度参数
    let temperature: Double?
    /// 是否启用流式输出回调
    let enableStreaming: Bool

    static let `default` = AgentConfig(
        maxSteps: 10,
        allowParallelToolCalls: false,
        temperature: nil,
        enableStreaming: false
    )
}
```

### 2.5 AgentStep — 执行步骤（中间状态）

**文件**: `LLM/Agent/AgentToolCallMonitor.swift`

```swift
/// 单个执行步骤的记录
struct AgentStep: Sendable {
    let stepIndex: Int
    let assistantMessage: AgentAssistantMessage
    let toolResults: [AgentToolResult]
    let durationMs: Int64
}

/// 步骤监控器协议
protocol AgentStepMonitor: AnyObject, Sendable {
    /// 每一步执行完成后调用
    func agentDidCompleteStep(_ step: AgentStep) async
    /// Agent 完成后调用
    func agentDidFinish(outcome: AgentOutcome) async
}

/// 用于 UI 展示的实时状态
struct AgentRealtimeState: Sendable {
    let currentStep: Int
    let lastToolCall: AgentToolCall?
    let accumulatedText: String
    let toolCallsSoFar: [AgentToolCall]
}
```

### 2.6 AgentResult — 执行结果

**文件**: `LLM/Agent/AgentResult.swift`

```swift
/// Agent 执行结果
struct AgentResult: Sendable {
    /// 终止原因
    enum Outcome: Sendable {
        /// 模型直接返回文本（无工具调用）
        case text(String)
        /// 调用了终止工具
        case terminationTool(name: String, argumentsJSON: String)
        /// 达到最大步数
        case maxStepsReached
        /// 执行出错
        case error(Error)
    }

    let outcome: Outcome
    let steps: [AgentStep]
    let totalDurationMs: Int64

    /// 提取最终答案文本（用于 answer_text 工具）
    var answerText: String? {
        if case .text(let text) = outcome { return text }
        if case .terminationTool("answer_text", let args) = outcome {
            return extractAnswer(from: args)
        }
        return nil
    }

    /// 提取要替换的文本（用于 edit_text 工具）
    var editedText: String? {
        if case .terminationTool("edit_text", let args) = outcome {
            return extractReplacement(from: args)
        }
        return nil
    }
}
```

---

## 三、LLM 多轮服务协议

### 3.1 LLMMultiTurnService

**文件**: `LLM/LLMMultiTurnService.swift`

现有 `LLMAgentService.runTool()` 只支持单轮 + 强制工具调用。新增多轮支持：

```swift
/// 单轮 LLM 输出
enum AgentTurn: Sendable {
    /// 纯文本回复
    case text(String)
    /// 工具调用
    case toolCalls([AgentToolCall])
    /// 文本 + 工具调用
    case textWithToolCalls(text: String, toolCalls: [AgentToolCall])
}

/// 多轮 LLM 服务协议
protocol LLMMultiTurnService: Sendable {
    /// 执行多轮对话
    /// - Parameters:
    ///   - messages: 消息历史（包含 system、user、assistant、toolResult）
    ///   - tools: 可用工具定义列表
    ///   - config: 调用配置
    /// - Returns: LLM 本轮输出
    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn
}

/// 调用配置
struct LLMCallConfig: Sendable {
    /// 强制使用某个工具（nil 表示模型自由选择）
    let forcedToolName: String?
    /// 允许并行工具调用
    let parallelToolCalls: Bool
    /// 温度参数
    let temperature: Double?
}
```

### 3.2 Provider 特定的消息序列化

**文件**: `LLM/Agent/AgentMessage+ProviderFormat.swift`

每种 API 格式（OpenAI/Anthropic/Gemini）消息格式不同，需要分别序列化：

```swift
extension AgentMessage {
    /// 转换为 OpenAI 兼容格式的消息
    static func toOpenAIMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // system → {"role": "system", "content": "..."}
        // user → {"role": "user", "content": "..."}
        // assistant (no tool) → {"role": "assistant", "content": "..."}
        // assistant (tool_calls) → {"role": "assistant", "tool_calls": [...], "content": null}
        // tool_result → {"role": "tool", "tool_call_id": "...", "content": "..."}
    }

    /// 转换为 Anthropic 格式的消息
    static func toAnthropicMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // system 合并到 system 字段
        // user → {"role": "user", "content": [{"type": "text", "text": "..."}]}
        // assistant (tool) → {"role": "assistant", "content": [{"type": "tool_use", ...}]}
        // tool_result → {"role": "user", "content": [{"type": "tool_result", ...}]}
    }

    /// 转换为 Gemini 格式的内容
    static func toGeminiContents(_ messages: [AgentMessage]) -> [[String: Any]] {
        // user → {"role": "user", "parts": [{"text": "..."}]}
        // model → {"role": "model", "parts": [{"text": "..."}]}
        // tool → {"role": "user", "parts": [{"functionCall": ...}, {"functionResponse": ...}]}
    }
}
```

---

## 四、核心引擎：AgentLoop

### 4.1 AgentLoop actor

**文件**: `LLM/Agent/AgentLoop.swift`

```swift
actor AgentLoop {
    private let llmService: LLMMultiTurnService
    private let toolRegistry: AgentToolRegistry
    private let config: AgentConfig
    private var stepMonitor: (any AgentStepMonitor)?

    init(
        llmService: LLMMultiTurnService,
        toolRegistry: AgentToolRegistry,
        config: AgentConfig = .default
    ) {
        self.llmService = llmService
        self.toolRegistry = toolRegistry
        self.config = config
    }

    /// 设置步骤监控器
    func setStepMonitor(_ monitor: (any AgentStepMonitor)?)

    /// 运行 Agent
    /// - Parameters:
    ///   - messages: 初始消息（通常为 system + user）
    ///   - streamHandler: 流式文本输出回调（可选）
    /// - Returns: Agent 执行结果
    func run(
        messages: [AgentMessage],
        streamHandler: ((String) -> Void)? = nil
    ) async throws -> AgentResult
}
```

### 4.2 执行流程详解

```
run(messages:):
  accumulatedMessages = messages
  accumulatedText = ""
  steps = []

  for stepIndex in 0..<config.maxSteps:
    stepStart = now()

    turn = await llmService.complete(
      messages: accumulatedMessages,
      tools: toolRegistry.definitions,
      config: LLMCallConfig(
        forcedToolName: nil,           // 自由选择
        parallelToolCalls: config.allowParallelToolCalls,
        temperature: config.temperature
      )
    )

    switch turn:
      case .text(let text):
        // 纯文本回复 → 终止
        if !text.isEmpty:
          accumulatedText += text
          streamHandler?(text)
        return AgentResult(outcome: .text(accumulatedText), steps: steps)

      case .toolCalls(let toolCalls):
        assistantMsg = assistant(toolCalls)
        accumulatedMessages += [assistantMsg]

        toolResults = []
        for toolCall in toolCalls:
          if toolRegistry.isTerminationTool(toolCall.name):
            // 终止工具 → 直接返回
            return AgentResult(
              outcome: .terminationTool(name: toolCall.name, argumentsJSON: toolCall.argumentsJSON),
              steps: steps + [step(assistantMsg, toolResults)]
            )

          result = await toolRegistry.execute(...)
          toolResults += [result]
          accumulatedMessages += [toolResultMessage(result)]

        steps += [step(assistantMsg, toolResults, durationMs)]

      case .textWithToolCalls(let text, let toolCalls):
        accumulatedText += text
        streamHandler?(text)
        // 同样处理 toolCalls...
```

### 4.3 并行工具执行

当 `config.allowParallelToolCalls = true` 且模型返回多个工具调用时：

```swift
// 并行执行所有工具
let toolResults = await withTaskGroup(of: AgentToolResult.self) { group in
    for toolCall in toolCalls {
        group.addTask {
            try await self.toolRegistry.execute(
                name: toolCall.name,
                arguments: toolCall.argumentsJSON,
                toolCallId: toolCall.id
            )
        }
    }
    var results: [AgentToolResult] = []
    for try await result in toolResults {
        results.append(result)
    }
    return results
}
```

---

## 五、内置工具实现

### 5.1 终止工具

#### AnswerTextTool

**文件**: `LLM/Agent/BuiltinAgentTools.swift`

```swift
/// 向用户展示答案的终止工具
struct AnswerTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: "answer_text",
        description: "当用户想要获取关于选中文本的问题答案时使用。在弹窗中向用户展示最终答案。",
        inputSchema: LLMJSONSchema(
            name: "answer_text",
            schema: [
                "type": .string("object"),
                "required": .array([.string("answer")]),
                "properties": .object([
                    "answer": .object([
                        "type": .string("string"),
                        "description": .string("要向用户展示的最终答案")
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("markdown"), .string("plain")])
                    ])
                ])
            ]
        )
    )

    func execute(arguments: String) async throws -> String {
        // 验证参数有效性
        struct Args: Codable { let answer: String; let format: String? }
        let args = try JSONDecoder().decode(Args.self, from: arguments.data(using: .utf8)!)
        return arguments  // 直接返回原 JSON，AgentResult 会解析
    }
}
```

#### EditTextTool

```swift
/// 替换选中文本的终止工具
struct EditTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: "edit_text",
        description: "当用户想要重写、翻译、改写或以其他方式修改选中文本时使用。用新文本替换用户之前选中的文本。",
        inputSchema: LLMJSONSchema(
            name: "edit_text",
            schema: [
                "type": .string("object"),
                "required": .array([.string("replacement")]),
                "properties": .object([
                    "replacement": .object([
                        "type": .string("string"),
                        "description": .string("用于替换选中文本的新内容")
                    ])
                ])
            ]
        )
    )

    func execute(arguments: String) async throws -> String {
        return arguments
    }
}
```

### 5.2 中间工具

#### GetClipboardTool

```swift
/// 读取剪贴板内容
struct GetClipboardTool: AgentTool {
    let definition = LLMAgentTool(
        name: "get_clipboard",
        description: "读取当前系统剪贴板的内容。当用户提到「剪贴板里的内容」或需要引用之前复制的内容时使用。",
        inputSchema: LLMJSONSchema(
            name: "get_clipboard",
            schema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:])
            ]
        )
    )

    private let clipboardService: ClipboardService

    func execute(arguments: String) async throws -> String {
        guard let content = clipboardService.getString() else {
            return #"{"error": "剪贴板为空或无文本内容"}"#
        }
        // 返回 JSON 格式
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return #"{"content": "\#(escaped)"}"#
    }
}
```

---

## 六、MCP 支持

### 6.1 MCP 协议概述

MCP（Model Context Protocol）是一个标准协议，用于 LLM 与外部工具服务通信。协议基于 JSON-RPC 2.0。

**传输方式**：
- **Stdio**：通过标准输入/输出与本地进程通信（适合本地运行的工具服务器）
- **HTTP/SSE**：通过 HTTP POST + SSE 接收响应（适合远程工具服务器）

### 6.2 MCP 消息结构

**文件**: `LLM/MCP/MCPMessage.swift`

```swift
/// MCP JSON-RPC 消息
struct MCPJsonRPCMessage: Codable, Sendable {
    let jsonrpc: String  // "2.0"
    let id: MCPMessageId?
    let method: String?
    let params: MCPParams?
    let result: MCPResult?
    let error: MCPError?
}

enum MCPMessageId: Codable, Sendable {
    case string(String)
    case number(Int)
}

enum MCPParams: Codable, Sendable {
    case initialize(MCPInitializeParams)
    case toolsList(MCPToolsListParams)
    case toolsCall(MCPToolsCallParams)
}

enum MCPResult: Codable, Sendable {
    case initialize(MCPInitializeResult)
    case toolsList(MCPToolsListResult)
    case toolsCall(MCPToolsCallResult)
}

/// 初始化参数
struct MCPInitializeParams: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let clientInfo: MCPClientInfo
}

/// 服务器能力
struct MCPServerCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?
}

/// 工具能力
struct MCPToolsCapability: Codable, Sendable {
    let listChanged: Bool?
}

/// 工具定义
struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let inputSchema: MCPObjectSchema
}

/// 工具调用参数
struct MCPToolsCallParams: Codable, Sendable {
    let name: String
    let arguments: [String: AnyCodable]?
}

/// 工具调用结果
struct MCPToolsCallResult: Codable, Sendable {
    let content: [MCPContentBlock]
    let isError: Bool?
}

struct MCPContentBlock: Codable, Sendable {
    let type: String  // "text"
    let text: String?
}
```

### 6.3 MCPClient 协议

**文件**: `LLM/MCP/MCPClient.swift`

```swift
/// MCP 客户端协议
protocol MCPClient: Actor {
    var serverInfo: MCPConnectionInfo { get }
    var isConnected: Bool { get }

    /// 连接到 MCP 服务器
    func connect() async throws

    /// 断开连接
    func disconnect() async

    /// 获取可用工具列表
    func listTools() async throws -> [MCPToolDefinition]

    /// 调用工具
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult

    /// 测试连接
    func ping() async throws
}

/// 连接信息
struct MCPConnectionInfo: Sendable {
    let name: String
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
}
```

### 6.4 Stdio MCP 客户端

**文件**: `LLM/MCP/StdioMCPClient.swift`

通过进程的标准输入/输出通信：

```swift
actor StdioMCPClient: MCPClient {
    private let config: MCPStdioConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var pendingRequests: [String: CheckedContinuation<MCPJsonRPCMessage, Error>] = [:]
    private var messageIdCounter: Int = 0
    private var connectionInfo: MCPConnectionInfo?

    init(config: MCPStdioConfig) {
        self.config = config
    }

    func connect() async throws {
        // 1. 启动进程
        process = Process()
        process?.executableURL = URL(fileURLWithPath: config.command)
        process?.arguments = config.args
        if !config.env.isEmpty {
            process?.environment = config.env
        }

        // 2. 设置管道
        inputPipe = Pipe()
        outputPipe = Pipe()
        process?.standardInput = inputPipe
        process?.standardOutput = outputPipe

        // 3. 启动读取循环
        try process?.run()
        startReadingLoop()

        // 4. 发送初始化
        let initResult = try await sendRequest(method: "initialize", params: .initialize(.init(
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: nil)),
            clientInfo: .init(name: "Typeflux", version: "1.0.0")
        )))

        guard case .initialize(let info) = initResult.result else {
            throw MCPError.invalidConnection
        }
        connectionInfo = info

        // 5. 发送 initialized 通知
        try await sendNotification(method: "notifications/initialized", params: nil)
    }

    func disconnect() async {
        process?.terminate()
        process = nil
    }

    func listTools() async throws -> [MCPToolDefinition] {
        let response = try await sendRequest(method: "tools/list", params: .toolsList(.init()))
        guard case .toolsList(let result) = response.result else {
            throw MCPError.invalidResponse
        }
        return result.tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        let argsDict = arguments.mapValues { AnyCodable($0) }
        let response = try await sendRequest(
            method: "tools/call",
            params: .toolsCall(.init(name: name, arguments: argsDict))
        )
        guard case .toolsCall(let result) = response.result else {
            throw MCPError.invalidResponse
        }
        return result
    }

    private func sendRequest(method: String, params: MCPParams?) async throws -> MCPJsonRPCMessage {
        let id = String(messageIdCounter)
        messageIdCounter += 1
        let message = MCPJsonRPCMessage(jsonrpc: "2.0", id: .string(id), method: method, params: params, result: nil, error: nil)
        let data = try JSONEncoder().encode(message)
        inputPipe?.fileHandleForWriting.write(data)
        inputPipe?.fileHandleForWriting.write("\n".data(using: .utf8)!)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func startReadingLoop() {
        Task {
            let handle = outputPipe!.fileHandleForReading
            for try await line in handle.bytes.untilLine() {
                if let data = line.data(using: .utf8),
                   let message = try? JSONDecoder().decode(MCPJsonRPCMessage.self, from: data) {
                    if let id = message.id, case .string(let idStr) = id {
                        pendingRequests[idStr]?.resume(returning: message)
                        pendingRequests[idStr] = nil
                    }
                }
            }
        }
    }
}

struct MCPStdioConfig: Sendable {
    let command: String
    let args: [String]
    let env: [String: String]
}
```

### 6.5 HTTP/SSE MCP 客户端

**文件**: `LLM/MCP/HTTPMCPClient.swift`

通过 HTTP POST 发送请求，SSE 接收响应：

```swift
actor HTTPMCPClient: MCPClient {
    private let config: MCPHTTPConfig
    private var session: URLSession?
    private var connectionInfo: MCPConnectionInfo?

    init(config: MCPHTTPConfig) {
        self.config = config
    }

    func connect() async throws {
        session = URLSession(configuration: .default)
        // 发送初始化请求
        let initResult = try await post(method: "initialize", params: .initialize(.init(
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: nil)),
            clientInfo: .init(name: "Typeflux", version: "1.0.0")
        )))
        guard case .initialize(let info) = initResult.result else {
            throw MCPError.invalidConnection
        }
        connectionInfo = info
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        let argsDict = arguments.mapValues { AnyCodable($0) }
        let response = try await post(
            method: "tools/call",
            params: .toolsCall(.init(name: name, arguments: argsDict))
        )
        guard case .toolsCall(let result) = response.result else {
            throw MCPError.invalidResponse
        }
        return result
    }

    private func post(method: String, params: MCPParams?) async throws -> MCPJsonRPCMessage {
        let message = MCPJsonRPCMessage(
            jsonrpc: "2.0",
            id: .string(String(messageIdCounter)),
            method: method,
            params: params,
            result: nil,
            error: nil
        )
        messageIdCounter += 1

        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(message)

        let (data, _) = try await session!.data(for: request)
        return try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data)
    }
}

struct MCPHTTPConfig: Sendable {
    let url: URL
    let apiKey: String?
}
```

### 6.6 MCP → AgentTool 适配器

**文件**: `LLM/MCP/MCPToolAdapter.swift`

将 MCP 工具包装为 `AgentTool`：

```swift
/// MCP 工具到 AgentTool 的适配器
struct MCPToolAdapter: AgentTool {
    let client: any MCPClient
    let toolDef: MCPToolDefinition

    var definition: LLMAgentTool {
        LLMAgentTool(
            name: toolDef.name,
            description: toolDef.description ?? "",
            inputSchema: convertSchema(toolDef.inputSchema)
        )
    }

    func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if let data = arguments.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = dict
        } else {
            args = [:]
        }

        let result = try await client.callTool(name: toolDef.name, arguments: args)
        let content = result.content.map { $0.text ?? "" }.joined(separator: "\n")

        if result.isError == true {
            return #"{"error": "\#(content)"}"#
        }
        return #"{"result": "\#(content)"}"#
    }

    private func convertSchema(_ mcpSchema: MCPObjectSchema) -> LLMJSONSchema {
        // 将 MCP JSON Schema 格式转换为 LLMJSONSchema
        ...
    }
}
```

### 6.7 MCPRegistry — MCP 服务器管理

**文件**: `LLM/MCP/MCPRegistry.swift`

```swift
actor MCPRegistry {
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    private var cachedTools: [String: (any AgentTool, UUID)] = [:]  // toolName → (adapter, serverId)

    /// 注册 MCP 服务器
    func addServer(_ config: MCPServerConfig) async throws {
        let client: any MCPClient
        switch config.transport {
        case .stdio(let stdioConfig):
            client = StdioMCPClient(config: stdioConfig)
        case .http(let httpConfig):
            client = HTTPMCPClient(config: httpConfig)
        }

        try await client.connect()
        servers[config.id] = client
        serverConfigs[config.id] = config

        // 刷新工具缓存
        try await refreshTools(for: config.id)
    }

    /// 移除 MCP 服务器
    func removeServer(id: UUID) async {
        await servers[id]?.disconnect()
        servers.removeValue(forKey: id)
        serverConfigs.removeValue(forKey: id)
        cachedTools = cachedTools.filter { $0.value.1 != id }
    }

    /// 获取所有 MCP 工具
    func allMCPtools() async -> [any AgentTool] {
        await refreshCachedToolsIfNeeded()
        return cachedTools.map { $0.value.0 }
    }

    /// 查找工具所属服务器
    func serverId(forToolName name: String) -> UUID? {
        cachedTools[name]?.1
    }

    private func refreshTools(for serverId: UUID) async throws {
        guard let client = servers[serverId] else { return }
        let tools = try await client.listTools()
        for tool in tools {
            cachedTools[tool.name] = (MCPToolAdapter(client: client, toolDef: tool), serverId)
        }
    }
}
```

---

## 七、MCP 配置存储

### 7.1 配置模型

**文件**: `Settings/MCPSettings.swift`

```swift
/// MCP 服务器配置
struct MCPServerConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var transport: MCPTransportConfig
    var enabled: Bool
    var autoConnect: Bool
}

/// 传输配置
enum MCPTransportConfig: Codable, Sendable {
    case stdio(MCPStdioTransportConfig)
    case http(MCPHTTPTransportConfig)
}

struct MCPStdioTransportConfig: Codable, Sendable {
    let command: String
    var args: [String]
    var env: [String: String]
}

struct MCPHTTPTransportConfig: Codable, Sendable {
    var url: String
    var apiKey: String?
}

/// MCP 设置存储
final class MCPSettingsStore {
    private let defaults: UserDefaults
    private let serversKey = "mcp.servers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var servers: [MCPServerConfig] {
        get {
            guard let data = defaults.data(forKey: serversKey),
                  let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
                return []
            }
            return configs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: serversKey)
            }
        }
    }

    func addServer(_ config: MCPServerConfig) {
        var current = servers
        current.append(config)
        servers = current
    }

    func removeServer(id: UUID) {
        servers = servers.filter { $0.id != id }
    }

    func updateServer(_ config: MCPServerConfig) {
        servers = servers.map { $0.id == config.id ? config : $0 }
    }
}
```

---

## 八、WorkflowController 集成

### 8.1 扩展而非修改

现有 `WorkflowController` 保持不变，新增扩展文件：

**文件**: `Workflow/WorkflowController+Agent.swift`

```swift
extension WorkflowController {
    /// 使用新 Agent 框架处理「随便问」
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        sessionID: UUID
    ) async throws -> AskAgentResult {
        // 1. 构建工具注册表
        let registry = await buildAgentToolRegistry(
            selectedText: selectedText,
            clipboard: clipboard
        )

        // 2. 创建 AgentLoop
        let agentLoop = AgentLoop(
            llmService: multiTurnLLMService,
            toolRegistry: registry,
            config: .default
        )

        // 3. 设置步骤监控（可选，用于后续 UI 展示）
        if settingsStore.agentStepLoggingEnabled {
            agentLoop.setStepMonitor(AgentStepLogger())
        }

        // 4. 构建初始消息
        let systemPrompt = PromptCatalog.askAgentSystemPrompt(personaPrompt: personaPrompt)
        let userPrompt = PromptCatalog.askAgentUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction
        )
        let messages: [AgentMessage] = [
            .system(systemPrompt),
            .user(userPrompt)
        ]

        // 5. 运行 Agent
        let result = try await agentLoop.run(messages: messages)

        // 6. 处理结果
        switch result.outcome {
        case .text(let text):
            return .answer(text)

        case .terminationTool("answer_text", let args):
            return .answer(parseAnswerArgs(args))

        case .terminationTool("edit_text", let args):
            return .edit(parseEditArgs(args))

        case .maxStepsReached:
            throw AgentError.maxStepsExceeded

        case .error(let error):
            throw error
        }
    }

    private func buildAgentToolRegistry(
        selectedText: String?,
        clipboard: ClipboardService
    ) -> AgentToolRegistry {
        let registry = AgentToolRegistry()

        // 注册内置终止工具
        registry.register(AnswerTextTool())
        registry.register(EditTextTool())

        // 注册中间工具
        registry.register(GetClipboardTool(clipboardService: clipboard))

        // 注册 MCP 工具（如果已配置）
        Task {
            let mcpTools = await mcpRegistry.allMCPtools()
            for tool in mcpTools {
                registry.register(tool)
            }
        }

        return registry
    }
}

/// Agent 执行结果
enum AskAgentResult: Sendable {
    case answer(String)   // 展示答案
    case edit(String)     // 替换文本
}
```

### 8.2 Prompt 模板

**文件**: `LLM/Agent/AgentPromptCatalog.swift`

```swift
enum AgentPromptCatalog {
    /// Agent 系统提示词
    static func askAgentSystemPrompt(personaPrompt: String?) -> String {
        var parts: [String] = [
            """
            You are a helpful AI assistant for the Typeflux voice input app.

            You have access to various tools to help answer the user's questions or modify their selected text.

            Available tools:
            - answer_text: Present a final answer to the user in a popup window. Use when the user asks a question, wants explanation, analysis, or any read-only information.
            - edit_text: Replace the user's selected text with new content. Use when the user explicitly wants to rewrite, translate, shorten, expand, fix, or reformat their selected text.
            - get_clipboard: Read the current clipboard content. Use when the user references content from their clipboard.

            Decision rules:
            - Default to answer_text for questions, explanations, and analysis.
            - Use edit_text only when the user clearly wants to transform their selected text.
            - If unsure, prefer answer_text (read-only) over edit_text.

            If the user asks a follow-up question after seeing your answer, continue the conversation naturally.
            """,
            languageConsistencyRule(for: "user's request")
        ]

        if let persona = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !persona.isEmpty {
            parts.append("""
            Persona/style guidance:
            \(persona)
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Agent 用户提示词
    static func askAgentUserPrompt(selectedText: String?, instruction: String) -> String {
        var parts: [String] = []

        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            parts.append("Selected text:\n---\n\(selected)\n---")
        }

        parts.append("User request: \(instruction)")

        return parts.joined(separator: "\n\n")
    }
}
```

---

## 九、OpenAICompatibleAgentService 多轮扩展

### 9.1 MultiTurn 扩展

**文件**: `LLM/Agent/LLMMultiTurnService+OpenAI.swift`

```swift
extension OpenAICompatibleAgentService: LLMMultiTurnService {
    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn {
        let provider = settingsStore.llmRemoteProvider
        let baseURL = URL(string: settingsStore.llmBaseURL)!
        let model = settingsStore.llmModel.isEmpty ? provider.defaultModel : settingsStore.llmModel

        switch provider.apiStyle {
        case .openAICompatible:
            return try await multiTurnOpenAI(
                baseURL: baseURL,
                model: model,
                apiKey: settingsStore.llmAPIKey,
                messages: messages,
                tools: tools,
                config: config
            )
        case .anthropic:
            return try await multiTurnAnthropic(
                baseURL: baseURL,
                model: model,
                apiKey: settingsStore.llmAPIKey,
                messages: messages,
                tools: tools,
                config: config
            )
        case .gemini:
            return try await multiTurnGemini(
                baseURL: baseURL,
                model: model,
                apiKey: settingsStore.llmAPIKey,
                messages: messages,
                tools: tools,
                config: config
            )
        }
    }

    private func multiTurnOpenAI(
        baseURL: URL,
        model: String,
        apiKey: String,
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = buildOpenAIBody(
            model: model,
            messages: messages,
            tools: tools,
            config: config
        )
        OpenAICompatibleResponseSupport.applyProviderTuning(body: &body, baseURL: baseURL, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await RemoteLLMClient.performJSONRequest(request)
        return parseOpenAIResponse(data)
    }

    private func buildOpenAIBody(
        model: String,
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": AgentMessage.toOpenAIMessages(messages),
            "parallel_tool_calls": config.parallelToolCalls,
            "tools": tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.jsonObject
                    ]
                ]
            }
        ]

        if let forcedTool = config.forcedToolName {
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": forcedTool]
            ]
        }

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        return body
    }

    private func parseOpenAIResponse(_ data: Data) -> AgentTurn {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            return .text("")
        }

        let text = message["content"] as? String ?? ""
        let toolCallsRaw = message["tool_calls"] as? [[String: Any]] ?? []

        if text.isEmpty && toolCallsRaw.isEmpty {
            return .text("")
        }

        if toolCallsRaw.isEmpty {
            return .text(text)
        }

        let toolCalls = toolCallsRaw.compactMap { raw -> AgentToolCall? in
            guard let fn = raw["function"] as? [String: Any],
                  let name = fn["name"] as? String,
                  let args = fn["arguments"] as? String else {
                return nil
            }
            let id = raw["id"] as? String ?? UUID().uuidString
            return AgentToolCall(id: id, name: name, argumentsJSON: args)
        }

        if text.isEmpty {
            return .toolCalls(toolCalls)
        }
        return .textWithToolCalls(text: text, toolCalls: toolCalls)
    }
}
```

---

## 十、错误处理

### 10.1 新增错误类型

**文件**: `LLM/Agent/AgentError.swift`

```swift
enum AgentError: LocalizedError, Equatable, Sendable {
    case maxStepsExceeded
    case toolNotFound(name: String)
    case toolExecutionFailed(name: String, reason: String)
    case mcpConnectionFailed(serverName: String, reason: String)
    case mcpServerNotFound(id: UUID)
    case invalidAgentState(reason: String)
    case llmConnectionFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .maxStepsExceeded:
            return "Agent reached maximum execution steps without terminating."
        case .toolNotFound(let name):
            return "Tool '\(name)' not found in registry."
        case .toolExecutionFailed(let name, let reason):
            return "Tool '\(name)' execution failed: \(reason)"
        case .mcpConnectionFailed(let serverName, let reason):
            return "MCP server '\(serverName)' connection failed: \(reason)"
        case .mcpServerNotFound(let id):
            return "MCP server with ID \(id) not found."
        case .invalidAgentState(let reason):
            return "Invalid agent state: \(reason)"
        case .llmConnectionFailed(let reason):
            return "LLM connection failed: \(reason)"
        }
    }
}
```

---

## 十一、单元测试

### 11.1 测试文件列表

每个新组件需要对应的测试文件：

| 测试文件 | 覆盖内容 |
|---------|---------|
| `AgentMessageTests.swift` | 消息序列化、反序列化、provider 格式转换 |
| `AgentToolRegistryTests.swift` | 工具注册、查找、执行、终止工具判断 |
| `AgentLoopTests.swift` | 循环执行、终止条件、最大步数限制 |
| `AgentConfigTests.swift` | 配置默认值、参数验证 |
| `BuiltinAgentToolsTests.swift` | AnswerTextTool、EditTextTool、GetClipboardTool |
| `MCPMessageTests.swift` | JSON-RPC 消息序列化/反序列化 |
| `StdioMCPClientTests.swift` | Stdio 客户端连接、工具调用（mock 进程） |
| `HTTPMCPClientTests.swift` | HTTP 客户端请求/响应 |
| `MCPToolAdapterTests.swift` | MCP → AgentTool 适配 |
| `LLMMultiTurnServiceTests.swift` | 多轮消息转换、provider 格式生成 |
| `AgentStepMonitorTests.swift` | 步骤监控回调、状态累积 |

### 11.2 测试示例

#### AgentToolRegistryTests

```swift
func testRegistryExecuteAndTerminationToolDetection() async throws {
    let registry = AgentToolRegistry()
    registry.register(AnswerTextTool())
    registry.register(EditTextTool())
    registry.register(GetClipboardTool(clipboardService: MockClipboard()))

    XCTAssertTrue(registry.isTerminationTool("answer_text"))
    XCTAssertTrue(registry.isTerminationTool("edit_text"))
    XCTAssertFalse(registry.isTerminationTool("get_clipboard"))
    XCTAssertFalse(registry.hasTool("nonexistent_tool"))

    let definitions = registry.definitions
    XCTAssertEqual(definitions.count, 3)
    XCTAssertEqual(definitions.map(\.name).sorted(), ["answer_text", "edit_text", "get_clipboard"])
}
```

#### AgentLoopTests

```swift
func testAgentTerminatesOnAnswerTextTool() async throws {
    let mockLLM = MockLLMMultiTurnService()
    mockLLM.turns = [
        .toolCalls([AgentToolCall(id: "1", name: "answer_text", argumentsJSON: #"{"answer":"42"}"#)])
    ]

    let registry = AgentToolRegistry()
    registry.register(AnswerTextTool())

    let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
    let result = try await loop.run(messages: [.system("..."), .user("...")])

    XCTAssertEqual(result.steps.count, 1)
    guard case .terminationTool("answer_text", _) = result.outcome else {
        XCTFail("Expected terminationTool")
        return
    }
}

func testAgentMaxStepsLimit() async throws {
    let mockLLM = MockLLMMultiTurnService()
    // 返回工具调用但不返回终止工具
    mockLLM.turns = Array(repeating: .toolCalls([AgentToolCall(id: "1", name: "get_clipboard", argumentsJSON: "{}")]), count: 15)

    let registry = AgentToolRegistry()
    registry.register(GetClipboardTool(clipboardService: MockClipboard()))

    let config = AgentConfig(maxSteps: 5, allowParallelToolCalls: false, temperature: nil, enableStreaming: false)
    let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: config)
    let result = try await loop.run(messages: [.system("..."), .user("...")])

    XCTAssertEqual(result.steps.count, 5)
    guard case .maxStepsReached = result.outcome else {
        XCTFail("Expected maxStepsReached")
        return
    }
}
```

#### MCPMessageTests

```swift
func testJsonRPCMessageInitialization() throws {
    let message = MCPJsonRPCMessage(
        jsonrpc: "2.0",
        id: .string("1"),
        method: "initialize",
        params: .initialize(.init(
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: nil)),
            clientInfo: .init(name: "Test", version: "1.0")
        )),
        result: nil,
        error: nil
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data)

    XCTAssertEqual(decoded.jsonrpc, "2.0")
    XCTAssertEqual(decoded.method, "initialize")
}
```

---

## 十二、依赖注入集成

### 12.1 DIContainer 扩展

**文件**: `App/DIContainer+Agent.swift`

```swift
extension DIContainer {
    /// 多轮 LLM 服务（用于 Agent）
    var llmMultiTurnService: LLMMultiTurnService {
        LLMMultiTurnRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleAgentService(settingsStore: settingsStore)
        )
    }

    /// MCP 注册表
    var mcpRegistry: MCPRegistry {
        MCPRegistry(settingsStore: MCPSettingsStore())
    }
}

/// 多轮 LLM 路由
final class LLMMultiTurnRouter: LLMMultiTurnService {
    private let settingsStore: SettingsStore
    private let openAICompatible: LLMMultiTurnService

    init(settingsStore: SettingsStore, openAICompatible: LLMMultiTurnService) {
        self.settingsStore = settingsStore
        self.openAICompatible = openAICompatible
    }

    func complete(messages: [AgentMessage], tools: [LLMAgentTool], config: LLMCallConfig) async throws -> AgentTurn {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            return try await openAICompatible.complete(messages: messages, tools: tools, config: config)
        case .ollama:
            // Ollama 暂不支持多轮工具调用
            throw AgentError.llmConnectionFailed(reason: "Ollama does not support multi-turn tool calls")
        }
    }
}
```

---

## 十三、实施顺序

### Phase 1: 核心数据结构（预计 2-3 天）

1. `AgentMessage.swift` — 消息结构
2. `AgentTool.swift` + `AgentToolRegistry.swift` — 工具协议和注册表
3. `AgentConfig.swift` — 配置
4. `AgentResult.swift` — 结果类型
5. `AgentToolCallMonitor.swift` — 步骤监控

### Phase 2: 内置工具（预计 1 天）

6. `BuiltinAgentTools.swift` — AnswerTextTool、EditTextTool、GetClipboardTool
7. 单元测试

### Phase 3: LLM 多轮服务（预计 2-3 天）

8. `LLMMultiTurnService.swift` — 协议定义
9. `OpenAICompatibleAgentService+MultiTurn.swift` — OpenAI 兼容实现
10. `AgentPromptCatalog.swift` — 提示词
11. 单元测试

### Phase 4: 核心引擎（预计 2 天）

12. `AgentLoop.swift` — 执行引擎
13. `AgentError.swift` — 错误类型
14. 单元测试

### Phase 5: MCP 支持（预计 3-4 天）

15. `MCPMessage.swift` — 消息结构
16. `MCPClient.swift` — 客户端协议
17. `StdioMCPClient.swift` — Stdio 实现
18. `HTTPMCPClient.swift` — HTTP 实现
19. `MCPToolAdapter.swift` — 适配器
20. `MCPRegistry.swift` — 服务器管理
21. `MCPSettings.swift` — 配置存储
22. 单元测试

### Phase 6: Workflow 集成（预计 1-2 天）

23. `WorkflowController+Agent.swift` — 集成
24. `DIContainer+Agent.swift` — 依赖注入
25. 集成测试

### Phase 7: 最终测试与修复（预计 2 天）

26. 端到端测试
27. Bug 修复
28. 文档完善

---

## 十四、向后兼容性

- 现有 `LLMAgentService.runTool()` 保持不变，现有功能（词汇监控等）继续工作
- 现有 `decideAskSelection` 双步流程作为 fallback
- 新 Agent 框架通过 feature flag 控制，默认关闭

```swift
// SettingsStore 扩展
var agentFrameworkEnabled: Bool {
    get { defaults.object(forKey: "agent.framework.enabled") as? Bool ?? false }
    set { defaults.set(newValue, forKey: "agent.framework.enabled") }
}
```

---

## 十五、关键设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 并发模型 | Swift `actor` | AgentLoop、ToolRegistry、MCPClient 都是 actor，保证线程安全 |
| 工具执行 | 顺序执行（默认） | 并行执行增加复杂度，默认关闭 |
| MCP 消息格式 | 完整 JSON-RPC 2.0 | 兼容标准 MCP 实现 |
| 工具参数 | JSON 字符串 | 统一格式，便于跨 provider |
| 流式输出 | 回调机制 | 不改变现有接口，UI 可选择性使用 |
| 向后兼容 | Feature flag | 现有功能不受影响 |

---

## 十六、已知限制

1. **Ollama 暂不支持多轮工具调用**：Ollama 不支持 tool_choice 强制指定，Phase 3 会添加有限支持
2. **并行工具调用暂不支持**：首批实现为顺序执行
3. **流式文本输出**：首批实现不包含，保留回调接口
4. **MCP 工具缓存**：工具列表在连接时获取一次，不自动刷新（可通过手动重连刷新）

---

## 十七、文档更新

实现完成后，需更新以下文档：
- `ARCHITECTURE.md` — 新增 Agent 框架章节
- `CLAUDE.md` — 新增 Agent 相关提示
- README 相关章节（如果涉及用户-facing 功能变更）
