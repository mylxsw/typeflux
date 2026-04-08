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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("Non-HTTP response")
        }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            throw MCPClientError.serverError(
                code: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode)",
            )
        }

        return (try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data), httpResponse)
    }
}
