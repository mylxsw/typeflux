import Foundation

struct MCPHTTPConfig {
    let url: URL
    let headers: [String: String]
    let urlSession: URLSession?

    init(url: URL, headers: [String: String] = [:], urlSession: URLSession? = nil) {
        self.url = url
        self.headers = headers
        self.urlSession = urlSession
    }
}

/// MCP client over HTTP transport.
actor HTTPMCPClient: MCPClient {
    private let config: MCPHTTPConfig
    private var session: URLSession?
    private var connectionInfo: MCPConnectionInfo?
    private var messageIdCounter: Int = 0
    private var sessionId: String?
    private var negotiatedProtocolVersion: String = "2024-11-05"

    var serverInfo: MCPConnectionInfo? {
        connectionInfo
    }

    var isConnected: Bool {
        session != nil && connectionInfo != nil
    }

    init(config: MCPHTTPConfig) {
        self.config = config
    }

    func connect() async throws {
        session = config.urlSession ?? URLSession(configuration: .default)
        let id = nextId()
        let initParams = MCPInitializeParams(
            protocolVersion: negotiatedProtocolVersion,
            capabilities: MCPServerCapabilities(tools: MCPToolsCapability(listChanged: nil)),
            clientInfo: MCPClientInfo(name: "Typeflux", version: "1.0.0"),
        )
        let initMsg = try MCPJsonRPCMessage.initializeRequest(id: .string(id), params: initParams)
        let (response, httpResponse) = try await post(message: initMsg)

        let initResult = try response.decodeInitializeResult()
        negotiatedProtocolVersion = initResult.protocolVersion
        sessionId = httpResponse.value(forHTTPHeaderField: "MCP-Session-Id")
        connectionInfo = MCPConnectionInfo(
            name: initResult.serverInfo?.name ?? "Unknown",
            protocolVersion: initResult.protocolVersion,
            capabilities: initResult.capabilities,
        )
    }

    func disconnect() async {
        session?.invalidateAndCancel()
        session = nil
        connectionInfo = nil
        sessionId = nil
        negotiatedProtocolVersion = "2024-11-05"
    }

    func listTools() async throws -> [MCPToolDefinition] {
        guard isConnected else { throw MCPClientError.notConnected }
        let id = nextId()
        let msg = MCPJsonRPCMessage.toolsListRequest(id: .string(id))
        let (response, _) = try await post(message: msg)
        return try response.decodeToolsListResult().tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        guard isConnected else { throw MCPClientError.notConnected }
        let argsDict = arguments.mapValues { AnyCodable($0) }
        let params = MCPToolsCallParams(name: name, arguments: argsDict)
        let id = nextId()
        let msg = try MCPJsonRPCMessage.toolsCallRequest(id: .string(id), params: params)
        let (response, _) = try await post(message: msg)
        return try response.decodeToolsCallResult()
    }

    func ping() async throws {
        guard isConnected else { throw MCPClientError.notConnected }
        let id = nextId()
        let msg = MCPJsonRPCMessage(jsonrpc: "2.0", id: .string(id), method: "ping", params: nil)
        _ = try await post(message: msg)
    }

    // MARK: - Private

    private func nextId() -> String {
        messageIdCounter += 1
        return String(messageIdCounter)
    }

    private func post(message: MCPJsonRPCMessage) async throws -> (MCPJsonRPCMessage, HTTPURLResponse) {
        guard let session else { throw MCPClientError.notConnected }

        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if connectionInfo != nil {
            request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "MCP-Session-Id")
        }
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(message)
        NetworkDebugLogger.logMessage("""
        [MCP HTTP Request]
        URL: \(Self.redactedDebugURL(config.url))
        Method: POST
        Headers: \(Self.redactedHeaders(request.allHTTPHeaderFields ?? [:]))
        BodyPreview: \(Self.debugPreview(for: request.httpBody))
        """)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("Non-HTTP response")
        }
        NetworkDebugLogger.logMessage("""
        [MCP HTTP Response]
        URL: \(Self.redactedDebugURL(httpResponse.url))
        Status: \(httpResponse.statusCode)
        Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "<missing>")
        Headers: \(httpResponse.allHeaderFields)
        BodyPreview: \(Self.debugPreview(for: data))
        """)

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            throw MCPClientError.serverError(
                code: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode)",
            )
        }

        do {
            let message = try Self.decodeMessage(
                from: data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            )
            return (message, httpResponse)
        } catch {
            NetworkDebugLogger.logError(
                context: """
                MCP JSON decode failed | url=\(Self.redactedDebugURL(httpResponse.url)) \
                | status=\(httpResponse.statusCode) \
                | contentType=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "<missing>") \
                | bodyPreview=\(Self.debugPreview(for: data))
                """,
                error: error,
            )
            throw error
        }
    }

    static func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "<nil>" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        let sensitiveNames = Set(["apikey", "api_key", "token", "access_token", "authorization"])
        components.queryItems = components.queryItems?.map { item in
            if sensitiveNames.contains(item.name.lowercased()) {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return components.string ?? url.absoluteString
    }

    static func debugPreview(for data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }

        let prefix = data.prefix(2048)
        let preview: String
        if let string = String(data: prefix, encoding: .utf8) {
            preview = string
        } else {
            preview = "<non-utf8 \(data.count) bytes>"
        }

        if data.count > prefix.count {
            return "\(preview)\n<truncated totalBytes=\(data.count)>"
        }

        return preview
    }

    static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        var redacted = headers
        for key in headers.keys {
            switch key.lowercased() {
            case "authorization", "x-api-key", "api-key":
                redacted[key] = "<redacted>"
            default:
                continue
            }
        }
        return redacted
    }

    static func decodeMessage(from data: Data, contentType: String?) throws -> MCPJsonRPCMessage {
        if let contentType, contentType.lowercased().contains("text/event-stream") {
            return try decodeSSEMessage(from: data)
        }

        return try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data)
    }

    static func decodeSSEMessage(from data: Data) throws -> MCPJsonRPCMessage {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse("SSE payload is not valid UTF-8")
        }

        var collectedDataLines: [String] = []

        func decodeCollectedLines() throws -> MCPJsonRPCMessage? {
            guard !collectedDataLines.isEmpty else { return nil }
            let payload = collectedDataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            collectedDataLines.removeAll(keepingCapacity: true)

            guard !payload.isEmpty, payload != "[DONE]" else { return nil }
            guard let payloadData = payload.data(using: .utf8) else {
                throw MCPClientError.invalidResponse("SSE data frame is not valid UTF-8")
            }
            return try JSONDecoder().decode(MCPJsonRPCMessage.self, from: payloadData)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if let message = try decodeCollectedLines() {
                    return message
                }
                continue
            }

            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                collectedDataLines.append(payload)
            }
        }

        if let message = try decodeCollectedLines() {
            return message
        }

        throw MCPClientError.invalidResponse("SSE response did not contain a JSON-RPC message")
    }
}
