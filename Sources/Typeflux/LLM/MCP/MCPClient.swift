import Foundation

/// MCP 服务器连接信息
struct MCPConnectionInfo {
    let name: String
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
}

/// MCP 客户端协议
protocol MCPClient: Actor {
    var serverInfo: MCPConnectionInfo? { get }
    var isConnected: Bool { get }

    /// 连接到 MCP 服务器
    func connect() async throws

    /// 断开连接
    func disconnect() async

    /// 获取可用工具列表
    func listTools() async throws -> [MCPToolDefinition]

    /// 调用工具
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolsCallResult

    /// 测试连接（发送 ping）
    func ping() async throws
}
