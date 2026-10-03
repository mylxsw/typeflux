import AppKit
import SwiftUI

/// Ask settings: where it runs, web search, local tools, skills and saved notes.
struct AskToolsSettingsView: View {
    let settings: SettingsStore
    var skills = AskSkillLibrary()
    var notes: AskMemoryNoteStore = .shared
    var owner: () -> String = { GlobalSoulOwner.currentID }

    @State private var folders: [String] = []
    @State private var codeEnabled = true
    @State private var newConversationsStayLocal = false
    @State private var searchProvider = AskSearchSettings.Provider.none
    @State private var searchKey = ""
    @State private var skillList: [AskSkill] = []
    @State private var disabledSkills: Set<String> = []
    @StateObject var memoryNotes = AskMemoryNotesSettingsModel()
    @State private var showingInstall = false
    @State private var installURL = ""
    @State private var installing = false
    @State private var installError: String?
    @State private var installTask: Task<Void, Never>?
    @State private var pendingRemoval: AskSkill?
    @State private var skillActionError: String?

    /// Which Agent settings tab to render; MCP servers are owned by the settings view model.
    var tab: AgentConfigurationTab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch tab {
            case .general:
                generalSections
            case .tools:
                toolSections
            case .skills:
                skillSections
            case .memory:
                memorySections
            case .mcpServers:
                EmptyView()
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private var generalSections: some View {
        AgentSettingsSection(title: L("agent.settings.runMode")) {
            AgentSettingsRow(icon: newConversationsStayLocal ? "lock" : "cloud", title: L("ask.settings.local.title"),
                             subtitle: L("ask.settings.local.subtitle"), subtitleLineLimit: nil) {
                selectorMenu(Self.storageName(local: newConversationsStayLocal),
                             label: L("ask.settings.local.title")) {
                    ForEach([false, true], id: \.self) { local in
                        Button(Self.storageName(local: local)) { setNewConversationsStayLocal(local) }
                    }
                }
            }
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

    private var searchProviderMenu: some View {
        selectorMenu(Self.searchProviderName(searchProvider), label: L("ask.settings.search.provider")) {
            ForEach(AskSearchSettings.Provider.allCases, id: \.self) { provider in
                Button(Self.searchProviderName(provider)) { setSearchProvider(provider) }
            }
        }
    }

    static func storageName(local: Bool) -> String {
        L(local ? "ask.storage.local" : "ask.storage.cloud")
    }

    /// A pop-up styled like the Models page selectors.
    private func selectorMenu<Items: View>(_ value: String, label: String,
                                           @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Text(value)
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
        .accessibilityLabel(label)
    }

    static func searchProviderName(_ provider: AskSearchSettings.Provider) -> String {
        switch provider {
        case .none: L("ask.settings.search.none")
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        }
    }

    @ViewBuilder private var toolSections: some View {
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

    @ViewBuilder private var skillSections: some View {
        AgentSettingsSection(title: L("ask.settings.skills.title"), detail: "\(skillList.count)",
                             footnote: L("ask.settings.skills.subtitle")) {
            ForEach(skillList, id: \.name) { skill in
                skillRow(skill)
                ModelRowDivider(leading: 66)
            }
            AgentSettingsActionRow(icon: "arrow.down.circle", title: L("ask.settings.skills.install")) {
                installError = nil
                installURL = ""
                showingInstall = true
            }
            ModelRowDivider(leading: 66)
            AgentSettingsActionRow(icon: "folder", title: L("ask.settings.skills.open")) { openSkillsFolder() }
        }
        .sheet(isPresented: $showingInstall) { installSheet }
        .alert(L("ask.settings.skills.actionFailed"), isPresented: Binding(
            get: { skillActionError != nil }, set: { if !$0 { skillActionError = nil } }
        )) {
            Button(L("common.ok")) { skillActionError = nil }
        } message: {
            Text(skillActionError ?? "")
        }
        .alert(L("ask.settings.skills.removeTitle"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button(L("ask.remove"), role: .destructive) {
                if let skill = pendingRemoval { removeSkill(skill) }
                pendingRemoval = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(String(format: L("ask.settings.skills.removeMessage"), pendingRemoval?.name ?? ""))
        }
    }

    private func skillRow(_ skill: AskSkill) -> some View {
        let source = skills.source(of: skill)
        let badge = skill.directory == nil ? L("ask.settings.skills.builtin")
            : source == nil ? L("ask.settings.skills.local") : "GitHub"
        return AgentSettingsRow(icon: "wand.and.stars", title: skill.name,
                                subtitle: skill.displayDescription, badge: badge) {
            HStack(spacing: 10) {
                if skills.hasPreviousVersion(of: skill) {
                    AgentSettingsIconButton(systemImage: "arrow.uturn.backward",
                                            help: L("ask.settings.skills.rollback")) {
                        do {
                            try skills.rollback(skill)
                            reload()
                        } catch {
                            skillActionError = error.localizedDescription
                        }
                    }
                }
                if skill.directory != nil {
                    AgentSettingsIconButton(systemImage: "trash", help: L("ask.remove"), role: .destructive) {
                        pendingRemoval = skill
                    }
                }
                // A turned-off skill is neither offered to the model nor loaded.
                Toggle("", isOn: Binding(get: { !disabledSkills.contains(skill.name) },
                                         set: { setSkill(skill.name, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(skill.name)
            }
        }
        .help(source.map(Self.skillSourceDescription) ?? "")
    }

    static func skillSourceDescription(_ source: AskSkillSource) -> String {
        let version = source.commit ?? L("ask.settings.skills.unverifiedVersion")
        let declarations = (source.declaredPermissions ?? []).joined(separator: ", ")
        return "\(source.repository)@\(source.ref)\n\(version)\n\(source.path)"
            + (declarations.isEmpty ? "" : "\n" + L("ask.settings.skills.declarations") + " " + declarations)
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.settings.skills.installTitle"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("ask.settings.skills.installHint"))
                .font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/owner/repo/tree/main/skills/name", text: $installURL)
                .textFieldStyle(ModelFieldStyle())
                .disabled(installing)
                .onSubmit { startInstall() }
            Text(L("ask.settings.skills.installWarning"))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let installError {
                Text(installError).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { installTask?.cancel(); showingInstall = false }
                    .buttonStyle(ModelActionStyle())
                Button {
                    startInstall()
                } label: {
                    HStack(spacing: 6) {
                        if installing { ProgressView().controlSize(.small) }
                        Text(L(installing ? "ask.settings.skills.installing" : "ask.settings.skills.installAction"))
                    }
                }
                .buttonStyle(ModelActionStyle(primary: true))
                .disabled(installing || installURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(ModelVisualStyle.canvas)
    }

    @ViewBuilder private var memorySections: some View {
        AgentSettingsSection(title: L("ask.settings.notes.title"), detail: "\(memoryNotes.notes.count)",
                             footnote: L("ask.settings.notes.subtitle")) {
            if memoryNotes.notes.isEmpty {
                AgentSettingsEmptyRow(text: L("ask.settings.notes.empty"))
            }
            ForEach(Array(memoryNotes.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { ModelRowDivider(leading: 66) }
                AgentSettingsRow(icon: "brain", title: note.text, titleLineLimit: nil) {
                    AgentSettingsIconButton(systemImage: "trash", help: L("ask.remove"), role: .destructive) {
                        removeNote(note)
                    }
                }
            }
        }
        if let error = memoryNotes.error {
            Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func setSkill(_ name: String, enabled: Bool) {
        var disabled = settings.askDisabledSkills
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        settings.askDisabledSkills = disabled
        disabledSkills = disabled
    }

    private func startInstall() {
        let url = installURL
        guard !installing, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        installing = true
        installError = nil
        installTask = Task { @MainActor in
            defer { installing = false; installTask = nil }
            do {
                _ = try await AskSkillInstaller(library: skills).install(from: url)
                guard !Task.isCancelled else { return }
                reload()
                showingInstall = false
            } catch is CancellationError {
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    func removeSkill(_ skill: AskSkill) {
        do {
            try skills.remove(skill)
            // Explicit removal resets the name preference; updates and rollback preserve it.
            if settings.askDisabledSkills.contains(skill.name) { setSkill(skill.name, enabled: true) }
            reload()
        } catch {
            skillActionError = error.localizedDescription
        }
    }

    var search: AskSearchSettings { AskSearchSettings(defaults: settings.defaults) }

    func setNewConversationsStayLocal(_ local: Bool) {
        newConversationsStayLocal = local
        settings.askNewConversationsStayLocal = local
    }

    func setSearchProvider(_ provider: AskSearchSettings.Provider) {
        searchProvider = provider
        search.provider = provider
        if provider == .none { search.setAPIKey(""); searchKey = "" }
    }

    func saveSearchKey() { search.setAPIKey(searchKey) }

    func reload() {
        folders = settings.askFileAccessFolders
        codeEnabled = settings.askCodeExecutionEnabled
        newConversationsStayLocal = settings.askNewConversationsStayLocal
        searchProvider = search.provider
        searchKey = search.apiKey
        skillList = skills.skills()
        disabledSkills = settings.askDisabledSkills
        memoryNotes.reload(from: notes, owner: owner())
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
        memoryNotes.remove(note, from: notes, owner: owner())
    }

    private func openSkillsFolder() {
        try? FileManager.default.createDirectory(at: skills.userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skills.userDirectory)
    }
}
