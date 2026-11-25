import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Typeflux
import TypefluxAudioSafety

struct CoreAudioRingTests {
    @Test func preservesStartupPrefixAndTimestampsUntilConsumerIsReady() throws {
        let ring = try #require(TFHALInputCreateBufferForTesting(16000, 2, 160))
        defer { TFHALInputDestroy(ring) }
        for index in 0 ..< 8 {
            let samples = [Float](repeating: Float(index) / 10, count: 320)
            #expect(push(ring, samples, 160, UInt64(index * 10), UInt64(index * 10 + 3)))
        }
        var output = [Float](repeating: 0, count: 320)
        var packet = TFHALInputPacket()
        for index in 0 ..< 8 {
            #expect(TFHALInputRead(ring, &output, 160, &packet))
            #expect(packet.frames == 160)
            #expect(packet.sampleHostTime == UInt64(index * 10))
            #expect(packet.callbackHostTime == UInt64(index * 10 + 3))
            #expect(output.allSatisfy { $0 == Float(index) / 10 })
        }
        #expect(!TFHALInputRead(ring, &output, 160, &packet))
    }

    @Test func boundedOverflowDoesNotOverwriteTheUnconsumedPrefix() throws {
        let ring = try #require(TFHALInputCreateBufferForTesting(16, 1, 4))
        defer { TFHALInputDestroy(ring) }
        for index in 0 ..< 8 {
            #expect(push(ring, [Float](repeating: Float(index), count: 4), 4, 0, 0))
        }
        #expect(!push(ring, [99, 99, 99, 99], 4, 0, 0))
        #expect(TFHALInputDroppedFrames(ring) == 4)
        var output: [Float] = [0, 0, 0, 0]
        var packet = TFHALInputPacket()
        for index in 0 ..< 8 {
            #expect(TFHALInputRead(ring, &output, 4, &packet))
            #expect(output == [Float](repeating: Float(index), count: 4))
            #expect(push(ring, [Float](repeating: Float(index + 8), count: 4), 4, 0, 0))
        }
        for index in 8 ..< 16 {
            #expect(TFHALInputRead(ring, &output, 4, &packet))
            #expect(output == [Float](repeating: Float(index), count: 4))
        }
    }

    @Test func refusesUndersizedDestinationWithoutConsumingPacket() throws {
        let ring = try #require(TFHALInputCreateBufferForTesting(16000, 1, 4))
        defer { TFHALInputDestroy(ring) }
        let oversized = push(ring, [1, 2, 3, 4, 5], 5, 0, 0)
        let accepted = push(ring, [1, 2, 3, 4], 4, 0, 0)
        #expect(!oversized)
        #expect(accepted)
        var packet = TFHALInputPacket()
        var output: [Float] = [9, 9, 9, 9]
        #expect(!TFHALInputRead(ring, &output, 2, &packet))
        #expect(output == [9, 9, 9, 9])
        #expect(TFHALInputRead(ring, &output, 4, &packet))
        #expect(output == [1, 2, 3, 4])
        #expect(TFHALInputCreateBufferForTesting(0, 1, 4) == nil)
        #expect(TFHALInputCreateBufferForTesting(16000, 0, 4) == nil)
        #expect(TFHALInputCreateBufferForTesting(16000, 1, 9000) == nil)
    }

    private func push(
        _ ring: OpaquePointer, _ samples: [Float], _ frames: UInt32,
        _ sampleTime: UInt64, _ callbackTime: UInt64
    ) -> Bool {
        samples.withUnsafeBufferPointer { pointer in
            TFHALInputPushForTesting(ring, pointer.baseAddress!, frames, sampleTime, callbackTime)
        }
    }

    @Test func signedHostTimeDifferencesHandleSamplesEarlierThanStart() {
        let duration = AVAudioTime.hostTime(forSeconds: 0.01)
        #expect(abs(CoreAudioRecorder.seconds(from: duration * 2, to: duration) + 0.01) < 0.000_001)
    }
}

