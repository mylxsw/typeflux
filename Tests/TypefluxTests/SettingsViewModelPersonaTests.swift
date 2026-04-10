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
