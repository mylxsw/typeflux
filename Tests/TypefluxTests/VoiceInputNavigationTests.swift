import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class VoiceInputNavigationTests: XCTestCase {
    private func makeViewModel(initialSection: StudioSection) throws -> StudioViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VoiceInputNavigationTests.\(UUID().uuidString)"))
        return StudioViewModel(
            settingsStore: SettingsStore(defaults: defaults),
            historyStore: InMemoryHistoryStore(),
            initialSection: initialSection
        )
    }

    func testSidebarVoiceInputOpensOverviewByDefault() throws {
        let viewModel = try makeViewModel(initialSection: .models)

        viewModel.navigateFromSidebar(to: .home)

        XCTAssertEqual(viewModel.currentSection, .home)
    }

    func testSidebarOverviewOpensOverviewAfterAnInitialHistoryPage() throws {
        let viewModel = try makeViewModel(initialSection: .history)
        viewModel.navigateFromSidebar(to: .models)

        viewModel.navigateFromSidebar(to: .home)

        XCTAssertEqual(viewModel.currentSection, .home)
    }

    func testSidebarOverviewOpensOverviewAfterVisitingPersonas() throws {
        let viewModel = try makeViewModel(initialSection: .home)
        viewModel.navigate(to: .personas)
        viewModel.navigateFromSidebar(to: .launcher)
        XCTAssertEqual(viewModel.currentSection, .launcher)
        XCTAssertEqual(viewModel.lastVoiceInputSection, .personas, "Feature history remains available to existing callers")

        viewModel.navigateFromSidebar(to: .home)

        XCTAssertEqual(viewModel.currentSection, .home)
    }

    func testDirectNavigationToOverviewStillOpensOverview() throws {
        let viewModel = try makeViewModel(initialSection: .vocabulary)

        viewModel.navigate(to: .home)

        XCTAssertEqual(viewModel.currentSection, .home)
        XCTAssertEqual(viewModel.lastVoiceInputSection, .home)
    }

    func testSidebarOtherEntriesNavigateDirectly() throws {
        let viewModel = try makeViewModel(initialSection: .home)

        viewModel.navigateFromSidebar(to: .settings)

        XCTAssertEqual(viewModel.currentSection, .settings)
        XCTAssertEqual(viewModel.lastVoiceInputSection, .home)
    }

    func testVoiceInputTabCountsVocabularyAndPersonas() throws {
        let viewModel = try makeViewModel(initialSection: .home)
        viewModel.vocabularyEntries = [
            VocabularyEntry(term: "Typeflux", source: .manual),
            VocabularyEntry(term: "Multica", source: .automatic)
        ]

        XCTAssertEqual(viewModel.voiceInputTabCount(for: .vocabulary), 2)
        XCTAssertEqual(viewModel.voiceInputTabCount(for: .personas), viewModel.personas.count)
        XCTAssertNil(viewModel.voiceInputTabCount(for: .home))
        XCTAssertNil(viewModel.voiceInputTabCount(for: .history))
        XCTAssertNil(viewModel.voiceInputTabCount(for: .models))
    }

    func testEverySidebarDestinationNavigatesDirectly() throws {
        let viewModel = try makeViewModel(initialSection: .history)
        for section in StudioSection.sidebarUpperCases {
            viewModel.navigateFromSidebar(to: section)
            XCTAssertEqual(viewModel.currentSection, section)
        }
    }

    func testVocabularyActionRemainsAvailableBelowToolbarTabs() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = StudioViewModel(settingsStore: settings, historyStore: InMemoryHistoryStore(),
                initialSection: .vocabulary,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            try await TypefluxNavigationTestSupport.withWindow(StudioView(viewModel: model)) { window, _ in
                try SettingsBehaviorTestSupport.button(L("vocabulary.action.newWord"), in: window).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let sheet = try XCTUnwrap(window.attachedSheet)
                try SettingsBehaviorTestSupport.button(L("common.cancel"), in: sheet).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                XCTAssertTrue(model.vocabularyEntries.isEmpty)
            }
        }
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
