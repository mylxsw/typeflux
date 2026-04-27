import AVFoundation
@testable import Typeflux
import XCTest

final class AVFoundationAudioRecorderTests: XCTestCase {
    func testValidateInputFormatAcceptsUsableMicrophoneFormat() throws {
        XCTAssertNoThrow(try AVFoundationAudioRecorder.validateInputFormat(channelCount: 1, sampleRate: 44_100))
    }

    func testValidateInputFormatRejectsZeroChannelFormat() throws {
        XCTAssertThrowsError(try AVFoundationAudioRecorder.validateInputFormat(channelCount: 0, sampleRate: 44_100)) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testValidateInputFormatRejectsZeroSampleRate() throws {
        XCTAssertThrowsError(try AVFoundationAudioRecorder.validateInputFormat(channelCount: 1, sampleRate: 0)) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testRebuildAudioEngineReplacesStaleEngineInstance() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = AVFoundationAudioRecorder(settingsStore: SettingsStore(defaults: defaults))
        let originalIdentifier = recorder.audioEngineIdentifierForTesting

        recorder.rebuildAudioEngineForTesting()

        XCTAssertNotEqual(recorder.audioEngineIdentifierForTesting, originalIdentifier)
    }

    func testResolvedInputDeviceUsesPreferredMicrophoneWhenAvailable() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.preferredMicrophoneID = "external-mic"
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(
                resolvedInputDeviceIDs: ["external-mic": 42],
                defaultInputDeviceID: 7,
            ),
        )

        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 42)
        XCTAssertEqual(settingsStore.preferredMicrophoneID, "external-mic")
    }

    func testResolvedInputDeviceFallsBackToDefaultWhenPreferredMicrophoneIsUnavailable() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.preferredMicrophoneID = "disconnected-mic"
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 7),
        )

        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 7)
        XCTAssertEqual(settingsStore.preferredMicrophoneID, AudioDeviceManager.automaticDeviceID)
    }

    func testResolvedInputDeviceUsesDefaultMicrophoneInAutomaticMode() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 9),
        )

        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 9)
        XCTAssertEqual(settingsStore.preferredMicrophoneID, AudioDeviceManager.automaticDeviceID)
    }

    func testDelayedMuteBeginsAfterConfiguredSleep() async throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.muteSystemOutputDuringRecording = true

        let beginExpectation = expectation(description: "Delayed mute begins")
        let muter = MockSystemAudioOutputMuter(beginExpectation: beginExpectation)
        let sleepController = SleepController()
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            outputMuter: muter,
            sleep: { duration in
                await sleepController.sleep(for: duration)
            },
        )

        recorder.beginMutedSessionAfterDelayForTesting()
        await sleepController.waitUntilSleeping()
        XCTAssertEqual(muter.beginCallCount, 0)

        await sleepController.resume()
        await fulfillment(of: [beginExpectation], timeout: 1.0)
        XCTAssertEqual(muter.beginCallCount, 1)
    }

    func testStoppingBeforeDelayedMutePreventsMuteSession() async throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.muteSystemOutputDuringRecording = true

        let muter = MockSystemAudioOutputMuter()
        let sleepController = SleepController()
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            outputMuter: muter,
            sleep: { duration in
                await sleepController.sleep(for: duration)
            },
        )

        recorder.beginMutedSessionAfterDelayForTesting()
        await sleepController.waitUntilSleeping()
        recorder.cancelMutedSessionForTesting()
        await sleepController.resume()
        await Task.yield()

        XCTAssertEqual(muter.beginCallCount, 0)
        XCTAssertEqual(muter.endCallCount, 1)
    }

    func testAudioBufferWriteCoordinatorDrainWaitsForQueuedWork() async {
        let coordinator = AudioBufferWriteCoordinator()
        let started = expectation(description: "Queued work started")

        coordinator.enqueue {
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.08)
        }

        await fulfillment(of: [started], timeout: 1.0)

        let start = Date()
        coordinator.drain()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.02)
    }

    func testAudioBufferWriteCoordinatorDrainIncludesMultipleQueuedOperations() {
        let coordinator = AudioBufferWriteCoordinator()
        let recorder = OrderedValueRecorder()

        coordinator.enqueue {
            recorder.append(1)
        }
        coordinator.enqueue {
            recorder.append(2)
        }

        coordinator.drain()

        XCTAssertEqual(recorder.values, [1, 2])
    }
}

private final class MockAudioDeviceManager: AudioDeviceManaging {
    private let devices: [AudioInputDevice]
    private let resolvedInputDeviceIDs: [String: AudioDeviceID]
    private let defaultInputDevice: AudioDeviceID?

    init(
        devices: [AudioInputDevice] = [],
        resolvedInputDeviceIDs: [String: AudioDeviceID] = [:],
        defaultInputDeviceID: AudioDeviceID? = nil,
    ) {
        self.devices = devices
        self.resolvedInputDeviceIDs = resolvedInputDeviceIDs
        defaultInputDevice = defaultInputDeviceID
    }

    func availableInputDevices() -> [AudioInputDevice] {
        devices
    }

    func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID? {
        resolvedInputDeviceIDs[uniqueID]
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultInputDevice
    }
}

private final class MockSystemAudioOutputMuter: SystemAudioOutputMuting {
    private let beginExpectation: XCTestExpectation?
    private(set) var beginCallCount = 0
    private(set) var endCallCount = 0

    init(beginExpectation: XCTestExpectation? = nil) {
        self.beginExpectation = beginExpectation
    }

    func beginMutedSession() {
        beginCallCount += 1
        beginExpectation?.fulfill()
    }

    func endMutedSession() {
        endCallCount += 1
    }
}

private actor SleepController {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilSleeping() async {
        if continuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class OrderedValueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        let values = storage
        lock.unlock()
        return values
    }
}
