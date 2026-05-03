# Agent Framework Refactoring Development Document

## Goal

Refactor the "Ask Anything" feature from the current fixed two-step flow (intent classification → execution) into a fully functional Agent framework with support for:
- **Iterative execution**: The agent can perform multi-step reasoning, limited to a maximum number of steps (default: 10)
- **Tool calling**: Built-in tools (termination tools, intermediate tools) + external MCP tools
- **MCP support**: Model Context Protocol, with Stdio (local process) and HTTP/SSE (remote server) transport modes
- **Intermediate state visibility**: Step-level tool call records are preserved for subsequent UI display

---

## 1. Architecture Overview

### 1.1 Current Architecture vs Target Architecture

**Current (two-step flow)**:
```
User input → STT → [LLM Call 1: forced answer_or_edit_selection tool] → [LLM Call 2: answer or rewrite]
```

**Target (Agent loop)**:
```
User input → STT → AgentLoop {
    for step in 0..<maxSteps:
        LLM reasoning → select tool → execute tool → feed result back to LLM
    Termination conditions: call termination tool / plain text response / max steps reached
}
```

### 1.2 Directory Structure

```
Sources/Typeflux/
├── LLM/
│   ├── Agent/
│   │   ├── AgentMessage.swift          # Multi-turn conversation message structure
│   │   ├── AgentTool.swift             # Tool protocol + registry
│   │   ├── AgentConfig.swift           # Configuration (max steps, etc.)
│   │   ├── AgentResult.swift           # Execution result
│   │   ├── AgentLoop.swift             # Core execution engine
│   │   ├── AgentToolRegistry.swift     # Tool registry actor
│   │   ├── AgentToolCallMonitor.swift  # Step monitoring (preserves intermediate state)
│   │   └── BuiltinAgentTools.swift     # Built-in tool implementations
│   ├── MCP/
│   │   ├── MCPClient.swift             # MCP client protocol
│   │   ├── MCPMessage.swift            # MCP JSON-RPC message structure
│   │   ├── StdioMCPClient.swift        # Stdio transport implementation
│   │   ├── HTTPMCPClient.swift         # HTTP/SSE transport implementation
│   │   ├── MCPRegistry.swift           # MCP server management
│   │   └── MCPToolAdapter.swift        # MCP → AgentTool adapter
│   ├── LLMMultiTurnService.swift       # Multi-turn LLM protocol
│   ├── OpenAICompatibleAgentService+MultiTurn.swift  # Multi-turn extension
│   └── AgentPromptCatalog.swift        # Agent-specific prompts
├── Settings/
│   └── MCPSettings.swift               # MCP configuration storage
└── Workflow/
    └── WorkflowController+Agent.swift   # Agent integration (extension, not modification)
```

---

## 2. Core Data Structures

### 2.1 AgentMessage — Multi-turn Conversation Messages

**File**: `LLM/Agent/AgentMessage.swift`

```swift
/// Message role
enum AgentMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool  // Tool return result
}

/// A single tool call
struct AgentToolCall: Equatable, Codable, Sendable {
    let id: String          // Unique ID used to correlate calls with results
    let name: String
    let argumentsJSON: String
}

/// Tool execution result
struct AgentToolResult: Equatable, Codable, Sendable {
    let toolCallId: String
    let content: String     // Content returned by the tool (text or JSON string)
    let isError: Bool
}

/// Assistant message (text + tool calls)
struct AgentAssistantMessage: Equatable, Codable, Sendable {
    let text: String?
    let toolCalls: [AgentToolCall]
}

/// Union type for a single message
enum AgentMessage: Equatable, Sendable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantMessage)
    case toolResult(AgentToolResult)

    /// Serialize to provider-specific dictionary format
    func toProviderFormat(role: AgentMessageRole, apiStyle: LLMRemoteAPIStyle) -> [String: Any]
}
```

### 2.2 AgentTool — Tool Protocol

**File**: `LLM/Agent/AgentTool.swift`

```swift
/// Agent tool protocol
protocol AgentTool: Sendable {
    /// Tool definition (name, description, input schema)
    var definition: LLMAgentTool { get }
    /// Execute the tool
    /// - Parameter arguments: JSON string of arguments
    /// - Returns: Execution result (text or JSON string)
    func execute(arguments: String) async throws -> String
}

/// Termination tool marker protocol
protocol TerminationTool: AgentTool {}

/// Built-in tool identifiers
enum BuiltinAgentToolName: String, CaseIterable {
    case answerText = "answer_text"
    case editText = "edit_text"
    case getClipboard = "get_clipboard"
}
```

