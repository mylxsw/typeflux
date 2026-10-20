import Foundation
import CoreAudio
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

    func testSettingsViewModelReflectsMicrophoneSelectedOutsideSettings() async throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: store,
            historyStore: AudioSettingsHistoryStore(),
            initialSection: .settings
        )

        store.preferredMicrophoneID = "external-microphone"
        let deadline = Date().addingTimeInterval(1)
        while viewModel.preferredMicrophoneID != "external-microphone", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.preferredMicrophoneID, "external-microphone")
    }

    func testSettingsViewModelReflectsInstantInputEnabledOutsideSettings() async throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: store,
            historyStore: AudioSettingsHistoryStore(),
            initialSection: .settings
        )

        store.instantVoiceInputEnabled = true
        let deadline = Date().addingTimeInterval(1)
        while !viewModel.instantVoiceInputEnabled, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewModel.instantVoiceInputEnabled)
    }

    func testSelectingBluetoothMicrophoneOffersInstantInputWithoutEnablingIt() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let devices = AudioSettingsDeviceManager()
        let viewModel = StudioViewModel(settingsStore: store, historyStore: AudioSettingsHistoryStore(),
                                        initialSection: .settings, audioDeviceManager: devices)

        viewModel.setPreferredMicrophoneID("bluetooth")

        XCTAssertTrue(viewModel.isInstantVoiceInputSuggestionPresented)
        XCTAssertFalse(store.instantVoiceInputEnabled)
        viewModel.isInstantVoiceInputSuggestionPresented = false
        viewModel.suggestInstantVoiceInputForCurrentMicrophoneIfNeeded()
        XCTAssertFalse(viewModel.isInstantVoiceInputSuggestionPresented)
        viewModel.setInstantVoiceInputEnabled(true)
        XCTAssertTrue(store.instantVoiceInputEnabled)
    }

    func testExistingBluetoothSelectionOffersSuggestionWhenSettingsOpens() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.preferredMicrophoneID = "bluetooth"
        let viewModel = StudioViewModel(settingsStore: store, historyStore: AudioSettingsHistoryStore(),
                                        initialSection: .settings, audioDeviceManager: AudioSettingsDeviceManager())

        viewModel.suggestInstantVoiceInputForCurrentMicrophoneIfNeeded()

        XCTAssertTrue(viewModel.isInstantVoiceInputSuggestionPresented)
        XCTAssertFalse(store.instantVoiceInputEnabled)
    }

    func testSuggestionSkipsBuiltInAutomaticAndAlreadyEnabled() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let devices = AudioSettingsDeviceManager()
        let viewModel = StudioViewModel(settingsStore: store, historyStore: AudioSettingsHistoryStore(),
                                        initialSection: .settings, audioDeviceManager: devices)

        viewModel.setPreferredMicrophoneID("built-in")
        XCTAssertFalse(viewModel.isInstantVoiceInputSuggestionPresented)
        viewModel.setPreferredMicrophoneID("")
        XCTAssertFalse(viewModel.isInstantVoiceInputSuggestionPresented)
        store.instantVoiceInputEnabled = true
        viewModel.setInstantVoiceInputEnabled(true)
        viewModel.setPreferredMicrophoneID("bluetooth")
        XCTAssertFalse(viewModel.isInstantVoiceInputSuggestionPresented)
    }

    func testInstantInputPolicyIgnoresBuiltInInputEvenWhenEnabled() throws {
        let suiteName = "SettingsStoreAudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let devices = AudioSettingsDeviceManager()
        store.instantVoiceInputEnabled = true

        store.preferredMicrophoneID = "built-in"
        XCTAssertFalse(InstantVoiceInputPolicy.isEffective(settings: store, devices: devices))
        store.preferredMicrophoneID = "bluetooth"
        XCTAssertTrue(InstantVoiceInputPolicy.isEffective(settings: store, devices: devices))
        store.preferredMicrophoneID = ""
        XCTAssertFalse(InstantVoiceInputPolicy.isEffective(settings: store, devices: devices))
    }
}

private final class AudioSettingsDeviceManager: AudioDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice] {
        [AudioInputDevice(id: "built-in", name: "Built-in"),
         AudioInputDevice(id: "bluetooth", name: "Bluetooth")]
    }

    func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID? {
        ["built-in": 1, "bluetooth": 2][uniqueID]
    }

    func defaultInputDeviceID() -> AudioDeviceID? { 2 }
    func automaticRecordingInputDeviceID() -> AudioDeviceID? { 1 }
    func observeDefaultInputDeviceChanges(_: @escaping @Sendable () -> Void) -> AudioInputDeviceChangeObservation? { nil }
    func isBluetoothInputDevice(_ deviceID: AudioDeviceID) -> Bool { deviceID == 2 }
    func isBuiltInInputDevice(_ deviceID: AudioDeviceID) -> Bool { deviceID == 1 }
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
