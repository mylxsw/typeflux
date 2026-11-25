import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Push-to-talk and Instant Voice Input capture on Core Audio HAL inputs.
/// Prepared Audio Units never run while idle unless an Instant Voice Input warm window is active.
/// Session state, input ownership, disk writes and callbacks are serialized on queue.
final class CoreAudioRecorder: AudioRecorder, @unchecked Sendable {
    static let instantVoiceInputPreRollDuration: TimeInterval = CoreAudioPreRollBuffer.defaultDuration
    static let instantVoiceInputIdleTimeout: TimeInterval = 15 * 60

    let queue = DispatchQueue(label: "typeflux.audio.hal-recorder", qos: .userInitiated)
    let settings: SettingsStore
    let devices: AudioDeviceManaging
    let outputMuter: SystemAudioOutputMuting
    let makeInput: (AudioDeviceID) throws -> CoreAudioInputCapturing
    private let outputDirectory: URL
    let automaticallyPrepare: Bool
    let observeChanges: Bool
    private let startupTimeout: TimeInterval
    let preRollDuration: TimeInterval
    let instantVoiceInputIdleTimeout: TimeInterval
    var prepared: (id: AudioDeviceID, input: CoreAudioInputCapturing)?
    var warm: WarmSession?
    var warmTimer: DispatchSourceTimer?
    var warmIdleWorkItem: DispatchWorkItem?
    var warmWindowIsActive = false
    var warmWindowGeneration: UInt64 = 0
    var session: Session?
    private var timer: DispatchSourceTimer?
    var observers: [NSObjectProtocol] = []
    var workspaceObservers: [NSObjectProtocol] = []
    var defaultInputObservation: AudioInputDeviceChangeObservation?
    var deviceObservation: CoreAudioDeviceObservation?
    var deviceObservationID = UUID()
    var suspended = false
    let activeInputLock = NSLock()
    var activeInputBluetooth = false

    var activeInputIsBluetooth: Bool {
        activeInputLock.withLock { activeInputBluetooth }
    }

    struct AcquiredInput {
        let deviceID: AudioDeviceID
        let input: CoreAudioInputCapturing
        let preRoll: [CoreAudioInputPacket]
        let alreadyRunning: Bool
    }

    final class Session {
        let id: UUID
        var input: CoreAudioInputCapturing
        var deviceID: AudioDeviceID
        let startDate: Date
        let startHostTime: UInt64
        let url: URL
        let outputFormat: AVAudioFormat
        var file: AVAudioFile?
        let converter: AudioRecordingBufferConverter
        let levelHandler: (Float) -> Void
        let bufferHandler: ((AVAudioPCMBuffer) -> Void)?
        var firstCallbackDate: Date?
        var signalTracker = AudioInputSignalTracker()
        var error: Error?
        var lastCallbackHostTime: UInt64
        var lastMeterHostTime: UInt64 = 0

        init(
            id: UUID, input: CoreAudioInputCapturing, deviceID: AudioDeviceID, url: URL,
            levelHandler: @escaping (Float) -> Void, bufferHandler: ((AVAudioPCMBuffer) -> Void)?
        ) {
            self.id = id
            self.input = input
            self.deviceID = deviceID
            self.url = url
            startDate = Date()
            startHostTime = mach_absolute_time()
            lastCallbackHostTime = startHostTime
            outputFormat = AVAudioFormat(standardFormatWithSampleRate: input.format.sampleRate, channels: 1)!
            converter = AudioRecordingBufferConverter(targetFormat: outputFormat)
            self.levelHandler = levelHandler
            self.bufferHandler = bufferHandler
        }
    }

    init(
        settingsStore: SettingsStore, audioDeviceManager: AudioDeviceManaging = AudioDeviceManager(),
        outputMuter: SystemAudioOutputMuting = SystemAudioOutputMuter(),
        outputDirectory: URL? = nil, prepareImmediately: Bool = true, observeChanges: Bool = true,
        startupTimeout: TimeInterval = 5,
        preRollDuration: TimeInterval = CoreAudioRecorder.instantVoiceInputPreRollDuration,
        instantVoiceInputIdleTimeout: TimeInterval = CoreAudioRecorder.instantVoiceInputIdleTimeout,
        makeInput: @escaping (AudioDeviceID) throws -> CoreAudioInputCapturing = { try CoreAudioInput(deviceID: $0) }
    ) {
        settings = settingsStore
        devices = audioDeviceManager
        self.outputMuter = outputMuter
        self.makeInput = makeInput
        automaticallyPrepare = prepareImmediately
        self.observeChanges = observeChanges
        self.startupTimeout = startupTimeout
        self.preRollDuration = preRollDuration
        self.instantVoiceInputIdleTimeout = instantVoiceInputIdleTimeout
        self.outputDirectory =
            outputDirectory
                ?? TypefluxDataDirectories.data.appendingPathComponent("audio", isDirectory: true)
        if observeChanges {
            observeLifecycle()
        }
        if prepareImmediately {
            prepareIfAuthorized()
        }
    }

