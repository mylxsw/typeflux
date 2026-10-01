import Foundation

struct MCPStdioConfig {
    let command: String
    let args: [String]
    let env: [String: String]
    /// Bounds every request so a stalled server cannot hang a conversation.
    let requestTimeout: Duration

    init(command: String, args: [String] = [], env: [String: String] = [:], requestTimeout: Duration = .seconds(120)) {
        self.command = command
        self.args = args
        self.env = env
        self.requestTimeout = requestTimeout
    }
}

/// MCP client over stdio transport.
actor StdioMCPClient: MCPClient {
    private let config: MCPStdioConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var pendingRequests: [String: CheckedContinuation<MCPJsonRPCMessage, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
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
        let environment = Self.launchEnvironment(base: ProcessInfo.processInfo.environment, overrides: config.env)
        guard let executable = Self.resolveExecutable(config.command, searchPath: environment["PATH"] ?? "") else {
            throw MCPClientError.launchFailed(config.command)
        }
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = config.args
        proc.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // An undrained pipe blocks a chatty server once its buffer fills.
        proc.standardError = FileHandle.nullDevice
        // Writing to an exited server must fail the request, not raise SIGPIPE in the app.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try proc.run()
        } catch {
            throw MCPClientError.launchFailed(config.command)
        }

        process = proc
        inputPipe = inPipe
        outputPipe = outPipe

        startReadingLoop(handle: outPipe.fileHandleForReading)

        do {
            let id = nextId()
            let initParams = MCPInitializeParams(
                protocolVersion: "2024-11-05",
                capabilities: MCPServerCapabilities(tools: MCPToolsCapability(listChanged: nil)),
                clientInfo: MCPClientInfo(name: "Typeflux", version: "1.0.0")
            )
            let initMsg = try MCPJsonRPCMessage.initializeRequest(id: .string(id), params: initParams)
            let response = try await sendMessage(initMsg, id: id)

            let initResult = try response.decodeInitializeResult()
            connectionInfo = MCPConnectionInfo(
                name: initResult.serverInfo?.name ?? "Unknown",
                protocolVersion: initResult.protocolVersion,
                capabilities: initResult.capabilities
            )
        } catch {
            await disconnect()
            throw error
        }

        // Send initialized notification (no response expected)
        sendMessageNoReply(MCPJsonRPCMessage.initializedNotification())
    }

    func disconnect() async {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        readingTask?.cancel()
        readingTask = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        connectionInfo = nil
        failPendingRequests(MCPClientError.notConnected)
    }

    func listTools() async throws -> [MCPToolDefinition] {
        guard isConnected else { throw MCPClientError.notConnected }
        return try await collectMCPToolPages { cursor in
            let id = nextId()
            let response = try await sendMessage(MCPJsonRPCMessage.toolsListRequest(id: .string(id), cursor: cursor), id: id)
            return try response.decodeToolsListResult()
        }
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

    // MARK: - Launch environment

    /// Directories where package managers commonly install MCP launchers such as
    /// `npx` and `uvx`. Apps opened from Finder inherit only the minimal system PATH.
    static func commonExecutableDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
         home + "/.local/bin", home + "/.cargo/bin", home + "/.bun/bin", home + "/.volta/bin"]
    }

    /// Configured variables win; PATH keeps its configured order and gains missing common directories.
    static func launchEnvironment(base: [String: String], overrides: [String: String],
                                  home: String = NSHomeDirectory()) -> [String: String] {
        var environment = base.merging(overrides) { _, new in new }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in commonExecutableDirectories(home: home) where !directories.contains(directory) {
            directories.append(directory)
        }
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    /// Accepts an absolute or `~` path, or a bare command name searched in `searchPath`.
    static func resolveExecutable(_ command: String, searchPath: String,
                                  fileManager: FileManager = .default) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let path = (trimmed as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(trimmed)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    // MARK: - Private

    private func nextId() -> String {
        messageIdCounter += 1
        return String(messageIdCounter)
    }

    private func sendMessage(_ message: MCPJsonRPCMessage, id: String) async throws -> MCPJsonRPCMessage {
        guard let pipe = inputPipe else { throw MCPClientError.notConnected }
        var line = try JSONEncoder().encode(message)
        line.append(contentsOf: "\n".utf8)
        let timeout = config.requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[id] = continuation
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: line)
                } catch {
                    finish(id, with: .failure(MCPClientError.notConnected))
                    return
                }
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.abandon(id, error: MCPClientError.timedOut)
                }
            }
        } onCancel: {
            Task { await self.abandon(id, error: CancellationError()) }
        }
    }

    private func sendMessageNoReply(_ message: MCPJsonRPCMessage) {
        guard let pipe = inputPipe,
              var line = try? JSONEncoder().encode(message) else { return }
        line.append(contentsOf: "\n".utf8)
        try? pipe.fileHandleForWriting.write(contentsOf: line)
    }

    /// Fails a request the caller gave up on and tells the server to stop working on it.
    private func abandon(_ id: String, error: Error) {
        guard pendingRequests[id] != nil else { return }
        finish(id, with: .failure(error))
        sendMessageNoReply(.cancelledNotification(
            requestId: .string(id),
            reason: error is CancellationError ? "Cancelled by the client" : "Request timed out"
        ))
    }

    private func finish(_ id: String, with result: Result<MCPJsonRPCMessage, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pendingRequests.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPendingRequests(_ error: Error) {
        for id in Array(pendingRequests.keys) {
            finish(id, with: .failure(error))
        }
    }

    private func receive(_ line: Data) {
        // Requests and notifications from the server carry a method; only responses resolve our requests.
        guard let msg = try? JSONDecoder().decode(MCPJsonRPCMessage.self, from: line),
              msg.method == nil, let msgId = msg.id else { return }
        finish(msgId.stringValue, with: .success(msg))
    }

    /// Reads on Foundation's background queue; the actor only awaits delivered chunks,
    /// so a quiet server never blocks other calls on this client.
    private func startReadingLoop(handle: FileHandle) {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        readingTask = Task {
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex ..< newline]
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    receive(Data(line))
                }
            }
            // End of output means the server exited; nothing pending can be answered.
            guard !Task.isCancelled else { return }
            failPendingRequests(MCPClientError.notConnected)
        }
    }
}
