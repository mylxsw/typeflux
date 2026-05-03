import AVFoundation
import Foundation

final class AVFoundationAudioRecorder: AudioRecorder {
    private static let outputMuteDelayWithStartCue: Duration = .milliseconds(1_225)
    private static let outputMuteDelayWithoutStartCue: Duration = .milliseconds(180)
    private static let silentInputRecoveryDelay: Duration = .milliseconds(1_000)
    private static let audioStartupTimeout: DispatchTimeInterval = .seconds(5)

    enum RecorderError: LocalizedError, Equatable {
        case inputDeviceUnavailable
        case inputStartupTimedOut

        var errorDescription: String? {
            switch self {
            case .inputDeviceUnavailable:
                return "No usable microphone input format is available."
            case .inputStartupTimedOut:
                return "Microphone input did not become ready in time."
            }
        }
    }

    private let makeAudioEngine: () -> AVAudioEngine
    private var engine: AVAudioEngine
    private let settingsStore: SettingsStore
    private let audioDeviceManager: AudioDeviceManaging
    private let outputMuter: SystemAudioOutputMuting
    private let sleep: @Sendable (Duration) async -> Void
    private let writeCoordinator = AudioBufferWriteCoordinator()
    private let lifecycleLock = NSLock()
    private let stateCondition = NSCondition()
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var levelHandler: ((Float) -> Void)?
    private var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var muteTask: Task<Void, Never>?
    private var silentInputRecoveryTask: Task<Void, Never>?
    private var isRecording = false
    private var isTapInstalled = false
    private var activeRecordingID: UUID?
    private var activeBufferCallbacks = 0
    private var inputBufferCallbackCount = 0