    deinit {
        timer?.cancel()
        warmTimer?.cancel()
        warmIdleWorkItem?.cancel()
        warm?.input.stop()
        session?.input.stop()
        outputMuter.endMutedSession()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        defaultInputObservation?.cancel()
    }

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        let attempt = CoreAudioStartupAttempt()
        queue.async { [self] in
            guard !attempt.isCancelled else { return }
            let result = Result {
                try startSession(attempt: attempt, levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
            }
            if !attempt.complete(result), session?.id == attempt.id {
                // A driver may finish after the caller timed out. Never leave that stale
                // attempt recording, and never publish its buffers to the next session.
                session?.input.stop()
                session = nil
                setActiveInput(nil)
                timer?.cancel()
                timer = nil
                invalidateDeviceObservation()
                prepared = nil
                outputMuter.endMutedSession()
            }
        }
        try attempt.wait(timeout: startupTimeout)
    }

    private func startSession(
        attempt: CoreAudioStartupAttempt, levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        guard session == nil, !suspended else {
            throw AVFoundationAudioRecorder.RecorderError.inputDeviceUnavailable
        }
        let acquired = try takeInputForStart()
        guard !attempt.isCancelled else {
            if acquired.alreadyRunning {
                acquired.input.stop()
            }
            invalidateDeviceObservation()
            throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let url = outputDirectory.appendingPathComponent(day).appendingPathComponent(UUID().uuidString + ".wav")
        let current = Session(
            id: attempt.id, input: acquired.input, deviceID: acquired.deviceID, url: url,
            levelHandler: levelHandler, bufferHandler: audioBufferHandler
        )
        // Publish the session before starting hardware. Early input stays in the C ring
        // until this queue returns, even if file creation or UI work is delayed.
        session = current
        if !acquired.alreadyRunning {
            do {
                try acquired.input.start()
            } catch {
                acquired.input.stop()
                session = nil
                invalidateDeviceObservation()
                throw error
            }
        }
        setActiveInput(acquired.deviceID)
        RecordingStartupLatencyTrace.shared.mark("audio.hal_start_return")
        for (index, packet) in acquired.preRoll.enumerated() {
            writePacket(packet, to: current, isPreRoll: true, emitPreRollLevel: index == acquired.preRoll.count - 1)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.consumeInput() }
        self.timer = timer
        timer.resume()
        if settings.muteSystemOutputDuringRecording {
            let delay: Double = settings.soundEffectsEnabled ? 1.225 : 0.180
            queue.asyncAfter(deadline: .now() + delay) { [weak self, weak current] in
                guard let self, let current, self.session === current else { return }
                self.outputMuter.beginMutedSession()
            }
        }
    }

    func stop() throws -> AudioFile {
        try queue.sync {
            guard let current = session else { throw NSError(domain: "AudioRecorder", code: 1) }
            timer?.cancel()
            timer = nil
            let wantsWarmInput = !suspended
                && InstantVoiceInputPolicy.isEffective(settings: settings, devices: devices)
                && (try? resolvedDeviceID()) == current.deviceID
            if !wantsWarmInput {
                // Stop hardware first, then drain every accepted packet before closing the file.
                current.input.stop()
            }
            consumeInput(checkHealth: false)
            session = nil
            setActiveInput(nil)
            outputMuter.endMutedSession()

            if let error = current.error ?? current.input.captureError {
                cleanupFailedStop(for: current)
                throw error
            }
            guard let file = current.file, let firstCallbackDate = current.firstCallbackDate else {
                cleanupFailedStop(for: current)
                throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            }
            if wantsWarmInput {
                beginWarmSession(id: current.deviceID, input: current.input)
            } else {
                invalidateDeviceObservation()
                cancelWarmWindow()
                prepareIfAuthorized()
            }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            current.file = nil
            return AudioFile(
                fileURL: current.url, duration: duration,
                startupTiming: .init(
                    audioEngineStartedAt: current.startDate, firstAudioBufferAt: firstCallbackDate,
                    firstAudioSignalAt: current.signalTracker.firstSignalAt,
                    leadingZeroDuration: current.signalTracker.leadingZeroDuration
                )
            )
        }
    }
}

extension CoreAudioRecorder {
    fileprivate func cleanupFailedStop(for current: Session) {
        current.input.stop()
        invalidateDeviceObservation()
        cancelWarmWindow()
        current.file = nil
        try? FileManager.default.removeItem(at: current.url)
        prepareIfAuthorized()
    }

