import AppKit
import SwiftUI

/// Ask settings: where it runs, web search, local tools, skills and saved notes.
struct AskToolsSettingsView: View {
    /// One capability row: where it works and how much it asks first.
    struct Capability: Equatable {
        var key: String
        var symbol: String
        var cloud: String
        var local: String
        var permission: String
    }

    let settings: SettingsStore
    var skills = AskSkillLibrary()
    var notes: AskMemoryNoteStore = .shared
    var owner: () -> String = { GlobalSoulOwner.currentID }
    var isSignedIn: () -> Bool = { AuthState.shared.isLoggedIn }

    @State private var folders: [String] = []
    @State private var codeEnabled = true
    @State private var localMode = false
    @State private var searchProvider = AskSearchSettings.Provider.none
    @State private var searchKey = ""
    @State private var skillList: [AskSkill] = []
    @State private var disabledSkills: Set<String> = []
    @State private var noteList: [AskMemoryNote] = []

    /// Which Agent settings tab to render; MCP servers are owned by the settings view model.
    var tab: AgentConfigurationTab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch tab {
            case .general:
                generalSections
            case .tools:
                toolSections
            case .skillsMemory:
                skillAndMemorySections
            case .mcpServers:
                EmptyView()
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private var generalSections: some View {
        AgentSettingsSection(title: L("agent.settings.runMode")) {
            AgentSettingsRow(icon: "desktopcomputer", title: L("ask.settings.local.title"),
                             subtitle: L("ask.settings.local.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: Binding(get: { localMode }, set: { localMode = $0; settings.askLocalModeEnabled = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            ModelRowDivider(leading: 66)
            locationRow
        }
        AgentSettingsSection(title: L("agent.settings.web")) {
            AgentSettingsRow(icon: "globe", title: L("ask.settings.search.title"),
                             subtitle: L("ask.settings.search.subtitle"), subtitleLineLimit: nil) {
                searchProviderMenu
            }
            if searchProvider != .none {
                ModelRowDivider(leading: 66)
                AgentSettingsRow(icon: "key", title: L("ask.settings.search.key")) {
                    SecureField(L("ask.settings.search.key"), text: $searchKey, onCommit: { saveSearchKey() })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10).frame(width: 240, height: 30)
                        .background(
                            ModelVisualStyle.control,
                            in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                                .strokeBorder(ModelVisualStyle.border)
                        )
                        .onChange(of: searchKey) { _ in saveSearchKey() }
                }
            }
        }
    }

    /// Where Ask runs right now. Cloud needs a sign-in; this Mac always works.
    private var locationRow: some View {
        let signedIn = isSignedIn()
        let local = Self.runsLocally(localMode: localMode, signedIn: signedIn)
        return AgentSettingsRow(icon: local ? "desktopcomputer" : "cloud",
                                title: L(local ? "ask.settings.location.local" : "ask.settings.location.cloud"),
                                subtitle: Self.locationDetail(local: local, signedIn: signedIn),
                                badge: L("ask.settings.location.current"), subtitleLineLimit: nil)
    }

    static func runsLocally(localMode: Bool, signedIn: Bool) -> Bool { localMode || !signedIn }

    static func locationDetail(local: Bool, signedIn: Bool) -> String {
        guard local else { return L("ask.settings.location.cloud.detail") }
        let detail = L("ask.settings.location.local.detail")
        return signedIn ? detail : detail + " " + L("ask.settings.location.cloud.signIn")
    }

    private var searchProviderMenu: some View {
        Menu {
            ForEach(AskSearchSettings.Provider.allCases, id: \.self) { provider in
                Button(Self.searchProviderName(provider)) { setSearchProvider(provider) }
            }
        } label: {
            Text(Self.searchProviderName(searchProvider))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same up/down indicator as the Models page selectors; clicks fall through to the menu.
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .allowsHitTesting(false)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(width: 160, height: 30, alignment: .leading)
        .background(
            ModelVisualStyle.control,
            in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                .strokeBorder(ModelVisualStyle.border)
        )
        .accessibilityLabel(L("ask.settings.search.provider"))
    }

    static func searchProviderName(_ provider: AskSearchSettings.Provider) -> String {
        switch provider {
        case .none: L("ask.settings.search.none")
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        }
    }

    @ViewBuilder private var toolSections: some View {
        AgentSettingsSection(title: L("ask.settings.capabilities.title"), footnote: L("ask.settings.capabilities.subtitle")) {
            capabilityTable.padding(.horizontal, 18).padding(.vertical, 14)
        }
        AgentSettingsSection(title: L("agent.settings.code")) {
            AgentSettingsRow(icon: "terminal", title: L("ask.settings.code.title"),
                             subtitle: L("ask.settings.code.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: Binding(get: { codeEnabled }, set: { codeEnabled = $0; settings.askCodeExecutionEnabled = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        AgentSettingsSection(title: L("ask.settings.folders.title"), detail: "\(folders.count)",
                             footnote: L("ask.settings.folders.subtitle")) {
            ForEach(folders, id: \.self) { folder in
                AgentSettingsRow(icon: "folder", title: (folder as NSString).lastPathComponent,
                                 subtitle: folder, subtitleLineLimit: 1) {
                    AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) { removeFolder(folder) }
                }
                ModelRowDivider(leading: 66)
            }
            AgentSettingsActionRow(icon: "plus", title: L("ask.settings.folders.add")) { addFolder() }
        }
    }

    @ViewBuilder private var skillAndMemorySections: some View {
        AgentSettingsSection(title: L("ask.settings.skills.title"), detail: "\(skillList.count)",
                             footnote: L("ask.settings.skills.subtitle")) {
            ForEach(skillList, id: \.name) { skill in
                AgentSettingsRow(icon: "wand.and.stars", title: skill.name, subtitle: skill.displayDescription,
                                 badge: skill.directory == nil ? L("ask.settings.skills.builtin") : nil) {
                    // A turned-off skill is neither offered to the model nor loaded.
                    Toggle("", isOn: Binding(get: { !disabledSkills.contains(skill.name) },
                                             set: { setSkill(skill.name, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(skill.name)
                }
                ModelRowDivider(leading: 66)
            }
            AgentSettingsActionRow(icon: "folder", title: L("ask.settings.skills.open")) { openSkillsFolder() }
        }
        AgentSettingsSection(title: L("ask.settings.notes.title"), detail: "\(noteList.count)",
                             footnote: L("ask.settings.notes.subtitle")) {
            if noteList.isEmpty {
                AgentSettingsEmptyRow(text: L("ask.settings.notes.empty"))
            }
            ForEach(Array(noteList.enumerated()), id: \.element.id) { index, note in
                if index > 0 { ModelRowDivider(leading: 66) }
                AgentSettingsRow(icon: "brain", title: note.text, titleLineLimit: nil) {
                    AgentSettingsIconButton(systemImage: "trash", help: L("ask.remove"), role: .destructive) {
                        removeNote(note)
                    }
                }
            }
        }
    }

    private var capabilityTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
            GridRow {
                ForEach(["ask.settings.capabilities.name", "ask.settings.location.cloud", "ask.settings.location.local",
                         "ask.settings.capabilities.permission"], id: \.self) { key in
                    Text(L(key)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Self.capabilities(searchProvider: searchProvider, folders: folders.count, codeEnabled: codeEnabled),
                    id: \.key) { item in
                GridRow {
                    Label(L("ask.settings.capability." + item.key), systemImage: item.symbol).font(.system(size: 13))
                    Text(item.cloud).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    Text(item.local).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    Text(item.permission).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The capability table. Approvals follow the tool risk tiers: reads and writes ask
    /// and can be allowed for a conversation; destructive calls ask every time.
    static func capabilities(searchProvider: AskSearchSettings.Provider, folders: Int, codeEnabled: Bool) -> [Capability] {
        let yes = L("ask.settings.capabilities.available")
        let off = L("ask.settings.off")
        let noFolders = L("ask.settings.capabilities.noFolders")
        let ask = L("ask.settings.permission.ask")
        return [
            Capability(key: "web", symbol: "magnifyingglass", cloud: yes,
                       local: searchProvider == .none ? L("ask.settings.capabilities.readOnlyWeb") : yes,
                       permission: L("ask.settings.permission.auto")),
            Capability(key: "files", symbol: "folder", cloud: folders == 0 ? noFolders : yes,
                       local: folders == 0 ? noFolders : yes, permission: ask),
            Capability(key: "code", symbol: "terminal", cloud: codeEnabled ? yes : off, local: codeEnabled ? yes : off,
                       permission: ask),
            Capability(key: "computer", symbol: "desktopcomputer", cloud: yes, local: yes, permission: ask),
            Capability(key: "mcp", symbol: "point.3.connected.trianglepath.dotted", cloud: yes, local: yes,
                       permission: L("ask.settings.permission.mcp")),
            Capability(key: "memory", symbol: "brain", cloud: yes, local: yes, permission: ask)
        ]
    }

    func setSkill(_ name: String, enabled: Bool) {
        var disabled = settings.askDisabledSkills
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        settings.askDisabledSkills = disabled
        disabledSkills = disabled
    }

    var search: AskSearchSettings { AskSearchSettings(defaults: settings.defaults) }

    func setSearchProvider(_ provider: AskSearchSettings.Provider) {
        searchProvider = provider
        search.provider = provider
        if provider == .none { search.setAPIKey(""); searchKey = "" }
    }

    func saveSearchKey() { search.setAPIKey(searchKey) }

    func reload() {
        folders = settings.askFileAccessFolders
        codeEnabled = settings.askCodeExecutionEnabled
        localMode = settings.askLocalModeEnabled
        searchProvider = search.provider
        searchKey = search.apiKey
        skillList = skills.skills()
        disabledSkills = settings.askDisabledSkills
        noteList = notes.list(owner: owner())
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("ask.settings.folders.add")
        guard panel.runModal() == .OK else { return }
        settings.askFileAccessFolders += panel.urls.map(\.path)
        reload()
    }

    func removeFolder(_ folder: String) {
        settings.askFileAccessFolders.removeAll { $0 == folder }
        reload()
    }

    func removeNote(_ note: AskMemoryNote) {
        _ = try? notes.remove(id: note.id, owner: owner())
        reload()
    }

    private func openSkillsFolder() {
        try? FileManager.default.createDirectory(at: skills.userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skills.userDirectory)
    }
}
