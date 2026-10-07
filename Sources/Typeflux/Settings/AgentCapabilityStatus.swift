import Foundation

/// What Ask can use, as summarized on the Agent overview.
enum AgentCapability: String, CaseIterable, Identifiable {
    case webSearch
    case imageGeneration
    case files
    case codeExecution
    case automation
    case skills
    case mcpServers

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .webSearch: L("agent.capability.webSearch.title")
        case .imageGeneration: L("imagegen.title")
        case .files: L("agent.capability.files.title")
        case .codeExecution: L("agent.capability.code.title")
        case .automation: L("agent.capability.automation.title")
        case .skills: L("agent.section.skills")
        case .mcpServers: L("agent.settings.mcp")
        }
    }

    var summary: String {
        switch self {
        case .webSearch: L("agent.capability.webSearch.summary")
        case .imageGeneration: L("imagegen.summary")
        case .files: L("agent.capability.files.summary")
        case .codeExecution: L("agent.capability.code.summary")
        case .automation: L("agent.capability.automation.summary")
        case .skills: L("agent.capability.skills.summary")
        case .mcpServers: L("agent.capability.mcp.summary")
        }
    }

    var symbol: String {
        switch self {
        case .webSearch: "globe"
        case .imageGeneration: "photo.badge.plus"
        case .files: "folder"
        case .codeExecution: "terminal"
        case .automation: "cursorarrow.click.2"
        case .skills: "wand.and.stars"
        case .mcpServers: "server.rack"
        }
    }

    /// The settings pane that configures the capability.
    var pane: AgentSettingsPane {
        switch self {
        case .webSearch: .webSearch
        case .imageGeneration: .imageGeneration
        case .files: .files
        case .codeExecution: .codeExecution
        case .automation: .automation
        case .skills: .skills
        case .mcpServers: .mcpServers
        }
    }
}

/// A search setting the user still has to fill in before search can run.
enum AgentSearchField: String, CaseIterable {
    case apiKey
    case accountID
    case gatewayID
    case byokAlias

    func title(for provider: AskSearchSettings.Provider) -> String {
        switch self {
        case .apiKey: L(provider == .cloudflare ? "ask.settings.search.cloudflare.token" : "ask.settings.search.key")
        case .accountID: L("ask.settings.search.cloudflare.account")
        case .gatewayID: L("ask.settings.search.cloudflare.gateway")
        case .byokAlias: L("ask.settings.search.cloudflare.alias")
        }
    }

    /// Fields that are missing or malformed for the selected provider, in form order.
    static func missing(in configuration: AskSearchConfiguration) -> [AgentSearchField] {
        guard configuration.provider != .none else { return [] }
        var fields: [AgentSearchField] = []
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || key.contains("\n") || key.contains("\r") { fields.append(.apiKey) }
        guard configuration.provider == .cloudflare else { return fields }
        let value = configuration.cloudflare.normalized
        if value.accountID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) == nil { fields.append(.accountID) }
        if !isIdentifier(value.gatewayID) { fields.append(.gatewayID) }
        if !value.byokAlias.isEmpty, !isIdentifier(value.byokAlias) { fields.append(.byokAlias) }
        return fields
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}

/// Everything the overview needs to describe the Agent's capabilities.
struct AgentCapabilityInputs: Equatable {
    var newConversationsStayLocal = false
    var searchProvider: AskSearchSettings.Provider = .none
    var missingSearchFields: [AgentSearchField] = []
    var folderCount = 0
    var codeExecutionEnabled = true
    var accessibilityGranted = false
    var screenRecordingGranted = false
    var skillCount = 0
    var enabledSkillCount = 0
    var mcpServerCount = 0
    var enabledMCPServerCount = 0
    var imageGenerationEnabled = false
    var imageGenerationReady = false
}

struct AgentCapabilityStatus: Equatable, Identifiable {
    enum Level: Equatable {
        /// Usable now.
        case ready
        /// Turned on or needed, but blocked by missing setup.
        case attention
        /// Deliberately off or empty.
        case off
    }

    let capability: AgentCapability
    let level: Level
    let label: String

    var id: String {
        capability.id
    }

    static func searchProviderName(_ provider: AskSearchSettings.Provider) -> String {
        switch provider {
        case .none: L("ask.settings.search.none")
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        case .cloudflare: "Cloudflare Web Search"
        }
    }

    /// The MCP servers' state for a server list, without the rest of the inputs.
    static func mcpStatus(for servers: [MCPServerConfig]) -> AgentCapabilityStatus {
        status(of: .mcpServers, inputs: AgentCapabilityInputs(mcpServerCount: servers.count,
                                                              enabledMCPServerCount: servers.filter(\.enabled).count))
    }

    static func statuses(for inputs: AgentCapabilityInputs) -> [AgentCapabilityStatus] {
        AgentCapability.allCases.map { status(of: $0, inputs: inputs) }
    }

    static func status(of capability: AgentCapability, inputs: AgentCapabilityInputs) -> AgentCapabilityStatus {
        let (level, label): (Level, String) = switch capability {
        case .imageGeneration:
            !inputs.imageGenerationEnabled ? (.off, L("agent.status.off"))
                : (inputs.imageGenerationReady ? (.ready, L("imagegen.ready")) : (.attention, L("imagegen.incomplete")))
        case .webSearch:
            if inputs.searchProvider == .none {
                // Private conversations have no other way to reach the web.
                inputs.newConversationsStayLocal
                    ? (.attention, L("agent.status.search.localOffline"))
                    : (.off, L("agent.status.off"))
            } else if !inputs.missingSearchFields.isEmpty {
                (.attention, L("agent.status.search.incomplete"))
            } else {
                (.ready, searchProviderName(inputs.searchProvider))
            }
        case .files:
            inputs.folderCount > 0
                ? (.ready, L("agent.status.files.count", inputs.folderCount))
                : (.off, L("agent.status.files.none"))
        case .codeExecution:
            inputs.codeExecutionEnabled
                ? (.ready, L("agent.status.code.on"))
                : (.off, L("agent.status.code.off"))
        case .automation:
            inputs.accessibilityGranted && inputs.screenRecordingGranted
                ? (.ready, L("agent.status.automation.ready"))
                : (.attention, L("agent.status.automation.missing"))
        case .skills:
            (inputs.enabledSkillCount > 0 ? .ready : .off,
             L("agent.status.skills.count", inputs.enabledSkillCount, inputs.skillCount))
        case .mcpServers:
            inputs.mcpServerCount == 0
                ? (.off, L("agent.status.mcp.none"))
                : (inputs.enabledMCPServerCount > 0 ? .ready : .off,
                   L("agent.status.mcp.count", inputs.enabledMCPServerCount))
        }
        return AgentCapabilityStatus(capability: capability, level: level, label: label)
    }
}
