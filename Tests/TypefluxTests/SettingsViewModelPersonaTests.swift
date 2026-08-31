import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelPersonaTests: XCTestCase {
    private var originalLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        originalLanguage = AppLocalization.shared.language
    }

    override func tearDown() {
        AppLocalization.shared.setLanguage(originalLanguage)
        originalLanguage = nil
        super.tearDown()
    }

    func testInitialSelectionIsNoneWhenPersonaRewriteIsDisabled() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    func testSelectNonePersonaClearsDraftFields() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.selectPersona(nil)

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.personaDraftName, "")
        XCTAssertEqual(viewModel.personaDraftPrompt, "")
    }

    func testSelectingPersonaDoesNotAutoActivateWhenPersonaRewriteIsDisabled() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        let persona = try XCTUnwrap(viewModel.personas.first)
        viewModel.selectPersona(persona.id)

        XCTAssertEqual(viewModel.selectedPersonaID, persona.id)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    func testSelectingSystemPersonaShowsResolvedLocalizedPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.localizedPrompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = .simplifiedChinese
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        let persona = try XCTUnwrap(viewModel.personas.first(where: { $0.id == SettingsStore.defaultPersonaID }))
        viewModel.selectPersona(persona.id)

        XCTAssertTrue(viewModel.personaDraftPrompt.contains("人设语言模式：继承。"))
        XCTAssertTrue(viewModel.personaDisplayPrompt(for: persona).contains("保持用户整体语气自然"))
        XCTAssertFalse(viewModel.personaDraftPrompt.contains("You are Typeflux AI"))
    }

    func testSystemPersonaSearchUsesResolvedLocalizedPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.localizedSearch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = .simplifiedChinese
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.searchQuery = "口头填充词"

        XCTAssertTrue(viewModel.filteredPersonas.contains(where: { $0.id == SettingsStore.defaultPersonaID }))
    }

    func testChangingAppLanguageRefreshesSelectedSystemPersonaPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.languageRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.selectPersona(SettingsStore.defaultPersonaID)
        XCTAssertTrue(viewModel.personaDraftPrompt.contains("Persona language mode: inherit."))

        viewModel.setAppLanguage(.simplifiedChinese)

        XCTAssertTrue(viewModel.personaDraftPrompt.contains("人设语言模式：继承。"))
        XCTAssertFalse(viewModel.personaDraftPrompt.contains("You are Typeflux AI"))
    }

    func testDeactivatePersonaRewriteKeepsNonePersonaSelected() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.selectPersona(nil)
        viewModel.deactivatePersonaRewrite()

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    func testSavePersonaAppBindingPersistsBindingAndClearsDraft() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        let persona = try XCTUnwrap(viewModel.personas.first)
        viewModel.personaAppBindingDraftIdentifier = "com.tinyspeck.slackmacgap"
        viewModel.personaAppBindingDraftPersonaID = persona.id

        viewModel.savePersonaAppBinding()

        XCTAssertEqual(settingsStore.personaAppBindings.count, 1)
        XCTAssertEqual(settingsStore.personaAppBindings.first?.appIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(settingsStore.personaAppBindings.first?.personaID, persona.id)
        XCTAssertTrue(viewModel.personaAppBindingDraftIdentifier.isEmpty)
    }

    func testSavePersonaAppBindingAllowsNoPersonaSelection() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.personaAppBindingDraftIdentifier = "com.apple.Notes"
        viewModel.personaAppBindingDraftPersonaID = nil

        viewModel.savePersonaAppBinding()

        XCTAssertEqual(settingsStore.personaAppBindings.count, 1)
        XCTAssertEqual(settingsStore.personaAppBindings.first?.appIdentifier, "com.apple.Notes")
        XCTAssertNil(settingsStore.personaAppBindings.first?.personaID)
        XCTAssertTrue(viewModel.personaAppBindingDraftIdentifier.isEmpty)
    }

    func testDeletePersonaRemovesAssociatedAppBindings() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let customPersona = PersonaProfile(name: "Chat Reply", prompt: "Be casual.")
        settingsStore.personas = settingsStore.personas + [customPersona]
        settingsStore.savePersonaAppBinding(
            appIdentifier: "com.tinyspeck.slackmacgap",
            personaID: customPersona.id
        )
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.deletePersona(id: customPersona.id)

        XCTAssertTrue(settingsStore.personaAppBindings.isEmpty)
        XCTAssertTrue(viewModel.personaAppBindings.isEmpty)
    }

    func testSetPersonaAppBindingsEnabledUpdatesStore() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.setPersonaAppBindingsEnabled(false)

        XCTAssertFalse(settingsStore.personaAppBindingsEnabled)
        XCTAssertFalse(viewModel.personaAppBindingsEnabled)
    }

    func testUpdatePersonaAppBindingPersonaUpdatesStore() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let originalPersona = PersonaProfile(name: "Casual", prompt: "Casual")
        let updatedPersona = PersonaProfile(name: "Formal", prompt: "Formal")
        settingsStore.personas = settingsStore.personas + [originalPersona, updatedPersona]
        settingsStore.savePersonaAppBinding(appIdentifier: "Slack", personaID: originalPersona.id)
        let bindingID = try XCTUnwrap(settingsStore.personaAppBindings.first?.id)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.updatePersonaAppBindingPersona(id: bindingID, personaID: updatedPersona.id)

        XCTAssertEqual(settingsStore.personaAppBindings.first?.personaID, updatedPersona.id)
        XCTAssertEqual(viewModel.personaAppBindings.first?.personaID, updatedPersona.id)
    }

    func testUpdatePersonaAppBindingPersonaCanDisablePersona() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let persona = PersonaProfile(name: "Casual", prompt: "Casual")
        settingsStore.personas = settingsStore.personas + [persona]
        settingsStore.savePersonaAppBinding(appIdentifier: "Slack", personaID: persona.id)
        let bindingID = try XCTUnwrap(settingsStore.personaAppBindings.first?.id)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.updatePersonaAppBindingPersona(id: bindingID, personaID: nil)

        XCTAssertNil(settingsStore.personaAppBindings.first?.personaID)
        XCTAssertNil(viewModel.personaAppBindings.first?.personaID)
    }

    func testSetPersonaAppBindingEnabledUpdatesStore() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let persona = try XCTUnwrap(settingsStore.personas.first)
        settingsStore.savePersonaAppBinding(appIdentifier: "Slack", personaID: persona.id)
        let bindingID = try XCTUnwrap(settingsStore.personaAppBindings.first?.id)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas
        )

        viewModel.setPersonaAppBindingEnabled(id: bindingID, isEnabled: false)

        XCTAssertFalse(settingsStore.personaAppBindings.first?.isEnabled ?? true)
        XCTAssertFalse(viewModel.personaAppBindings.first?.isEnabled ?? true)
    }

    func testPersonaLibrarySeparatesEditingFromDefaultAndPreservesUnsavedChanges() throws {
        let suite = "SettingsViewModelPersonaTests.library.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let persona = PersonaProfile(name: "Writing", prompt: "Original instructions")
        store.personas = store.personas + [persona]
        store.applyPersonaSelection(SettingsStore.defaultPersonaID)
        let model = StudioViewModel(settingsStore: store, historyStore: InMemoryHistoryStore(), initialSection: .personas)

        model.selectPersona(persona.id)
        XCTAssertFalse(model.isEditingDefaultPersona)
        XCTAssertTrue(model.isDefaultPersona(SettingsStore.defaultPersonaID))
        model.personaDraftName = "Edited name"
        model.personaDraftPrompt = "Unsaved instructions"
        model.activateSelectedPersona()

        XCTAssertTrue(model.isEditingDefaultPersona)
        XCTAssertFalse(model.isDefaultPersona(SettingsStore.defaultPersonaID))
        XCTAssertEqual(model.personaDraftName, "Edited name")
        XCTAssertEqual(model.personaDraftPrompt, "Unsaved instructions")
        XCTAssertEqual(store.personas.first { $0.id == persona.id }?.prompt, "Original instructions")
        XCTAssertTrue(model.hasPersonaDraftChanges)

        model.savePersonaDraft()
        XCTAssertFalse(model.hasPersonaDraftChanges)
        XCTAssertEqual(store.personas.first { $0.id == persona.id }?.prompt, "Unsaved instructions")
        model.personaDraftPrompt = "Discard this change"
        model.cancelPersonaEditing()
        XCTAssertEqual(model.personaDraftPrompt, "Unsaved instructions")
        XCTAssertTrue(model.isEditingDefaultPersona)
    }

    func testPersonaLibraryDefaultIndicatorRespectsDisabledRewriteAndNewDraft() throws {
        let suite = "SettingsViewModelPersonaTests.library.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        // A remembered active ID must not make a disabled persona appear as default.
        store.activePersonaID = SettingsStore.defaultPersonaID.uuidString
        store.personaRewriteEnabled = false
        let model = StudioViewModel(settingsStore: store, historyStore: InMemoryHistoryStore(), initialSection: .personas)
        XCTAssertTrue(model.isDefaultPersona(nil))
        XCTAssertFalse(model.isDefaultPersona(SettingsStore.defaultPersonaID))
        XCTAssertTrue(model.isEditingDefaultPersona)

        model.beginCreatingPersona()
        XCTAssertFalse(model.isEditingDefaultPersona)
        model.selectPersona(SettingsStore.defaultPersonaID)
        XCTAssertFalse(model.isCreatingPersonaDraft)
        XCTAssertTrue(model.selectedPersonaIsSystem)
        XCTAssertFalse(model.canSavePersonaDraft)
        XCTAssertFalse(model.hasPersonaDraftChanges)
        XCTAssertEqual(model.personaDraftName, "Typeflux")

        model.beginCreatingPersona()
        model.selectPersona(nil)
        XCTAssertFalse(model.isCreatingPersonaDraft)
        XCTAssertTrue(model.isEditingDefaultPersona)
        XCTAssertEqual(model.personaDraftName, "")
    }

    func testPersonaLibraryGroupsFilterAndUsesRealCustomPromptPreview() throws {
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let suite = "SettingsViewModelPersonaTests.library.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .simplifiedChinese
        let persona = PersonaProfile(name: "Writing", prompt: "\n  Summarize the report.  \nKeep the zebraquartz decisions.")
        let emptyPersona = PersonaProfile(name: "Empty", prompt: " \n ")
        store.personas = store.personas + [persona, emptyPersona]
        let model = StudioViewModel(settingsStore: store, historyStore: InMemoryHistoryStore(), initialSection: .personas)
        XCTAssertEqual(model.filteredBuiltInPersonas.count, 2)
        XCTAssertEqual(Set(model.filteredCustomPersonas.map(\.id)), [persona.id, emptyPersona.id])
        XCTAssertEqual(model.personaListSubtitle(for: persona), "Summarize the report.")
        XCTAssertEqual(model.personaListSubtitle(for: emptyPersona), "自定义人设")
        let builtIn = try XCTUnwrap(model.filteredBuiltInPersonas.first { $0.id == SettingsStore.defaultPersonaID })
        XCTAssertEqual(model.personaListSubtitle(for: builtIn), "整理口述，保留原意")
        let translator = try XCTUnwrap(model.filteredBuiltInPersonas.first { $0.id != SettingsStore.defaultPersonaID })
        XCTAssertEqual(model.personaListSubtitle(for: translator), "将口述内容翻译为英文")

        model.searchQuery = "  整理口述  "
        XCTAssertEqual(model.filteredBuiltInPersonas.map(\.id), [SettingsStore.defaultPersonaID])
        XCTAssertTrue(model.filteredCustomPersonas.isEmpty)
        model.searchQuery = "zebraquartz"
        XCTAssertTrue(model.filteredBuiltInPersonas.isEmpty)
        XCTAssertEqual(model.filteredCustomPersonas.map(\.id), [persona.id])
        model.searchQuery = "no-match-12345"
        XCTAssertTrue(model.filteredPersonas.isEmpty)
        model.searchQuery = ""
        XCTAssertEqual(model.filteredCustomPersonas.count, 2)
    }

    func testCreatingPersonaFromFilteredLibraryKeepsSavedItemVisible() throws {
        let suite = "SettingsViewModelPersonaTests.creating.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let persona = PersonaProfile(name: "Writing", prompt: "Write clearly.")
        store.personas = store.personas + [persona]
        let model = StudioViewModel(settingsStore: store, historyStore: InMemoryHistoryStore(), initialSection: .personas)
        model.searchQuery = "no-match"
        model.beginCreatingPersona()
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertFalse(model.canSavePersonaDraft)
        model.personaDraftName = "New Persona"
        model.personaDraftPrompt = "Write concisely."
        XCTAssertTrue(model.canSavePersonaDraft)
        model.savePersonaDraft()
        XCTAssertFalse(model.isCreatingPersonaDraft)
        XCTAssertFalse(model.hasPersonaDraftChanges)
        XCTAssertTrue(model.filteredCustomPersonas.contains { $0.id == model.selectedPersonaID })
        XCTAssertTrue(store.personas.contains { $0.name == "New Persona" })
    }

    func testPersonaEditorBoundsLongPromptAtSmallAndLargeWindowSizes() throws {
        let suite = "SettingsViewModelPersonaTests.layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let prompt = Array(repeating: "Keep the original meaning and write clearly.", count: 100).joined(separator: "\n")
        let persona = PersonaProfile(name: "Writing", prompt: prompt)
        store.personas = store.personas + [persona]
        let model = StudioViewModel(settingsStore: store, historyStore: InMemoryHistoryStore(), initialSection: .personas)
        model.selectPersona(persona.id)

        for size in [CGSize(width: 842, height: 436), CGSize(width: 1000, height: 668)] {
            let target = StudioPersonaLibraryView(viewModel: model) { _ in }
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: target)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()

            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let textView = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
            let scroll = try XCTUnwrap(textView.enclosingScrollView)
            let rect = host.convert(scroll.bounds, from: scroll)
            XCTAssertGreaterThan(rect.height, 100)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxY, size.height - 54, "Prompt must leave room for pinned footer")
            XCTAssertEqual(textView.string, prompt)
        }
    }

    // MARK: - Auto persona default when LLM becomes configured via Settings

    func testSwitchingToTypefluxCloudAutoSelectsTypefluxPersona() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home
        )

        XCTAssertFalse(settingsStore.personaRewriteEnabled)

        viewModel.setLLMRemoteProvider(LLMRemoteProvider.typefluxCloud)

        XCTAssertTrue(settingsStore.personaRewriteEnabled)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    func testApplyingOpenAIAPIKeyAutoSelectsTypefluxPersona() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home
        )

        viewModel.setLLMRemoteProvider(LLMRemoteProvider.openAI)
        XCTAssertFalse(settingsStore.personaRewriteEnabled, "OpenAI without key should not trigger default")

        viewModel.setLLMAPIKey("sk-test")
        viewModel.applyModelConfiguration(shouldShowToast: false)

        XCTAssertTrue(settingsStore.personaRewriteEnabled)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    func testExplicitlyDisabledPersonaStaysOffWhenLLMIsConfigured() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home
        )

        // User explicitly turns persona off before configuring LLM.
        settingsStore.applyPersonaSelection(nil)

        viewModel.setLLMRemoteProvider(LLMRemoteProvider.typefluxCloud)

        XCTAssertFalse(settingsStore.personaRewriteEnabled, "Explicit opt-out must be respected")
        XCTAssertEqual(settingsStore.activePersonaID, "")
    }
}

private final class InMemoryHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}
