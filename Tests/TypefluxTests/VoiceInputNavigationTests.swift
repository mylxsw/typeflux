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

    func testSidebarVoiceInputReturnsToTheInitialVoiceInputTab() throws {
        let viewModel = try makeViewModel(initialSection: .history)
        viewModel.navigateFromSidebar(to: .models)

        viewModel.navigateFromSidebar(to: .home)

        XCTAssertEqual(viewModel.currentSection, .history)
    }

    func testSidebarVoiceInputReturnsToTheLastShownTab() throws {
        let viewModel = try makeViewModel(initialSection: .home)
        viewModel.navigate(to: .personas)
        viewModel.navigateFromSidebar(to: .launcher)
        XCTAssertEqual(viewModel.currentSection, .launcher)
        XCTAssertEqual(viewModel.lastVoiceInputSection, .personas, "Leaving the group keeps its last tab")

        viewModel.navigateFromSidebar(to: .home)

        XCTAssertEqual(viewModel.currentSection, .personas)
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

    func testTabBarRendersEveryVoiceInputTab() {
        let bar = VoiceInputTabBar(selection: .vocabulary, count: { $0 == .vocabulary ? 12 : nil }, onSelect: { _ in })
        let host = NSHostingView(rootView: bar)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testTabInvokesItsAction() {
        var tapped = false
        let tab = StudioUnderlineTab(title: "History", count: nil, selected: false) { tapped = true }

        tab.action()

        XCTAssertTrue(tapped)
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