### 2.3 AgentToolRegistry — Tool Registry

**File**: `LLM/Agent/AgentToolRegistry.swift`

```swift
actor AgentToolRegistry {
    private var tools: [String: any AgentTool] = [:]
    private var terminationToolNames: Set<String> = []

    func register(_ tool: any AgentTool)
    func registerAll(_ tools: [any AgentTool])
    func unregister(name: String)

    /// Execute a tool
    func execute(name: String, arguments: String, toolCallId: String) async throws -> AgentToolResult

    /// Get all tool definitions (used for LLM calls)
    var definitions: [LLMAgentTool] { get }

    /// Check if a tool is a termination tool
    func isTerminationTool(name: String) -> Bool

    /// Check if a tool exists
    func hasTool(name: String) -> Bool
}
```

### 2.4 AgentConfig — Configuration

**File**: `LLM/Agent/AgentConfig.swift`

```swift
struct AgentConfig: Sendable {
    /// Maximum number of execution steps (default 10)
    let maxSteps: Int
    /// Whether to allow the LLM to call multiple tools in parallel (default false)
    let allowParallelToolCalls: Bool
    /// Temperature parameter
    let temperature: Double?
    /// Whether to enable streaming output callbacks
    let enableStreaming: Bool

    static let `default` = AgentConfig(
        maxSteps: 10,
        allowParallelToolCalls: false,
        temperature: nil,
        enableStreaming: false
    )
}
```

### 2.5 AgentStep — Execution Step (Intermediate State)

**File**: `LLM/Agent/AgentToolCallMonitor.swift`

```swift
/// Record of a single execution step
struct AgentStep: Sendable {
    let stepIndex: Int
    let assistantMessage: AgentAssistantMessage
    let toolResults: [AgentToolResult]
    let durationMs: Int64
}

/// Step monitor protocol
protocol AgentStepMonitor: AnyObject, Sendable {
    /// Called after each step completes
    func agentDidCompleteStep(_ step: AgentStep) async
    /// Called when the agent finishes
    func agentDidFinish(outcome: AgentOutcome) async
}

/// Real-time state for UI display
struct AgentRealtimeState: Sendable {
    let currentStep: Int
    let lastToolCall: AgentToolCall?
    let accumulatedText: String
    let toolCallsSoFar: [AgentToolCall]
}
```

### 2.6 AgentResult — Execution Result

**File**: `LLM/Agent/AgentResult.swift`

```swift
/// Agent execution result
struct AgentResult: Sendable {
    /// Termination reason
    enum Outcome: Sendable {
        /// The model returned plain text directly (no tool calls)
        case text(String)
        /// A termination tool was called
        case terminationTool(name: String, argumentsJSON: String)
        /// Maximum steps reached
        case maxStepsReached
        /// Execution error
        case error(Error)
    }

    let outcome: Outcome
    let steps: [AgentStep]
    let totalDurationMs: Int64

    /// Extract the final answer text (for the answer_text tool)
    var answerText: String? {
        if case .text(let text) = outcome { return text }
        if case .terminationTool("answer_text", let args) = outcome {
            return extractAnswer(from: args)
        }
        return nil
    }

    /// Extract the replacement text (for the edit_text tool)
    var editedText: String? {
        if case .terminationTool("edit_text", let args) = outcome {
            return extractReplacement(from: args)
        }
        return nil
    }
}
```

---

## 3. Multi-turn LLM Service Protocol

### 3.1 LLMMultiTurnService

**File**: `LLM/LLMMultiTurnService.swift`

The existing `LLMAgentService.runTool()` only supports single-turn calls with forced tool invocation. This adds multi-turn support:

```swift
/// Single-turn LLM output
enum AgentTurn: Sendable {
    /// Plain text response
    case text(String)
    /// Tool calls
    case toolCalls([AgentToolCall])
    /// Text + tool calls
    case textWithToolCalls(text: String, toolCalls: [AgentToolCall])
}

/// Multi-turn LLM service protocol
protocol LLMMultiTurnService: Sendable {
    /// Execute a multi-turn conversation
    /// - Parameters:
    ///   - messages: Message history (including system, user, assistant, toolResult)
    ///   - tools: List of available tool definitions
    ///   - config: Call configuration
    /// - Returns: LLM output for the current turn
    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn
}

/// Call configuration
struct LLMCallConfig: Sendable {
    /// Force a specific tool to be used (nil means the model chooses freely)
    let forcedToolName: String?
    /// Allow parallel tool calls
    let parallelToolCalls: Bool
    /// Temperature parameter
    let temperature: Double?
}
```

