@testable import Typeflux
import XCTest

final class StatusBarMenuSupportTests: XCTestCase {
    @MainActor
    func testStatusBarMenuIncludesSettingsItemNearAppearanceControls() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Status bar menu test requires a GUI WindowServer session.")
        }

        let controller = StatusBarController(
            appState: AppStateStore(),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "StatusBarMenuSupportTests.\(UUID().uuidString)")!),
            historyStore: EmptyHistoryStore(),
            agentJobStore: EmptyAgentJobStore(),
        )

        controller.start()
        defer { controller.stop() }

        let titles = controller.menu?.items.map(\.title) ?? []
        let settingsItem = try XCTUnwrap(controller.menu?.items.first { $0.title == L("menu.settings") })

        XCTAssertEqual(controller.menu?.showsStateColumn, false)
        XCTAssertNotEqual(settingsItem.title, "Settings")
        XCTAssertFalse(NSStringFromSelector(try XCTUnwrap(settingsItem.action)).localizedCaseInsensitiveContains("settings"))
        XCTAssertLessThan(
            try XCTUnwrap(titles.firstIndex(of: L("menu.appearance"))),
            try XCTUnwrap(titles.firstIndex(of: L("menu.settings"))),
        )
        XCTAssertLessThan(
            try XCTUnwrap(titles.firstIndex(of: L("menu.settings"))),
            try XCTUnwrap(titles.firstIndex(of: L("menu.checkForUpdates"))),
        )
    }

    func testRecentTranscriptionRecordsFiltersEmptyFinalTextAndLimitsResults() {
        let base = Date(timeIntervalSince1970: 1_000)
        let records = [
            HistoryRecord(date: base.addingTimeInterval(1), transcriptText: "old"),
            HistoryRecord(date: base.addingTimeInterval(2), transcriptText: "   "),
            HistoryRecord(date: base.addingTimeInterval(3), errorMessage: "failed"),
            HistoryRecord(date: base.addingTimeInterval(4), transcriptText: "new"),
            HistoryRecord(date: base.addingTimeInterval(5), personaResultText: "newest"),
        ]

        let recent = StatusBarMenuSupport.recentTranscriptionRecords(from: records, limit: 2)

        XCTAssertEqual(recent.map(\.finalText), ["newest", "new"])
    }

    func testRecentHistoryTitleFlattensNewlinesAndTruncatesLongText() {
        let record = HistoryRecord(
            date: Date(timeIntervalSince1970: 1_000),
            transcriptText: "first line\nsecond line with a very long transcript body that should be shortened",
        )

        let title = StatusBarMenuSupport.recentHistoryTitle(for: record)

        XCTAssertFalse(title.contains("\n"))
        XCTAssertTrue(title.hasSuffix("..."))
        XCTAssertTrue(title.contains("first line second line"))
    }
}

private final class EmptyHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
}

private struct EmptyAgentJobStore: AgentJobStore {
    func save(_: AgentJob) async throws {}
    func list(limit _: Int, offset _: Int) async throws -> [AgentJob] { [] }
    func job(id _: UUID) async throws -> AgentJob? { nil }
    func delete(id _: UUID) async throws {}
    func clear() async throws {}
    func count() async throws -> Int { 0 }
}
