@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelPersonaTests: XCTestCase {
    func testInitialSelectionIsNoneWhenPersonaRewriteIsDisabled() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    func testSelectNonePersonaClearsDraftFields() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        viewModel.selectPersona(nil)

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.personaDraftName, "")
        XCTAssertEqual(viewModel.personaDraftPrompt, "")
    }

    func testSelectingPersonaDoesNotAutoActivateWhenPersonaRewriteIsDisabled() throws {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        let persona = try XCTUnwrap(viewModel.personas.first)
        viewModel.selectPersona(persona.id)

        XCTAssertEqual(viewModel.selectedPersonaID, persona.id)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    func testSelectingSystemPersonaShowsResolvedLocalizedPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.localizedPrompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = .simplifiedChinese
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        let persona = try XCTUnwrap(viewModel.personas.first(where: { $0.id == SettingsStore.defaultPersonaID }))
        viewModel.selectPersona(persona.id)

        XCTAssertTrue(viewModel.personaDraftPrompt.contains("人设语言模式：继承。"))
        XCTAssertTrue(viewModel.personaDisplayPrompt(for: persona).contains("把原始口述内容整理成可直接使用的文字"))
        XCTAssertFalse(viewModel.personaDraftPrompt.contains("You are Typeflux AI"))
    }

    func testSystemPersonaSearchUsesResolvedLocalizedPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.localizedSearch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = .simplifiedChinese
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        viewModel.searchQuery = "原始口述内容"

        XCTAssertTrue(viewModel.filteredPersonas.contains(where: { $0.id == SettingsStore.defaultPersonaID }))
    }

    func testChangingAppLanguageRefreshesSelectedSystemPersonaPrompt() throws {
        let suiteName = "SettingsViewModelPersonaTests.languageRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        viewModel.selectPersona(SettingsStore.defaultPersonaID)
        XCTAssertTrue(viewModel.personaDraftPrompt.contains("You are Typeflux AI"))

        viewModel.setAppLanguage(.simplifiedChinese)

        XCTAssertTrue(viewModel.personaDraftPrompt.contains("人设语言模式：继承。"))
        XCTAssertFalse(viewModel.personaDraftPrompt.contains("You are Typeflux AI"))
    }

    func testDeactivatePersonaRewriteKeepsNonePersonaSelected() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .personas,
        )

        viewModel.selectPersona(nil)
        viewModel.deactivatePersonaRewrite()

        XCTAssertNil(viewModel.selectedPersonaID)
        XCTAssertEqual(viewModel.activePersonaID, "")
        XCTAssertFalse(viewModel.personaRewriteEnabled)
    }

    // MARK: - Auto persona default when LLM becomes configured via Settings

    func testSwitchingToTypefluxCloudAutoSelectsTypefluxPersona() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home,
        )

        XCTAssertFalse(settingsStore.personaRewriteEnabled)

        viewModel.setLLMRemoteProvider(LLMRemoteProvider.typefluxCloud)

        XCTAssertTrue(settingsStore.personaRewriteEnabled)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    func testApplyingOpenAIAPIKeyAutoSelectsTypefluxPersona() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home,
        )

        viewModel.setLLMRemoteProvider(LLMRemoteProvider.openAI)
        XCTAssertFalse(settingsStore.personaRewriteEnabled, "OpenAI without key should not trigger default")

        viewModel.setLLMAPIKey("sk-test")
        viewModel.applyModelConfiguration(shouldShowToast: false)

        XCTAssertTrue(settingsStore.personaRewriteEnabled)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    func testExplicitlyDisabledPersonaStaysOffWhenLLMIsConfigured() {
        let suiteName = "SettingsViewModelPersonaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .home,
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
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}
