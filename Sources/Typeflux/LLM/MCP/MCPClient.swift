import Foundation

/// MCP server connection info.
struct MCPConnectionInfo {
    let name: String
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
}

/// MCP client protocol.
protocol MCPClient: Actor {
    var serverInfo: MCPConnectionInfo? { get }
    var isConnected: Bool { get }

    /// Connects to an MCP server.
    func connect() async throws

    /// Disconnects.
    func disconnect() async

    /// Returns available tools.
    func listTools() async throws -> [MCPToolDefinition]

    /// Calls a tool.
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult

    /// Tests connectivity (sends ping).
    func ping() async throws
}
