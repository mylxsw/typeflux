import Foundation

/// MCP server registry actor.
actor MCPRegistry {
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    private var cachedTools: [String: (any AgentTool, UUID)] = [:]

    private let settingsStore: MCPSettingsStore

    init(settingsStore: MCPSettingsStore = MCPSettingsStore()) {
        self.settingsStore = settingsStore
    }

    /// Registers an MCP server.
    func addServer(_ config: MCPServerConfig) async throws {
        let client = makeClient(for: config)
        try await client.connect()
        servers[config.id] = client
        serverConfigs[config.id] = config
        try await refreshTools(for: config.id)
    }

    /// Removes an MCP server.
    func removeServer(id: UUID) async {
        await servers[id]?.disconnect()
        servers.removeValue(forKey: id)
        serverConfigs.removeValue(forKey: id)
        cachedTools = cachedTools.filter { $0.value.1 != id }
    }

    /// Returns all MCP tools.
    func allMCPTools() async -> [any AgentTool] {
        cachedTools.map(\.value.0)
    }

    /// Finds the server ID that owns a tool.
    func serverId(forToolName name: String) -> UUID? {
        cachedTools[name]?.1
    }

    /// Reconnects all servers with autoConnect enabled.
    func connectAutoConnectServers() async {
        for config in settingsStore.servers where config.enabled && config.autoConnect {
            guard servers[config.id] == nil else { continue }
            try? await addServer(config)
        }
    }

    /// Connects all enabled servers in the given list (skips already-connected ones).
    func connectEnabledServers(_ configs: [MCPServerConfig]) async {
        for config in configs where config.enabled {
            guard servers[config.id] == nil else { continue }
            try? await addServer(config)
        }
    }

    /// Returns the number of connected servers.
    var connectedServerCount: Int {
        servers.count
    }

    // MARK: - Private

    private func makeClient(for config: MCPServerConfig) -> any MCPClient {
        switch config.transport {
        case let .stdio(stdioConfig):
            return StdioMCPClient(config: MCPStdioConfig(
                command: stdioConfig.command,
                args: stdioConfig.args,
                env: stdioConfig.env,
            ))
        case let .http(httpConfig):
            let url = URL(string: httpConfig.url) ?? URL(string: "http://localhost")!
            return HTTPMCPClient(config: MCPHTTPConfig(url: url, headers: httpConfig.headers))
        }
    }

    private func refreshTools(for serverId: UUID) async throws {
        guard let client = servers[serverId] else { return }
        let tools = try await client.listTools()
        for toolDef in tools {
            let adapter = MCPToolAdapter(client: client, toolDef: toolDef)
            cachedTools[toolDef.name] = (adapter, serverId)
        }
    }
}
