import AppKit
import SwiftUI

/// Agent settings panes: the overview, one pane per built-in capability, skills and saved notes.
/// MCP servers are owned by the settings view model and rendered by `StudioView`.
struct AskToolsSettingsView: View {
    let settings: SettingsStore
    var skills = AskSkillLibrary()
    var notes: AskMemoryNoteStore = .shared
    var owner: () -> String = { GlobalSoulOwner.currentID }

    @State var folders: [String] = []
    @State var codeEnabled = true
    @State var newConversationsStayLocal = false
    @State var searchProvider = AskSearchSettings.Provider.none
    @State var searchKey = ""
    @State var cloudflareSearch = AskCloudflareSearchConfiguration()
    @State var skillList: [AskSkill] = []
    @State var disabledSkills: Set<String> = []
    @StateObject var memoryNotes = AskMemoryNotesSettingsModel()
    @State var showingInstall = false
    @State var installURL = ""
    @State var installing = false
    @State var installError: String?
    @State var installTask: Task<Void, Never>?
    @State var pendingRemoval: AskSkill?
    @State var skillActionError: String?
    @State var skillQuery = ""
    @State var skillFilter = SkillFilter.all
    @State var inspectedSkill: InspectedSkill?
    @State var removedFolder: RemovedFolder?
    @State var mcpServerCount = 0
    @State var enabledMCPServerCount = 0
    @State var accessibilityGranted = false
    @State var screenRecordingGranted = false

    /// Which Agent settings pane to render; the caller renders `.mcpServers` itself.
    var pane: AgentSettingsPane = .overview
    /// Opens another pane, e.g. from the overview's attention list.
    var onNavigate: (AgentSettingsPane) -> Void = { _ in }
    /// Reports capability states so the caller can show them in the pane list.
    var onStatusesChange: ([AgentCapabilityStatus]) -> Void = { _ in }
    var permissions = AgentAutomationPermissions.live

    enum SkillFilter: Hashable { case all, enabled, disabled }

    struct InspectedSkill: Identifiable {
        let name: String
        var id: String {
            name
        }
    }

