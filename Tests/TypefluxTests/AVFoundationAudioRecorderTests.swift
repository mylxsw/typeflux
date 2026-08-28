import AVFoundation
import AudioToolbox
@testable import Typeflux
import XCTest

final class AVFoundationAudioRecorderTests: XCTestCase {
    func testRecordingStartupBufferRelayPreservesPrefixAndOrdering() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let first = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.1)
        let second = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.2)
        let third = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.3)
        let relay = RecordingStartupAudioBufferRelay()
        var amplitudes: [Float] = []

        relay.append(first)
        relay.append(second)
        relay.activate { buffer in
            amplitudes.append(buffer.floatChannelData?[0][0] ?? 0)
        }
        relay.append(third)

        XCTAssertEqual(amplitudes.count, 3)
        XCTAssertEqual(amplitudes[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(amplitudes[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(amplitudes[2], 0.3, accuracy: 0.001)
    }

    func testRecordingStartupBufferRelayDropsBufferedAudioAfterCancellation() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.25)
        let relay = RecordingStartupAudioBufferRelay()
        var deliveryCount = 0

        relay.append(buffer)
        relay.cancel()
        relay.activate { _ in deliveryCount += 1 }
        relay.append(buffer)

        XCTAssertEqual(deliveryCount, 0)
    }

    func testRecordingStartupBufferRelayPreservesFirstBufferArrivalTime() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeTestBuffer(format: format, frameLength: 160)
        let receivedAt = Date(timeIntervalSince1970: 1234)
        let relay = RecordingStartupAudioBufferRelay()

        relay.append(buffer, receivedAt: receivedAt)
        relay.append(buffer, receivedAt: receivedAt.addingTimeInterval(1))

        XCTAssertEqual(relay.firstBufferReceivedAt, receivedAt)
    }

    func testRecordingStartupBufferRelayKeepsOnlyTheConfiguredPreRollTail() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let relay = RecordingStartupAudioBufferRelay(maximumBufferedDuration: 0.25)
        var amplitudes: [Float] = []

        for amplitude: Float in [0.1, 0.2, 0.3, 0.4] {
            relay.append(try makeTestBuffer(
                format: format,
                frameLength: 1600,
                amplitude: amplitude
            ))
        }
        relay.activate { buffer in
            amplitudes.append(buffer.floatChannelData?[0][0] ?? 0)
        }

        XCTAssertEqual(amplitudes.count, 2)
        XCTAssertEqual(amplitudes[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(amplitudes[1], 0.4, accuracy: 0.001)
    }

    func testRecordingStartupBufferRelaySignalsWhenInstantCaptureIsArmed() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let relay = RecordingStartupAudioBufferRelay(maximumBufferedDuration: 0.5)

        XCTAssertFalse(relay.waitForFirstBuffer(timeout: .milliseconds(0)))
        relay.append(try makeTestBuffer(format: format, frameLength: 160))
        XCTAssertTrue(relay.waitForFirstBuffer(timeout: .milliseconds(0)))
    }

    func testRecordingStartupBufferRelayDropsStalePreRollWhenWarmEngineStopped() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))
        let relay = RecordingStartupAudioBufferRelay(maximumBufferedDuration: 0.5)
        let staleBuffer = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.1)
        let freshBuffer = try makeTestBuffer(format: format, frameLength: 160, amplitude: 0.4)
        var amplitudes: [Float] = []

        relay.append(staleBuffer)
        relay.discardBufferedAudio()
        relay.append(freshBuffer)
        relay.activate { buffer in
            amplitudes.append(buffer.floatChannelData?[0][0] ?? 0)
        }

        XCTAssertEqual(amplitudes.count, 1)
        XCTAssertEqual(amplitudes[0], 0.4, accuracy: 0.001)
    }

    func testInputTapUsesLowLatencyBufferSize() {
        XCTAssertEqual(AVFoundationAudioRecorder.inputTapBufferSize, 512)
    }

    func testPreparedInputFastPathAcceptsUnchangedMicrophoneGeneration() {
        let signature = PreparedInputEngineSignature(
            deviceID: 7,
            preferredMicrophoneID: AudioDeviceManager.automaticDeviceID,
            generation: 3
        )

        XCTAssertTrue(AVFoundationAudioRecorder.canReusePreparedInputEngine(
            prepared: signature,
            current: signature
        ))
    }

    func testPreparedInputFastPathRejectsDefaultBluetoothDeviceSwitch() {
        let prepared = PreparedInputEngineSignature(
            deviceID: 7,
            preferredMicrophoneID: AudioDeviceManager.automaticDeviceID,
            generation: 3
        )
        let bluetoothInput = PreparedInputEngineSignature(
            deviceID: 42,
            preferredMicrophoneID: AudioDeviceManager.automaticDeviceID,
            generation: 4
        )

        XCTAssertFalse(AVFoundationAudioRecorder.canReusePreparedInputEngine(
            prepared: prepared,
            current: bluetoothInput
        ))
    }

    func testPreparedInputFastPathRejectsPreferredMicrophoneSwitch() {
        let prepared = PreparedInputEngineSignature(
            deviceID: 7,
            preferredMicrophoneID: "built-in",
            generation: 3
        )
        let bluetoothInput = PreparedInputEngineSignature(
            deviceID: 42,
            preferredMicrophoneID: "bluetooth-headset",
            generation: 4
        )

        XCTAssertFalse(AVFoundationAudioRecorder.canReusePreparedInputEngine(
            prepared: prepared,
            current: bluetoothInput
        ))
    }

    func testPreparedInputFastPathRejectsConfigurationGenerationChangeOnSameDevice() {
        let prepared = PreparedInputEngineSignature(
            deviceID: 42,
            preferredMicrophoneID: "bluetooth-headset",
            generation: 3
        )
        let reconfiguredInput = PreparedInputEngineSignature(
            deviceID: 42,
            preferredMicrophoneID: "bluetooth-headset",
            generation: 4
        )

        XCTAssertFalse(AVFoundationAudioRecorder.canReusePreparedInputEngine(
            prepared: prepared,
            current: reconfiguredInput
        ))
    }

    func testAutomaticDefaultInputChangeInvalidatesPreparedInputGeneration() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let audioDeviceManager = MockAudioDeviceManager(defaultInputDeviceID: 7)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: SettingsStore(defaults: defaults),
            audioDeviceManager: audioDeviceManager
        )
        let initialGeneration = recorder.preparedInputGenerationForTesting

        audioDeviceManager.simulateDefaultInputDeviceChange()

        XCTAssertEqual(recorder.preparedInputGenerationForTesting, initialGeneration + 1)
    }

    func testPreferredMicrophoneChangeInvalidatesPreparedInputGeneration() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(
                resolvedInputDeviceIDs: ["bluetooth-headset": 42],
                defaultInputDeviceID: 7
            )
        )
        let initialGeneration = recorder.preparedInputGenerationForTesting

        settingsStore.preferredMicrophoneID = "bluetooth-headset"

        XCTAssertEqual(recorder.preparedInputGenerationForTesting, initialGeneration + 1)
    }

    func testInstantVoiceInputChangeInvalidatesPreparedInputGeneration() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: nil)
        )
        let initialGeneration = recorder.preparedInputGenerationForTesting

        settingsStore.instantVoiceInputEnabled = true

        XCTAssertEqual(recorder.preparedInputGenerationForTesting, initialGeneration + 1)
    }

    func testInstantVoiceInputUsesHalfSecondPreRoll() {
        XCTAssertEqual(AVFoundationAudioRecorder.instantVoiceInputPreRollDuration, 0.5)
    }

    func testPreparedInputSuspendsAndRebuildsAcrossSleepLifecycle() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = AVFoundationAudioRecorder(
            settingsStore: SettingsStore(defaults: defaults),
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: nil)
        )
        let initialGeneration = recorder.preparedInputGenerationForTesting

        recorder.suspendPreparedInputForTesting()

        XCTAssertTrue(recorder.preparedInputIsSuspendedForTesting)
        XCTAssertEqual(recorder.preparedInputGenerationForTesting, initialGeneration + 1)

        recorder.resumePreparedInputForTesting()

        XCTAssertFalse(recorder.preparedInputIsSuspendedForTesting)
        XCTAssertEqual(recorder.preparedInputGenerationForTesting, initialGeneration + 2)
    }

    func testValidateInputFormatAcceptsUsableMicrophoneFormat() throws {
        XCTAssertNoThrow(try AVFoundationAudioRecorder.validateInputFormat(channelCount: 1, sampleRate: 44100))
    }

    func testValidateInputFormatRejectsZeroChannelFormat() throws {
        XCTAssertThrowsError(try AVFoundationAudioRecorder.validateInputFormat(
            channelCount: 0,
            sampleRate: 44100
        )) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testValidateInputFormatRejectsZeroSampleRate() throws {
        XCTAssertThrowsError(try AVFoundationAudioRecorder.validateInputFormat(
            channelCount: 1,
            sampleRate: 0
        )) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testFormatNotSupportedIsRecoverableDuringInputReconfiguration() {
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: Int(kAudioUnitErr_FormatNotSupported)
        )

        XCTAssertTrue(AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error))
    }

    func testUnrelatedAudioStartupErrorIsNotRecoverable() {
        let error = NSError(domain: "AudioRecorderTests", code: 99)

        XCTAssertFalse(AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error))
    }

    func testAudioTapExceptionIsRecoverableDuringInputReconfiguration() {
        let error = NSError(domain: "ai.gulu.app.typeflux.audio-tap", code: 1)

        XCTAssertTrue(AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error))
    }

    func testRequireInputDeviceRejectsMissingDevice() {
        XCTAssertThrowsError(try AVFoundationAudioRecorder.requireInputDeviceID(nil)) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
        XCTAssertThrowsError(try AVFoundationAudioRecorder.requireInputDeviceID(kAudioObjectUnknown)) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testRequireInputDeviceAcceptsAvailableDevice() throws {
        XCTAssertEqual(try AVFoundationAudioRecorder.requireInputDeviceID(42), 42)
    }

    func testStartWithoutResolvedInputDeviceThrowsInsteadOfInstallingTap() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = AVFoundationAudioRecorder(
            settingsStore: SettingsStore(defaults: defaults),
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: nil)
        )

        XCTAssertThrowsError(try recorder.start(levelHandler: { _ in }, audioBufferHandler: nil)) { error in
            XCTAssertEqual(error as? AVFoundationAudioRecorder.RecorderError, .inputDeviceUnavailable)
        }
    }

    func testRecordingBufferConverterKeepsFileFormatWhenInputSampleRateChanges() throws {
        let targetFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ))
        let bluetoothFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ))
        let settledFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ))
        let bluetoothBuffer = try makeTestBuffer(format: bluetoothFormat, frameLength: 240, amplitude: 0.25)
        let settledBuffer = try makeTestBuffer(format: settledFormat, frameLength: 480, amplitude: 0.25)
        let converter = AudioRecordingBufferConverter(targetFormat: targetFormat)

        let convertedBluetoothBuffer = try converter.convert(bluetoothBuffer)
        let convertedSettledBuffer = try converter.convert(settledBuffer)

        XCTAssertEqual(convertedBluetoothBuffer.format, targetFormat)
        XCTAssertEqual(convertedSettledBuffer.format, targetFormat)
        XCTAssertGreaterThan(convertedBluetoothBuffer.frameLength, 0)
        XCTAssertGreaterThan(convertedSettledBuffer.frameLength, 0)
        XCTAssertGreaterThan(peakAmplitude(in: convertedBluetoothBuffer), 0.1)
        XCTAssertGreaterThan(peakAmplitude(in: convertedSettledBuffer), 0.1)
    }

    func testAutomaticInputFollowsSystemDefaultDeviceChanges() {
        XCTAssertTrue(AVFoundationAudioRecorder.shouldFollowSystemDefaultInputDevice(
            preferredMicrophoneID: AudioDeviceManager.automaticDeviceID
        ))
    }

    func testExplicitInputIgnoresSystemDefaultDeviceChanges() {
        XCTAssertFalse(AVFoundationAudioRecorder.shouldFollowSystemDefaultInputDevice(
            preferredMicrophoneID: "external-microphone"
        ))
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

    func testPrepareEngineForRecordingSessionReplacesStaleEngineInstance() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = AVFoundationAudioRecorder(settingsStore: SettingsStore(defaults: defaults))
        let originalIdentifier = recorder.audioEngineIdentifierForTesting

        recorder.prepareEngineForRecordingSessionForTesting()

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
                defaultInputDeviceID: 7
            )
        )

        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 42)
        XCTAssertEqual(settingsStore.preferredMicrophoneID, "external-mic")
    }

    func testExplicitInputDeviceForRecordingIsNilInAutomaticMode() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 9)
        )

        XCTAssertNil(recorder.explicitInputDeviceIDForRecordingForTesting())
        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 9)
    }

    func testExplicitInputDeviceForRecordingUsesPreferredMicrophoneWhenAvailable() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.preferredMicrophoneID = "external-mic"
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(
                resolvedInputDeviceIDs: ["external-mic": 42],
                defaultInputDeviceID: 7
            )
        )

        XCTAssertEqual(recorder.explicitInputDeviceIDForRecordingForTesting(), 42)
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
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 7)
        )

        XCTAssertEqual(recorder.resolvedInputDeviceIDForTesting(), 7)
        XCTAssertEqual(settingsStore.preferredMicrophoneID, AudioDeviceManager.automaticDeviceID)
    }

    func testExplicitInputDeviceForRecordingFallsBackToAutomaticWhenPreferredMicrophoneIsUnavailable() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.preferredMicrophoneID = "disconnected-mic"
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 7)
        )

        XCTAssertNil(recorder.explicitInputDeviceIDForRecordingForTesting())
        XCTAssertEqual(settingsStore.preferredMicrophoneID, AudioDeviceManager.automaticDeviceID)
    }

    func testResolvedInputDeviceUsesDefaultMicrophoneInAutomaticMode() throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: MockAudioDeviceManager(defaultInputDeviceID: 9)
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
            }
        )

        recorder.beginMutedSessionAfterDelayForTesting()
        await sleepController.waitUntilSleeping()
        XCTAssertEqual(muter.beginCallCount, 0)

        await sleepController.resume()
        await fulfillment(of: [beginExpectation], timeout: 1.0)
        XCTAssertEqual(muter.beginCallCount, 1)
    }

    func testDelayedMuteWaitsForStartCueWhenSoundEffectsAreEnabled() async throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.soundEffectsEnabled = true
        settingsStore.muteSystemOutputDuringRecording = true

        let sleepController = SleepController()
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            outputMuter: MockSystemAudioOutputMuter(),
            sleep: { duration in
                await sleepController.sleep(for: duration)
            }
        )

        recorder.beginMutedSessionAfterDelayForTesting()
        await sleepController.waitUntilSleeping()

        let durations = await sleepController.recordedDurations()
        XCTAssertEqual(durations, [.milliseconds(1225)])
        recorder.cancelMutedSessionForTesting()
        await sleepController.resume()
    }

    func testDelayedMuteUsesShortDelayWhenSoundEffectsAreDisabled() async throws {
        let suiteName = "AVFoundationAudioRecorderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.soundEffectsEnabled = false
        settingsStore.muteSystemOutputDuringRecording = true

        let sleepController = SleepController()
        let recorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            outputMuter: MockSystemAudioOutputMuter(),
            sleep: { duration in
                await sleepController.sleep(for: duration)
            }
        )

        recorder.beginMutedSessionAfterDelayForTesting()
        await sleepController.waitUntilSleeping()

        let durations = await sleepController.recordedDurations()
        XCTAssertEqual(durations, [.milliseconds(180)])
        recorder.cancelMutedSessionForTesting()
        await sleepController.resume()
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
            }
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

    func testSilentInputRecoveryTriggersWhenNoStartupBuffersArrive() {
        XCTAssertTrue(AVFoundationAudioRecorder.shouldRecoverSilentInput(
            isRecording: true,
            callbackCountAtStart: 4,
            currentCallbackCount: 4,
            peakInputPowerSinceStart: -.infinity
        ))
    }

    func testSilentInputRecoveryTriggersWhenStartupBuffersAreSilent() {
        XCTAssertTrue(AVFoundationAudioRecorder.shouldRecoverSilentInput(
            isRecording: true,
            callbackCountAtStart: 4,
            currentCallbackCount: 7,
            peakInputPowerSinceStart: -60
        ))
    }

    func testSilentInputRecoveryDoesNotTriggerAfterAudibleStartupInput() {
        XCTAssertFalse(AVFoundationAudioRecorder.shouldRecoverSilentInput(
            isRecording: true,
            callbackCountAtStart: 4,
            currentCallbackCount: 7,
            peakInputPowerSinceStart: -30
        ))
    }

    func testSilentInputRecoveryDoesNotTriggerForLowButNonZeroStartupInput() {
        XCTAssertFalse(AVFoundationAudioRecorder.shouldRecoverSilentInput(
            isRecording: true,
            callbackCountAtStart: 4,
            currentCallbackCount: 7,
            peakInputPowerSinceStart: -56
        ))
    }

    func testSilentInputRecoveryDoesNotTriggerAfterRecordingStops() {
        XCTAssertFalse(AVFoundationAudioRecorder.shouldRecoverSilentInput(
            isRecording: false,
            callbackCountAtStart: 4,
            currentCallbackCount: 4,
            peakInputPowerSinceStart: -.infinity
        ))
    }

    func testReplacementInputHealthAcceptsSilentBuffersWhenCallbacksResume() {
        XCTAssertFalse(AVFoundationAudioRecorder.shouldRecoverInputHealth(
            requiresAudibleInput: false,
            callbackCountAtStart: 0,
            currentCallbackCount: 2,
            peakInputPowerSinceStart: -60
        ))
    }

    func testReplacementInputHealthRetriesWhenNoCallbacksResume() {
        XCTAssertTrue(AVFoundationAudioRecorder.shouldRecoverInputHealth(
            requiresAudibleInput: false,
            callbackCountAtStart: 0,
            currentCallbackCount: 0,
            peakInputPowerSinceStart: -.infinity
        ))
    }

    private func makeTestBuffer(
        format: AVAudioFormat,
        frameLength: AVAudioFrameCount,
        amplitude: Float = 0
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength))
        buffer.frameLength = frameLength
        if amplitude != 0, let channelData = buffer.floatChannelData {
            for channel in 0 ..< Int(format.channelCount) {
                for frame in 0 ..< Int(frameLength) {
                    channelData[channel][frame] = frame.isMultiple(of: 2) ? amplitude : -amplitude
                }
            }
        }
        return buffer
    }

    private func peakAmplitude(in buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        return (0 ..< Int(buffer.frameLength)).reduce(0) { peak, index in
            max(peak, abs(samples[index]))
        }
    }
}

private final class MockAudioDeviceManager: AudioDeviceManaging {
    private let devices: [AudioInputDevice]
    private let resolvedInputDeviceIDs: [String: AudioDeviceID]
    private let defaultInputDevice: AudioDeviceID?
    private var defaultInputDeviceChangeHandler: (@Sendable () -> Void)?

    init(
        devices: [AudioInputDevice] = [],
        resolvedInputDeviceIDs: [String: AudioDeviceID] = [:],
        defaultInputDeviceID: AudioDeviceID? = nil
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

    func observeDefaultInputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> AudioInputDeviceChangeObservation? {
        defaultInputDeviceChangeHandler = handler
        return MockAudioInputDeviceChangeObservation()
    }

    func simulateDefaultInputDeviceChange() {
        defaultInputDeviceChangeHandler?()
    }
}

private final class MockAudioInputDeviceChangeObservation: AudioInputDeviceChangeObservation {
    func cancel() {}
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
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async {
        durations.append(duration)
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

    func recordedDurations() -> [Duration] {
        durations
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
