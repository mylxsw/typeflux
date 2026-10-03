import Foundation

struct MCPHTTPConfig {
    let url: URL
    let headers: [String: String]
    let urlSession: URLSession?
    /// Answers 401 challenges with OAuth; nil keeps static headers only.
    let authorizer: MCPOAuthAuthorizer?
    let requestTimeout: TimeInterval
    let maximumResponseBytes: Int

    init(url: URL, headers: [String: String] = [:], urlSession: URLSession? = nil,
         authorizer: MCPOAuthAuthorizer? = nil, requestTimeout: TimeInterval = 60,
         maximumResponseBytes: Int = 8 * 1024 * 1024) {
        self.url = url
        self.headers = headers
        self.urlSession = urlSession
        self.authorizer = authorizer
        self.requestTimeout = requestTimeout.isFinite ? max(0.001, requestTimeout) : 60
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }
}

/// POST-based Streamable HTTP, with JSON or incremental SSE responses.
actor HTTPMCPClient: MCPClient {
    private let config: MCPHTTPConfig
    private var session: URLSession?
    private var connectionInfo: MCPConnectionInfo?
    private var messageIdCounter = 0
    private var sessionId: String?
    private var negotiatedProtocolVersion: String?
    private var generation = UUID()
    private var connectionTask: Task<Void, Error>?
    private var needsReconnect = false
    private var pending: [UUID: MCPHTTPExchange] = [:]
    private var toolsChangedHandler: (@Sendable () async -> Void)?
    private var notificationHandler: (@Sendable (MCPJsonRPCMessage) async -> Void)?

    var serverInfo: MCPConnectionInfo? {
        connectionInfo
    }

    var isConnected: Bool {
        connectionInfo != nil
    }

    var pendingRequestCount: Int {
        pending.count
    }

    init(config: MCPHTTPConfig) {
        self.config = config
    }

    func setToolsChangedHandler(_ handler: @escaping @Sendable () async -> Void) async {
        toolsChangedHandler = handler
    }

    /// Receives notifications (including progress and logging) separately from results.
    func setNotificationHandler(_ handler: @escaping @Sendable (MCPJsonRPCMessage) async -> Void) {
        notificationHandler = handler
    }

    func connect() async throws {
        try Task.checkCancellation()
        if isConnected {
            return
        }
        if let connectionTask {
            try await waitForConnection(connectionTask)
            return
        }
        resetConnection(reconnect: false)
        session = config.urlSession ?? URLSession(configuration: .default)
        let current = generation
        let task = Task { try await self.initialize(generation: current) }
        connectionTask = task
        do {
            try await waitForConnection(task)
            guard current == generation else { throw MCPClientError.notConnected }
            connectionTask = nil
        } catch {
            if current == generation {
                resetConnection(reconnect: false)
            }
            throw error
        }
    }

    private func waitForConnection(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }

    private func initialize(generation current: UUID) async throws {
        let params = MCPInitializeParams(
            protocolVersion: MCPProtocol.latestVersion,
            capabilities: MCPServerCapabilities(tools: nil),
            clientInfo: MCPClientInfo(name: "Typeflux", version: "1.0.0")
        )
        let message = try MCPJsonRPCMessage.initializeRequest(id: .string(nextId()), params: params)
        let response = try await post(message: message)
        let result = try response.message!.decodeInitializeResult()
        // These revisions share the supported POST/tools subset. Legacy HTTP+SSE
        // (2024-11-05) is a different transport and is deliberately not advertised.
        guard ["2025-06-18", "2025-03-26"].contains(result.protocolVersion) else {
            throw MCPClientError.invalidResponse("Unsupported MCP protocol version: \(result.protocolVersion)")
        }
        guard current == generation else { throw MCPClientError.notConnected }
        if let id = response.http.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard !id.isEmpty, id.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) }) else {
                throw MCPClientError.invalidResponse("Invalid MCP session ID")
            }
            sessionId = id
        }
        negotiatedProtocolVersion = result.protocolVersion
        _ = try await post(message: .initializedNotification())
        guard current == generation else { throw MCPClientError.notConnected }
        connectionInfo = MCPConnectionInfo(name: result.serverInfo?.name ?? "Unknown",
                                           protocolVersion: result.protocolVersion, capabilities: result.capabilities)
    }

    func disconnect() async {
        resetConnection(reconnect: false)
    }

    private func resetConnection(reconnect: Bool) {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        for exchange in pending.values {
            exchange.cancel(MCPClientError.notConnected)
        }
        pending.removeAll()
        // Injected sessions may be shared with OAuth or another client.
        if config.urlSession == nil {
            session?.invalidateAndCancel()
        }
        session = nil
        connectionInfo = nil
        sessionId = nil
        negotiatedProtocolVersion = nil
        needsReconnect = reconnect
    }

    private func ensureConnected() async throws {
        try Task.checkCancellation()
        if needsReconnect || connectionTask != nil {
            try await connect()
        }
        guard isConnected else { throw MCPClientError.notConnected }
    }

    func listTools() async throws -> [MCPToolDefinition] {
        try await ensureConnected()
        return try await collectMCPToolPages { cursor in
            let response = try await post(message: .toolsListRequest(id: .string(nextId()), cursor: cursor))
            return try response.message!.decodeToolsListResult()
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        try await ensureConnected()
        let params = MCPToolsCallParams(name: name, arguments: arguments.mapValues { AnyCodable($0) })
        let message = try MCPJsonRPCMessage.toolsCallRequest(id: .string(nextId()), params: params)
        let response = try await post(message: message)
        return try response.message!.decodeToolsCallResult()
    }

    func ping() async throws {
        try await ensureConnected()
        _ = try await post(message: MCPJsonRPCMessage(id: .string(nextId()), method: "ping"))
    }

    private func nextId() -> String {
        messageIdCounter += 1
        return String(messageIdCounter)
    }

    private func post(message: MCPJsonRPCMessage) async throws -> MCPHTTPExchange.Response {
        let current = generation
        let hadSession = sessionId != nil
        let token = await config.authorizer?.accessToken()
        do {
            try checkGeneration(current)
            do {
                return try await exchange(message: message, bearer: token, generation: current)
            } catch let MCPHTTPTransportError.unauthorized(challenge) {
                guard let authorizer = config.authorizer else { throw MCPHTTPTransportError.status(401) }
                let fresh = try await authorizer.authorize(challenge: challenge)
                try checkGeneration(current)
                // Only an explicit authentication rejection is retried, once.
                return try await exchange(message: message, bearer: fresh, generation: current)
            }
        } catch {
            await handleFailure(error, message: message, bearer: token, generation: current, hadSession: hadSession)
            switch error {
            case MCPHTTPTransportError.unauthorized:
                throw MCPClientError.serverError(code: 401, message: "HTTP 401 after authentication retry")
            case let MCPHTTPTransportError.status(code):
                throw MCPClientError.serverError(code: code, message: code == 404 && hadSession
                    ? "MCP session expired; reconnect before the next request. The request was not replayed."
                    : "HTTP \(code)")
            default: throw error
            }
        }
    }

    private func handleFailure(_ error: Error, message: MCPJsonRPCMessage, bearer: String?,
                               generation current: UUID, hadSession: Bool) async {
        guard current == generation else { return }
        if case MCPHTTPTransportError.status(404) = error, hadSession {
            resetConnection(reconnect: true)
        } else if let urlError = error as? URLError, urlError.code != .cancelled {
            resetConnection(reconnect: true)
        } else if let id = message.id, message.method != "initialize", Self.stoppedWaiting(error) {
            // Cancellation is advisory and has its own short bound. Never
            // retry the abandoned request, even when its effect is unknown.
            let cancellation = Task {
                _ = try? await self.exchange(
                    message: .cancelledNotification(requestId: id, reason: "Client stopped waiting"),
                    bearer: bearer, generation: current, timeout: min(1, config.requestTimeout)
                )
            }
            await cancellation.value
        }
    }

    private static func stoppedWaiting(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if case MCPClientError.timedOut = error {
            return true
        }
        return false
    }

    private func checkGeneration(_ current: UUID) throws {
        try Task.checkCancellation()
        guard current == generation, session != nil else { throw MCPClientError.notConnected }
    }

    private func exchange(message: MCPJsonRPCMessage, bearer: String?, generation current: UUID,
                          timeout: TimeInterval? = nil) async throws -> MCPHTTPExchange.Response {
        try checkGeneration(current)
        guard let session else { throw MCPClientError.notConnected }
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Protocol headers are owned by the negotiated connection, not static config.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(sessionId, forHTTPHeaderField: "MCP-Session-Id")
        if let bearer {
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(message)
        let exchange = MCPHTTPExchange(expectedID: message.method == nil ? nil : message.id,
                                       maximumResponseBytes: config.maximumResponseBytes) { [weak self] notification in
            Task { await self?.receive(notification, generation: current) }
        }
        let key = UUID()
        pending[key] = exchange
        defer { pending[key] = nil }
        NetworkDebugLogger
            .logMessage(
                "[MCP HTTP] POST \(Self.redactedDebugURL(config.url)) method=\(message.method ?? "response") id=\(message.id?.stringValue ?? "none")"
            )
        let response = try await exchange.run(
            session: session,
            request: request,
            timeout: timeout ?? config.requestTimeout
        )
        try checkGeneration(current)
        return response
    }

    private func receive(_ message: MCPJsonRPCMessage, generation current: UUID) async {
        guard generation == current else { return }
        if let id = message.id {
            // No sampling, roots or elicitation capabilities were advertised.
            let reply = message.method == "ping" ? MCPJsonRPCMessage(id: id, result: [:])
                : MCPJsonRPCMessage(
                    id: id,
                    error: MCPErrorDetail(code: -32601, message: "Method not supported", data: nil)
                )
            _ = try? await post(message: reply)
        } else {
            if message.method == "notifications/tools/list_changed" {
                await toolsChangedHandler?()
            }
            await notificationHandler?(message)
        }
    }
}

extension HTTPMCPClient {
    static func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "<nil>" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<invalid URL>" }
        components.user = nil
        components.password = nil
        // Queries may contain server-specific credentials whose names we cannot know.
        components.queryItems = components.queryItems?.map { URLQueryItem(name: $0.name, value: "<redacted>") }
        components.fragment = nil
        return components.string ?? "<invalid URL>"
    }
}
