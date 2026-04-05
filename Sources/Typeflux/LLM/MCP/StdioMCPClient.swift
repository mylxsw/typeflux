import Foundation

struct MCPStdioConfig {
    let command: String
    let args: [String]
    let env: [String: String]

    init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

/// Stdio 传输 MCP 客户端
actor StdioMCPClient: MCPClient {
    private let config: MCPStdioConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var pendingRequests: [String: CheckedContinuation<MCPJsonRPCMessage, Error>] = [:]
    private var messageIdCounter: Int = 0
    private var connectionInfo: MCPConnectionInfo?
    private var readingTask: Task<Void, Never>?

    var serverInfo: MCPConnectionInfo? {
        connectionInfo
    }

    var isConnected: Bool {
        process?.isRunning == true
    }

    init(config: MCPStdioConfig) {
        self.config = config
    }

    func connect() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.command)
        proc.arguments = config.args
        if !config.env.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(config.env) { _, new in new }
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe() // Suppress stderr

        try proc.run()

        process = proc
        inputPipe = inPipe
        outputPipe = outPipe

        startReadingLoop(handle: outPipe.fileHandleForReading)

        // Send initialize
        let id = nextId()
        let initParams = MCPInitializeParams(
            protocolVersion: "2024-11-05",
            capabilities: MCPServerCapabilities(tools: MCPToolsCapability(listChanged: nil)),
            clientInfo: MCPClientInfo(name: "Typeflux", version: "1.0.0"),
        )
        let initMsg = try MCPJsonRPCMessage.initializeRequest(id: .string(id), params: initParams)
        let response = try await sendMessage(initMsg, id: id)

        let initResult = try response.decodeInitializeResult()
        connectionInfo = MCPConnectionInfo(
            name: initResult.serverInfo?.name ?? "Unknown",
            protocolVersion: initResult.protocolVersion,
            capabilities: initResult.capabilities,
        )

        // Send initialized notification (no response expected)
        let notification = MCPJsonRPCMessage.initializedNotification()
        sendMessageNoReply(notification)
    }

    func disconnect() async {
        readingTask?.cancel()
        readingTask = nil
        process?.terminate()
        process = nil
        connectionInfo = nil
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests = [:]
    }

    func listTools() async throws -> [MCPToolDefinition] {
        guard isConnected else { throw MCPClientError.notConnected }
        let id = nextId()
        let msg = MCPJsonRPCMessage.toolsListRequest(id: .string(id))
        let response = try await sendMessage(msg, id: id)
        let result = try response.decodeToolsListResult()
        return result.tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        guard isConnected else { throw MCPClientError.notConnected }
        let argsDict = arguments.mapValues { AnyCodable($0) }
        let params = MCPToolsCallParams(name: name, arguments: argsDict)
        let id = nextId()
        let msg = try MCPJsonRPCMessage.toolsCallRequest(id: .string(id), params: params)
        let response = try await sendMessage(msg, id: id)
        return try response.decodeToolsCallResult()
    }

    func ping() async throws {
        guard isConnected else { throw MCPClientError.notConnected }
        let id = nextId()
        let msg = MCPJsonRPCMessage(jsonrpc: "2.0", id: .string(id), method: "ping", params: nil)
        _ = try await sendMessage(msg, id: id)
    }

    // MARK: - Private

    private func nextId() -> String {
        messageIdCounter += 1
        return String(messageIdCounter)
    }

    private func sendMessage(_ message: MCPJsonRPCMessage, id: String) async throws -> MCPJsonRPCMessage {
        guard let pipe = inputPipe else { throw MCPClientError.notConnected }
        let data = try JSONEncoder().encode(message)
        var lineData = data
        lineData.append(contentsOf: "\n".utf8)
        pipe.fileHandleForWriting.write(lineData)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func sendMessageNoReply(_ message: MCPJsonRPCMessage) {
        guard let pipe = inputPipe,
              let data = try? JSONEncoder().encode(message) else { return }
        var lineData = data
        lineData.append(contentsOf: "\n".utf8)
        pipe.fileHandleForWriting.write(lineData)
    }

    private func startReadingLoop(handle: FileHandle) {
        readingTask = Task {
            var buffer = Data()
            while !Task.isCancelled {
                let available = handle.availableData
                if available.isEmpty { break }
                buffer.append(available)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer[buffer.startIndex ..< newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex ... newlineRange.lowerBound)

                    if let msg = try? JSONDecoder().decode(MCPJsonRPCMessage.self, from: lineData),
                       let msgId = msg.id
                    {
                        let idStr = msgId.stringValue
                        pendingRequests[idStr]?.resume(returning: msg)
                        pendingRequests.removeValue(forKey: idStr)
                    }
                }
            }
        }
    }
}