    struct RemovedFolder: Equatable {
        let path: String
        let index: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch pane {
            case .overview:
                overviewSections
            case .webSearch:
                searchPane
            case .files:
                filesPane
            case .codeExecution:
                codePane
            case .automation:
                automationPane
            case .skills:
                AgentPaneHeader(symbol: AgentCapability.skills.symbol, title: AgentCapability.skills.title,
                                subtitle: AgentCapability.skills.summary) {
                    skillHeaderActions
                }
                skillSections
            case .mcpServers:
                EmptyView()
            case .memory:
                memorySections
            }
        }
        .onAppear(perform: reload)
        .onChange(of: capabilityStatuses) { onStatusesChange($0) }
    }

    // MARK: - Shared state

    var search: AskSearchSettings { AskSearchSettings(defaults: settings.defaults) }

    var searchConfiguration: AskSearchConfiguration {
        AskSearchConfiguration(provider: searchProvider, apiKey: searchKey, cloudflare: cloudflareSearch)
    }

    var missingSearchFields: [AgentSearchField] {
        AgentSearchField.missing(in: searchConfiguration)
    }

    var capabilityInputs: AgentCapabilityInputs {
        AgentCapabilityInputs(
            newConversationsStayLocal: newConversationsStayLocal,
            searchProvider: searchProvider,
            missingSearchFields: missingSearchFields,
            folderCount: folders.count,
            codeExecutionEnabled: codeEnabled,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted,
            skillCount: skillList.count,
            enabledSkillCount: skillList.filter { !disabledSkills.contains($0.name) }.count,
            mcpServerCount: mcpServerCount,
            enabledMCPServerCount: enabledMCPServerCount
        )
    }

    var capabilityStatuses: [AgentCapabilityStatus] {
        AgentCapabilityStatus.statuses(for: capabilityInputs)
    }

    static func storageName(local: Bool) -> String {
        L(local ? "ask.storage.local" : "ask.storage.cloud")
    }

    static func searchProviderName(_ provider: AskSearchSettings.Provider) -> String {
        AgentCapabilityStatus.searchProviderName(provider)
    }

    func reload() {
        folders = settings.askFileAccessFolders
        codeEnabled = settings.askCodeExecutionEnabled
        newConversationsStayLocal = settings.askNewConversationsStayLocal
        searchProvider = search.provider
        searchKey = search.apiKey
        cloudflareSearch = search.cloudflare
        skillList = skills.skills()
        disabledSkills = settings.askDisabledSkills
        let servers = settings.mcpServers
        mcpServerCount = servers.count
        enabledMCPServerCount = servers.filter(\.enabled).count
        accessibilityGranted = permissions.accessibilityGranted()
        screenRecordingGranted = permissions.screenRecordingGranted()
        memoryNotes.reload(from: notes, owner: owner())
        onStatusesChange(capabilityStatuses)
    }

    // MARK: - Actions

    func setNewConversationsStayLocal(_ local: Bool) {
        newConversationsStayLocal = local
        settings.askNewConversationsStayLocal = local
    }

    func setSearchProvider(_ provider: AskSearchSettings.Provider) {
        searchProvider = provider
        search.provider = provider
        searchKey = search.apiKey
    }

    func saveSearchKey() { search.setAPIKey(searchKey) }

    /// Turns local web search on with the provider most likely to be set up, or off.
    func setSearchEnabled(_ enabled: Bool) {
        setSearchProvider(enabled ? Self.providerWhenEnabling(cloudflare: cloudflareSearch) : .none)
    }

    /// Cloudflare when its account is already filled in, otherwise Tavily.
    static func providerWhenEnabling(cloudflare: AskCloudflareSearchConfiguration) -> AskSearchSettings.Provider {
        cloudflare.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .tavily : .cloudflare
    }

    func setCodeExecution(_ enabled: Bool) {
        codeEnabled = enabled
        settings.askCodeExecutionEnabled = enabled
    }

    func setSkill(_ name: String, enabled: Bool) {
        var disabled = settings.askDisabledSkills
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        settings.askDisabledSkills = disabled
        disabledSkills = disabled
    }

    func removeFolder(_ folder: String) {
        let index = settings.askFileAccessFolders.firstIndex(of: folder)
        settings.askFileAccessFolders.removeAll { $0 == folder }
        if let index { removedFolder = RemovedFolder(path: folder, index: index) }
        reload()
    }

    /// Puts the last removed folder back where it was.
    func undoRemoveFolder() {
        guard let removed = removedFolder else { return }
        removedFolder = nil
        settings.askFileAccessFolders = Self.restoring(removed, in: settings.askFileAccessFolders)
        reload()
    }

    /// `list` with the removed folder back at its old position, unless it was added again meanwhile.
    static func restoring(_ removed: RemovedFolder, in list: [String]) -> [String] {
        guard !list.contains(removed.path) else { return list }
        var result = list
        result.insert(removed.path, at: min(max(removed.index, 0), result.count))
        return result
    }

    func removeNote(_ note: AskMemoryNote) {
        memoryNotes.remove(note, from: notes, owner: owner())
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("ask.settings.folders.add")
        guard panel.runModal() == .OK else { return }
        settings.askFileAccessFolders += panel.urls.map(\.path)
        reload()
    }

    @ViewBuilder var memorySections: some View {
        AgentPaneHeader(symbol: AgentSettingsPane.memory.symbol, title: AgentSettingsPane.memory.title,
                        subtitle: L("agent.memory.subtitle")) {
            AgentStatusBadge(level: memoryNotes.notes.isEmpty ? .off : .ready,
                             label: L("agent.memory.count", memoryNotes.notes.count))
        }
        MemoryNotesEditorView(model: memoryNotes, store: notes, owner: owner(),
                              correctionsEnabled: MemoryRollout.enabled(settings.defaults))
    }
}