    func consumeInput(checkHealth: Bool = true) {
        guard let current = session else { return }
        while let packet = current.input.read() {
            writePacket(packet, to: current, isPreRoll: false, emitPreRollLevel: false)
        }
        if let error = current.input.captureError {
            current.error = error
        }
        // Silence is valid audio. Only missing callbacks or explicit device changes
        // indicate a broken input; never rebuild merely because the user is quiet.
        if checkHealth, !suspended, current.error == nil,
           Self.seconds(from: current.lastCallbackHostTime, to: mach_absolute_time()) > 2 {
            current.error = AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            current.input.stop()
        }
    }

    fileprivate func takeInputForStart() throws -> AcquiredInput {
        let id = try resolvedDeviceID()
        if let warmMatch = takeWarmSessionForRecording(matching: id) {
            prepared = nil
            observeDevice(id)
            return AcquiredInput(
                deviceID: id, input: warmMatch.input, preRoll: warmMatch.preRoll, alreadyRunning: true
            )
        }
        let (coldID, coldInput) = try takeColdInput(resolvedID: id)
        return AcquiredInput(deviceID: coldID, input: coldInput, preRoll: [], alreadyRunning: false)
    }

    func takeInput() throws -> (AudioDeviceID, CoreAudioInputCapturing) {
        stopWarmSession()
        return try takeColdInput(resolvedID: resolvedDeviceID())
    }

    private func takeColdInput(resolvedID id: AudioDeviceID) throws -> (AudioDeviceID, CoreAudioInputCapturing) {
        let input: CoreAudioInputCapturing = if let prepared, prepared.id == id {
            prepared.input
        } else {
            try makeInput(id)
        }
        prepared = nil
        observeDevice(id)
        return (id, input)
    }

    func resolvedDeviceID() throws -> AudioDeviceID {
        // An explicitly selected microphone always wins, Bluetooth included.
        let preferred = settings.preferredMicrophoneID
        if !preferred.isEmpty, let id = devices.resolveInputDeviceID(for: preferred) {
            return id
        }
        return try AVFoundationAudioRecorder.requireInputDeviceID(devices.automaticRecordingInputDeviceID())
    }

    func setActiveInput(_ deviceID: AudioDeviceID?) {
        let bluetooth = deviceID.map(devices.isBluetoothInputDevice) ?? false
        activeInputLock.withLock { activeInputBluetooth = bluetooth }
    }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start
            ? AVAudioTime.seconds(forHostTime: end - start)
            : -AVAudioTime.seconds(forHostTime: start - end)
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for sampleIndex in 0 ..< Int(buffer.frameLength) {
            sum += samples[sampleIndex] * samples[sampleIndex]
        }
        let power = 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 0.000_001))
        return max(0, min(1, (power + 60) / 60))
    }

    #if DEBUG
        func drainForTesting() {
            queue.sync {}
        }

        func inputChangedForTesting() {
            queue.sync { inputChanged() }
        }

        func defaultInputChangedForTesting() {
            queue.sync { defaultInputChanged() }
        }

        func consumeWarmInputForTesting() {
            queue.sync { consumeWarmInput() }
        }

        var isWarmWindowActiveForTesting: Bool {
            queue.sync { warmWindowIsActive && warm != nil }
        }

        func suspendForTesting() {
            queue.sync {
                suspended = true
                cancelWarmWindow()
                prepared = nil
                invalidateDeviceObservation()
                session?.input.stop()
                outputMuter.endMutedSession()
            }
        }

        func resumeForTesting() {
            queue.sync {
                guard suspended else { return }
                suspended = false
                inputChanged()
            }
        }
    #endif
}

private final class CoreAudioStartupAttempt: @unchecked Sendable {
    let id = UUID()
    private let condition = NSCondition()
    private var result: Result<Void, Error>?
    private var cancelled = false

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func complete(_ result: Result<Void, Error>) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { return false }
        self.result = result
        condition.signal()
        return true
    }

    func wait(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if !condition.wait(until: deadline), result == nil {
                cancelled = true
                throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            }
        }
        try result!.get()
    }
}
