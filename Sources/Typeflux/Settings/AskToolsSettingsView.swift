import AppKit
import SwiftUI

/// Settings for Ask's local tools: authorized folders, code execution, skills and saved notes.
struct AskToolsSettingsView: View {
    let settings: SettingsStore
    var skills = AskSkillLibrary()
    var notes: AskMemoryNoteStore = .shared
    var owner: () -> String = { GlobalSoulOwner.currentID }

    @State private var folders: [String] = []
    @State private var codeEnabled = true
    @State private var localMode = false
    @State private var searchProvider = AskSearchSettings.Provider.none
    @State private var searchKey = ""
    @State private var skillList: [AskSkill] = []
    @State private var noteList: [AskMemoryNote] = []

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                    StudioSettingRow(title: L("ask.settings.local.title"), subtitle: L("ask.settings.local.subtitle")) {
                        Toggle("", isOn: Binding(get: { localMode }, set: { localMode = $0; settings.askLocalModeEnabled = $0 }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    sectionHeader(L("ask.settings.search.title"), L("ask.settings.search.subtitle"))
                    Picker(L("ask.settings.search.provider"), selection: Binding(get: { searchProvider }, set: { setSearchProvider($0) })) {
                        Text(L("ask.settings.search.none")).tag(AskSearchSettings.Provider.none)
                        Text("Tavily").tag(AskSearchSettings.Provider.tavily)
                        Text("Brave Search").tag(AskSearchSettings.Provider.brave)
                    }
                    .frame(maxWidth: 320)
                    if searchProvider != .none {
                        SecureField(L("ask.settings.search.key"), text: $searchKey, onCommit: { saveSearchKey() })
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                            .onChange(of: searchKey) { _ in saveSearchKey() }
                    }
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                    sectionHeader(L("ask.settings.folders.title"), L("ask.settings.folders.subtitle"))
                    if folders.isEmpty {
                        Text(L("ask.settings.folders.empty")).foregroundStyle(StudioTheme.textSecondary)
                    }
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button(L("ask.remove")) { removeFolder(folder) }
                        }
                    }
                    StudioButton(title: L("ask.settings.folders.add"), systemImage: "plus.circle.fill", variant: .secondary) { addFolder() }
                }
            }
            StudioCard {
                StudioSettingRow(title: L("ask.settings.code.title"), subtitle: L("ask.settings.code.subtitle")) {
                    Toggle("", isOn: Binding(get: { codeEnabled }, set: { codeEnabled = $0; settings.askCodeExecutionEnabled = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                    sectionHeader(L("ask.settings.skills.title"), L("ask.settings.skills.subtitle"))
                    ForEach(skillList, id: \.name) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(skill.name).font(.system(size: 12.5, weight: .semibold))
                                if skill.directory == nil { StudioPill(title: L("ask.settings.skills.builtin")) }
                            }
                            Text(skill.description).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                    StudioButton(title: L("ask.settings.skills.open"), systemImage: "folder", variant: .secondary) { openSkillsFolder() }
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                    sectionHeader(L("ask.settings.notes.title"), L("ask.settings.notes.subtitle"))
                    if noteList.isEmpty {
                        Text(L("ask.settings.notes.empty")).foregroundStyle(StudioTheme.textSecondary)
                    }
                    ForEach(noteList) { note in
                        HStack(alignment: .firstTextBaseline) {
                            Text(note.text).textSelection(.enabled)
                            Spacer()
                            Button(L("ask.remove")) { removeNote(note) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
        }
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
