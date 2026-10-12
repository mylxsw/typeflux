import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsOrganizationTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func withModel(section: StudioSection = .settings,
                           _ check: (SettingsStore, StudioViewModel) async throws -> Void) async throws {
        try await UI.withFixture { store in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-organization-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            store.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let model = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: section,
                                        modelLibrary: AskModelLibrary(defaults: store.defaults, automaticallyLoadsCatalog: false))
            try await check(store, model)
        }
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese, .korean])
    func `voice input and settings titles remain above their tabs`(language: AppLanguage) async throws {
        try await withModel(section: .home) { _, model in
            model.setAppLanguage(language)
            for width: CGFloat in [720, 1100] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { _, host in
                    for section in StudioSection.voiceInputCases + [.settings] {
                        model.navigate(to: section)
                        let tabTitle = section == .settings ? AppSettingsPane.general.title : StudioSection.home.title
                        try await UI.wait {
                            UI.elements(in: host).contains {
                                $0.value("accessibilityIdentifier") as? String == "studio.page.title"
                                    && UI.contains(section.shellTitle, in: $0.object)
                            } && UI.contains(tabTitle, in: host)
                        }
                        let title = try #require(UI.elements(in: host).first {
                            $0.value("accessibilityIdentifier") as? String == "studio.page.title"
                                && UI.contains(section.shellTitle, in: $0.object)
                        })
                        let tab = try UI.button(tabTitle, in: host)
                        #expect(title.frame.minY > tab.frame.maxY, "The page title stays above the tab bar")
                        #expect(abs(title.frame.minX - tab.frame.minX) < 2, "Title and tabs share a leading edge")
                        try UI.snapshot(host, name: "page-title-\(section.rawValue)-\(language.rawValue)-\(Int(width))")
                    }
                }
            }
        }
    }

    @Test func `general removes providers and personas while advanced opens as the last tab`() async throws {
        try await withModel { _, model in
            #expect(AppSettingsPane.allCases.last == .advanced)
            for width: CGFloat in [720, 1100] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { _, host in
                    for key in ["settings.providers",
                                "settings.identity", "personas.redesign.dictation", "personas.redesign.auxiliary",
                                "settings.advanced.voiceProcessingTimeout.title", "settings.servers.title"] {
                        #expect(!UI.contains(L(key), in: host))
                    }
                    let advanced = try UI.button(AppSettingsPane.advanced.title, in: host)
                    let appearance = try UI.button(AppSettingsPane.appearance.title, in: host)
                    #expect(advanced.frame.minX > appearance.frame.maxX)
                    try advanced.press()
                    try await UI.wait { UI.contains(L("settings.advanced.voiceProcessingTimeout.title"), in: host) }
                    #expect(UI.contains(L("settings.servers.api.title"), in: host))
                    #expect(UI.contains(L("settings.servers.asr.title"), in: host))
                    #expect(!UI.contains(L("settings.launchAtLogin.title"), in: host))
                    try UI.snapshot(host, name: "settings-advanced-tab-\(Int(width))")
                    try UI.button(AppSettingsPane.general.title, in: host).press()
                    try await UI.wait { UI.contains(L("settings.launchAtLogin.title"), in: host) }
                    #expect(!UI.contains(L("settings.advanced.voiceProcessingTimeout.title"), in: host))
                }
            }
        }
    }

    @Test func `persona defaults remain visible above the editor at narrow and wide widths`() async throws {
        try await withModel(section: .personas) { _, model in
            model.selectPersona(SettingsStore.defaultPersonaID)
            for width: CGFloat in [720, 1100] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { _, host in
                    for key in ["personas.redesign.dictation", "personas.redesign.auxiliary"] {
                        #expect(UI.contains(L(key), in: host))
                    }
                    let elements = UI.elements(in: host)
                    let defaultPicker = try #require(elements.first {
                        $0.value("accessibilityIdentifier") as? String == "personas.defaultSelection"
                    })
                    let auxiliaryPicker = try #require(elements.first {
                        $0.value("accessibilityIdentifier") as? String == "personas.auxiliarySelection"
                    })
                    #expect(abs(defaultPicker.frame.midY - auxiliaryPicker.frame.midY) < 1)
                    #expect(auxiliaryPicker.frame.minX > defaultPicker.frame.maxX)
                    #expect(UI.contains(L("settings.personas.prompt"), in: host))
                    #expect(!elements.contains { $0.value("accessibilityIdentifier") as? String == "personas.name" })
                    try UI.snapshot(host, name: "personas-input-defaults-\(Int(width))")
                }
            }
        }
    }

    @Test func `changing input personas persists without switching or discarding the editor draft`() async throws {
        try await withModel(section: .personas) { store, model in
            let target = try #require(model.personas.first)
            model.beginCreatingPersona()
            model.personaDraftName = "Unsaved persona"
            model.personaDraftPrompt = "Keep these unsaved instructions."
            let selectedID = model.selectedPersonaID
            model.setDefaultPersonaSelection(target.id)
            model.setAuxiliaryPersona(target.id.uuidString)
            try await Task.sleep(for: .milliseconds(50))
            #expect(store.activePersonaID == target.id.uuidString)
            #expect(store.personaRewriteEnabled)
            #expect(store.personaSelectionIsExplicit)
            #expect(store.auxiliaryPersonaID == target.id.uuidString)
            #expect(model.defaultPersonaSelectionID == target.id)
            #expect(model.selectedPersonaID == selectedID)
            #expect(model.isCreatingPersonaDraft)
            #expect(model.personaDraftName == "Unsaved persona")
            #expect(model.personaDraftPrompt == "Keep these unsaved instructions.")
            model.setDefaultPersonaSelection(nil)
            #expect(!store.personaRewriteEnabled)
            #expect(model.defaultPersonaSelectionID == nil)
            #expect(model.isCreatingPersonaDraft)
            #expect(model.personaDraftPrompt == "Keep these unsaved instructions.")
            model.setDefaultPersonaSelection(UUID())
            #expect(!store.personaRewriteEnabled)
            model.savePersonaDraft()
            try await Task.sleep(for: .milliseconds(50))
            let editingID = model.selectedPersonaID
            model.personaDraftPrompt = "Unsaved edits to an existing persona."
            model.setDefaultPersonaSelection(target.id)
            model.setAuxiliaryPersona(target.id.uuidString)
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.selectedPersonaID == editingID)
            #expect(model.personaDraftPrompt == "Unsaved edits to an existing persona.")
            #expect(model.hasPersonaDraftChanges)
        }
    }
}
