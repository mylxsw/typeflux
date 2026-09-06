import AVFoundation
import CoreAudio
import Foundation
import Testing
import TypefluxAudioSafety

@testable import Typeflux

struct CoreAudioRingTests {
    @Test func preservesStartupPrefixAndTimestampsUntilConsumerIsReady() throws {
        let ring = try #require(TFHALInputCreateBufferForTesting(16000, 2, 160))
        defer { TFHALInputDestroy(ring) }
        for index in 0..<8 {
            let samples = [Float](repeating: Float(index) / 10, count: 320)
            #expect(push(ring, samples, 160, UInt64(index * 10), UInt64(index * 10 + 3)))
        }
        var output = [Float](repeating: 0, count: 320)
        var packet = TFHALInputPacket()
        for index in 0..<8 {
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
        for index in 0..<8 {
            #expect(push(ring, [Float](repeating: Float(index), count: 4), 4, 0, 0))
        }
        #expect(!push(ring, [99, 99, 99, 99], 4, 0, 0))
        #expect(TFHALInputDroppedFrames(ring) == 4)
        var output: [Float] = [0, 0, 0, 0]
        var packet = TFHALInputPacket()
        for index in 0..<8 {
            #expect(TFHALInputRead(ring, &output, 4, &packet))
            #expect(output == [Float](repeating: Float(index), count: 4))
            #expect(push(ring, [Float](repeating: Float(index + 8), count: 4), 4, 0, 0))
        }
        for index in 8..<16 {
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
        input.packetsOnStart = [try input.packet(amplitude: 0.2), try input.packet(amplitude: 0.4)]
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
        input.packetsOnStart = [try input.packet(amplitude: 0)]
        let recorder = fixture.recorder { _ in input }
        try recorder.start(levelHandler: { _ in })
        let file = try recorder.stop()
        #expect(input.starts == 1)
        #expect(file.duration == 0.01)
    }

    @Test func startFailureReleasesInputAndAllowsRetry() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let failed = try FakeInput()
        failed.startError = Failure.expected
        let healthy = try FakeInput()
        healthy.packetsOnStart = [try healthy.packet(amplitude: 0.3)]
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
        input.packetsOnStart = [try input.packet(amplitude: 0.2)]
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
        input.packetsOnStart = [try input.packet(amplitude: 0.2)]
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

    @Test func timedOutPreparationCannotStartTheMicrophoneLater() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let input = try FakeInput()
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: Devices(),
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: false,
            startupTimeout: 0.01,
            makeInput: { _ in
                Thread.sleep(forTimeInterval: 0.05)
                return input
            })
        #expect(throws: AVFoundationAudioRecorder.RecorderError.self) { try recorder.start(levelHandler: { _ in }) }
        recorder.drainForTesting()
        #expect(input.starts == 0)
    }

    @Test func inputChangeDrainsOldAudioAndContinuesInTheSameFile() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let oldInput = try FakeInput()
        oldInput.packetsOnStart = [try oldInput.packet(amplitude: 0.2)]
        oldInput.packetOnStop = try oldInput.packet(amplitude: 0.3)
        let replacement = try FakeInput()
        replacement.packetsOnStart = [try replacement.packet(amplitude: 0.5)]
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
        input.startDelay = 0.05
        input.packetsOnStart = [try input.packet(amplitude: 0.3)]
        let recorder = CoreAudioRecorder(
            settingsStore: fixture.settings, audioDeviceManager: Devices(),
            outputDirectory: fixture.directory, prepareImmediately: false, observeChanges: false,
            startupTimeout: 0.01, makeInput: { _ in input })
        var deliveredFrames = 0
        #expect(throws: AVFoundationAudioRecorder.RecorderError.self) {
            try recorder.start(levelHandler: { _ in }, audioBufferHandler: { deliveredFrames += Int($0.frameLength) })
        }
        recorder.drainForTesting()
        #expect(input.starts == 1)
        #expect(input.stops == 1)
        #expect(deliveredFrames == 0)
    }

    private enum Failure: Error { case expected }

    private final class FakeInput: CoreAudioInputCapturing {
        let format: AVAudioFormat
        let deviceBufferFrames: UInt32 = 160
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
            if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
            if let startError { throw startError }
            pending = packetsOnStart
        }
        func stop() {
            stops += 1
            if let packetOnStop {
                pending.append(packetOnStop)
                self.packetOnStop = nil
            }
        }
        func read() -> CoreAudioInputPacket? { pending.isEmpty ? nil : pending.removeFirst() }
        func packet(amplitude: Float) throws -> CoreAudioInputPacket {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            for index in 0..<160 { buffer.floatChannelData![0][index] = amplitude }
            return CoreAudioInputPacket(
                buffer: buffer, sampleHostTime: mach_absolute_time(), callbackHostTime: mach_absolute_time())
        }
    }

    private final class Devices: AudioDeviceManaging {
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID? { nil }
        func defaultInputDeviceID() -> AudioDeviceID? { 42 }
        func observeDefaultInputDeviceChanges(_ handler: @escaping @Sendable () -> Void)
            -> AudioInputDeviceChangeObservation?
        { nil }
    }

    private final class Fixture {
        let suite = "CoreAudioRecorderTests." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        func recorder(makeInput: @escaping (AudioDeviceID) throws -> CoreAudioInputCapturing) -> CoreAudioRecorder {
            CoreAudioRecorder(
                settingsStore: settings, audioDeviceManager: Devices(), outputDirectory: directory,
                prepareImmediately: false, observeChanges: false, makeInput: makeInput)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}

struct SwitchableAudioRecorderTests {
    @Test func ordinaryRecordingDefaultsToCoreAudioWhileInstantInputKeepsPreRoll() {
        #expect(SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: false, override: nil))
        #expect(!SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: true, override: nil))
        #expect(!SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: false, override: "legacy"))
        #expect(!SwitchableAudioRecorder.usesCoreAudio(instantVoiceInputEnabled: true, override: "coreaudio"))
    }

    @Test func selectionIsPinnedUntilStopAndFallbackDoesNotRetryMidRecording() throws {
        var coreEnabled = true
        let core = FakeRecorder()
        let legacy = FakeRecorder()
        let recorder = SwitchableAudioRecorder(
            useCoreAudio: { coreEnabled }, makeCoreAudio: { core }, makeLegacy: { legacy })
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

    private final class FakeRecorder: AudioRecorder {
        var starts = 0
        var stops = 0
        var failStart = false
        func start(levelHandler: @escaping (Float) -> Void, audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?) throws {
            starts += 1
            if failStart { throw NSError(domain: "test", code: 1) }
        }
        func stop() throws -> AudioFile {
            stops += 1
            return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/unused.wav"), duration: 0)
        }
    }
}
