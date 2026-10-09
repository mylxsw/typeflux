import AppKit
@testable import Typeflux
import XCTest

final class StatusBarMenuSupportTests: XCTestCase {
    @MainActor
    func testOpenTypefluxMenuEntryOpensConversationDirectlyWithoutDuplicateAskEntry() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Requires a GUI WindowServer session")
        }
        let suite = "AskMenuEntryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var openCount = 0
        let controller = StatusBarController(
            appState: AppStateStore(),
            settingsStore: SettingsStore(defaults: defaults),
            historyStore: EmptyHistoryStore(),
            onOpenAskConversations: { openCount += 1 }
        )
        controller.start()
        defer { controller.stop() }
        let menu = try XCTUnwrap(controller.menu)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == L("menu.openVoiceStudio") })
        XCTAssertEqual(index, 0)
        XCTAssertEqual(menu.items.filter { $0.title == L("menu.openVoiceStudio") }.count, 1)
        XCTAssertFalse(menu.items.contains { $0.title == L("menu.openAskConversations") })
        XCTAssertEqual(menu.items[index + 1].title, L("menu.addVocabulary"))
        XCTAssertEqual(menu.items[index + 2].title, L("menu.notes"))
        XCTAssertNil(menu.items[index].submenu)
        XCTAssertTrue(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
        XCTAssertEqual(openCount, 1)
        menu.performActionForItem(at: index)
        XCTAssertEqual(openCount, 2)
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == L("menu.settings") })
        XCTAssertNotEqual(settingsItem.action, menu.items[index].action)
    }

    func testStatusBarIconUsesBoundedMenuBarDimensions() {
        XCTAssertEqual(StatusBarController.IconLayout.imageSize, NSSize(width: 22, height: 22))
        XCTAssertEqual(StatusBarController.IconLayout.statusItemLength, NSStatusItem.squareLength)
        XCTAssertLessThanOrEqual(StatusBarController.IconLayout.pointSize, 16)
    }

    func testLocalModelDownloadTitleIncludesModelAndProgress() {
        let title = StatusBarMenuSupport.localModelDownloadTitle(
            for: .downloading(model: .qwen3ASR, progress: 0.42)
        )

        XCTAssertEqual(title, L("menu.downloadingLocalModelNamed", LocalSTTModel.qwen3ASR.displayName, 42))
        XCTAssertNil(StatusBarMenuSupport.localModelDownloadTitle(for: .idle))
    }

    func testLocalModelDownloadTitleIncludesFailureState() {
        let title = StatusBarMenuSupport.localModelDownloadTitle(
            for: .failed(model: .senseVoiceSmall, message: "Network unavailable")
        )

        XCTAssertEqual(title, L("menu.localModelDownloadFailedNamed", LocalSTTModel.senseVoiceSmall.displayName))
    }

    @MainActor
    func testStatusBarMenuReadsSharedLocalModelDownloadProgress() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Status bar menu test requires a GUI WindowServer session.")
        }
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let controller = try StatusBarController(
            appState: AppStateStore(),
            settingsStore: SettingsStore(
                defaults: XCTUnwrap(UserDefaults(suiteName: "StatusBarMenuProgressTests.\(UUID().uuidString)"))
            ),
            historyStore: EmptyHistoryStore()
        )

        controller.start()
        defer { controller.stop() }

        LocalModelDownloadProgressCenter.shared.reportDownloading(model: .whisperLocal, progress: 0.35)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let title = L("menu.downloadingLocalModelNamed", LocalSTTModel.whisperLocal.displayName, 35)
        XCTAssertTrue(controller.menu?.items.contains { $0.title == title } ?? false)
    }

    @MainActor
    func testStatusBarMenuIncludesSettingsItemNearAppearanceControls() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Status bar menu test requires a GUI WindowServer session.")
        }

        let controller = try StatusBarController(
            appState: AppStateStore(),
            settingsStore: SettingsStore(
                defaults: XCTUnwrap(UserDefaults(suiteName: "StatusBarMenuSupportTests.\(UUID().uuidString)"))
            ),
            historyStore: EmptyHistoryStore()
        )

        controller.start()
        defer { controller.stop() }

        let titles = controller.menu?.items.map(\.title) ?? []
        let settingsItem = try XCTUnwrap(controller.menu?.items.first { $0.title == L("menu.settings") })

        XCTAssertEqual(controller.menu?.showsStateColumn, false)
        XCTAssertNotEqual(settingsItem.title, "Settings")
        XCTAssertFalse(try NSStringFromSelector(XCTUnwrap(settingsItem.action))
            .localizedCaseInsensitiveContains("settings"))
        XCTAssertLessThan(
            try XCTUnwrap(titles.firstIndex(of: L("menu.appearance"))),
            try XCTUnwrap(titles.firstIndex(of: L("menu.settings")))
        )
        XCTAssertLessThan(
            try XCTUnwrap(titles.firstIndex(of: L("menu.settings"))),
            try XCTUnwrap(titles.firstIndex(of: L("menu.checkForUpdates")))
        )
    }

    func testRecentTranscriptionRecordsFiltersEmptyFinalTextAndLimitsResults() {
        let base = Date(timeIntervalSince1970: 1000)
        let records = [
            HistoryRecord(date: base.addingTimeInterval(1), transcriptText: "old"),
            HistoryRecord(date: base.addingTimeInterval(2), transcriptText: "   "),
            HistoryRecord(date: base.addingTimeInterval(3), errorMessage: "failed"),
            HistoryRecord(date: base.addingTimeInterval(4), transcriptText: "new"),
            HistoryRecord(date: base.addingTimeInterval(5), personaResultText: "newest")
        ]

        let recent = StatusBarMenuSupport.recentTranscriptionRecords(from: records, limit: 2)

        XCTAssertEqual(recent.map(\.finalText), ["newest", "new"])
    }

    func testRecentHistoryTitleFlattensNewlinesAndTruncatesLongText() {
        let record = HistoryRecord(
            date: Date(timeIntervalSince1970: 1000),
            transcriptText: "first line\nsecond line with a very long transcript body that should be shortened"
        )

        let title = StatusBarMenuSupport.recentHistoryTitle(for: record)

        XCTAssertFalse(title.contains("\n"))
        XCTAssertTrue(title.hasSuffix("..."))
        XCTAssertTrue(title.contains("first line second line"))
    }
}

private final class EmptyHistoryStore: HistoryStore {
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
        URL(fileURLWithPath: NSTemporaryDirectory())
    }
}

