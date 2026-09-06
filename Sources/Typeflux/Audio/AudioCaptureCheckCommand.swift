#if DEBUG
    import AVFoundation
    import CoreAudio
    import Foundation

    /// Run from the signed development app, never from an unbundled SwiftPM executable.
    /// Captured audio is discarded; only timing and device-running state are printed.
    public enum AudioCaptureCheckCommand {
        public static func run(arguments: [String]) async -> Int {
            guard Bundle.main.bundleURL.pathExtension == "app",
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                let requestedMode = arguments.first,
                ["coreaudio", "legacy", "pipeline", "compare"].contains(requestedMode)
            else {
                print(
                    "Use the microphone-authorized signed app: audio-capture-check coreaudio|legacy|pipeline|compare [1...20]"
                )
                return 1
            }
            let count = min(20, max(1, Int(arguments.dropFirst().first ?? "5") ?? 5))
            let devices = AudioDeviceManager()
            let settings = SettingsStore()
            guard
                let device = devices.resolveInputDeviceID(for: settings.preferredMicrophoneID)
                    ?? devices.defaultInputDeviceID()
            else { return 1 }
            do {
                for iteration in 1...count {
                    let mode =
                        requestedMode == "compare"
                        ? (iteration.isMultiple(of: 2) ? "coreaudio" : "legacy") : requestedMode
                    let idleBefore = running(device)
                    let processIdleBefore = processInputRunning()
                    if mode == "pipeline" {
                        try await checkPipeline(settings: settings, devices: devices, iteration: iteration)
                        continue
                    }
                    let preparedAt = mach_absolute_time()
                    let metrics = Metrics()
                    var input: CoreAudioInput?
                    var engine: AVAudioEngine?
                    if mode == "coreaudio" {
                        input = try CoreAudioInput(deviceID: device)
                    } else {
                        let newEngine = AVAudioEngine()
                        newEngine.inputNode.auAudioUnit.setValue(Int(device), forKey: "deviceID")
                        newEngine.inputNode.installTap(
                            onBus: 0, bufferSize: AVFoundationAudioRecorder.inputTapBufferSize,
                            format: nil
                        ) { buffer, timestamp in
                            metrics.append(
                                frames: buffer.frameLength, sampleRate: buffer.format.sampleRate,
                                sampleHostTime: timestamp.isHostTimeValid ? timestamp.hostTime : 0,
                                callbackHostTime: mach_absolute_time(), buffer: buffer)
                        }
                        newEngine.prepare()
                        engine = newEngine
                    }
                    let preparationMs = CoreAudioRecorder.seconds(from: preparedAt, to: mach_absolute_time()) * 1000
                    try await Task.sleep(for: .milliseconds(500))
                    let idlePrepared = running(device)
                    let processIdlePrepared = processInputRunning()
                    let start = mach_absolute_time()
                    if let input { try input.start() } else { try engine?.start() }
                    let startReturnedMs = CoreAudioRecorder.seconds(from: start, to: mach_absolute_time()) * 1000
                    let isRunning = running(device)
                    let processRecording = processInputRunning()
                    for _ in 0..<400 {
                        if let input {
                            while let packet = input.read() {
                                metrics.append(
                                    frames: packet.buffer.frameLength, sampleRate: packet.buffer.format.sampleRate,
                                    sampleHostTime: packet.sampleHostTime, callbackHostTime: packet.callbackHostTime, buffer: packet.buffer)
                            }
                        }
                        try await Task.sleep(for: .milliseconds(4))
                    }
                    input?.stop()
                    engine?.stop()
                    if let input {
                        while let packet = input.read() {
                            metrics.append(
                                frames: packet.buffer.frameLength, sampleRate: packet.buffer.format.sampleRate,
                                sampleHostTime: packet.sampleHostTime, callbackHostTime: packet.callbackHostTime, buffer: packet.buffer)
                        }
                        if let error = input.captureError { throw error }
                    }
                    engine?.inputNode.removeTap(onBus: 0)
                    try await Task.sleep(for: .milliseconds(300))
                    let idleStopped = running(device)
                    let processIdleStopped = processInputRunning()
                    input = nil
                    engine = nil
                    let result = metrics.summary(start: start).merging([
                        "mode": mode, "iteration": iteration, "preparationMs": preparationMs,
                        "startReturnMs": startReturnedMs, "runningBefore": idleBefore,
                        "runningPrepared": idlePrepared, "runningDuring": isRunning,
                        "runningStopped": idleStopped, "deviceID": device,
                        "processInputBefore": processIdleBefore, "processInputPrepared": processIdlePrepared,
                        "processInputDuring": processRecording, "processInputStopped": processIdleStopped,
                    ]) { _, right in right }
                    print(
                        String(
                            data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
                            encoding: .utf8)!)
                    try await Task.sleep(for: .milliseconds(300))
                }
                return 0
            } catch {
                print("Audio capture check failed: \(error.localizedDescription)")
                return 1
            }
        }

        private static func checkPipeline(settings: SettingsStore, devices: AudioDeviceManager, iteration: Int)
            async throws
        {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "typeflux-capture-check-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = CoreAudioRecorder(
                settingsStore: settings, audioDeviceManager: devices, outputDirectory: directory)
            try await Task.sleep(for: .milliseconds(500))
            let started = Date()
            try await recorder.startInBackground(levelHandler: { _ in }, audioBufferHandler: nil)
            try await Task.sleep(for: .milliseconds(650))
            let result = try recorder.stop()
            let file = try AVAudioFile(forReading: result.fileURL)
            print(
                "pipeline iteration=\(iteration) firstCallbackMs=\((result.startupTiming!.firstAudioBufferAt!.timeIntervalSince(started)) * 1000) frames=\(file.length) duration=\(result.duration) channels=\(file.processingFormat.channelCount)"
            )
            guard file.length > 0, file.processingFormat.channelCount == 1 else {
                throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            }
        }

        private static func running(_ device: AudioDeviceID) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? Int(value) : -1
        }

        private static func processInputRunning() -> Int {
            guard #available(macOS 14.2, *) else { return -1 }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = getpid()
            var process: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr
            else { return -1 }
            if process == kAudioObjectUnknown { return 0 }
            address.mSelector = kAudioProcessPropertyIsRunningInput
            var value: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr ? Int(value) : -1
        }

        private final class Metrics: @unchecked Sendable {
            private let lock = NSLock()
            private var firstCallback: UInt64?
            private var firstSample: UInt64?
            private var firstFrames: UInt32 = 0
            private var totalFrames: UInt64 = 0
            private var rate: Double = 0
            private var previousSample: UInt64?
            private var previousFrames: UInt32 = 0
            private var maximumGap: Double = 0
            private var firstNonzeroFrame: UInt64?
            private var firstNonzeroCallback: UInt64?

            func append(frames: UInt32, sampleRate: Double, sampleHostTime: UInt64, callbackHostTime: UInt64, buffer: AVAudioPCMBuffer) {
                lock.lock()
                defer { lock.unlock() }
                if firstCallback == nil {
                    firstCallback = callbackHostTime
                    firstSample = sampleHostTime == 0 ? nil : sampleHostTime
                    firstFrames = frames
                }
                if let previousSample, sampleHostTime > 0 {
                    let gap =
                        CoreAudioRecorder.seconds(from: previousSample, to: sampleHostTime)
                        - Double(previousFrames) / sampleRate
                    maximumGap = max(maximumGap, abs(gap))
                }
                previousSample = sampleHostTime == 0 ? nil : sampleHostTime
                previousFrames = frames
                if firstNonzeroFrame == nil, let channels = buffer.floatChannelData {
                    let channelCount = Int(buffer.format.channelCount)
                    for frame in 0..<Int(frames) {
                        let nonzero = (0..<channelCount).contains { channel in
                            let value = buffer.format.isInterleaved
                                ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                            return value.isFinite && value != 0
                        }
                        if nonzero {
                            firstNonzeroFrame = totalFrames + UInt64(frame)
                            firstNonzeroCallback = callbackHostTime
                            break
                        }
                    }
                }
                totalFrames += UInt64(frames)
                rate = sampleRate
            }

            func summary(start: UInt64) -> [String: Any] {
                lock.lock()
                defer { lock.unlock() }
                return [
                    "firstCallbackMs": firstCallback.map { CoreAudioRecorder.seconds(from: start, to: $0) * 1000 }
                        ?? -1,
                    "firstSampleMs": firstSample.map { CoreAudioRecorder.seconds(from: start, to: $0) * 1000 } ?? -1,
                    "firstFrames": firstFrames, "totalFrames": totalFrames, "sampleRate": rate,
                    "maximumTimestampGapMs": maximumGap * 1000,
                    "leadingZeroMs": firstNonzeroFrame.map { Double($0) / rate * 1000 } ?? -1,
                    "firstNonzeroCallbackMs": firstNonzeroCallback.map {
                        CoreAudioRecorder.seconds(from: start, to: $0) * 1000
                    } ?? -1,
                ]
            }
        }
    }
#endif
