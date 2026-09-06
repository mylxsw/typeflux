import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// Ordinary push-to-talk capture. Prepared Audio Units never run while idle.
/// Session state, input ownership, disk writes and callbacks are serialized on queue.
final class CoreAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let queue = DispatchQueue(label: "typeflux.audio.hal-recorder", qos: .userInitiated)
    private let settings: SettingsStore
    private let devices: AudioDeviceManaging
    private let outputMuter: SystemAudioOutputMuting
    private let makeInput: (AudioDeviceID) throws -> CoreAudioInputCapturing
    private let outputDirectory: URL
    private let automaticallyPrepare: Bool
    private let observeChanges: Bool
    private let startupTimeout: TimeInterval
    private var prepared: (id: AudioDeviceID, input: CoreAudioInputCapturing)?
    private var session: Session?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultInputObservation: AudioInputDeviceChangeObservation?
    private var deviceObservation: CoreAudioDeviceObservation?
    private var deviceObservationID = UUID()
    private var suspended = false

    private final class Session {
        let id: UUID
        var input: CoreAudioInputCapturing
        let startDate: Date
        let startHostTime: UInt64
        let url: URL
        let outputFormat: AVAudioFormat
        var file: AVAudioFile?
        let converter: AudioRecordingBufferConverter
        let levelHandler: (Float) -> Void
        let bufferHandler: ((AVAudioPCMBuffer) -> Void)?
        var firstCallbackDate: Date?
        var error: Error?
        var lastCallbackHostTime: UInt64
        var lastMeterHostTime: UInt64 = 0

        init(
            id: UUID, input: CoreAudioInputCapturing, url: URL, levelHandler: @escaping (Float) -> Void,
            bufferHandler: ((AVAudioPCMBuffer) -> Void)?
        ) {
            self.id = id
            self.input = input
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
        makeInput: @escaping (AudioDeviceID) throws -> CoreAudioInputCapturing = { try CoreAudioInput(deviceID: $0) }
    ) {
        settings = settingsStore
        devices = audioDeviceManager
        self.outputMuter = outputMuter
        self.makeInput = makeInput
        automaticallyPrepare = prepareImmediately
        self.observeChanges = observeChanges
        self.startupTimeout = startupTimeout
        self.outputDirectory =
            outputDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("Typeflux/audio", isDirectory: true)
        if observeChanges { observeLifecycle() }
        if prepareImmediately { prepareIfAuthorized() }
    }

    deinit {
        timer?.cancel()
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
            if !attempt.complete(result) {
                // A driver may finish after the caller timed out. Never leave that stale
                // attempt recording, and never publish its buffers to the next session.
                if session?.id == attempt.id {
                    session?.input.stop()
                    session = nil
                    timer?.cancel()
                    timer = nil
                    invalidateDeviceObservation()
                    prepared = nil
                    outputMuter.endMutedSession()
                }
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
        let input = try takeInput()
        guard !attempt.isCancelled else {
            invalidateDeviceObservation()
            throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
        }
        let date = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let url = outputDirectory.appendingPathComponent(day).appendingPathComponent(UUID().uuidString + ".wav")
        let current = Session(
            id: attempt.id, input: input, url: url, levelHandler: levelHandler, bufferHandler: audioBufferHandler)
        // Publish the session before starting hardware. Early input stays in the C ring
        // until this queue returns, even if file creation or UI work is delayed.
        session = current
        do {
            try input.start()
        } catch {
            input.stop()
            session = nil
            invalidateDeviceObservation()
            throw error
        }
        RecordingStartupLatencyTrace.shared.mark("audio.hal_start_return")
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
            // Stop hardware first, then drain every accepted packet before closing the file.
            current.input.stop()
            timer?.cancel()
            timer = nil
            consumeInput(checkHealth: false)
            session = nil
            invalidateDeviceObservation()
            outputMuter.endMutedSession()
            defer { prepareIfAuthorized() }
            let error = current.error ?? current.input.captureError
            if let error {
                current.file = nil
                try? FileManager.default.removeItem(at: current.url)
                throw error
            }
            guard let file = current.file, let firstCallbackDate = current.firstCallbackDate else {
                throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            current.file = nil
            return AudioFile(
                fileURL: current.url, duration: duration,
                startupTiming: .init(
                    audioEngineStartedAt: current.startDate, firstAudioBufferAt: firstCallbackDate
                ))
        }
    }

    private func consumeInput(checkHealth: Bool = true) {
        guard let current = session else { return }
        while let packet = current.input.read() {
            current.lastCallbackHostTime = packet.callbackHostTime
            if current.firstCallbackDate == nil {
                let callbackDelta = Self.seconds(from: current.startHostTime, to: packet.callbackHostTime)
                current.firstCallbackDate = current.startDate.addingTimeInterval(callbackDelta)
                let sampleDelta =
                    packet.sampleHostTime == 0
                    ? "unknown"
                    : String(
                        format: "%.1f",
                        Self.seconds(from: current.startHostTime, to: packet.sampleHostTime) * 1000)
                NetworkDebugLogger.logMessage(
                    "[Core Audio Startup] callbackMs=\(String(format: "%.1f", callbackDelta * 1000)) "
                        + "sampleMs=\(sampleDelta) frames=\(packet.buffer.frameLength) "
                        + "sampleRate=\(packet.buffer.format.sampleRate) deviceBufferFrames=\(current.input.deviceBufferFrames)"
                )
                RecordingStartupLatencyTrace.shared.markFirstAudioBuffer()
            }
            guard current.error == nil else { continue }
            do {
                if current.file == nil {
                    try FileManager.default.createDirectory(
                        at: current.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    current.file = try AVAudioFile(
                        forWriting: current.url,
                        settings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: current.outputFormat.sampleRate,
                            AVNumberOfChannelsKey: 1,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                        ])
                }
                let mono = try current.converter.convert(packet.buffer)
                try current.file?.write(from: mono)
                current.bufferHandler?(mono)
                if Self.seconds(from: current.lastMeterHostTime, to: packet.callbackHostTime) >= 0.03 {
                    current.lastMeterHostTime = packet.callbackHostTime
                    current.levelHandler(Self.level(of: mono))
                }
            } catch {
                current.error = error
            }
        }
        if let error = current.input.captureError { current.error = error }
        // Silence is valid audio. Only missing callbacks or explicit device changes
        // indicate a broken input; never rebuild merely because the user is quiet.
        if checkHealth, !suspended, current.error == nil,
            Self.seconds(from: current.lastCallbackHostTime, to: mach_absolute_time()) > 2
        {
            current.error = AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            current.input.stop()
        }
    }

    private func takeInput() throws -> CoreAudioInputCapturing {
        let id = try resolvedDeviceID()
        let input: CoreAudioInputCapturing
        if let prepared, prepared.id == id {
            input = prepared.input
        } else {
            input = try makeInput(id)
        }
        prepared = nil
        observeDevice(id)
        return input
    }

    private func resolvedDeviceID() throws -> AudioDeviceID {
        let preferred = settings.preferredMicrophoneID
        if !preferred.isEmpty, let id = devices.resolveInputDeviceID(for: preferred) { return id }
        return try AVFoundationAudioRecorder.requireInputDeviceID(devices.defaultInputDeviceID())
    }

    private func prepareIfAuthorized() {
        guard automaticallyPrepare, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        queue.async { [weak self] in
            guard let self, self.session == nil, !self.suspended, self.prepared == nil else { return }
            do {
                let id = try self.resolvedDeviceID()
                let input = try self.makeInput(id)
                self.prepared = (id, input)
                self.observeDevice(id)
            } catch {
                // Start retries preparation and surfaces failures through the existing workflow.
                self.prepared = nil
            }
        }
    }

    private func inputChanged() {
        prepared = nil
        invalidateDeviceObservation()
        guard !suspended else { return }
        guard let current = session else {
            prepareIfAuthorized()
            return
        }
        current.input.stop()
        consumeInput(checkHealth: false)
        do {
            current.input = try takeInput()
            current.lastCallbackHostTime = mach_absolute_time()
            try current.input.start()
            NetworkDebugLogger.logMessage("[Core Audio Recorder] Restarted input after a device change.")
        } catch {
            current.input.stop()
            current.error = error
        }
    }

    private func observeDevice(_ id: AudioDeviceID) {
        invalidateDeviceObservation()
        guard observeChanges else { return }
        let observationID = deviceObservationID
        deviceObservation = CoreAudioDeviceObservation(deviceID: id, queue: queue) { [weak self] in
            guard let self, self.deviceObservationID == observationID else { return }
            self.inputChanged()
        }
    }

    private func invalidateDeviceObservation() {
        deviceObservationID = UUID()
        deviceObservation = nil
    }

    private func observeLifecycle() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .preferredMicrophoneDidChange, object: settings, queue: nil
            ) { [weak self] _ in self?.queue.async { [weak self] in self?.inputChanged() } })
        defaultInputObservation = devices.observeDefaultInputDeviceChanges { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.settings.preferredMicrophoneID.isEmpty else { return }
                self.inputChanged()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
                [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.suspended = true
                    self.prepared = nil
                    self.invalidateDeviceObservation()
                    self.session?.input.stop()
                    self.outputMuter.endMutedSession()
                }
            })
        workspaceObservers.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
                [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.suspended = false
                    self.inputChanged()
                }
            })
    }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        if end >= start { return AVAudioTime.seconds(forHostTime: end - start) }
        return -AVAudioTime.seconds(forHostTime: start - end)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let power = 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 0.000_001))
        return max(0, min(1, (power + 60) / 60))
    }

    #if DEBUG
        func drainForTesting() { queue.sync {} }
        func inputChangedForTesting() { queue.sync { inputChanged() } }
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

private final class CoreAudioDeviceObservation {
    private let deviceID: AudioDeviceID
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = []

    init(deviceID: AudioDeviceID, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.deviceID = deviceID
        self.queue = queue
        listener = { _, _ in onChange() }
        for selector in [
            kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
            kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyBufferFrameSize,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration
                    ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
    }

    deinit {
        for var address in addresses { AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener) }
    }
}
