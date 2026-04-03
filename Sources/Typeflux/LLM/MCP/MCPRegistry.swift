import Foundation

/// MCP 服务器注册表 actor
actor MCPRegistry {
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    private var cachedTools: [String: (any AgentTool, UUID)] = [:]

    private let settingsStore: MCPSettingsStore

    init(settingsStore: MCPSettingsStore = MCPSettingsStore()) {
        self.settingsStore = settingsStore
    }

    /// 注册 MCP 服务器
    func addServer(_ config: MCPServerConfig) async throws {
        let client = makeClient(for: config)
        try await client.connect()
        servers[config.id] = client
        serverConfigs[config.id] = config
        try await refreshTools(for: config.id)
    }

    /// 移除 MCP 服务器
    func removeServer(id: UUID) async {
        await servers[id]?.disconnect()
        servers.removeValue(forKey: id)
        serverConfigs.removeValue(forKey: id)
        cachedTools = cachedTools.filter { $0.value.1 != id }
    }

    /// 获取所有 MCP 工具
    func allMCPTools() async -> [any AgentTool] {
        cachedTools.map(\.value.0)
    }

    /// 查找工具所属服务器 ID
    func serverId(forToolName name: String) -> UUID? {
        cachedTools[name]?.1
    }

    /// 重新连接所有启用了 autoConnect 的服务器
    func connectAutoConnectServers() async {
        for config in settingsStore.servers where config.enabled && config.autoConnect {
            guard servers[config.id] == nil else { continue }
            try? await addServer(config)
        }
    }

    /// 获取已连接服务器数量
    var connectedServerCount: Int {
        servers.count
    }

    // MARK: - Private

    private func makeClient(for config: MCPServerConfig) -> any MCPClient {
        switch config.transport {
        case .stdio(let stdioConfig):
            return StdioMCPClient(config: MCPStdioConfig(
                command: stdioConfig.command,
                args: stdioConfig.args,
                env: stdioConfig.env
            ))
        case .http(let httpConfig):
            let url = URL(string: httpConfig.url) ?? URL(string: "http://localhost")!
            return HTTPMCPClient(config: MCPHTTPConfig(url: url, apiKey: httpConfig.apiKey))
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