struct CoreAudioRecorderTests {
    @Test func capturesEarlyPrefixAndDrainsFinalPacketOnImmediateStop() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2), input.packet(amplitude: 0.4)]
        input.packetOnStop = try input.packet(amplitude: 0.6)
        let recorder = fixture.recorder { _ in input }
        var deliveredFrames = 0
        try recorder.start(levelHandler: { _ in }, audioBufferHandler: { deliveredFrames += Int($0.frameLength) })
        let result = try recorder.stop()
        let file = try AVAudioFile(forReading: result.fileURL)
        #expect(input.starts == 1)
        #expect(input.stops == 1)
        #expect(file.length == 480)
        #expect(deliveredFrames == 480)
        #expect(result.duration == 0.03)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(abs(samples[0] - 0.2) < 0.001)
        #expect(abs(samples[160] - 0.4) < 0.001)
        #expect(abs(samples[320] - 0.6) < 0.001)
        #expect(result.startupTiming?.firstAudioBufferAt != nil)
    }

    @Test func quietAudioIsSavedWithoutRestartingInput() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0)]
        let recorder = fixture.recorder { _ in input }
        try recorder.start(levelHandler: { _ in })
        let file = try recorder.stop()
        #expect(input.starts == 1)
        #expect(file.duration == 0.01)
        #expect(file.startupTiming?.firstAudioSignalAt == nil)
        #expect(file.startupTiming?.leadingZeroDuration == 0.01)
    }

    @Test func measuresDigitalZeroPrefixWithoutRemovingItFromRecording() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        input.packetsOnStart = try [
            input.packet(amplitude: 0), input.packet(amplitude: 0),
            input.packet(amplitude: 0.2)
        ]
        let recorder = fixture.recorder { _ in input }
        try recorder.start(levelHandler: { _ in })
        let result = try recorder.stop()
        #expect(result.startupTiming?.firstAudioSignalAt != nil)
        #expect(result.startupTiming?.leadingZeroDuration == 0.02)
        let file = try AVAudioFile(forReading: result.fileURL)
        #expect(file.length == 480)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0 ..< 320).allSatisfy { samples[$0] == 0 })
        #expect(abs(samples[320] - 0.2) < 0.001)
    }

    @Test func startFailureReleasesInputAndAllowsRetry() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let failed = try FakeInput()
        failed.startError = Failure.expected
        let healthy = try FakeInput()
        healthy.packetsOnStart = try [healthy.packet(amplitude: 0.3)]
        var attempts = 0
        let recorder = fixture.recorder { _ in
            attempts += 1
            return attempts == 1 ? failed : healthy
        }
        #expect(throws: Failure.self) { try recorder.start(levelHandler: { _ in }) }
        #expect(failed.stops == 1)
        try recorder.start(levelHandler: { _ in })
        #expect(try recorder.stop().duration == 0.01)
    }

    @Test func missingAudioAndOverflowAreReportedInsteadOfReturningSuccess() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        let recorder = fixture.recorder { _ in input }
        try recorder.start(levelHandler: { _ in })
        #expect(throws: AVFoundationAudioRecorder.RecorderError.self) { try recorder.stop() }
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        input.captureError = Failure.expected
        try recorder.start(levelHandler: { _ in })
        #expect(throws: Failure.self) { try recorder.stop() }
        let enumerator = FileManager.default.enumerator(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect((enumerator?.allObjects as? [URL] ?? []).allSatisfy { $0.pathExtension != "wav" })
    }

    @Test func preferredDeviceFallsBackWhenDisconnectedAndIdleDoesNotStartInput() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.preferredMicrophoneID = "disconnected"
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        var resolved: AudioDeviceID?
        let recorder = fixture.recorder { id in
            resolved = id
            return input
        }
        #expect(input.starts == 0)
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(resolved == 42)
    }

    @Test func automaticSelectionRecordsFromTheAutomaticInputInsteadOfABluetoothDefault() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.devices.automatic = 7
        fixture.devices.bluetooth = [42]
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        var resolved: [AudioDeviceID] = []
        let recorder = fixture.recorder { id in
            resolved.append(id)
            return input
        }
        try recorder.start(levelHandler: { _ in })
        #expect(!recorder.activeInputIsBluetooth)
        _ = try recorder.stop()
        #expect(resolved == [7])
    }

    @Test func explicitlySelectedBluetoothMicrophoneWinsOverAutomaticSelection() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.preferredMicrophoneID = "airpods"
        fixture.devices.explicit = ["airpods": 10]
        fixture.devices.automatic = 7
        fixture.devices.bluetooth = [10]
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        var resolved: [AudioDeviceID] = []
        let recorder = fixture.recorder { id in
            resolved.append(id)
            return input
        }
        #expect(!recorder.activeInputIsBluetooth)
        try recorder.start(levelHandler: { _ in })
        #expect(recorder.activeInputIsBluetooth)
        _ = try recorder.stop()
        #expect(!recorder.activeInputIsBluetooth)
        #expect(resolved == [10])
    }

    @Test func defaultInputChangeKeepsRecordingWhenAutomaticInputIsUnchanged() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.devices.automatic = 7
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        var attempts = 0
        let recorder = fixture.recorder { _ in
            attempts += 1
            return input
        }
        try recorder.start(levelHandler: { _ in })
        // A headset connected and became the system default; Automatic still picks 7.
        recorder.defaultInputChangedForTesting()
        #expect(input.stops == 0)
        #expect(attempts == 1)
        _ = try recorder.stop()
    }

    @Test func defaultInputChangeSwitchesToTheNewAutomaticInput() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.devices.automatic = 7
        let oldInput = try FakeInput()
        oldInput.packetsOnStart = try [oldInput.packet(amplitude: 0.2)]
        let replacement = try FakeInput()
        replacement.packetsOnStart = try [replacement.packet(amplitude: 0.5)]
        var resolved: [AudioDeviceID] = []
        let recorder = fixture.recorder { id in
            resolved.append(id)
            return id == 7 ? oldInput : replacement
        }
        try recorder.start(levelHandler: { _ in })
        fixture.devices.automatic = 8
        fixture.devices.bluetooth = [8]
        recorder.defaultInputChangedForTesting()
        #expect(recorder.activeInputIsBluetooth)
        let result = try recorder.stop()
        #expect(resolved == [7, 8])
        #expect(oldInput.stops == 1)
        #expect(replacement.starts == 1)
        #expect(try AVAudioFile(forReading: result.fileURL).length == 320)
    }

    @Test func systemDefaultChangeNotificationReachesTheRecorder() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.devices.automatic = 7
        let oldInput = try FakeInput()
        oldInput.packetsOnStart = try [oldInput.packet(amplitude: 0.2)]
        let replacement = try FakeInput()
        replacement.packetsOnStart = try [replacement.packet(amplitude: 0.5)]
        var resolved: [AudioDeviceID] = []
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: true,
            makeInput: { id in
                resolved.append(id)
                return id == 7 ? oldInput : replacement
            }
        )
        try recorder.start(levelHandler: { _ in })
        fixture.devices.automatic = 8
        let notify = try #require(fixture.devices.defaultInputChanged)
        notify()
        recorder.drainForTesting()
        _ = try recorder.stop()
        #expect(resolved == [7, 8])
        #expect(replacement.starts == 1)
    }

    @Test func explicitMicrophoneIgnoresSystemDefaultChanges() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.preferredMicrophoneID = "usb"
        fixture.devices.explicit = ["usb": 5]
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.2)]
        var attempts = 0
        let recorder = fixture.recorder { _ in
            attempts += 1
            return input
        }
        try recorder.start(levelHandler: { _ in })
        fixture.devices.automatic = 8
        recorder.defaultInputChangedForTesting()
        #expect(attempts == 1)
        #expect(input.stops == 0)
        _ = try recorder.stop()
    }

    @Test func timedOutPreparationCannotStartTheMicrophoneLater() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: Devices(),
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: false,
            startupTimeout: 0.01,
            makeInput: { _ in
                Thread.sleep(forTimeInterval: 0.5)
                return input
            }
        )
        #expect(throws: AVFoundationAudioRecorder.RecorderError.self) { try recorder.start(levelHandler: { _ in }) }
        recorder.drainForTesting()
        #expect(input.starts == 0)
    }

    @Test func inputChangeDrainsOldAudioAndContinuesInTheSameFile() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let oldInput = try FakeInput()
        oldInput.packetsOnStart = try [oldInput.packet(amplitude: 0.2)]
        oldInput.packetOnStop = try oldInput.packet(amplitude: 0.3)
        let replacement = try FakeInput()
        replacement.packetsOnStart = try [replacement.packet(amplitude: 0.5)]
        var attempts = 0
        let recorder = fixture.recorder { _ in
            attempts += 1
            return attempts == 1 ? oldInput : replacement
        }
        try recorder.start(levelHandler: { _ in })
        recorder.inputChangedForTesting()
        let result = try recorder.stop()
        #expect(oldInput.stops == 1)
        #expect(replacement.starts == 1)
        #expect(replacement.stops == 1)
        #expect(try AVAudioFile(forReading: result.fileURL).length == 480)
    }

    @Test func lateHardwareStartIsStoppedWithoutDeliveringStaleAudio() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        // Leave enough dispatch time under concurrent coverage instrumentation so
        // this exercises a late hardware start, rather than a timeout before start.
        input.startDelay = 0.5
        input.packetsOnStart = try [input.packet(amplitude: 0.3)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: Devices(),
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: false,
            startupTimeout: 0.25, makeInput: { _ in input }
        )
        var deliveredFrames = 0
        #expect(throws: AVFoundationAudioRecorder.RecorderError.self) {
            try recorder.start(levelHandler: { _ in }, audioBufferHandler: { deliveredFrames += Int($0.frameLength) })
        }
        recorder.drainForTesting()
        #expect(input.starts == 1)
        #expect(input.stops == 1)
        #expect(deliveredFrames == 0)
    }

    @Test func instantVoiceInputKeepsExternalMicrophoneWarmAndPrependsBoundedPreRoll() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.instantVoiceInputEnabled = true
        fixture.devices.automatic = 42 // External USB / hub microphone (not built-in)
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.1)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: true,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 60,
            makeInput: { _ in input }
        )

        // First recording starts cold, then keeps the external input warm on stop.
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(input.starts == 1)
        #expect(input.stops == 0)
        #expect(recorder.isWarmWindowActiveForTesting)

        // Emit three 10ms packets while warm; 20ms pre-roll keeps the newest two (0.3, 0.4).
        try input.enqueue([
            input.packet(amplitude: 0.2),
            input.packet(amplitude: 0.3),
            input.packet(amplitude: 0.4)
        ])
        recorder.consumeWarmInputForTesting()

        // Start the second recording (replaying 0.3 and 0.4 from pre-roll), then emit live audio (0.5).
        var streamedFrames = 0
        var lastLevel: Float = 0
        try recorder.start(
            levelHandler: { lastLevel = $0 },
            audioBufferHandler: { streamedFrames += Int($0.frameLength) }
        )
        try input.enqueue([input.packet(amplitude: 0.5)])
        let second = try recorder.stop()

        // Hardware never stopped or restarted across the warm transition.
        #expect(input.starts == 1)
        #expect(input.stops == 0)
        #expect(streamedFrames == 480)
        #expect(lastLevel > 0)
        #expect(second.startupTiming?.firstAudioBufferAt == second.startupTiming?.audioEngineStartedAt)

        let file = try AVAudioFile(forReading: second.fileURL)
        #expect(file.length == 480)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(abs(samples[0] - 0.3) < 0.001)
        #expect(abs(samples[160] - 0.4) < 0.001)
        #expect(abs(samples[320] - 0.5) < 0.001)
    }

    @Test func externalDisplayOutputSwitchDuringMutedRecordingDoesNotInterruptWarmCapture() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.instantVoiceInputEnabled = true
        fixture.settings.muteSystemOutputDuringRecording = true
        fixture.devices.automatic = 42 // External USB microphone on monitor hub

        // External DisplayPort monitor (171) has no mute control; built-in speakers (157) can mute.
        let outputDevices = OutputDevices(defaultID: 171, builtInID: 157, muteStates: [157: 0])
        let outputMuter = SystemAudioOutputMuter(devices: outputDevices)
        let input = try FakeInput()
        input.packetsOnStart = try [input.packet(amplitude: 0.25)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputMuter: outputMuter, outputDirectory: fixture.directory,
            prepareImmediately: false, observeChanges: true,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 60,
            makeInput: { _ in input }
        )

        // First session arms warm capture and exercises delayed mute + output switch + restore.
        try recorder.start(levelHandler: { _ in })
        Thread.sleep(forTimeInterval: 0.22)
        recorder.drainForTesting()
        #expect(outputDevices.defaultID == 157)
        #expect(outputDevices.muteStates[157] == 1)

        try input.enqueue([input.packet(amplitude: 0.35)])
        let first = try recorder.stop()
        #expect(outputDevices.defaultID == 171)
        #expect(outputDevices.muteStates[157] == 0)
        #expect(try AVAudioFile(forReading: first.fileURL).length == 320)
        #expect(input.starts == 1)
        #expect(input.stops == 0)
        #expect(recorder.isWarmWindowActiveForTesting)

        // Second session starts with pre-roll and survives another output switch with zero gap.
        try input.enqueue([input.packet(amplitude: 0.45)])
        try recorder.start(levelHandler: { _ in })
        Thread.sleep(forTimeInterval: 0.22)
        try input.enqueue([input.packet(amplitude: 0.55)])
        let second = try recorder.stop()

        #expect(outputDevices.defaultID == 171)
        #expect(outputDevices.muteStates[157] == 0)
        #expect(input.starts == 1)
        #expect(input.stops == 0)
        let file = try AVAudioFile(forReading: second.fileURL)
        #expect(file.length == 320)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(abs(samples[0] - 0.45) < 0.001)
        #expect(abs(samples[160] - 0.55) < 0.001)
    }

    @Test func instantVoiceInputReleasesWarmInputAfterIdleTimeoutDisableBuiltInOrSleep() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.instantVoiceInputEnabled = true
        fixture.devices.explicit = ["usb": 42, "built-in": 9]
        fixture.devices.builtIn = [9]
        fixture.settings.preferredMicrophoneID = "usb"

        let firstInput = try FakeInput()
        firstInput.packetsOnStart = try [firstInput.packet(amplitude: 0.2)]
        let timeoutRecorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: true,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 0.05,
            makeInput: { _ in firstInput }
        )
        try timeoutRecorder.start(levelHandler: { _ in })
        _ = try timeoutRecorder.stop()
        #expect(timeoutRecorder.isWarmWindowActiveForTesting)
        Thread.sleep(forTimeInterval: 0.12)
        timeoutRecorder.drainForTesting()
        #expect(!timeoutRecorder.isWarmWindowActiveForTesting)
        #expect(firstInput.stops == 1)

        // Disabling Instant Voice Input stops the warm input immediately.
        let secondInput = try FakeInput()
        secondInput.packetsOnStart = try [secondInput.packet(amplitude: 0.2)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: true,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 60,
            makeInput: { _ in secondInput }
        )
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(recorder.isWarmWindowActiveForTesting)
        fixture.settings.instantVoiceInputEnabled = false
        recorder.drainForTesting()
        #expect(!recorder.isWarmWindowActiveForTesting)
        #expect(secondInput.stops == 1)

        // Switching to a built-in microphone cancels an active warm window.
        fixture.settings.instantVoiceInputEnabled = true
        secondInput.packetsOnStart = try [secondInput.packet(amplitude: 0.2)]
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(recorder.isWarmWindowActiveForTesting)
        fixture.settings.preferredMicrophoneID = "built-in"
        recorder.drainForTesting()
        #expect(!recorder.isWarmWindowActiveForTesting)
        #expect(secondInput.stops == 2)

        // Built-in microphone does not stay warm on stop even when the toggle is enabled.
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(!recorder.isWarmWindowActiveForTesting)
        #expect(secondInput.stops == 3)

        // Sleep / session lock releases an active warm input immediately.
        fixture.settings.preferredMicrophoneID = "usb"
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(recorder.isWarmWindowActiveForTesting)
        recorder.suspendForTesting()
        #expect(!recorder.isWarmWindowActiveForTesting)
        #expect(secondInput.stops == 4)
        recorder.resumeForTesting()
    }

    @Test func warmInputCaptureErrorFallsBackToFreshColdInputOnNextStart() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.instantVoiceInputEnabled = true
        let brokenAfterStop = try FakeInput()
        brokenAfterStop.packetsOnStart = try [brokenAfterStop.packet(amplitude: 0.2)]
        let healthy = try FakeInput()
        healthy.packetsOnStart = try [healthy.packet(amplitude: 0.6)]
        var created = 0
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: false,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 60,
            makeInput: { _ in
                created += 1
                return created == 1 ? brokenAfterStop : healthy
            }
        )

        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        brokenAfterStop.captureError = Failure.expected

        try recorder.start(levelHandler: { _ in })
        let result = try recorder.stop()
        #expect(brokenAfterStop.stops == 1)
        #expect(healthy.starts == 1)
        #expect(result.duration == 0.01)
    }

    @Test func preRollBufferSlicesSingleOversizedPacketToConfiguredTail() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1))
        let raw = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        raw.frameLength = 100
        for index in 0 ..< 100 {
            raw.floatChannelData?[0][index] = Float(index)
        }
        var preRoll = CoreAudioPreRollBuffer(maximumDuration: 0.04, sampleRate: 1000)
        preRoll.append(CoreAudioInputPacket(buffer: raw, sampleHostTime: 100, callbackHostTime: 200))

        let drained = preRoll.drain()
        #expect(drained.count == 1)
        #expect(drained[0].buffer.frameLength == 40)
        #expect(drained[0].buffer.floatChannelData?[0][0] == 60)
        #expect(drained[0].buffer.floatChannelData?[0][39] == 99)

        let stereo = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 1000, channels: 2, interleaved: true
        ))
        let stereoBuffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 100))
        stereoBuffer.frameLength = 100
        for index in 0 ..< 200 {
            stereoBuffer.floatChannelData?[0][index] = Float(index)
        }
        preRoll.append(CoreAudioInputPacket(buffer: stereoBuffer, sampleHostTime: 0, callbackHostTime: 300))
        let stereoDrained = preRoll.drain()
        #expect(stereoDrained.count == 1)
        #expect(stereoDrained[0].buffer.frameLength == 40)
        #expect(stereoDrained[0].buffer.floatChannelData?[0][0] == 120)
        #expect(stereoDrained[0].buffer.floatChannelData?[0][79] == 199)
    }

    @Test func switchingExternalMicrophonesRearmsWarmSessionOnNewDevice() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.instantVoiceInputEnabled = true
        fixture.devices.explicit = ["usb-a": 42, "usb-b": 43]
        fixture.settings.preferredMicrophoneID = "usb-a"

        let first = try FakeInput()
        first.packetsOnStart = try [first.packet(amplitude: 0.2)]
        let second = try FakeInput()
        second.packetsOnStart = try [second.packet(amplitude: 0.7)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: fixture.devices,
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: true,
            preRollDuration: 0.02, instantVoiceInputIdleTimeout: 60,
            makeInput: { id in id == 42 ? first : second }
        )

        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(recorder.isWarmWindowActiveForTesting)

        fixture.settings.preferredMicrophoneID = "usb-b"
        recorder.drainForTesting()
        #expect(first.stops == 1)
        #expect(second.starts == 1)
        #expect(recorder.isWarmWindowActiveForTesting)

        try recorder.start(levelHandler: { _ in })
        let result = try recorder.stop()
        #expect(second.starts == 1)
        #expect(result.duration == 0.01)
    }

    private enum Failure: Error { case expected }

    private final class OutputDevices: AudioOutputDeviceAccessing {
        var defaultID: AudioDeviceID?
        let builtInID: AudioDeviceID?
        var muteStates: [AudioDeviceID: UInt32]
        init(defaultID: AudioDeviceID?, builtInID: AudioDeviceID?, muteStates: [AudioDeviceID: UInt32]) {
            self.defaultID = defaultID
            self.builtInID = builtInID
            self.muteStates = muteStates
        }

        func defaultOutputDeviceID() -> AudioDeviceID? {
            defaultID
        }

        func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
            defaultID = deviceID
            return true
        }

        func builtInOutputDeviceID() -> AudioDeviceID? {
            builtInID
        }

        func currentMuteState(for deviceID: AudioDeviceID) -> UInt32? {
            muteStates[deviceID]
        }

        func setMute(_ isMuted: Bool, for deviceID: AudioDeviceID) -> Bool {
            guard muteStates[deviceID] != nil else { return false }
            muteStates[deviceID] = isMuted ? 1 : 0
            return true
        }
    }

    private final class FakeInput: CoreAudioInputCapturing {
        let format: AVAudioFormat
        let deviceBufferFrames: UInt32 = 160
        private let lock = NSLock()
        var captureError: Error?
        var startError: Error?
        var startDelay: TimeInterval = 0
        var starts = 0
        var stops = 0
        var packetsOnStart: [CoreAudioInputPacket] = []
        var packetOnStop: CoreAudioInputPacket?
        private var pending: [CoreAudioInputPacket] = []

        init() throws {
            format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        }

        func start() throws {
            starts += 1
            if startDelay > 0 {
                Thread.sleep(forTimeInterval: startDelay)
            }
            if let startError {
                throw startError
            }
            lock.withLock { pending = packetsOnStart }
        }

        func stop() {
            stops += 1
            lock.withLock {
                if let packetOnStop {
                    pending.append(packetOnStop)
                    self.packetOnStop = nil
                }
            }
        }

        func enqueue(_ packets: [CoreAudioInputPacket]) {
            lock.withLock { pending.append(contentsOf: packets) }
        }

        func read() -> CoreAudioInputPacket? {
            lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        }

        func packet(amplitude: Float) throws -> CoreAudioInputPacket {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            for index in 0 ..< 160 {
                buffer.floatChannelData![0][index] = amplitude
            }
            return CoreAudioInputPacket(
                buffer: buffer, sampleHostTime: mach_absolute_time(), callbackHostTime: mach_absolute_time()
            )
        }
    }

    private final class Devices: AudioDeviceManaging {
        var explicit: [String: AudioDeviceID] = [:]
        var automatic: AudioDeviceID = 42
        var bluetooth: Set<AudioDeviceID> = []
        var builtIn: Set<AudioDeviceID> = []
        func availableInputDevices() -> [AudioInputDevice] {
            []
        }

        func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID? {
            explicit[uniqueID]
        }

        func defaultInputDeviceID() -> AudioDeviceID? {
            42
        }

        func automaticRecordingInputDeviceID() -> AudioDeviceID? {
            automatic
        }

        func isBluetoothInputDevice(_ deviceID: AudioDeviceID) -> Bool {
            bluetooth.contains(deviceID)
        }

        func isBuiltInInputDevice(_ deviceID: AudioDeviceID) -> Bool {
            builtIn.contains(deviceID)
        }

        var defaultInputChanged: (@Sendable () -> Void)?
        func observeDefaultInputDeviceChanges(_ handler: @escaping @Sendable () -> Void)
            -> AudioInputDeviceChangeObservation? {
            defaultInputChanged = handler
            return nil
        }
    }

    private final class Fixture {
        let suite = "CoreAudioRecorderTests." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let devices = Devices()
        func recorder(makeInput: @escaping (AudioDeviceID) throws -> CoreAudioInputCapturing) -> CoreAudioRecorder {
            CoreAudioRecorder(
                settingsStore: settings, audioDeviceManager: devices, outputDirectory: directory,
                prepareImmediately: false, observeChanges: false, makeInput: makeInput
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}

struct SwitchableAudioRecorderTests {
    @Test func bothOrdinaryAndInstantVoiceInputDefaultToCoreAudioUnlessOverriddenToLegacy() {
        #expect(SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: false, override: nil))
        #expect(SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: true, override: nil))
        #expect(!SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: false, override: "legacy"))
        #expect(!SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: true, override: "legacy"))
        #expect(SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: true, override: "coreaudio"))
    }

    @Test func selectionIsPinnedUntilStopAndFallbackDoesNotRetryMidRecording() throws {
        var coreEnabled = true
        let core = FakeRecorder()
        let legacy = FakeRecorder()
        let recorder = SwitchableAudioRecorder(
            useCoreAudio: { coreEnabled }, makeCoreAudio: { core }, makeLegacy: { legacy }
        )
        try recorder.start(levelHandler: { _ in })
        coreEnabled = false
        _ = try recorder.stop()
        #expect(core.stops == 1)
        #expect(legacy.stops == 0)
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(legacy.starts == 1)
        #expect(legacy.stops == 1)
    }

    @Test func failedCoreStartupUsesCompatibleRecorder() throws {
        let core = FakeRecorder()
        core.failStart = true
        let legacy = FakeRecorder()
        let recorder = SwitchableAudioRecorder(useCoreAudio: { true }, makeCoreAudio: { core }, makeLegacy: { legacy })
        try recorder.start(levelHandler: { _ in })
        _ = try recorder.stop()
        #expect(core.starts == 1)
        #expect(core.stops == 0)
        #expect(legacy.starts == 1)
        #expect(legacy.stops == 1)
    }

    @Test func reportsBluetoothInputOfTheActiveRecorderOnly() throws {
        let core = FakeRecorder()
        core.bluetooth = true
        let recorder = SwitchableAudioRecorder(
            useCoreAudio: { true }, makeCoreAudio: { core }, makeLegacy: { FakeRecorder() }
        )
        #expect(!recorder.activeInputIsBluetooth)
        try recorder.start(levelHandler: { _ in })
        #expect(recorder.activeInputIsBluetooth)
        _ = try recorder.stop()
        #expect(!recorder.activeInputIsBluetooth)
    }

    private final class FakeRecorder: AudioRecorder {
        var starts = 0
        var stops = 0
        var failStart = false
        var bluetooth = false
        var activeInputIsBluetooth: Bool {
            bluetooth
        }

        func start(
            levelHandler _: @escaping (Float) -> Void,
            audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
        ) throws {
            starts += 1
            if failStart {
                throw NSError(domain: "test", code: 1)
            }
        }

        func stop() throws -> AudioFile {
            stops += 1
            return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/unused.wav"), duration: 0)
        }
    }
}
