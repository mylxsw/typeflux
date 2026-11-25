import Foundation

/// MCP 服务器传输配置
enum MCPTransportConfig: Codable, Equatable {
    case stdio(MCPStdioTransportConfig)
    case http(MCPHTTPTransportConfig)
}

struct MCPStdioTransportConfig: Codable, Equatable {
    let command: String
    var args: [String]
    var env: [String: String]

    init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

struct MCPHTTPTransportConfig: Codable, Equatable {
    var url: String
    var headers: [String: String]

    init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// MCP 服务器配置
struct MCPServerConfig: Codable, Equatable, Identifiable {
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
    private let serversKey = "agent.mcpServers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var servers: [MCPServerConfig] {
        get {
            // An explicitly saved empty list supersedes the legacy store too.
            guard let data = defaults.data(forKey: serversKey) ?? defaults.data(forKey: "mcp.servers"),
                  let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
            else {
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

enum MCPAuthorizationState: String {
    case required, authorized, expired, saved

    var label: String { L("agent.mcp.oauth." + rawValue) }

    var action: String {
        L(self == .required ? "agent.mcp.oauth.signIn" : "agent.mcp.oauth.again")
    }

    var needsAuthorization: Bool { self == .required || self == .expired }
}

extension MCPHTTPTransportConfig {
    static func hasAuthenticationHeader(_ headers: [String: String]) -> Bool {
        let names: Set<String> = ["authorization", "x-api-key", "api-key", "x-auth-token", "x-access-token", "cookie"]
        return headers.keys.contains { names.contains($0.lowercased()) }
    }

    var oauthResource: URL? {
        guard !Self.hasAuthenticationHeader(headers),
              let resource = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(resource.scheme?.lowercased() ?? ""), resource.host != nil else { return nil }
        return resource
    }
}

extension MCPTransportConfig {
    var oauthResource: URL? {
        guard case let .http(config) = self else { return nil }
        return config.oauthResource
    }
}
