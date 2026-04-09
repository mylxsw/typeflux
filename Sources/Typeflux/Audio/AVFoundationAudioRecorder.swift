import AVFoundation
import Foundation

final class AVFoundationAudioRecorder: AudioRecorder {
    private static let outputMuteDelay: Duration = .milliseconds(180)

    private let engine = AVAudioEngine()
    private let settingsStore: SettingsStore
    private let audioDeviceManager: AudioDeviceManager
    private let outputMuter: SystemAudioOutputMuting
    private let sleep: @Sendable (Duration) async -> Void
    private let writeCoordinator = AudioBufferWriteCoordinator()
    private let stateCondition = NSCondition()
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var levelHandler: ((Float) -> Void)?
    private var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var muteTask: Task<Void, Never>?
    private var isRecording = false
    private var activeBufferCallbacks = 0

    init(
        settingsStore: SettingsStore,
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager(),
        outputMuter: SystemAudioOutputMuting = SystemAudioOutputMuter(),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
    ) {
        self.settingsStore = settingsStore
        self.audioDeviceManager = audioDeviceManager
        self.outputMuter = outputMuter
        self.sleep = sleep
    }

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?,
    ) throws {
        stopInternal()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let now = Date()
        let calendar = Calendar.current
        let year = String(format: "%04d", calendar.component(.year, from: now))
        let month = String(format: "%02d", calendar.component(.month, from: now))
        let day = String(format: "%02d", calendar.component(.day, from: now))
        let dir = appSupport.appendingPathComponent("Typeflux/audio/\(year)/\(month)/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let inputNode = engine.inputNode
        try configureInputDeviceIfNeeded(for: inputNode)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let outputFile = try AVAudioFile(forWriting: url, settings: outputSettings)
        stateCondition.lock()
        audioFile = outputFile
        startedAt = Date()
        self.levelHandler = levelHandler
        self.audioBufferHandler = audioBufferHandler
        stateCondition.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        if settingsStore.muteSystemOutputDuringRecording {
            scheduleMutedSessionStart()
        }
        stateCondition.lock()
        isRecording = true
        stateCondition.unlock()
    }

    func stop() throws -> AudioFile {
        stateCondition.lock()
        let currentAudioFile = audioFile
        let currentStartedAt = startedAt
        let currentlyRecording = isRecording
        stateCondition.unlock()

        guard currentlyRecording, let currentAudioFile else {
            throw NSError(domain: "AudioRecorder", code: 1)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        stateCondition.lock()
        while activeBufferCallbacks > 0 {
            stateCondition.wait()
        }
        stateCondition.unlock()

        writeCoordinator.drain()

        let duration = Date().timeIntervalSince(currentStartedAt ?? Date())
        let fileURL = currentAudioFile.url

        stateCondition.lock()
        audioFile = nil
        startedAt = nil
        levelHandler = nil
        audioBufferHandler = nil
        isRecording = false
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        outputMuter.endMutedSession()

        return AudioFile(fileURL: fileURL, duration: duration)
    }

    private func stopInternal() {
        stateCondition.lock()
        let currentlyRecording = isRecording
        stateCondition.unlock()

        if currentlyRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        stateCondition.lock()
        while activeBufferCallbacks > 0 {
            stateCondition.wait()
        }
        stateCondition.unlock()

        writeCoordinator.drain()

        stateCondition.lock()
        audioFile = nil
        startedAt = nil
        levelHandler = nil
        audioBufferHandler = nil
        isRecording = false
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        outputMuter.endMutedSession()
    }

    private func scheduleMutedSessionStart() {
        muteTask?.cancel()
        muteTask = Task { [weak self] in
            guard let self else { return }
            await sleep(Self.outputMuteDelay)
            stateCondition.lock()
            let isRecording = isRecording
            stateCondition.unlock()
            guard !Task.isCancelled, isRecording else { return }
            outputMuter.beginMutedSession()
        }
    }

    #if DEBUG
        func beginMutedSessionAfterDelayForTesting() {
            stateCondition.lock()
            isRecording = true
            stateCondition.unlock()
            scheduleMutedSessionStart()
        }

        func cancelMutedSessionForTesting() {
            stateCondition.lock()
            isRecording = false
            stateCondition.unlock()
            muteTask?.cancel()
            muteTask = nil
            outputMuter.endMutedSession()
        }
    #endif

    private func configureInputDeviceIfNeeded(for inputNode: AVAudioInputNode) throws {
        let preferredID = settingsStore.preferredMicrophoneID
        guard !preferredID.isEmpty else { return }
        guard let deviceID = audioDeviceManager.resolveInputDeviceID(for: preferredID) else { return }

        inputNode.auAudioUnit.setValue(Int(deviceID), forKey: "deviceID")
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        autoreleasepool {
            stateCondition.lock()
            guard let audioFile = self.audioFile else {
                stateCondition.unlock()
                return
            }
            let levelHandler = self.levelHandler
            let audioBufferHandler = self.audioBufferHandler
            activeBufferCallbacks += 1
            stateCondition.unlock()

            defer {
                stateCondition.lock()
                activeBufferCallbacks -= 1
                if activeBufferCallbacks == 0 {
                    stateCondition.broadcast()
                }
                stateCondition.unlock()
            }

            do {
                let monoBuffer = try makeMonoPCMBuffer(from: buffer)
                let previewBuffer = clone(buffer: monoBuffer)
                let normalizedLevel = normalizePower(rmsPower(for: monoBuffer))

                writeCoordinator.enqueue {
                    do {
                        try audioFile.write(from: monoBuffer)
                        levelHandler?(normalizedLevel)
                        if let previewBuffer {
                            audioBufferHandler?(previewBuffer)
                        }
                    } catch {
                        NetworkDebugLogger.logError(context: "Audio buffer handling failed", error: error)
                    }
                }
            } catch {
                NetworkDebugLogger.logError(context: "Audio buffer handling failed", error: error)
            }
        }
    }

    private func makeMonoPCMBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false,
        ) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create mono audio format."],
            )
        }

        if buffer.format.channelCount == 1, buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let clone = clone(buffer: buffer, format: monoFormat) else {
                throw NSError(
                    domain: "AudioRecorder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to clone mono audio buffer."],
                )
            }
            return clone
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: monoFormat) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter."],
            )
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameCapacity,
        ) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate mono audio buffer."],
            )
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }

        guard status != .error else {
            throw NSError(
                domain: "AudioRecorder",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unable to convert input audio."],
            )
        }

        return outputBuffer
    }

    private func clone(buffer: AVAudioPCMBuffer, format: AVAudioFormat? = nil) -> AVAudioPCMBuffer? {
        let targetFormat = format ?? buffer.format
        guard let copy = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        guard
            let source = buffer.floatChannelData,
            let destination = copy.floatChannelData
        else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(targetFormat.channelCount)
        for channel in 0 ..< channelCount {
            destination[channel].update(from: source[min(channel, Int(buffer.format.channelCount) - 1)], count: frameCount)
        }

        return copy
    }

    private func rmsPower(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -60 }
        let samples = channelData[0]
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -60 }

        var sum: Float = 0
        for index in 0 ..< count {
            let sample = samples[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(count))
        guard rms > 0 else { return -60 }
        return 20 * log10(rms)
    }

    private func normalizePower(_ power: Float) -> Float {
        let minDb: Float = -60
        let clamped = max(minDb, power)
        return (clamped - minDb) / -minDb
    }
}

final class AudioBufferWriteCoordinator {
    private let queue = DispatchQueue(label: "typeflux.audio.buffer-writer")
    private let group = DispatchGroup()

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        group.enter()
        queue.async {
            defer { self.group.leave() }
            operation()
        }
    }

    func drain() {
        group.wait()
    }
}
