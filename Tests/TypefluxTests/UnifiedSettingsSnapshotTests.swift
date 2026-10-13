import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Unified settings style and appearance matrix", .exclusiveUIState)
@MainActor
struct UnifiedSettingsSnapshotTests {
    /// The acceptance owner opts in to PNG export; no files are committed as baselines.
    @Test func `personas agent launcher and sheets`() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_UNIFIED_SETTINGS_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: path)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("unified-settings-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            settings.askFileAccessFolders = ["/Users/fixture/Documents", "/Users/fixture/Projects"]
            settings.askNewConversationsStayLocal = true
            settings.askLauncherKeywords = AskPluginRegistry.defaultKeywords
            let custom = PersonaProfile(name: "Weekly report", prompt: "Describe progress, plans and risks.")
            settings.personas += [custom]
            settings.savePersonaAppBinding(appIdentifier: "com.apple.mail", personaID: custom.id)
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                                        initialSection: .personas,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            let workflows = AskWorkflowStore(settings: settings, root: root.appendingPathComponent("Workflows"))
            let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"))
            _ = try notes.add("Prefers concise answers", owner: "fixture")
            let skills = AskSkillLibrary(userDirectory: root.appendingPathComponent("Skills"))
            let images = AskImageSettingsModel(store: AskImageSettings(
                defaults: settings.defaults,
                keys: AskImageKeyStore(read: { _ in "" }, write: { _, _ in })
            ), discover: { _, _ in [] })
            try await personas(model: model, custom: custom, images: images, output: output)
            try await agent(settings: settings, model: model, skills: skills, notes: notes, images: images,
                            output: output)
            try await launcher(settings: settings, workflows: workflows, output: output)
            try await sheets(settings: settings, model: model, workflows: workflows, output: output)
        }
    }

    private func personas(model: StudioViewModel, custom: PersonaProfile, images: AskImageSettingsModel,
                          output: URL) async throws {
        model.selectPersona(SettingsStore.defaultPersonaID)
        try await capture(StudioView(viewModel: model, imageSettingsModel: images), "personas-built-in", output,
                          wide: true, model: model)
        model.selectPersona(custom.id)
        model.personaDraftPrompt += "\nKeep it brief."
        try await capture(StudioView(viewModel: model, imageSettingsModel: images), "personas-dirty", output,
                          wide: true, model: model)
        model.cancelPersonaEditing()
        model.beginCreatingPersona(name: "New persona")
        try await capture(StudioView(viewModel: model, imageSettingsModel: images), "personas-create", output,
                          wide: true, model: model)
        model.cancelPersonaEditing()
        model.searchQuery = "No matching persona"
        try await capture(StudioPersonaLibraryView(viewModel: model, onDelete: { _ in }), "personas-no-results", output)
        model.searchQuery = ""
        model.personaAppBindingsEnabled = false
        try await capture(StudioPersonaAppRulesDrawer(viewModel: model, discover: { [] }), "persona-rules-paused",
                          output)
        model.personaAppBindingsEnabled = true
        model.personaAppBindings = []
        model.isAddingPersonaAppRule = true
        try await capture(StudioPersonaAppRulesDrawer(viewModel: model, discover: { [] }), "persona-rules-add", output)
        model.isAddingPersonaAppRule = false
    }

    // swiftlint:disable:next function_parameter_count
    private func agent(settings: SettingsStore, model: StudioViewModel, skills: AskSkillLibrary,
                       notes: AskMemoryNoteStore, images: AskImageSettingsModel, output: URL) async throws {
        for pane in AgentSettingsPane.allCases where pane != .mcpServers {
            let view = AskToolsSettingsView(settings: settings, skills: skills, notes: notes, owner: { "fixture" },
                                            imageSettingsModel: images, pane: pane,
                                            permissions: .fixed(accessibility: false, screenRecording: true))
            try await capture(view, "agent-" + pane.rawValue, output)
        }
        images.select(.openRouter)
        images.configuration.size = "1024x1024"
        images.configuration.quality = "high"
        try await capture(AskImageSettingsView(model: images), "agent-image-advanced", output)
        let skill = AskSkill(name: "Review", description: "Review a proposed change", body: "", directory: nil)
        try await capture(AgentSkillDetailView(skill: skill, badge: (text: "Built-in", accent: false), source: nil,
                                               enabled: .constant(true), canRollback: false, onRollback: {},
                                               onReveal: nil, onRemove: nil, onClose: {}), "agent-skill-detail", output)
        let skillPane = AskToolsSettingsView(settings: settings, skills: skills, notes: notes, owner: { "fixture" },
                                             imageSettingsModel: images, pane: .skills)
        try await capture(skillPane.installSheet, "agent-skill-install", output)
        model.currentSection = .agent
        try await capture(StudioView(viewModel: model, agentPane: .mcpServers, imageSettingsModel: images),
                          "mcp-empty", output, wide: true, model: model)
        model.importMCPServers([MCPServerConfig(name: "Local tools", transport: .stdio(.init(command: "tool"))),
                                MCPServerConfig(name: "Disabled", transport: .http(.init(
                                    url: "https://example.invalid/mcp"
                                )), enabled: false)])
        if let server = model.mcpServers.first {
            model.mcpServerTestResults[server.id] = .failure(message: "Connection unavailable")
        }
        try await capture(StudioView(viewModel: model, agentPane: .mcpServers, imageSettingsModel: images),
                          "mcp-error-and-disabled", output, wide: true, model: model)
    }

    private func launcher(settings: SettingsStore, workflows: AskWorkflowStore, output: URL) async throws {
        for pane in [LauncherSettingsPane.basics, .keywords, .translation, .clipboard, .workflows] {
            try await capture(LauncherSettingsView(settings: settings, pane: pane, workflows: workflows),
                              "launcher-" + pane.rawValue, output)
        }
        for tab in LauncherSearchSettingsView.Tab.allCases {
            try await capture(LauncherSearchSettingsView(settings: settings, index: AskTestFileIndex(),
                                                         fullDiskAccess: { true }, tab: tab),
                              "launcher-search-" + tab.rawValue, output)
        }
    }

    private func sheets(settings: SettingsStore, model: StudioViewModel, workflows: AskWorkflowStore,
                        output: URL) async throws {
        for kind in [AskKeywordKind.translate, .prompt, .web, .system] {
            var draft = AskKeywordDraft(adding: kind)
            draft.keyword = "example"
            if kind == .prompt {
                draft.prompt = "Summarize {input}."
            }
            try await capture(AskKeywordEditorSheet(draft: draft, keywords: [], workflows: [],
                                                    onSave: { _ in }, onCancel: {}), "keyword-sheet-" + kind.rawValue,
                              output)
        }
        let hotkeys = HotkeySettingsModel(settingsStore: settings, workflows: workflows)
        try await capture(KeywordHotkeyEditorSheet(model: hotkeys, draft: KeywordHotkeyDraft(adding: nil), onDone: {}),
                          "keyword-hotkey-sheet", output)
        model.beginAddMCPServer()
        try await capture(MCPServerEditorView(viewModel: model, onClose: {}), "mcp-editor-stdio", output)
        model.mcpDraftTransportType = .http
        try await capture(MCPServerEditorView(viewModel: model, onClose: {}), "mcp-editor-http", output)
        try await capture(MCPServerImportSheet(text: .constant("{"), existingNames: [], cancel: {}, confirm: { _ in }),
                          "mcp-import-invalid", output)
        let json = #"{"mcpServers":{"example":{"command":"tool"}}}"#
        try await capture(MCPServerImportSheet(text: .constant(json), existingNames: [], cancel: {}, confirm: { _ in }),
                          "mcp-import-preview", output)
        let fallback = KeywordHotkeyEditorSheet(model: hotkeys, draft: KeywordHotkeyDraft(adding: nil), onDone: {})
            .environment(\.typefluxAccessibilityOptions,
                         TypefluxAccessibilityOptions(reduceTransparency: true, increasedContrast: true))
        try await TypefluxUISnapshot.renderMatrix(fallback, size: NSSize(width: 720, height: 860), directory: output,
                                                  name: "sheet-accessibility-fallback", increasedContrast: true)
    }

    private func capture(_ view: some View, _ name: String, _ output: URL, wide: Bool = false,
                         model: StudioViewModel? = nil) async throws {
        let size = NSSize(width: wide ? 1180 : 720, height: 860)
        if let model {
            for style in InterfaceStyle.allCases {
                model.setInterfaceStyle(style)
                for dark in [false, true] {
                    model.appearanceMode = dark ? .dark : .light
                    try await TypefluxUISnapshot.render(view, size: size, style: style, dark: dark,
                                                        file: output
                                                            .appendingPathComponent(
                                                                "\(name)-\(style.rawValue)-\(dark ? "dark" : "light").png"
                                                            ))
                }
            }
        } else {
            try await TypefluxUISnapshot.renderMatrix(view, size: size, directory: output, name: name)
        }
    }
}
