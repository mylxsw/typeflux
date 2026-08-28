import Foundation
@testable import Typeflux
import XCTest

@MainActor
final class SettingsStoreAudioTests: XCTestCase {
    func testInstantVoiceInputIsDisabledByDefault() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SettingsStore(defaults: defaults).instantVoiceInputEnabled)
    }

    func testInstantVoiceInputPersistsAndNotifiesOnlyWhenChanged() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .instantVoiceInputDidChange,
            object: store,
            queue: nil
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.instantVoiceInputEnabled = true
        store.instantVoiceInputEnabled = true

        XCTAssertTrue(store.instantVoiceInputEnabled)
        XCTAssertEqual(notificationCount, 1)
    }

    func testInstantVoiceInputPersistsThroughSettingsViewModel() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: store,
            historyStore: AudioSettingsHistoryStore(),
            initialSection: .settings
        )

        viewModel.setInstantVoiceInputEnabled(true)

        XCTAssertTrue(viewModel.instantVoiceInputEnabled)
        XCTAssertTrue(store.instantVoiceInputEnabled)
    }
}

private final class AudioSettingsHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: "/tmp/typeflux-audio-settings-history.md") }
}
