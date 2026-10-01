import Foundation

/// MCP server registry actor.
actor MCPRegistry {
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    /// Keyed by server and tool name: two servers may expose tools with the same name.
    private var cachedTools: [ToolKey: MCPToolAdapter] = [:]

    private struct ToolKey: Hashable {
        let serverId: UUID
        let name: String
    }

    private let settingsStore: MCPSettingsStore
    private let clientFactory: (MCPServerConfig) -> any MCPClient

    init(settingsStore: MCPSettingsStore = MCPSettingsStore(),
         clientFactory: ((MCPServerConfig) -> any MCPClient)? = nil) {
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory ?? Self.makeClient(for:)
    }

    /// Registers an MCP server.
    func addServer(_ config: MCPServerConfig) async throws {
        let client = clientFactory(config)
        try await client.connect()
        servers[config.id] = client
        serverConfigs[config.id] = config
        let serverId = config.id
        await client.setToolsChangedHandler { [weak self] in try? await self?.refreshTools(for: serverId) }
        do {
            try await refreshTools(for: config.id)
        } catch {
            // A server whose tools cannot be listed is unusable; do not keep its process alive.
            await removeServer(id: config.id)
            throw error
        }
    }

    /// Removes an MCP server.
    func removeServer(id: UUID) async {
        await servers[id]?.disconnect()
        servers.removeValue(forKey: id)
        serverConfigs.removeValue(forKey: id)
        cachedTools = cachedTools.filter { $0.key.serverId != id }
    }

    /// Returns all MCP tools.
    func allMCPTools() async -> [any AgentTool] {
        registeredTools().map(\.tool)
    }

    /// Returns every tool with its owning server, ordered by server name then tool name.
    func registeredTools() -> [MCPRegisteredTool] {
        cachedTools.map { key, tool in
            MCPRegisteredTool(serverId: key.serverId, serverName: serverConfigs[key.serverId]?.name ?? "", tool: tool)
        }.sorted {
            ($0.serverName, $0.serverId.uuidString, $0.tool.toolDef.name) < ($1.serverName, $1.serverId.uuidString, $1.tool.toolDef.name)
        }
    }

    /// Tools for the voice agent, which calls them by bare name: a name shared by
    /// several servers is qualified as `<server>_<tool>` instead of shadowing another tool.
    func uniqueAgentTools() -> [any AgentTool] {
        AskLocalTools.mcpToolNames(registeredTools()).map { name, entry in
            let bare = String(name.dropFirst("mcp_".count))
            return bare == entry.tool.toolDef.name ? entry.tool as any AgentTool : MCPRenamedTool(base: entry.tool, name: bare)
        }
    }

    /// Finds the server ID that owns a tool; nil when unknown or ambiguous.
    func serverId(forToolName name: String) -> UUID? {
        let owners = cachedTools.keys.filter { $0.name == name }
        return owners.count == 1 ? owners.first?.serverId : nil
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

    private static func makeClient(for config: MCPServerConfig) -> any MCPClient {
        switch config.transport {
        case let .stdio(stdioConfig):
            return StdioMCPClient(config: MCPStdioConfig(
                command: stdioConfig.command,
                args: stdioConfig.args,
                env: stdioConfig.env
            ))
        case let .http(httpConfig):
            let url = URL(string: httpConfig.url) ?? URL(string: "http://localhost")!
            // Background connections reuse or refresh a sign-in but never open a browser.
            return HTTPMCPClient(config: MCPHTTPConfig(url: url, headers: httpConfig.headers,
                                                       authorizer: MCPOAuthAuthorizer(resource: url, interactive: false)))
        }
    }

    func refreshTools(for serverId: UUID) async throws {
        guard let client = servers[serverId] else { return }
        let tools = try await client.listTools()
        cachedTools = cachedTools.filter { $0.key.serverId != serverId }
        for toolDef in tools {
            cachedTools[ToolKey(serverId: serverId, name: toolDef.name)] = MCPToolAdapter(client: client, toolDef: toolDef)
        }
    }
}

struct MCPRegisteredTool {
    let serverId: UUID
    let serverName: String
    let tool: MCPToolAdapter
}

/// An MCP tool exposed under a server-qualified name.
struct MCPRenamedTool: AgentTool {
    let base: MCPToolAdapter
    let name: String

    var definition: LLMAgentTool {
        let original = base.definition
        return LLMAgentTool(name: name, description: original.description, inputSchema: original.inputSchema)
    }

    func execute(arguments: String) async throws -> String {
        try await base.execute(arguments: arguments)
    }
}
