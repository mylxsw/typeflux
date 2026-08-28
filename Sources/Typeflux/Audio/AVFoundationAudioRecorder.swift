import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import TypefluxAudioSafety

final class AVFoundationAudioRecorder: AudioRecorder {
    static let inputTapBufferSize: AVAudioFrameCount = 512
    static let instantVoiceInputPreRollDuration: TimeInterval = 0.5
    private static let outputMuteDelayWithStartCue: Duration = .milliseconds(1225)
    private static let outputMuteDelayWithoutStartCue: Duration = .milliseconds(180)
    private static let silentInputRecoveryDelay: DispatchTimeInterval = .seconds(1)
    private static let silentInputRecoveryPeakPowerThreshold: Float = -58
    private static let audioStartupTimeout: DispatchTimeInterval = .seconds(5)
    private static let instantCaptureArmingTimeout: DispatchTimeInterval = .seconds(2)
    private static let preparedInputBuildWaitTimeout: DispatchTimeInterval = .seconds(4)
    private static let configurationRecoveryDelay: DispatchTimeInterval = .milliseconds(200)
    private static let configurationRecoveryContinuationDelay: DispatchTimeInterval = .seconds(1)
    private static let configurationRecoveryRetryDelay: TimeInterval = 0.25
    private static let configurationRecoveryMaxAttemptCount = 5

    enum RecorderError: LocalizedError, Equatable {
        case inputDeviceUnavailable
        case inputStartupTimedOut

        var errorDescription: String? {
            switch self {
            case .inputDeviceUnavailable:
                "No usable microphone input format is available."
            case .inputStartupTimedOut:
                "Microphone input did not become ready in time."
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
    private let configurationRecoveryQueue = DispatchQueue(label: "typeflux.audio.configuration-recovery")
    private let inputPreparationQueue = DispatchQueue(label: "typeflux.audio.input-preparation", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    private let preparedInputLock = NSLock()
    private let preparedInputBuildGroup = DispatchGroup()
    private let stateCondition = NSCondition()
    private var audioFile: AVAudioFile?
    private var recordingBufferConverter: AudioRecordingBufferConverter?
    private var startedAt: Date?
    private var levelHandler: ((Float) -> Void)?
    private var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var audioEngineStartedAt: Date?
    private var firstAudioBufferAt: Date?
    private var muteTask: Task<Void, Never>?
    private var inputHealthCheckWorkItem: DispatchWorkItem?
    private var isRecording = false
    private var isTapInstalled = false
    private var activeRecordingID: UUID?
    private var activeBufferCallbacks = 0
    private var inputBufferCallbackCount = 0
    private var peakInputPowerSinceStart: Float = -.infinity
    private var engineConfigurationObserver: NSObjectProtocol?
    private var preferredMicrophoneObserver: NSObjectProtocol?
    private var defaultInputDeviceChangeObservation: AudioInputDeviceChangeObservation?
    private var activeInputGenerationID: UUID?
    private var preparedInputEngine: PreparedInputEngine?
    private var preparedInputGeneration: UInt64 = 0
    private var preparedInputBuildIsPending = false
    private var preparedInputBuildNeedsRetry = false
    private var preparedInputIsSuspended = false
    private var preparedMicrophoneObserver: NSObjectProtocol?
    private var instantVoiceInputObserver: NSObjectProtocol?
    private var preparedEngineConfigurationObserver: NSObjectProtocol?
    private var preparedDefaultInputDeviceChangeObservation: AudioInputDeviceChangeObservation?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        settingsStore: SettingsStore,
        audioDeviceManager: AudioDeviceManaging = AudioDeviceManager(),
        outputMuter: SystemAudioOutputMuting = SystemAudioOutputMuter(),
        makeAudioEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.settingsStore = settingsStore
        self.audioDeviceManager = audioDeviceManager
        self.outputMuter = outputMuter
        self.makeAudioEngine = makeAudioEngine
        engine = makeAudioEngine()
        self.sleep = sleep
        observePreparedInputLifecycle()
        schedulePreparedInputEngineBuild()
    }

    deinit {
        removeInputChangeObservers()
        removePreparedInputLifecycleObservers()
        discardPreparedInputEngine()
        inputHealthCheckWorkItem?.cancel()
    }

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
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
                let preparedSession = try prepareRecordingSession(
                    id: startupAttempt.id,
                    startupAttempt: startupAttempt
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
                "[Audio Recorder] Microphone input startup timed out; abandoning stale AVAudioEngine startup."
            )
            throw RecorderError.inputStartupTimedOut
        }

        let preparedSession = try startupResult.value().get()

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stopInternal()

        engine = preparedSession.engine
        isTapInstalled = true
        observeInputChanges(for: engine)
        let startedAt = Date()
        stateCondition.lock()
        audioFile = preparedSession.audioFile
        recordingBufferConverter = preparedSession.recordingBufferConverter
        self.startedAt = startedAt
        self.levelHandler = levelHandler
        self.audioBufferHandler = audioBufferHandler
        audioEngineStartedAt = preparedSession.audioEngineStartedAt
        firstAudioBufferAt = preparedSession.firstAudioBufferAt
        activeRecordingID = preparedSession.id
        activeInputGenerationID = preparedSession.inputGenerationID
        isRecording = true
        inputBufferCallbackCount = 0
        let callbackCountAtStart = 0
        peakInputPowerSinceStart = -.infinity
        stateCondition.unlock()

        guard engine.isRunning else {
            stopInternal()
            throw RecorderError.inputDeviceUnavailable
        }

        // AVAudioEngine may deliver tap callbacks before the new recording state
        // is published. Replay that startup prefix now instead of dropping the
        // first spoken frames while the hotkey-triggered session is activating.
        let recordingID = preparedSession.id
        let inputGenerationID = preparedSession.inputGenerationID
        preparedSession.startupBufferRelay.activate { [weak self] buffer in
            self?.handleInputBuffer(
                buffer,
                recordingID: recordingID,
                inputGenerationID: inputGenerationID
            )
        }

        scheduleInputHealthCheck(
            for: engine,
            recordingID: preparedSession.id,
            inputGenerationID: preparedSession.inputGenerationID,
            callbackCountAtStart: callbackCountAtStart,
            requiresAudibleInput: true
        )
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
        let startupTiming = AudioRecorderStartupTiming(
            audioEngineStartedAt: audioEngineStartedAt,
            firstAudioBufferAt: firstAudioBufferAt
        )
        stateCondition.unlock()

        guard currentlyRecording, let currentAudioFile else {
            throw NSError(domain: "AudioRecorder", code: 1)
        }

        removeInputChangeObservers()
        cancelInputHealthCheck()
        removeInputTapIfInstalled()
        engine.stop()

        stateCondition.lock()
        while activeBufferCallbacks > 0 {
            stateCondition.wait()
        }
        stateCondition.unlock()

        writeCoordinator.drain()

        let wallClockDuration = Date().timeIntervalSince(currentStartedAt ?? Date())
        let writtenAudioDuration = currentAudioFile.processingFormat.sampleRate > 0
            ? Double(currentAudioFile.length) / currentAudioFile.processingFormat.sampleRate
            : 0
        let duration = max(wallClockDuration, writtenAudioDuration)
        let fileURL = currentAudioFile.url

        stateCondition.lock()
        audioFile = nil
        recordingBufferConverter = nil
        startedAt = nil
        levelHandler = nil
        audioBufferHandler = nil
        audioEngineStartedAt = nil
        firstAudioBufferAt = nil
        isRecording = false
        activeRecordingID = nil
        activeInputGenerationID = nil
        peakInputPowerSinceStart = -.infinity
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        outputMuter.endMutedSession()
        schedulePreparedInputEngineBuild()

        return AudioFile(fileURL: fileURL, duration: duration, startupTiming: startupTiming)
    }

