import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Unified Persona, Agent and Launcher settings", .exclusiveUIState)
@MainActor
struct UnifiedSettingsBehaviorTests {
    private typealias Controls = SettingsBehaviorTestSupport

    @Test func `capability states use library tones`() {
        #expect(AgentCapabilityStatus.Level.ready.tone == .success)
        #expect(AgentCapabilityStatus.Level.attention.tone == .warning)
        #expect(AgentCapabilityStatus.Level.off.tone == .inactive)
    }

    @Test func `keyword sheet keeps validation and save action`() async throws {
        try await Controls.withFixture { _ in
            var draft = AskKeywordDraft(adding: .web)
            draft.keyword = "lookup"
            draft.aliases = ["find"]
            var saved: AskKeyword?
            let view = AskKeywordEditorSheet(draft: draft, keywords: [], workflows: [],
                                             onSave: { saved = $0 }, onCancel: {})
            try await Controls.withWindow(view, width: 560, height: 580) { _, host in
                try await Controls.wait { Controls.contains("lookup", in: host) }
                try control("ask.settings.keywords.sheet.save", in: host).press()
                #expect(saved?.keyword == "lookup")
                #expect(saved?.aliases == ["find"])
                #expect(saved?.pluginID == AskWebSearchPlugin.id)
            }
            draft.keyword = "already-used"
            let occupied = AskKeyword(keyword: draft.keyword, pluginID: AskPromptPlugin.id)
            try await Controls.withWindow(AskKeywordEditorSheet(draft: draft, keywords: [occupied], workflows: [],
                                                                onSave: { saved = $0 }, onCancel: {}),
                                          width: 560, height: 580) { _, host in
                let save = try control("ask.settings.keywords.sheet.save", in: host)
                #expect(save.value("isAccessibilityEnabled") as? Bool == false)
                #expect(saved?.keyword == "lookup")
            }
        }
    }

    @Test func `keyword sheet cancel does not save`() async throws {
        try await Controls.withFixture { _ in
            var cancelled = false
            var saved = false
            let view = AskKeywordEditorSheet(draft: AskKeywordDraft(adding: .prompt), keywords: [], workflows: [],
                                             onSave: { _ in saved = true }, onCancel: { cancelled = true })
            try await Controls.withWindow(view, width: 560, height: 580) { _, host in
                try control("typeflux.sheet.cancel", in: host).press()
                #expect(cancelled)
                #expect(!saved)
            }
        }
    }

    @Test func `import sheet rejects invalid JSON and previews unique names`() async throws {
        try await Controls.withFixture { _ in
            for text in ["{", #"{"mcpServers":{"example":{"command":"tool"}}}"#] {
                var imported: [MCPServerConfig] = []
                let view = MCPServerImportSheet(text: .constant(text), existingNames: ["example"],
                                                cancel: {}, confirm: { imported = $0 })
                try await Controls.withWindow(view, width: 520, height: 400) { _, host in
                    let save = try control("typeflux.sheet.confirm", in: host)
                    if text == "{" {
                        #expect(save.value("isAccessibilityEnabled") as? Bool == false)
                        #expect(imported.isEmpty)
                    } else {
                        try save.press()
                        #expect(imported.map(\.name) == ["example 2"])
                    }
                }
            }
        }
    }

    @Test func `browser switch still persists after form migration`() async throws {
        try await Controls.withFixture { settings in
            settings.askBrowserSearchSettings.tabsEnabled = false
            let view = LauncherSearchSettingsView(settings: settings, index: AskTestFileIndex(),
                                                  fullDiskAccess: { true }, tab: .browsers)
            try await Controls.withWindow(view, width: 640, height: 900) { _, host in
                let identifier = "launcher.search.browser.tab.enabled"
                try await Controls.wait { Controls.elements(in: host).contains {
                    $0.value("accessibilityIdentifier") as? String == identifier
                } }
                try control(identifier, in: host).press()
                #expect(settings.askBrowserSearchSettings.tabsEnabled)
                try control(identifier, in: host).press()
                #expect(!settings.askBrowserSearchSettings.tabsEnabled)
            }
        }
    }

    @Test
    func `native persona list selection protects unsaved drafts`() async throws {
        try await Controls.withFixture { _ in
            let fixture = try PersonaLibraryFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            try await Controls.withWindow(StudioPersonaRosterView(viewModel: model, onDelete: { _ in }),
                                          width: 300, height: 800) { _, host in
                @MainActor func tables(in view: NSView) -> [NSTableView] {
                    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
                }
                let firstTable = tables(in: host).first
                let table = try #require(firstTable)
                @MainActor func row(_ title: String) throws -> Int {
                    let index = (0 ..< table.numberOfRows).first { index in
                        guard let view = table.rowView(atRow: index, makeIfNecessary: true) else { return false }
                        return Controls.contains(title, in: view)
                    }
                    return try #require(index)
                }
                try table.selectRowIndexes(IndexSet(integer: row(fixture.custom.name)), byExtendingSelection: false)
                try await Controls.wait { model.selectedPersonaID == fixture.custom.id }
                model.personaDraftPrompt = "Unsaved changes"
                let defaultPersona = model.personas.first { $0.id == SettingsStore.defaultPersonaID }
                let original = try #require(defaultPersona)
                try table.selectRowIndexes(IndexSet(integer: row(original.name)), byExtendingSelection: false)
                try await Controls.wait { model.pendingPersonaNavigation != nil }
                #expect(model.selectedPersonaID == fixture.custom.id)
                #expect(model.personaDraftPrompt == "Unsaved changes")
                model.resolvePersonaDraftGuard(.cancel)
                #expect(model.selectedPersonaID == fixture.custom.id)
                model.selectPersonaGuardingDraft(original.id)
                model.resolvePersonaDraftGuard(.discard)
                #expect(model.selectedPersonaID == original.id)
            }
        }
    }

    private func control(_ identifier: String, in root: Any) throws -> Controls.Element {
        let element = Controls.elements(in: root).first {
            $0.value("accessibilityIdentifier") as? String == identifier
        }
        return try #require(element)
    }
}