    init(
        settingsStore: SettingsStore,
        audioDeviceManager: AudioDeviceManaging = AudioDeviceManager(),
        outputMuter: SystemAudioOutputMuting = SystemAudioOutputMuter(),
        makeAudioEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
    ) {
        self.settingsStore = settingsStore
        self.audioDeviceManager = audioDeviceManager
        self.outputMuter = outputMuter
        self.makeAudioEngine = makeAudioEngine
        engine = makeAudioEngine()
        self.sleep = sleep
    }

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?,
    ) throws {
        let startupAttempt = RecordingStartupAttempt()
        let startupResult = RecordingStartupResultBox()
        let startupSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                startupResult.store(.failure(RecorderError.inputDeviceUnavailable))
                startupSemaphore.signal()
                return
            }
            do {
                let preparedSession = try self.prepareRecordingSession(
                    id: startupAttempt.id,
                    startupAttempt: startupAttempt,
                )
                startupResult.store(.success(preparedSession))
            } catch {
                startupResult.store(.failure(error))
            }
            startupSemaphore.signal()
        }

        guard startupSemaphore.wait(timeout: .now() + Self.audioStartupTimeout) == .success else {
            startupAttempt.cancel()
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Microphone input startup timed out; abandoning stale AVAudioEngine startup.",
            )
            throw RecorderError.inputStartupTimedOut
        }

        let preparedSession = try startupResult.value().get()

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stopInternal()

        engine = preparedSession.engine
        isTapInstalled = true
        stateCondition.lock()
        audioFile = preparedSession.audioFile
        startedAt = preparedSession.startedAt
        self.levelHandler = levelHandler
        self.audioBufferHandler = audioBufferHandler
        activeRecordingID = preparedSession.id
        isRecording = true
        let callbackCountAtStart = inputBufferCallbackCount
        stateCondition.unlock()
        scheduleSilentInputRecoveryIfNeeded(callbackCountAtStart: callbackCountAtStart)
        if settingsStore.muteSystemOutputDuringRecording {
            scheduleMutedSessionStart()
        }
    }

    func stop() throws -> AudioFile {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateCondition.lock()
        let currentAudioFile = audioFile
        let currentStartedAt = startedAt
        let currentlyRecording = isRecording
        stateCondition.unlock()

        guard currentlyRecording, let currentAudioFile else {
            throw NSError(domain: "AudioRecorder", code: 1)
        }

        removeInputTapIfInstalled()
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
        activeRecordingID = nil
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        silentInputRecoveryTask?.cancel()
        silentInputRecoveryTask = nil
        outputMuter.endMutedSession()

        return AudioFile(fileURL: fileURL, duration: duration)
    }

    private func stopInternal() {
        stateCondition.lock()
        let shouldStopEngine = isRecording || isTapInstalled
        stateCondition.unlock()

        if shouldStopEngine {
            removeInputTapIfInstalled()
            engine.stop()
            engine.reset()
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
        activeRecordingID = nil
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        silentInputRecoveryTask?.cancel()
        silentInputRecoveryTask = nil
        outputMuter.endMutedSession()
    }

    private func rebuildAudioEngine() {
        engine.stop()
        engine.reset()
        engine = makeAudioEngine()
        isTapInstalled = false
    }

    private func prepareEngineForRecordingSession() {
        // Bluetooth and aggregate input devices can reappear with a valid CoreAudio
        // default device while an existing AVAudioEngine input node remains silent.
        // Rebuilding here forces AVFoundation to bind to the current HAL device.
        rebuildAudioEngine()
    }

    private func prepareRecordingSession(
        id: UUID,
        startupAttempt: RecordingStartupAttempt,
    ) throws -> PreparedRecordingSession {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let now = Date()
        let calendar = Calendar.current
        let year = String(format: "%04d", calendar.component(.year, from: now))
        let month = String(format: "%02d", calendar.component(.month, from: now))
        let day = String(format: "%02d", calendar.component(.day, from: now))
        let dir = appSupport.appendingPathComponent("Typeflux/audio/\(year)/\(month)/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var sessionEngine = makeAudioEngine()
        let inputNodeAndFormat: (AVAudioInputNode, AVAudioFormat)
        do {
            inputNodeAndFormat = try prepareInputNodeAndFormat(for: sessionEngine)
        } catch RecorderError.inputDeviceUnavailable {
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Rebuilding audio engine after microphone input format became unavailable.",
            )
            sessionEngine.stop()
            sessionEngine.reset()
            sessionEngine = makeAudioEngine()
            inputNodeAndFormat = try prepareInputNodeAndFormat(for: sessionEngine)
        }

        let inputNode = inputNodeAndFormat.0
        let inputFormat = inputNodeAndFormat.1
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
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self, startupAttempt] buffer, _ in
            guard !startupAttempt.isCancelled else { return }
            self?.handleInputBuffer(buffer, recordingID: id)
        }

        do {
            sessionEngine.prepare()
            try sessionEngine.start()
            RecordingStartupLatencyTrace.shared.mark("audio.engine_start_return")
        } catch {
            inputNode.removeTap(onBus: 0)
            sessionEngine.stop()
            sessionEngine.reset()
            throw error
        }

        guard !startupAttempt.isCancelled else {
            inputNode.removeTap(onBus: 0)
            sessionEngine.stop()
            sessionEngine.reset()
            throw RecorderError.inputStartupTimedOut
        }

        return PreparedRecordingSession(
            id: id,
            engine: sessionEngine,
            audioFile: outputFile,
            startedAt: Date(),
        )
    }

    private func prepareInputNodeAndFormat(for engine: AVAudioEngine) throws -> (AVAudioInputNode, AVAudioFormat) {
        let inputNode = engine.inputNode
        let inputFormat = try configureInputDeviceAndResolveFormat(for: inputNode)
        return (inputNode, inputFormat)
    }

    private func removeInputTapIfInstalled() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func scheduleMutedSessionStart() {
        muteTask?.cancel()
        let delay = settingsStore.soundEffectsEnabled
            ? Self.outputMuteDelayWithStartCue
            : Self.outputMuteDelayWithoutStartCue
        muteTask = Task { [weak self] in
            guard let self else { return }
            await sleep(delay)
            let isRecording = currentRecordingState()
            guard !Task.isCancelled, isRecording else { return }
            outputMuter.beginMutedSession()
        }
    }

    private func scheduleSilentInputRecoveryIfNeeded(callbackCountAtStart: Int) {
        silentInputRecoveryTask?.cancel()
        silentInputRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await sleep(Self.silentInputRecoveryDelay)
            guard !Task.isCancelled else { return }
            recoverSilentInputIfNeeded(callbackCountAtStart: callbackCountAtStart)
        }
    }

    private func recoverSilentInputIfNeeded(callbackCountAtStart: Int) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateCondition.lock()
        let shouldRecover = isRecording && inputBufferCallbackCount == callbackCountAtStart
        stateCondition.unlock()
        guard shouldRecover else { return }

        NetworkDebugLogger.logMessage(
            "[Audio Recorder] No input buffers received after start; rebuilding audio engine.",
        )

        do {
            removeInputTapIfInstalled()
            engine.stop()
            rebuildAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = try configureInputDeviceAndResolveFormat(for: inputNode)
            inputNode.removeTap(onBus: 0)
            let recordingID = currentRecordingID()
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                self?.handleInputBuffer(buffer, recordingID: recordingID)
            }
            isTapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            NetworkDebugLogger.logError(context: "Silent input recovery failed", error: error)
        }
    }

    #if DEBUG
        var audioEngineIdentifierForTesting: ObjectIdentifier {
            ObjectIdentifier(engine)
        }

        func rebuildAudioEngineForTesting() {
            rebuildAudioEngine()
        }

        func prepareEngineForRecordingSessionForTesting() {
            prepareEngineForRecordingSession()
        }

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

        func resolvedInputDeviceIDForTesting() -> AudioDeviceID? {
            resolveInputDeviceID()
        }

        func explicitInputDeviceIDForRecordingForTesting() -> AudioDeviceID? {
            resolveExplicitInputDeviceIDForRecording()
        }
    #endif

    private func resolveInputDeviceID() -> AudioDeviceID? {
        resolveInputDeviceIDForRecording()
    }

    private func configureInputDeviceAndResolveFormat(for inputNode: AVAudioInputNode) throws -> AVAudioFormat {
        let preferredID = settingsStore.preferredMicrophoneID
        if let deviceID = resolveInputDeviceIDForRecording() {
            inputNode.auAudioUnit.setValue(Int(deviceID), forKey: "deviceID")
        }

        if !preferredID.isEmpty, settingsStore.preferredMicrophoneID == preferredID {
            let preferredFormat = inputNode.inputFormat(forBus: 0)
            if Self.isUsableInputFormat(preferredFormat) {
                return preferredFormat
            }

            NetworkDebugLogger.logMessage(
                """
                [Audio Recorder] Falling back to automatic microphone selection.
                preferredMicrophoneID: \(preferredID)
                sampleRate: \(preferredFormat.sampleRate)
                channelCount: \(preferredFormat.channelCount)
                """,
            )
            resetUnavailablePreferredMicrophone(preferredID: preferredID)
            throw RecorderError.inputDeviceUnavailable
        }

        let automaticFormat = inputNode.inputFormat(forBus: 0)
        try Self.validateInputFormat(automaticFormat)
        return automaticFormat
    }

    private func resolveExplicitInputDeviceIDForRecording() -> AudioDeviceID? {
        let preferredID = settingsStore.preferredMicrophoneID
        guard !preferredID.isEmpty else {
            return nil
        }

        if let deviceID = audioDeviceManager.resolveInputDeviceID(for: preferredID) {
            return deviceID
        }

        resetUnavailablePreferredMicrophone(preferredID: preferredID)
        return nil
    }

    private func resolveInputDeviceIDForRecording() -> AudioDeviceID? {
        resolveExplicitInputDeviceIDForRecording() ?? audioDeviceManager.defaultInputDeviceID()
    }

    private func resetUnavailablePreferredMicrophone(preferredID: String) {
        NetworkDebugLogger.logMessage(
            """
            [Audio Recorder] Preferred microphone is unavailable; falling back to automatic selection.
            preferredMicrophoneID: \(preferredID)
            """,
        )
        settingsStore.preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
    }

    private func currentRecordingState() -> Bool {
        stateCondition.lock()
        let isRecording = isRecording
        stateCondition.unlock()
        return isRecording
    }

    private func currentRecordingID() -> UUID? {
        stateCondition.lock()
        let activeRecordingID = activeRecordingID
        stateCondition.unlock()
        return activeRecordingID
    }

    static func validateInputFormat(_ format: AVAudioFormat) throws {
        try validateInputFormat(channelCount: format.channelCount, sampleRate: format.sampleRate)
    }

    static func validateInputFormat(channelCount: AVAudioChannelCount, sampleRate: Double) throws {
        guard isUsableInputFormat(channelCount: channelCount, sampleRate: sampleRate) else {
            throw RecorderError.inputDeviceUnavailable
        }
    }

    static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        isUsableInputFormat(channelCount: format.channelCount, sampleRate: format.sampleRate)
    }

    static func isUsableInputFormat(channelCount: AVAudioChannelCount, sampleRate: Double) -> Bool {
        channelCount > 0 && sampleRate > 0
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, recordingID: UUID?) {
        autoreleasepool {
            stateCondition.lock()
            guard let recordingID, activeRecordingID == recordingID, let audioFile = self.audioFile else {
                stateCondition.unlock()
                return
            }
            let levelHandler = self.levelHandler
            let audioBufferHandler = self.audioBufferHandler
            activeBufferCallbacks += 1
            inputBufferCallbackCount += 1
            stateCondition.unlock()

            RecordingStartupLatencyTrace.shared.markFirstAudioBuffer()

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

private struct PreparedRecordingSession {
    let id: UUID
    let engine: AVAudioEngine
    let audioFile: AVAudioFile
    let startedAt: Date
}

private final class RecordingStartupAttempt {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class RecordingStartupResultBox {
    private let lock = NSLock()
    private var result: Result<PreparedRecordingSession, Error>?

    func store(_ result: Result<PreparedRecordingSession, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func value() -> Result<PreparedRecordingSession, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut)
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