    private func stopInternal() {
        stateCondition.lock()
        let shouldStopEngine = isRecording || isTapInstalled
        stateCondition.unlock()

        removeInputChangeObservers()
        cancelInputHealthCheck()
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
        recordingBufferConverter = nil
        startedAt = nil
        levelHandler = nil
        audioBufferHandler = nil
        audioEngineStartedAt = nil
        firstAudioBufferAt = nil
        isRecording = false
        activeRecordingID = nil
        activeInputGenerationID = nil
        peakInputPowerSinceStart = -.infinity
        stateCondition.unlock()
        muteTask?.cancel()
        muteTask = nil
        outputMuter.endMutedSession()
    }

    private func rebuildAudioEngine() {
        removeInputChangeObservers()
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
        startupAttempt: RecordingStartupAttempt
    ) throws -> PreparedRecordingSession {
        let preparedInput = try takePreparedInputEngineOrBuild()
        let sessionEngine = preparedInput.engine
        let inputFormat = preparedInput.inputFormat
        let startupBufferRelay = preparedInput.startupBufferRelay
        let usesInstantPreRoll = preparedInput.includesInstantPreRoll && sessionEngine.isRunning

        if preparedInput.includesInstantPreRoll, !usesInstantPreRoll {
            startupBufferRelay.discardBufferedAudio()
        }

        guard !startupAttempt.isCancelled else {
            disposePreparedInputEngine(preparedInput)
            throw RecorderError.inputStartupTimedOut
        }

        let audioEngineStartedAt = Date()
        if !sessionEngine.isRunning {
            do {
                try sessionEngine.start()
            } catch {
                disposePreparedInputEngine(preparedInput)
                throw error
            }
        }
        RecordingStartupLatencyTrace.shared.mark("audio.engine_start_return")

        guard isPreparedInputEngineCurrent(preparedInput.signature) else {
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Microphone changed while the prepared input was starting; retrying with a fresh engine."
            )
            disposePreparedInputEngine(preparedInput)
            throw RecorderError.inputDeviceUnavailable
        }