### 3.2 Provider-specific Message Serialization

**File**: `LLM/Agent/AgentMessage+ProviderFormat.swift`

Each API format (OpenAI/Anthropic/Gemini) has a different message structure and requires separate serialization:

```swift
extension AgentMessage {
    /// Convert to OpenAI-compatible message format
    static func toOpenAIMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // system → {"role": "system", "content": "..."}
        // user → {"role": "user", "content": "..."}
        // assistant (no tool) → {"role": "assistant", "content": "..."}
        // assistant (tool_calls) → {"role": "assistant", "tool_calls": [...], "content": null}
        // tool_result → {"role": "tool", "tool_call_id": "...", "content": "..."}
    }

    /// Convert to Anthropic message format
    static func toAnthropicMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // system merged into the system field
        // user → {"role": "user", "content": [{"type": "text", "text": "..."}]}
        // assistant (tool) → {"role": "assistant", "content": [{"type": "tool_use", ...}]}
        // tool_result → {"role": "user", "content": [{"type": "tool_result", ...}]}
    }

    /// Convert to Gemini content format
    static func toGeminiContents(_ messages: [AgentMessage]) -> [[String: Any]] {
        // user → {"role": "user", "parts": [{"text": "..."}]}
        // model → {"role": "model", "parts": [{"text": "..."}]}
        // tool → {"role": "user", "parts": [{"functionCall": ...}, {"functionResponse": ...}]}
    }
}
```

---

## 4. Core Engine: AgentLoop

### 4.1 AgentLoop Actor

**File**: `LLM/Agent/AgentLoop.swift`

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

    /// Set the step monitor
    func setStepMonitor(_ monitor: (any AgentStepMonitor)?)

    /// Run the agent
    /// - Parameters:
    ///   - messages: Initial messages (typically system + user)
    ///   - streamHandler: Streaming text output callback (optional)
    /// - Returns: Agent execution result
    func run(
        messages: [AgentMessage],
        streamHandler: ((String) -> Void)? = nil
    ) async throws -> AgentResult
}
```

### 4.2 Execution Flow Detail

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
        forcedToolName: nil,           // Free choice
        parallelToolCalls: config.allowParallelToolCalls,
        temperature: config.temperature
      )
    )

    switch turn:
      case .text(let text):
        // Plain text response → terminate
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
            // Termination tool → return immediately
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
        // Process toolCalls in the same way...
```

### 4.3 Parallel Tool Execution

When `config.allowParallelToolCalls = true` and the model returns multiple tool calls:

