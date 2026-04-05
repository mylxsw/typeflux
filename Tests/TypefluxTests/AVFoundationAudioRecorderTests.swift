@testable import Typeflux
import XCTest

final class AVFoundationAudioRecorderTests: XCTestCase {
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