        guard !startupAttempt.isCancelled else {
            disposePreparedInputEngine(preparedInput)
            throw RecorderError.inputStartupTimedOut
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let now = Date()
        let calendar = Calendar.current
        let year = String(format: "%04d", calendar.component(.year, from: now))
        let month = String(format: "%02d", calendar.component(.month, from: now))
        let day = String(format: "%02d", calendar.component(.day, from: now))
        let dir = appSupport.appendingPathComponent("Typeflux/audio/\(year)/\(month)/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: url, settings: outputSettings)
        } catch {
            disposePreparedInputEngine(preparedInput)
            throw error
        }
        let recordingBufferConverter = AudioRecordingBufferConverter(targetFormat: outputFile.processingFormat)
        let inputGenerationID = UUID()

        guard !startupAttempt.isCancelled else {
            disposePreparedInputEngine(preparedInput)
            throw RecorderError.inputStartupTimedOut
        }

        return PreparedRecordingSession(
            id: id,
            engine: sessionEngine,
            audioFile: outputFile,
            recordingBufferConverter: recordingBufferConverter,
            inputGenerationID: inputGenerationID,
            startupBufferRelay: startupBufferRelay,
            audioEngineStartedAt: audioEngineStartedAt,
            firstAudioBufferAt: usesInstantPreRoll
                ? audioEngineStartedAt
                : startupBufferRelay.firstBufferReceivedAt
        )
    }

    private func takePreparedInputEngineOrBuild() throws -> PreparedInputEngine {
        guard waitForPendingPreparedInputBuild() else {
            throw RecorderError.inputStartupTimedOut
        }
        let currentSignature = try currentPreparedInputSignature()
        var cachedInput: PreparedInputEngine?
        var staleInput: PreparedInputEngine?

        preparedInputLock.lock()
        if let preparedInputEngine,
           Self.canReusePreparedInputEngine(
               prepared: preparedInputEngine.signature,
               current: currentSignature
           ) {
            cachedInput = preparedInputEngine
            self.preparedInputEngine = nil
        } else if let preparedInputEngine {
            staleInput = preparedInputEngine
            self.preparedInputEngine = nil
        }
        preparedInputLock.unlock()

        if let staleInput {
            disposePreparedInputEngine(staleInput)
        }
        if let cachedInput {
            NetworkDebugLogger.logMessage("[Audio Recorder] Starting from prepared microphone input fast path.")
            return cachedInput
        }
        return try buildPreparedInputEngine(signature: currentSignature)
    }

    private func buildPreparedInputEngine(
        signature: PreparedInputEngineSignature,
        includesInstantPreRoll: Bool = false
    ) throws -> PreparedInputEngine {
        var preparedEngine = makeAudioEngine()
        let inputNodeAndFormat: (AVAudioInputNode, AVAudioFormat)
        do {
            inputNodeAndFormat = try prepareInputNodeAndFormat(for: preparedEngine)
        } catch RecorderError.inputDeviceUnavailable {
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Rebuilding audio engine after microphone input format became unavailable."
            )
            preparedEngine.stop()
            preparedEngine.reset()
            preparedEngine = makeAudioEngine()
            inputNodeAndFormat = try prepareInputNodeAndFormat(for: preparedEngine)
        }

        let inputNode = inputNodeAndFormat.0
        let startupBufferRelay = RecordingStartupAudioBufferRelay(
            maximumBufferedDuration: includesInstantPreRoll ? Self.instantVoiceInputPreRollDuration : nil
        )
        inputNode.removeTap(onBus: 0)
        do {
            try installInputTap(on: inputNode) { [startupBufferRelay] buffer, _ in
                startupBufferRelay.append(buffer, receivedAt: Date())
            }
            preparedEngine.prepare()
        } catch {
            inputNode.removeTap(onBus: 0)
            preparedEngine.stop()
            preparedEngine.reset()
            throw error
        }
        return PreparedInputEngine(
            engine: preparedEngine,
            inputFormat: inputNodeAndFormat.1,
            startupBufferRelay: startupBufferRelay,
            signature: signature,
            includesInstantPreRoll: includesInstantPreRoll
        )
    }

    private func schedulePreparedInputEngineBuild() {
        preparedInputLock.lock()
        guard preparedInputEngine == nil,
              !preparedInputBuildIsPending,
              !preparedInputIsSuspended
        else {
            preparedInputLock.unlock()
            return
        }
        preparedInputBuildIsPending = true
        preparedInputBuildGroup.enter()
        preparedInputLock.unlock()

        inputPreparationQueue.async { [weak self] in
            self?.prepareInputEngineInBackground()
        }
    }