```swift
// Execute all tools in parallel
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

## 5. Built-in Tool Implementations

### 5.1 Termination Tools

#### AnswerTextTool

**File**: `LLM/Agent/BuiltinAgentTools.swift`

```swift
/// Termination tool that presents an answer to the user
struct AnswerTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: "answer_text",
        description: "Use when the user wants to get an answer about selected text. Presents the final answer to the user in a popup window.",
        inputSchema: LLMJSONSchema(
            name: "answer_text",
            schema: [
                "type": .string("object"),
                "required": .array([.string("answer")]),
                "properties": .object([
                    "answer": .object([
                        "type": .string("string"),
                        "description": .string("The final answer to present to the user")
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
        // Validate argument validity
        struct Args: Codable { let answer: String; let format: String? }
        let args = try JSONDecoder().decode(Args.self, from: arguments.data(using: .utf8)!)
        return arguments  // Return the original JSON directly; AgentResult will parse it
    }
}
```

#### EditTextTool

```swift
/// Termination tool that replaces the selected text
struct EditTextTool: AgentTool, TerminationTool {
    let definition = LLMAgentTool(
        name: "edit_text",
        description: "Use when the user wants to rewrite, translate, paraphrase, or otherwise modify the selected text. Replaces the user's previously selected text with new content.",
        inputSchema: LLMJSONSchema(
            name: "edit_text",
            schema: [
                "type": .string("object"),
                "required": .array([.string("replacement")]),
                "properties": .object([
                    "replacement": .object([
                        "type": .string("string"),
                        "description": .string("The new content to replace the selected text with")
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

### 5.2 Intermediate Tools

#### GetClipboardTool

```swift
/// Reads the contents of the clipboard
struct GetClipboardTool: AgentTool {
    let definition = LLMAgentTool(
        name: "get_clipboard",
        description: "Reads the current system clipboard contents. Use when the user mentions 'the content in the clipboard' or needs to reference previously copied content.",
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
            return #"{"error": "Clipboard is empty or contains no text content"}"#
        }
        // Return in JSON format
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

## 6. MCP Support

### 6.1 MCP Protocol Overview

MCP (Model Context Protocol) is a standard protocol for communication between LLMs and external tool services. The protocol is based on JSON-RPC 2.0.

**Transport modes**:
- **Stdio**: Communicates with a local process via standard input/output (suitable for locally running tool servers)
- **HTTP/SSE**: Sends requests via HTTP POST and receives responses via SSE (suitable for remote tool servers)

### 6.2 MCP Message Structure

**File**: `LLM/MCP/MCPMessage.swift`

```swift
/// MCP JSON-RPC message
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

/// Initialization parameters
struct MCPInitializeParams: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let clientInfo: MCPClientInfo
}

/// Server capabilities
struct MCPServerCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?
}

/// Tools capability
struct MCPToolsCapability: Codable, Sendable {
    let listChanged: Bool?
}

/// Tool definition
struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let inputSchema: MCPObjectSchema
}

/// Tool call parameters
struct MCPToolsCallParams: Codable, Sendable {
    let name: String
    let arguments: [String: AnyCodable]?
}

/// Tool call result
struct MCPToolsCallResult: Codable, Sendable {
    let content: [MCPContentBlock]
    let isError: Bool?
}

struct MCPContentBlock: Codable, Sendable {
    let type: String  // "text"
    let text: String?
}
```

### 6.3 MCPClient Protocol

**File**: `LLM/MCP/MCPClient.swift`

```swift
/// MCP client protocol
protocol MCPClient: Actor {
    var serverInfo: MCPConnectionInfo { get }
    var isConnected: Bool { get }

    /// Connect to an MCP server
    func connect() async throws

    /// Disconnect
    func disconnect() async

    /// Get the list of available tools
    func listTools() async throws -> [MCPToolDefinition]

    /// Call a tool
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult

    /// Test the connection
    func ping() async throws
}

/// Connection information
struct MCPConnectionInfo: Sendable {
    let name: String
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
}
```

### 6.4 Stdio MCP Client

**File**: `LLM/MCP/StdioMCPClient.swift`

Communicates with a process via its standard input/output:

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
        // 1. Start the process
        process = Process()
        process?.executableURL = URL(fileURLWithPath: config.command)
        process?.arguments = config.args
        if !config.env.isEmpty {
            process?.environment = config.env
        }

        // 2. Set up pipes
        inputPipe = Pipe()
        outputPipe = Pipe()
        process?.standardInput = inputPipe
        process?.standardOutput = outputPipe

        // 3. Start the read loop
        try process?.run()
        startReadingLoop()

        // 4. Send initialization
        let initResult = try await sendRequest(method: "initialize", params: .initialize(.init(
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: nil)),
            clientInfo: .init(name: "Typeflux", version: "1.0.0")
        )))

        guard case .initialize(let info) = initResult.result else {
            throw MCPError.invalidConnection
        }
        connectionInfo = info

        // 5. Send the initialized notification
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

### 6.5 HTTP/SSE MCP Client

**File**: `LLM/MCP/HTTPMCPClient.swift`

Sends requests via HTTP POST and receives responses via SSE:

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
        // Send the initialization request
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

### 6.6 MCP → AgentTool Adapter

**File**: `LLM/MCP/MCPToolAdapter.swift`

Wraps an MCP tool as an `AgentTool`:

```swift
/// Adapter from MCP tool to AgentTool
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
        // Convert MCP JSON Schema format to LLMJSONSchema
        ...
    }
}
```

### 6.7 MCPRegistry — MCP Server Management

**File**: `LLM/MCP/MCPRegistry.swift`

```swift
actor MCPRegistry {
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    private var cachedTools: [String: (any AgentTool, UUID)] = [:]  // toolName → (adapter, serverId)

    /// Register an MCP server
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

        // Refresh the tool cache
        try await refreshTools(for: config.id)
    }

    /// Remove an MCP server
    func removeServer(id: UUID) async {
        await servers[id]?.disconnect()
        servers.removeValue(forKey: id)
        serverConfigs.removeValue(forKey: id)
        cachedTools = cachedTools.filter { $0.value.1 != id }
    }

    /// Get all MCP tools
    func allMCPtools() async -> [any AgentTool] {
        await refreshCachedToolsIfNeeded()
        return cachedTools.map { $0.value.0 }
    }

    /// Look up which server owns a given tool
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

## 7. MCP Configuration Storage

### 7.1 Configuration Model

**File**: `Settings/MCPSettings.swift`

```swift
/// MCP server configuration
struct MCPServerConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var transport: MCPTransportConfig
    var enabled: Bool
    var autoConnect: Bool
}

/// Transport configuration
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

/// MCP settings store
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

## 8. WorkflowController Integration

### 8.1 Extension, Not Modification

The existing `WorkflowController` remains unchanged. A new extension file is added:

**File**: `Workflow/WorkflowController+Agent.swift`

```swift
extension WorkflowController {
    /// Handle "Ask Anything" using the new Agent framework
    func runAskAgent(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        sessionID: UUID
    ) async throws -> AskAgentResult {
        // 1. Build the tool registry
        let registry = await buildAgentToolRegistry(
            selectedText: selectedText,
            clipboard: clipboard
        )

        // 2. Create the AgentLoop
        let agentLoop = AgentLoop(
            llmService: multiTurnLLMService,
            toolRegistry: registry,
            config: .default
        )

        // 3. Set up step monitoring (optional, for subsequent UI display)
        if settingsStore.agentStepLoggingEnabled {
            agentLoop.setStepMonitor(AgentStepLogger())
        }

        // 4. Build initial messages
        let systemPrompt = PromptCatalog.askAgentSystemPrompt(personaPrompt: personaPrompt)
        let userPrompt = PromptCatalog.askAgentUserPrompt(
            selectedText: selectedText,
            instruction: spokenInstruction
        )
        let messages: [AgentMessage] = [
            .system(systemPrompt),
            .user(userPrompt)
        ]

        // 5. Run the agent
        let result = try await agentLoop.run(messages: messages)

        // 6. Process the result
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

        // Register built-in termination tools
        registry.register(AnswerTextTool())
        registry.register(EditTextTool())

        // Register intermediate tools
        registry.register(GetClipboardTool(clipboardService: clipboard))

        // Register MCP tools (if configured)
        Task {
            let mcpTools = await mcpRegistry.allMCPtools()
            for tool in mcpTools {
                registry.register(tool)
            }
        }

        return registry
    }
}

/// Agent execution result
enum AskAgentResult: Sendable {
    case answer(String)   // Display an answer
    case edit(String)     // Replace text
}
```

### 8.2 Prompt Templates

**File**: `LLM/Agent/AgentPromptCatalog.swift`

```swift
enum AgentPromptCatalog {
    /// Agent system prompt
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

    /// Agent user prompt
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

## 9. OpenAICompatibleAgentService Multi-turn Extension

### 9.1 MultiTurn Extension

**File**: `LLM/Agent/LLMMultiTurnService+OpenAI.swift`

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

## 10. Error Handling

### 10.1 New Error Types

**File**: `LLM/Agent/AgentError.swift`

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

## 11. Unit Tests

### 11.1 Test File List

Each new component requires a corresponding test file:

| Test File | Coverage |
|-----------|----------|
| `AgentMessageTests.swift` | Message serialization, deserialization, provider format conversion |
| `AgentToolRegistryTests.swift` | Tool registration, lookup, execution, termination tool detection |
| `AgentLoopTests.swift` | Loop execution, termination conditions, max step limit |
| `AgentConfigTests.swift` | Default configuration values, parameter validation |
| `BuiltinAgentToolsTests.swift` | AnswerTextTool, EditTextTool, GetClipboardTool |
| `MCPMessageTests.swift` | JSON-RPC message serialization/deserialization |
| `StdioMCPClientTests.swift` | Stdio client connection, tool calling (mock process) |
| `HTTPMCPClientTests.swift` | HTTP client request/response |
| `MCPToolAdapterTests.swift` | MCP → AgentTool adaptation |
| `LLMMultiTurnServiceTests.swift` | Multi-turn message conversion, provider format generation |
| `AgentStepMonitorTests.swift` | Step monitor callbacks, state accumulation |

### 11.2 Test Examples

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
    // Return tool calls but never return a termination tool
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

## 12. Dependency Injection Integration

### 12.1 DIContainer Extension

**File**: `App/DIContainer+Agent.swift`

```swift
extension DIContainer {
    /// Multi-turn LLM service (used by the Agent)
    var llmMultiTurnService: LLMMultiTurnService {
        LLMMultiTurnRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleAgentService(settingsStore: settingsStore)
        )
    }

    /// MCP registry
    var mcpRegistry: MCPRegistry {
        MCPRegistry(settingsStore: MCPSettingsStore())
    }
}

/// Multi-turn LLM router
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
            // Ollama does not yet support multi-turn tool calls
            throw AgentError.llmConnectionFailed(reason: "Ollama does not support multi-turn tool calls")
        }
    }
}
```

---

## 13. Implementation Order

### Phase 1: Core Data Structures (estimated 2–3 days)

1. `AgentMessage.swift` — Message structure
2. `AgentTool.swift` + `AgentToolRegistry.swift` — Tool protocol and registry
3. `AgentConfig.swift` — Configuration
4. `AgentResult.swift` — Result type
5. `AgentToolCallMonitor.swift` — Step monitoring

### Phase 2: Built-in Tools (estimated 1 day)

6. `BuiltinAgentTools.swift` — AnswerTextTool, EditTextTool, GetClipboardTool
7. Unit tests

### Phase 3: Multi-turn LLM Service (estimated 2–3 days)

8. `LLMMultiTurnService.swift` — Protocol definition
9. `OpenAICompatibleAgentService+MultiTurn.swift` — OpenAI-compatible implementation
10. `AgentPromptCatalog.swift` — Prompts
11. Unit tests

### Phase 4: Core Engine (estimated 2 days)

12. `AgentLoop.swift` — Execution engine
13. `AgentError.swift` — Error types
14. Unit tests

### Phase 5: MCP Support (estimated 3–4 days)

15. `MCPMessage.swift` — Message structure
16. `MCPClient.swift` — Client protocol
17. `StdioMCPClient.swift` — Stdio implementation
18. `HTTPMCPClient.swift` — HTTP implementation
19. `MCPToolAdapter.swift` — Adapter
20. `MCPRegistry.swift` — Server management
21. `MCPSettings.swift` — Configuration storage
22. Unit tests

### Phase 6: Workflow Integration (estimated 1–2 days)

23. `WorkflowController+Agent.swift` — Integration
24. `DIContainer+Agent.swift` — Dependency injection
25. Integration tests

### Phase 7: Final Testing and Bug Fixes (estimated 2 days)

26. End-to-end tests
27. Bug fixes
28. Documentation updates

---

## 14. Backward Compatibility

- The existing `LLMAgentService.runTool()` remains unchanged; existing features (vocabulary monitoring, etc.) continue to work
- The existing `decideAskSelection` two-step flow is kept as a fallback
- The new Agent framework is controlled by a feature flag, disabled by default

```swift
// SettingsStore extension
var agentFrameworkEnabled: Bool {
    get { defaults.object(forKey: "agent.framework.enabled") as? Bool ?? false }
    set { defaults.set(newValue, forKey: "agent.framework.enabled") }
}
```

---

## 15. Key Design Decisions

| Decision Point | Choice | Rationale |
|----------------|--------|-----------|
| Concurrency model | Swift `actor` | AgentLoop, ToolRegistry, and MCPClient are all actors, ensuring thread safety |
| Tool execution | Sequential (default) | Parallel execution adds complexity; disabled by default |
| MCP message format | Full JSON-RPC 2.0 | Compatible with standard MCP implementations |
| Tool arguments | JSON string | Unified format, easy to use across providers |
| Streaming output | Callback mechanism | Does not change existing interfaces; UI can use it optionally |
| Backward compatibility | Feature flag | Existing functionality remains unaffected |

---

## 16. Known Limitations

1. **Ollama does not yet support multi-turn tool calls**: Ollama does not support `tool_choice` forced selection; Phase 3 will add limited support
2. **Parallel tool calls not yet supported**: The initial implementation uses sequential execution only
3. **Streaming text output**: Not included in the initial implementation; the callback interface is preserved for future use
4. **MCP tool caching**: The tool list is fetched once at connection time and is not automatically refreshed (can be refreshed by manually reconnecting)

---

## 17. Documentation Updates

After implementation is complete, the following documents need to be updated:
- `ARCHITECTURE.md` — Add a new Agent framework section
- `CLAUDE.md` — Add Agent-related guidance
- README sections (if user-facing functionality changes)
