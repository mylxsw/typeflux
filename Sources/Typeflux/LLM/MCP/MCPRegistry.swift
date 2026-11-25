import Foundation

/// MCP server registry actor.
actor MCPRegistry {
    private var stopped = false
    private var servers: [UUID: any MCPClient] = [:]
    private var serverConfigs: [UUID: MCPServerConfig] = [:]
    private var savedConnections: Set<UUID> = []
    /// Keyed by server and tool name: two servers may expose tools with the same name.
    private var cachedTools: [ToolKey: MCPToolAdapter] = [:]
    /// Invalidate approvals on every accepted tools/list, including changes to
    /// schema keywords an older decoder cannot represent.
    private var toolRevisions: [ToolKey: UUID] = [:]
    private var connecting: [UUID: Task<Void, Error>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var connectionErrors: [UUID: String] = [:]

    private struct ToolKey: Hashable {
        let serverId: UUID
        let name: String
    }

    private let onToolsChanged: (@Sendable ([AskToolDefinition], [String: String]) async -> Void)?
    private let settingsStore: MCPSettingsStore
    private let clientFactory: (MCPServerConfig) -> any MCPClient

    init(settingsStore: MCPSettingsStore = MCPSettingsStore(),
         clientFactory: ((MCPServerConfig) -> any MCPClient)? = nil,
         onToolsChanged: (@Sendable ([AskToolDefinition], [String: String]) async -> Void)? = nil) {
        self.onToolsChanged = onToolsChanged
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory ?? Self.makeClient(for:)
    }

    /// Registers or reconnects a server; concurrent callers share one attempt.
    func addServer(_ config: MCPServerConfig, fromSettings: Bool = false) async throws {
        let serverId = config.id
        while true {
            try Task.checkCancellation()
            guard !stopped, !fromSettings || (config.enabled && settingsStore.servers.contains(config)) else {
                throw MCPClientError.notConnected
            }
            guard let current = serverConfigs[serverId] else { break }
            if current == config {
                if fromSettings { savedConnections.insert(serverId) }
                if let task = connecting[serverId] {
                    try await task.value
                    return
                }
                if let client = servers[serverId] {
                    let generation = generations[serverId]
                    let connected = await client.isConnected
                    guard generations[serverId] == generation else { continue }
                    if connected && connectionErrors[serverId] == nil { return }
                }
            }
            await removeServer(id: serverId)
        }
        if fromSettings { savedConnections.insert(serverId) }
        serverConfigs[serverId] = config
        let generation = UUID()
        generations[serverId] = generation
        let task = Task { try await self.establish(config, generation: generation) }
        connecting[serverId] = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generations[serverId] == generation else { throw MCPClientError.notConnected }
            connecting[serverId] = nil
            connectionErrors[serverId] = nil
            await publishAuthorizationInventory()
        } catch {
            if generations[serverId] == generation {
                await removeServer(id: serverId)
                if generations[serverId] == nil {
                    connectionErrors[serverId] = error.localizedDescription
                }
            }
            throw error
        }
    }

    private func establish(_ config: MCPServerConfig, generation: UUID) async throws {
        let serverId = config.id
        try Task.checkCancellation()
        guard generations[serverId] == generation else { throw MCPClientError.notConnected }
        let client = clientFactory(config)
        servers[serverId] = client
        do {
            try await client.connect()
            try Task.checkCancellation()
            guard generations[serverId] == generation else { throw MCPClientError.notConnected }
        } catch {
            // A late connection may finish after removeServer already disconnected
            // it. Release it again instead of leaving an unregistered process alive.
            if generations[serverId] != generation {
                await client.disconnect()
            }
            throw error
        }
        await client.setToolsChangedHandler { [weak self] in
            try? await self?.refreshTools(for: serverId, generation: generation)
        }
        try await refreshTools(for: serverId, generation: generation)
    }

    /// Removes an MCP server.
    func removeServer(id: UUID) async {
        let client = servers.removeValue(forKey: id)
        generations[id] = nil
        connecting.removeValue(forKey: id)?.cancel()
        serverConfigs.removeValue(forKey: id)
        savedConnections.remove(id)
        connectionErrors[id] = nil
        cachedTools = cachedTools.filter { $0.key.serverId != id }
        toolRevisions = toolRevisions.filter { $0.key.serverId != id }
        await client?.disconnect()
    }

    /// Retires only live connections, retaining the user's persisted server list.
    func shutdown() async {
        stopped = true
        let ids = Set(servers.keys).union(connecting.keys)
        for id in ids { await removeServer(id: id) }
    }

    /// Returns all MCP tools.
    func allMCPTools() async -> [any AgentTool] {
        registeredTools().map(\.tool)
    }

    /// Returns every tool with its owning server, ordered by server name then tool name.
    func registeredTools() -> [MCPRegisteredTool] {
        let eligible = Set(settingsStore.servers.filter { $0.enabled && serverConfigs[$0.id] == $0 }.map(\.id))
        return cachedTools.compactMap { key, tool -> MCPRegisteredTool? in
            guard !savedConnections.contains(key.serverId) || eligible.contains(key.serverId) else { return nil }
            return MCPRegisteredTool(serverId: key.serverId, serverName: serverConfigs[key.serverId]?.name ?? "", tool: tool)
        }.sorted {
            ($0.serverName, $0.serverId.uuidString, $0.tool.toolDef.name) < (
                $1.serverName,
                $1.serverId.uuidString,
                $1.tool.toolDef.name
            )
        }
    }

    func authorizationIdentities() -> [String: String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Dictionary(uniqueKeysWithValues: AskLocalTools.mcpToolNames(registeredTools()).map { name, entry in
            (name, entry.serverId.uuidString + AskToolPolicy.digest(
                (try? encoder.encode(serverConfigs[entry.serverId])) ?? Data()))
        })
    }

    private func publishAuthorizationInventory() async {
        guard let onToolsChanged else { return }
        let definitions = AskLocalTools.mcpToolNames(registeredTools()).compactMap { $0.1.askDefinition(named: $0.0) }
        await onToolsChanged(definitions, authorizationIdentities())
    }

    /// Tools for the voice agent, which calls them by bare name: a name shared by
    /// several servers is qualified as `<server>_<tool>` instead of shadowing another tool.
    func uniqueAgentTools() -> [any AgentTool] {
        AskLocalTools.mcpToolNames(registeredTools()).map { name, entry in
            let bare = String(name.dropFirst("mcp_".count))
            return bare == entry.tool.toolDef.name ? entry.tool as any AgentTool : MCPRenamedTool(
                base: entry.tool,
                name: bare
            )
        }
    }

    /// Finds the server ID that owns a tool; nil when unknown or ambiguous.
    func serverId(forToolName name: String) -> UUID? {
        let owners = cachedTools.keys.filter { $0.name == name }
        return owners.count == 1 ? owners.first?.serverId : nil
    }

    /// Local registry evidence, including the connection generation. Display names
    /// and server-provided read-only annotations cannot transfer an approval.
    func approvalBinding(serverId: UUID, toolName: String) throws -> AskToolBinding {
        guard let generation = generations[serverId], let revision = toolRevisions[ToolKey(serverId: serverId, name: toolName)],
              let tool = cachedTools[ToolKey(serverId: serverId, name: toolName)],
              !savedConnections.contains(serverId) || hasCurrentConfig(serverId) else {
            throw MCPClientError.notConnected
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(target: .init(kind: "mcp_server", id: serverId.uuidString, version: generation.uuidString),
                     toolVersion: revision.uuidString + ":" + AskToolPolicy.digest(try encoder.encode(tool.toolDef)),
                     serverId: serverId.uuidString, serverVersion: generation.uuidString,
                     summary: (serverConfigs[serverId]?.name ?? "MCP") + " / " + toolName)
    }

    func callApproved(serverId: UUID, toolName: String, arguments: String,
                      binding: AskToolBinding, authorize: @MainActor () throws -> Void = {}) async throws -> MCPToolsCallResult {
        try await authorize()
        guard try approvalBinding(serverId: serverId, toolName: toolName) == binding,
              let tool = cachedTools[ToolKey(serverId: serverId, name: toolName)] else {
            throw AskLocalError.message(L("ask.approval.changed"))
        }
        try Task.checkCancellation()
        return try await tool.call(arguments: arguments)
    }

    /// Reconnects all servers with autoConnect enabled.
    func connectAutoConnectServers() async {
        await connectSavedServers(automaticOnly: true)
    }

    /// Work discovers tools on demand, including servers that do not connect at startup.
    func connectSavedServers(automaticOnly: Bool = false) async {
        for id in savedConnections where !hasCurrentConfig(id) {
            await removeServer(id: id)
        }
        for config in settingsStore.servers where config.enabled && (!automaticOnly || config.autoConnect) {
            try? await addServer(config, fromSettings: true)
        }
    }

    private func hasCurrentConfig(_ id: UUID) -> Bool {
        guard let config = serverConfigs[id], config.enabled else { return false }
        return settingsStore.servers.contains(config)
    }

    /// Connects all enabled servers in the given list (skips already-connected ones).
    func connectEnabledServers(_ configs: [MCPServerConfig]) async {
        for config in configs where config.enabled {
            try? await addServer(config)
        }
    }

    /// Returns the number of connected servers.
    var connectedServerCount: Int {
        get async {
            var count = 0
            for client in servers.values where await client.isConnected {
                count += 1
            }
            return count
        }
    }

    /// Bulk/background connects retain their failure reason for diagnostics.
    func lastConnectionError(for serverId: UUID) -> String? {
        connectionErrors[serverId]
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
                                                       authorizer: MCPOAuthAuthorizer(
                                                           resource: url,
                                                           interactive: false
                                                       )))
        }
    }

    func refreshTools(for serverId: UUID) async throws {
        guard let generation = generations[serverId] else { return }
        try await refreshTools(for: serverId, generation: generation)
    }

    private func refreshTools(for serverId: UUID, generation: UUID) async throws {
        guard generations[serverId] == generation else { return }
        guard let client = servers[serverId] else { return }
        do {
            let tools = try await client.listTools()
            try Task.checkCancellation()
            guard generations[serverId] == generation else { throw MCPClientError.notConnected }
            cachedTools = cachedTools.filter { $0.key.serverId != serverId }
            toolRevisions = toolRevisions.filter { $0.key.serverId != serverId }
            for toolDef in tools {
                toolRevisions[ToolKey(serverId: serverId, name: toolDef.name)] = UUID()
                cachedTools[ToolKey(serverId: serverId, name: toolDef.name)] = MCPToolAdapter(
                    client: client,
                    toolDef: toolDef
                )
            }
            connectionErrors[serverId] = nil
            await publishAuthorizationInventory()
        } catch {
            if generations[serverId] == generation {
                cachedTools = cachedTools.filter { $0.key.serverId != serverId }
                connectionErrors[serverId] = error.localizedDescription
            }
            throw error
        }
    }
}

struct MCPRegisteredTool {
    let serverId: UUID
    let serverName: String
    let tool: MCPToolAdapter

    func askDefinition(named name: String) -> AskToolDefinition? {
        let definition = tool.definition
        guard let data = try? JSONSerialization.data(withJSONObject: definition.inputSchema.jsonObject,
                                                     options: .sortedKeys) else { return nil }
        let description = "MCP server: \(serverName.prefix(200)). \(definition.description)"
        return .init(name: name, description: String(description.prefix(2000)), parameters: JSONValue(data: data), mcpServer: String(serverName.prefix(200)))
    }
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