    private func prepareInputEngineInBackground() {
        defer {
            preparedInputLock.lock()
            preparedInputBuildIsPending = false
            let shouldRetry = preparedInputBuildNeedsRetry && !preparedInputIsSuspended
            preparedInputBuildNeedsRetry = false
            preparedInputLock.unlock()
            if shouldRetry {
                schedulePreparedInputEngineBuild()
            }
            preparedInputBuildGroup.leave()
        }
        guard !currentRecordingState() else { return }

        do {
            let signature = try currentPreparedInputSignature()
            let instantVoiceInputEnabled = settingsStore.instantVoiceInputEnabled
            let preparedInput = try buildPreparedInputEngine(
                signature: signature,
                includesInstantPreRoll: instantVoiceInputEnabled
            )
            if instantVoiceInputEnabled {
                do {
                    try preparedInput.engine.start()
                } catch {
                    disposePreparedInputEngine(preparedInput)
                    throw error
                }
                guard preparedInput.startupBufferRelay.waitForFirstBuffer(
                    timeout: Self.instantCaptureArmingTimeout
                ) else {
                    disposePreparedInputEngine(preparedInput)
                    throw RecorderError.inputStartupTimedOut
                }
            }
            preparedInputLock.lock()
            let canStore = preparedInputEngine == nil
                && preparedInputGeneration == signature.generation
                && !preparedInputIsSuspended
                && settingsStore.instantVoiceInputEnabled == instantVoiceInputEnabled
            if canStore {
                preparedInputEngine = preparedInput
            }
            preparedInputLock.unlock()
            if canStore {
                let mode = instantVoiceInputEnabled ? "armed with in-memory pre-roll" : "prepared"
                NetworkDebugLogger.logMessage("[Audio Recorder] Microphone input is \(mode) for the next recording.")
            } else {
                disposePreparedInputEngine(preparedInput)
            }
        } catch {
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Microphone input preconfiguration unavailable; next recording will use cold start."
            )
        }
    }

    private func waitForPendingPreparedInputBuild() -> Bool {
        preparedInputLock.lock()
        let buildIsPending = preparedInputBuildIsPending
        preparedInputLock.unlock()
        guard buildIsPending else { return true }
        return preparedInputBuildGroup.wait(
            timeout: .now() + Self.preparedInputBuildWaitTimeout
        ) == .success
    }

    private func currentPreparedInputSignature() throws -> PreparedInputEngineSignature {
        let deviceID = try Self.requireInputDeviceID(resolveInputDeviceIDForRecording())
        preparedInputLock.lock()
        let generation = preparedInputGeneration
        preparedInputLock.unlock()
        return PreparedInputEngineSignature(
            deviceID: deviceID,
            preferredMicrophoneID: settingsStore.preferredMicrophoneID,
            generation: generation
        )
    }

    private func isPreparedInputEngineCurrent(_ signature: PreparedInputEngineSignature) -> Bool {
        guard let currentSignature = try? currentPreparedInputSignature() else { return false }
        return Self.canReusePreparedInputEngine(prepared: signature, current: currentSignature)
    }

    private func observePreparedInputLifecycle() {
        preparedMicrophoneObserver = NotificationCenter.default.addObserver(
            forName: .preferredMicrophoneDidChange,
            object: settingsStore,
            queue: nil
        ) { [weak self] _ in
            self?.invalidatePreparedInputEngine(reason: "preferred microphone changed")
        }
        preparedDefaultInputDeviceChangeObservation = audioDeviceManager.observeDefaultInputDeviceChanges {
            [weak self] in
            guard let self,
                  Self.shouldFollowSystemDefaultInputDevice(
                      preferredMicrophoneID: settingsStore.preferredMicrophoneID
                  )
            else { return }
            invalidatePreparedInputEngine(reason: "default input device changed")
        }
        instantVoiceInputObserver = NotificationCenter.default.addObserver(
            forName: .instantVoiceInputDidChange,
            object: settingsStore,
            queue: nil
        ) { [weak self] _ in
            self?.invalidatePreparedInputEngine(reason: "instant voice input setting changed")
        }
        preparedEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let changedEngine = notification.object as? AVAudioEngine,
                  preparedInputEngineMatches(changedEngine)
            else { return }
            inputPreparationQueue.async { [weak self] in
                self?.invalidatePreparedInputEngine(reason: "prepared engine configuration changed")
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.suspendPreparedInputEngine(reason: "system sleeping") },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.suspendPreparedInputEngine(reason: "session locked") },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.resumePreparedInputEngine(reason: "system woke") },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.resumePreparedInputEngine(reason: "session unlocked") }
        ]
    }

    private func removePreparedInputLifecycleObservers() {
        if let preparedMicrophoneObserver {
            NotificationCenter.default.removeObserver(preparedMicrophoneObserver)
            self.preparedMicrophoneObserver = nil
        }
        preparedDefaultInputDeviceChangeObservation?.cancel()
        preparedDefaultInputDeviceChangeObservation = nil
        if let instantVoiceInputObserver {
            NotificationCenter.default.removeObserver(instantVoiceInputObserver)
            self.instantVoiceInputObserver = nil
        }
        if let preparedEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(preparedEngineConfigurationObserver)
            self.preparedEngineConfigurationObserver = nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func invalidatePreparedInputEngine(reason: String) {
        preparedInputLock.lock()
        preparedInputGeneration &+= 1
        let staleInput = preparedInputEngine
        preparedInputEngine = nil
        if preparedInputBuildIsPending {
            preparedInputBuildNeedsRetry = true
        }
        preparedInputLock.unlock()
        if let staleInput {
            disposePreparedInputEngine(staleInput)
        }
        NetworkDebugLogger.logMessage("[Audio Recorder] Invalidated prepared input: \(reason).")
        schedulePreparedInputEngineBuild()
    }

    private func preparedInputEngineMatches(_ changedEngine: AVAudioEngine) -> Bool {
        preparedInputLock.lock()
        defer { preparedInputLock.unlock() }
        return preparedInputEngine?.engine === changedEngine
    }

    private func suspendPreparedInputEngine(reason: String) {
        preparedInputLock.lock()
        guard !preparedInputIsSuspended else {
            preparedInputLock.unlock()
            return
        }
        preparedInputIsSuspended = true
        preparedInputGeneration &+= 1
        let staleInput = preparedInputEngine
        preparedInputEngine = nil
        preparedInputLock.unlock()
        if let staleInput {
            disposePreparedInputEngine(staleInput)
        }
        NetworkDebugLogger.logMessage("[Audio Recorder] Suspended prepared input: \(reason).")
    }

    private func resumePreparedInputEngine(reason: String) {
        preparedInputLock.lock()
        guard preparedInputIsSuspended else {
            preparedInputLock.unlock()
            return
        }
        preparedInputIsSuspended = false
        preparedInputGeneration &+= 1
        if preparedInputBuildIsPending {
            preparedInputBuildNeedsRetry = true
        }
        preparedInputLock.unlock()
        NetworkDebugLogger.logMessage("[Audio Recorder] Resuming prepared input: \(reason).")
        schedulePreparedInputEngineBuild()
    }

    private func discardPreparedInputEngine() {
        preparedInputLock.lock()
        let staleInput = preparedInputEngine
        preparedInputEngine = nil
        preparedInputLock.unlock()
        if let staleInput {
            disposePreparedInputEngine(staleInput)
        }
    }

    private func disposePreparedInputEngine(_ preparedInput: PreparedInputEngine) {
        preparedInput.startupBufferRelay.cancel()
        preparedInput.engine.inputNode.removeTap(onBus: 0)
        preparedInput.engine.stop()
        preparedInput.engine.reset()
    }

    private func prepareInputNodeAndFormat(for engine: AVAudioEngine) throws -> (AVAudioInputNode, AVAudioFormat) {
        let inputNode = engine.inputNode
        let inputFormat = try configureInputDeviceAndResolveFormat(for: inputNode)
        return (inputNode, inputFormat)
    }

    private func observeInputChanges(for observedEngine: AVAudioEngine) {
        removeInputChangeObservers()
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: nil
        ) { [weak self, weak observedEngine] _ in
            guard let self, let observedEngine else { return }
            scheduleConfigurationRecovery(
                for: observedEngine,
                after: Self.configurationRecoveryDelay
            )
        }
        preferredMicrophoneObserver = NotificationCenter.default.addObserver(
            forName: .preferredMicrophoneDidChange,
            object: settingsStore,
            queue: nil
        ) { [weak self, weak observedEngine] _ in
            guard let self, let observedEngine else { return }
            scheduleConfigurationRecovery(
                for: observedEngine,
                after: Self.configurationRecoveryDelay
            )
        }
        defaultInputDeviceChangeObservation = audioDeviceManager.observeDefaultInputDeviceChanges {
            [weak self, weak observedEngine] in
            guard let self, let observedEngine else { return }
            guard Self.shouldFollowSystemDefaultInputDevice(
                preferredMicrophoneID: settingsStore.preferredMicrophoneID
            ) else {
                return
            }
            scheduleConfigurationRecovery(
                for: observedEngine,
                after: Self.configurationRecoveryDelay
            )
        }
    }

    private func scheduleConfigurationRecovery(
        for observedEngine: AVAudioEngine,
        after delay: DispatchTimeInterval,
        nextHealthCheckRequiresAudibleInput: Bool = true
    ) {
        configurationRecoveryQueue.asyncAfter(
            deadline: .now() + delay
        ) { [weak self, weak observedEngine] in
            guard let self, let observedEngine else { return }
            recoverFromConfigurationChange(
                for: observedEngine,
                nextHealthCheckRequiresAudibleInput: nextHealthCheckRequiresAudibleInput
            )
        }
    }

    private func removeInputChangeObservers() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        if let preferredMicrophoneObserver {
            NotificationCenter.default.removeObserver(preferredMicrophoneObserver)
            self.preferredMicrophoneObserver = nil
        }
        defaultInputDeviceChangeObservation?.cancel()
        defaultInputDeviceChangeObservation = nil
    }

    private func recoverFromConfigurationChange(
        for observedEngine: AVAudioEngine,
        nextHealthCheckRequiresAudibleInput: Bool = true
    ) {
        for attempt in 1 ... Self.configurationRecoveryMaxAttemptCount {
            lifecycleLock.lock()

            stateCondition.lock()
            let shouldRecover = isRecording && engine === observedEngine
            let recordingID = activeRecordingID
            stateCondition.unlock()

            guard shouldRecover, let recordingID else {
                lifecycleLock.unlock()
                return
            }

            do {
                try replaceInputEngineAfterConfigurationChange(
                    recordingID: recordingID,
                    healthCheckRequiresAudibleInput: nextHealthCheckRequiresAudibleInput
                )
                lifecycleLock.unlock()
                NetworkDebugLogger.logMessage(
                    "[Audio Recorder] Restarted microphone input after a device change; awaiting audio buffers."
                )
                return
            } catch {
                lifecycleLock.unlock()
                let isRecoverable = Self.isRecoverableInputReconfigurationError(error)
                guard isRecoverable else {
                    NetworkDebugLogger.logError(
                        context: "Audio device configuration recovery failed",
                        error: error
                    )
                    return
                }

                guard attempt < Self.configurationRecoveryMaxAttemptCount else {
                    NetworkDebugLogger.logMessage(
                        "[Audio Recorder] Microphone is still reconfiguring; recovery will continue in the background."
                    )
                    scheduleConfigurationRecovery(
                        for: observedEngine,
                        after: Self.configurationRecoveryContinuationDelay,
                        nextHealthCheckRequiresAudibleInput: nextHealthCheckRequiresAudibleInput
                    )
                    return
                }

                Thread.sleep(forTimeInterval: Self.configurationRecoveryRetryDelay)
            }
        }
    }

    private func replaceInputEngineAfterConfigurationChange(
        recordingID: UUID,
        healthCheckRequiresAudibleInput: Bool
    ) throws {
        removeInputChangeObservers()
        cancelInputHealthCheck()
        removeInputTapIfInstalled()
        engine.stop()
        engine.reset()

        let replacementEngine = makeAudioEngine()
        let inputGenerationID = UUID()
        var replacementTapInstalled = false
        do {
            let inputNodeAndFormat = try prepareInputNodeAndFormat(for: replacementEngine)
            let inputNode = inputNodeAndFormat.0
            inputNode.removeTap(onBus: 0)
            try installInputTap(on: inputNode) { [weak self] buffer, _ in
                self?.handleInputBuffer(
                    buffer,
                    recordingID: recordingID,
                    inputGenerationID: inputGenerationID
                )
            }
            replacementTapInstalled = true
            replacementEngine.prepare()
            observeInputChanges(for: replacementEngine)
            try replacementEngine.start()
            guard replacementEngine.isRunning else {
                throw RecorderError.inputDeviceUnavailable
            }
        } catch {
            removeInputChangeObservers()
            if replacementTapInstalled {
                replacementEngine.inputNode.removeTap(onBus: 0)
            }
            replacementEngine.stop()
            replacementEngine.reset()
            throw error
        }

        engine = replacementEngine
        isTapInstalled = true
        stateCondition.lock()
        activeInputGenerationID = inputGenerationID
        inputBufferCallbackCount = 0
        peakInputPowerSinceStart = -.infinity
        stateCondition.unlock()
        scheduleInputHealthCheck(
            for: replacementEngine,
            recordingID: recordingID,
            inputGenerationID: inputGenerationID,
            callbackCountAtStart: 0,
            requiresAudibleInput: healthCheckRequiresAudibleInput
        )
    }

    private func removeInputTapIfInstalled() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func installInputTap(
        on inputNode: AVAudioInputNode,
        handler: @escaping AVAudioNodeTapBlock
    ) throws {
        var installationError: NSError?
        let installed = TFInstallAudioTapSafely(
            inputNode,
            0,
            Self.inputTapBufferSize,
            nil,
            handler,
            &installationError
        )
        guard installed else {
            throw installationError ?? RecorderError.inputDeviceUnavailable
        }
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

    private func scheduleInputHealthCheck(
        for observedEngine: AVAudioEngine,
        recordingID: UUID,
        inputGenerationID: UUID,
        callbackCountAtStart: Int,
        requiresAudibleInput: Bool
    ) {
        cancelInputHealthCheck()
        let workItem = DispatchWorkItem { [weak self, weak observedEngine] in
            guard let self, let observedEngine else { return }
            verifyInputHealth(
                for: observedEngine,
                recordingID: recordingID,
                inputGenerationID: inputGenerationID,
                callbackCountAtStart: callbackCountAtStart,
                requiresAudibleInput: requiresAudibleInput
            )
        }
        inputHealthCheckWorkItem = workItem
        configurationRecoveryQueue.asyncAfter(
            deadline: .now() + Self.silentInputRecoveryDelay,
            execute: workItem
        )
    }

    private func cancelInputHealthCheck() {
        inputHealthCheckWorkItem?.cancel()
        inputHealthCheckWorkItem = nil
    }

    private func verifyInputHealth(
        for observedEngine: AVAudioEngine,
        recordingID: UUID,
        inputGenerationID: UUID,
        callbackCountAtStart: Int,
        requiresAudibleInput: Bool
    ) {
        lifecycleLock.lock()
        stateCondition.lock()
        let isCurrentInput = isRecording
            && engine === observedEngine
            && activeRecordingID == recordingID
            && activeInputGenerationID == inputGenerationID
        let currentCallbackCount = inputBufferCallbackCount
        let currentPeakInputPower = peakInputPowerSinceStart
        stateCondition.unlock()

        guard isCurrentInput else {
            lifecycleLock.unlock()
            return
        }

        let shouldRecover = Self.shouldRecoverInputHealth(
            requiresAudibleInput: requiresAudibleInput,
            callbackCountAtStart: callbackCountAtStart,
            currentCallbackCount: currentCallbackCount,
            peakInputPowerSinceStart: currentPeakInputPower
        )
        inputHealthCheckWorkItem = nil
        lifecycleLock.unlock()

        guard shouldRecover else {
            NetworkDebugLogger.logMessage(
                "[Audio Recorder] Microphone input is healthy after audio device configuration."
            )
            return
        }

        NetworkDebugLogger.logMessage(
            "[Audio Recorder] Microphone input produced no usable audio after configuration; rebuilding audio engine."
        )
        recoverFromConfigurationChange(
            for: observedEngine,
            nextHealthCheckRequiresAudibleInput: false
        )
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

        var preparedInputGenerationForTesting: UInt64 {
            preparedInputLock.lock()
            defer { preparedInputLock.unlock() }
            return preparedInputGeneration
        }

        var preparedInputIsSuspendedForTesting: Bool {
            preparedInputLock.lock()
            defer { preparedInputLock.unlock() }
            return preparedInputIsSuspended
        }

        func suspendPreparedInputForTesting() {
            suspendPreparedInputEngine(reason: "test")
        }

        func resumePreparedInputForTesting() {
            resumePreparedInputEngine(reason: "test")
        }
    #endif

    private func resolveInputDeviceID() -> AudioDeviceID? {
        resolveInputDeviceIDForRecording()
    }

    private func configureInputDeviceAndResolveFormat(for inputNode: AVAudioInputNode) throws -> AVAudioFormat {
        let preferredID = settingsStore.preferredMicrophoneID
        let deviceID = try Self.requireInputDeviceID(resolveInputDeviceIDForRecording())
        inputNode.auAudioUnit.setValue(Int(deviceID), forKey: "deviceID")

        if !preferredID.isEmpty, settingsStore.preferredMicrophoneID == preferredID {
            let preferredFormat = inputNode.outputFormat(forBus: 0)
            if Self.isUsableInputFormat(preferredFormat) {
                return preferredFormat
            }

            NetworkDebugLogger.logMessage(
                """
                [Audio Recorder] Falling back to automatic microphone selection.
                preferredMicrophoneID: \(preferredID)
                sampleRate: \(preferredFormat.sampleRate)
                channelCount: \(preferredFormat.channelCount)
                """
            )
            resetUnavailablePreferredMicrophone(preferredID: preferredID)
            throw RecorderError.inputDeviceUnavailable
        }

        let automaticFormat = inputNode.outputFormat(forBus: 0)
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
            """
        )
        settingsStore.preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
    }

    private func currentRecordingState() -> Bool {
        stateCondition.lock()
        let isRecording = isRecording
        stateCondition.unlock()
        return isRecording
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

    static func shouldFollowSystemDefaultInputDevice(preferredMicrophoneID: String) -> Bool {
        preferredMicrophoneID == AudioDeviceManager.automaticDeviceID
    }

    static func canReusePreparedInputEngine(
        prepared: PreparedInputEngineSignature,
        current: PreparedInputEngineSignature
    ) -> Bool {
        prepared == current
    }

    static func isRecoverableInputReconfigurationError(_ error: Error) -> Bool {
        if let recorderError = error as? RecorderError {
            return recorderError == .inputDeviceUnavailable || recorderError == .inputStartupTimedOut
        }

        let nsError = error as NSError
        if nsError.domain == TFAudioTapErrorDomain {
            return true
        }
        let recoverableAudioUnitCodes = [
            Int(kAudioUnitErr_FormatNotSupported),
            Int(kAudioUnitErr_FailedInitialization),
            Int(kAudioUnitErr_CannotDoInCurrentContext)
        ]
        if recoverableAudioUnitCodes.contains(nsError.code) {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRecoverableInputReconfigurationError(underlyingError)
        }

        return false
    }

    static func requireInputDeviceID(_ deviceID: AudioDeviceID?) throws -> AudioDeviceID {
        guard let deviceID, deviceID != kAudioObjectUnknown else {
            throw RecorderError.inputDeviceUnavailable
        }
        return deviceID
    }

    private func handleInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        recordingID: UUID,
        inputGenerationID: UUID
    ) {
        autoreleasepool {
            stateCondition.lock()
            guard
                activeRecordingID == recordingID,
                activeInputGenerationID == inputGenerationID,
                let audioFile = self.audioFile,
                let recordingBufferConverter
            else {
                stateCondition.unlock()
                return
            }
            let levelHandler = self.levelHandler
            let audioBufferHandler = self.audioBufferHandler
            activeBufferCallbacks += 1
            inputBufferCallbackCount += 1
            if firstAudioBufferAt == nil {
                firstAudioBufferAt = Date()
            }
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
                let monoBuffer = try recordingBufferConverter.convert(buffer)
                let previewBuffer = clone(buffer: monoBuffer)
                let inputPower = rmsPower(for: monoBuffer)
                let normalizedLevel = normalizePower(inputPower)

                stateCondition.lock()
                if activeRecordingID == recordingID, activeInputGenerationID == inputGenerationID {
                    peakInputPowerSinceStart = max(peakInputPowerSinceStart, inputPower)
                }
                stateCondition.unlock()

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
            destination[channel].update(
                from: source[min(channel, Int(buffer.format.channelCount) - 1)],
                count: frameCount
            )
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

    static func shouldRecoverSilentInput(
        isRecording: Bool,
        callbackCountAtStart: Int,
        currentCallbackCount: Int,
        peakInputPowerSinceStart: Float
    ) -> Bool {
        guard isRecording else { return false }
        return shouldRecoverInputHealth(
            requiresAudibleInput: true,
            callbackCountAtStart: callbackCountAtStart,
            currentCallbackCount: currentCallbackCount,
            peakInputPowerSinceStart: peakInputPowerSinceStart
        )
    }

    static func shouldRecoverInputHealth(
        requiresAudibleInput: Bool,
        callbackCountAtStart: Int,
        currentCallbackCount: Int,
        peakInputPowerSinceStart: Float
    ) -> Bool {
        guard currentCallbackCount > callbackCountAtStart else { return true }
        return requiresAudibleInput
            && peakInputPowerSinceStart <= silentInputRecoveryPeakPowerThreshold
    }
}

private struct PreparedRecordingSession {
    let id: UUID
    let engine: AVAudioEngine
    let audioFile: AVAudioFile
    let recordingBufferConverter: AudioRecordingBufferConverter
    let inputGenerationID: UUID
    let startupBufferRelay: RecordingStartupAudioBufferRelay
    let audioEngineStartedAt: Date
    let firstAudioBufferAt: Date?
}

struct PreparedInputEngineSignature: Equatable {
    let deviceID: AudioDeviceID
    let preferredMicrophoneID: String
    let generation: UInt64
}

private struct PreparedInputEngine {
    let engine: AVAudioEngine
    let inputFormat: AVAudioFormat
    let startupBufferRelay: RecordingStartupAudioBufferRelay
    let signature: PreparedInputEngineSignature
    let includesInstantPreRoll: Bool
}

/// Preserves tap buffers emitted after AVAudioEngine starts but before the
/// recorder publishes its active session. Activation drains the prefix in order
/// and then forwards subsequent buffers directly.
final class RecordingStartupAudioBufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let firstBufferSemaphore = DispatchSemaphore(value: 0)
    private let maximumBufferedDuration: TimeInterval?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingDuration: TimeInterval = 0
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var isCancelled = false
    private var firstReceivedAt: Date?

    init(maximumBufferedDuration: TimeInterval? = nil) {
        self.maximumBufferedDuration = maximumBufferedDuration
    }

    var firstBufferReceivedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return firstReceivedAt
    }

    func append(_ buffer: AVAudioPCMBuffer, receivedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        if firstReceivedAt == nil {
            firstReceivedAt = receivedAt
            firstBufferSemaphore.signal()
        }
        if let handler {
            // Once active, stay on the audio tap's zero-copy path. Copies are
            // needed only while preserving the short pre-activation prefix.
            handler(buffer)
            return
        }
        guard let copiedBuffer = Self.copy(buffer) else { return }
        pendingBuffers.append(copiedBuffer)
        pendingDuration += Self.duration(of: copiedBuffer)
        trimBufferedAudioIfNeeded()
    }

    func activate(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, self.handler == nil else { return }
        pendingBuffers.forEach(handler)
        pendingBuffers.removeAll(keepingCapacity: false)
        pendingDuration = 0
        self.handler = handler
    }

    func waitForFirstBuffer(timeout: DispatchTimeInterval) -> Bool {
        lock.lock()
        let hasReceivedBuffer = firstReceivedAt != nil
        lock.unlock()
        return hasReceivedBuffer || firstBufferSemaphore.wait(timeout: .now() + timeout) == .success
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        pendingBuffers.removeAll(keepingCapacity: false)
        pendingDuration = 0
        handler = nil
        lock.unlock()
    }

    func discardBufferedAudio() {
        lock.lock()
        pendingBuffers.removeAll(keepingCapacity: false)
        pendingDuration = 0
        firstReceivedAt = nil
        lock.unlock()
    }

    #if DEBUG
        var bufferedFrameCountForTesting: AVAudioFrameCount {
            lock.lock()
            defer { lock.unlock() }
            return pendingBuffers.reduce(0) { $0 + $1.frameLength }
        }
    #endif

    private func trimBufferedAudioIfNeeded() {
        guard let maximumBufferedDuration else { return }
        while pendingDuration > maximumBufferedDuration, pendingBuffers.count > 1 {
            pendingDuration -= Self.duration(of: pendingBuffers.removeFirst())
        }
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return TimeInterval(buffer.frameLength) / buffer.format.sampleRate
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = source.mData,
                  let destinationData = destination.mData
            else { continue }
            memcpy(
                destinationData,
                sourceData,
                Int(min(source.mDataByteSize, destination.mDataByteSize))
            )
        }
        return copy
    }
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
