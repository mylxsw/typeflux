import Foundation

/// MCP 服务器传输配置
enum MCPTransportConfig: Codable, Sendable {
    case stdio(MCPStdioTransportConfig)
    case http(MCPHTTPTransportConfig)
}

struct MCPStdioTransportConfig: Codable, Sendable {
    let command: String
    var args: [String]
    var env: [String: String]

    init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

struct MCPHTTPTransportConfig: Codable, Sendable {
    var url: String
    var headers: [String: String]

    init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// MCP 服务器配置
struct MCPServerConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var transport: MCPTransportConfig
    var enabled: Bool
    var autoConnect: Bool

    init(
        id: UUID = UUID(),
        name: String,
        transport: MCPTransportConfig,
        enabled: Bool = true,
        autoConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
        self.autoConnect = autoConnect
    }
}

/// MCP 设置存储
final class MCPSettingsStore: @unchecked Sendable {
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
