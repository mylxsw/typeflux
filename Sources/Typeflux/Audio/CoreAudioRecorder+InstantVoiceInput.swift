import AppKit
import AVFoundation
import CoreAudio
import Foundation

extension CoreAudioRecorder {
    final class WarmSession {
        let id: AudioDeviceID
        let input: CoreAudioInputCapturing
        var preRoll: CoreAudioPreRollBuffer
        var lastCallbackHostTime: UInt64

        init(id: AudioDeviceID, input: CoreAudioInputCapturing, preRollDuration: TimeInterval) {
            self.id = id
            self.input = input
            preRoll = CoreAudioPreRollBuffer(
                maximumDuration: preRollDuration,
                sampleRate: input.format.sampleRate
            )
            lastCallbackHostTime = mach_absolute_time()
        }
    }

    func beginWarmSession(id: AudioDeviceID, input: CoreAudioInputCapturing) {
        if let existing = warm, existing.input !== input {
            existing.input.stop()
        }
        warmTimer?.cancel()
        warmTimer = nil
        warmIdleWorkItem?.cancel()
        warmIdleWorkItem = nil
        prepared = nil

        warmWindowIsActive = true
        warmWindowGeneration &+= 1
        let generation = warmWindowGeneration

        installRunningWarmSession(id: id, input: input)

        let workItem = DispatchWorkItem { [weak self] in
            self?.expireWarmWindow(generation: generation)
        }
        warmIdleWorkItem = workItem
        queue.asyncAfter(deadline: .now() + instantVoiceInputIdleTimeout, execute: workItem)
        NetworkDebugLogger.logMessage(
            "[Core Audio Recorder] Microphone input is armed with in-memory pre-roll for the next recording."
        )
    }

    func rearmWarmSessionKeepingDeadline(id: AudioDeviceID, input: CoreAudioInputCapturing) {
        if let existing = warm, existing.input !== input {
            existing.input.stop()
        }
        warmTimer?.cancel()
        warmTimer = nil
        prepared = nil
        installRunningWarmSession(id: id, input: input)
    }

    private func installRunningWarmSession(id: AudioDeviceID, input: CoreAudioInputCapturing) {
        let session = WarmSession(id: id, input: input, preRollDuration: preRollDuration)
        while let packet = input.read() {
            session.lastCallbackHostTime = packet.callbackHostTime
            session.preRoll.append(packet)
        }
        warm = session
        observeDevice(id)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.consumeWarmInput() }
        warmTimer = timer
        timer.resume()
    }

    func consumeWarmInput() {
        guard let currentWarm = warm, session == nil else { return }
        while let packet = currentWarm.input.read() {
            currentWarm.lastCallbackHostTime = packet.callbackHostTime
            currentWarm.preRoll.append(packet)
        }
        if currentWarm.input.captureError != nil
            || (!suspended && Self.seconds(from: currentWarm.lastCallbackHostTime, to: mach_absolute_time()) > 2) {
            stopWarmSession()
            prepareIfAuthorized()
        }
    }

    func takeWarmSessionForRecording(matching deviceID: AudioDeviceID) -> (
        input: CoreAudioInputCapturing,
        preRoll: [CoreAudioInputPacket]
    )? {
        // Consuming the warm session pauses the idle release timer for the duration
        // of the recording; stop() opens a fresh full-length window on completion.
        warmWindowIsActive = false
        warmWindowGeneration &+= 1
        warmIdleWorkItem?.cancel()
        warmIdleWorkItem = nil
        warmTimer?.cancel()
        warmTimer = nil

        guard let currentWarm = warm else { return nil }
        warm = nil

        guard currentWarm.id == deviceID, currentWarm.input.captureError == nil else {
            currentWarm.input.stop()
            invalidateDeviceObservation()
            return nil
        }

        while let packet = currentWarm.input.read() {
            currentWarm.lastCallbackHostTime = packet.callbackHostTime
            currentWarm.preRoll.append(packet)
        }
        guard currentWarm.input.captureError == nil else {
            currentWarm.input.stop()
            invalidateDeviceObservation()
            return nil
        }

        return (currentWarm.input, currentWarm.preRoll.drain())
    }

    func stopWarmSession() {
        warmTimer?.cancel()
        warmTimer = nil
        guard let currentWarm = warm else { return }
        warm = nil
        currentWarm.input.stop()
        invalidateDeviceObservation()
    }

    func cancelWarmWindow() {
        warmWindowIsActive = false
        warmWindowGeneration &+= 1
        warmIdleWorkItem?.cancel()
        warmIdleWorkItem = nil
        stopWarmSession()
    }

    func instantVoiceInputSettingChanged() {
        guard session == nil else { return }
        guard !InstantVoiceInputPolicy.isEffective(settings: settings, devices: devices) else { return }
        cancelWarmWindow()
        prepareIfAuthorized()
    }

    private func expireWarmWindow(generation: UInt64) {
        guard warmWindowIsActive, warmWindowGeneration == generation else { return }
        cancelWarmWindow()
        NetworkDebugLogger.logMessage(
            "[Core Audio Recorder] Released instant voice input after the idle timeout."
        )
        prepareIfAuthorized()
    }

    func writePacket(
        _ packet: CoreAudioInputPacket, to current: Session, isPreRoll: Bool, emitPreRollLevel: Bool
    ) {
        recordPacketTiming(packet, in: current, isPreRoll: isPreRoll)
        guard current.error == nil else { return }
        appendPacketAudio(packet, to: current, isPreRoll: isPreRoll, emitPreRollLevel: emitPreRollLevel)
    }

    private func recordPacketTiming(_ packet: CoreAudioInputPacket, in current: Session, isPreRoll: Bool) {
        let callbackDelta = Self.seconds(from: current.startHostTime, to: packet.callbackHostTime)
        let receivedAt = isPreRoll ? current.startDate : current.startDate.addingTimeInterval(callbackDelta)
        if !isPreRoll || packet.callbackHostTime > current.lastCallbackHostTime {
            current.lastCallbackHostTime = packet.callbackHostTime
        }
        let hadSignal = current.signalTracker.firstSignalAt != nil
        current.signalTracker.observe(packet.buffer, receivedAt: receivedAt)
        if !hadSignal, let signalAt = current.signalTracker.firstSignalAt {
            NetworkDebugLogger.logMessage(
                "[Audio Input Signal] firstSignalMs=\(signalAt.timeIntervalSince(current.startDate) * 1000) "
                    + "leadingZeroMs=\(current.signalTracker.leadingZeroDuration * 1000)"
            )
        }
        guard current.firstCallbackDate == nil else { return }
        current.firstCallbackDate = receivedAt
        if isPreRoll {
            NetworkDebugLogger.logMessage(
                "[Core Audio Startup] warmPreRollFrames=\(packet.buffer.frameLength) "
                    + "sampleRate=\(packet.buffer.format.sampleRate) deviceBufferFrames=\(current.input.deviceBufferFrames)"
            )
        } else {
            let sampleDelta = packet.sampleHostTime == 0
                ? "unknown"
                : String(format: "%.1f", Self.seconds(from: current.startHostTime, to: packet.sampleHostTime) * 1000)
            NetworkDebugLogger.logMessage(
                "[Core Audio Startup] callbackMs=\(String(format: "%.1f", callbackDelta * 1000)) "
                    + "sampleMs=\(sampleDelta) frames=\(packet.buffer.frameLength) "
                    + "sampleRate=\(packet.buffer.format.sampleRate) deviceBufferFrames=\(current.input.deviceBufferFrames)"
            )
        }
        RecordingStartupLatencyTrace.shared.markFirstAudioBuffer()
    }

    private func appendPacketAudio(
        _ packet: CoreAudioInputPacket, to current: Session, isPreRoll: Bool, emitPreRollLevel: Bool
    ) {
        do {
            if current.file == nil {
                try FileManager.default.createDirectory(
                    at: current.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                current.file = try AVAudioFile(
                    forWriting: current.url,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: current.outputFormat.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                )
            }
            let mono = try current.converter.convert(packet.buffer)
            try current.file?.write(from: mono)
            current.bufferHandler?(mono)
            if isPreRoll {
                if emitPreRollLevel {
                    current.levelHandler(Self.level(of: mono))
                }
            } else if Self.seconds(from: current.lastMeterHostTime, to: packet.callbackHostTime) >= 0.03 {
                current.lastMeterHostTime = packet.callbackHostTime
                current.levelHandler(Self.level(of: mono))
            }
        } catch {
            current.error = error
        }
    }

    func prepareIfAuthorized() {
        guard automaticallyPrepare, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        queue.async { [weak self] in
            guard let self, self.session == nil, self.warm == nil, !self.suspended, self.prepared == nil else {
                return
            }
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

    func inputChanged() {
        let wasWarm = warmWindowIsActive
        stopWarmSession()
        prepared = nil
        invalidateDeviceObservation()
        guard !suspended else {
            cancelWarmWindow()
            return
        }
        guard let current = session else {
            guard wasWarm, InstantVoiceInputPolicy.isEffective(settings: settings, devices: devices) else {
                cancelWarmWindow()
                prepareIfAuthorized()
                return
            }
            do {
                let id = try resolvedDeviceID()
                let input = try makeInput(id)
                try input.start()
                rearmWarmSessionKeepingDeadline(id: id, input: input)
            } catch {
                cancelWarmWindow()
                prepareIfAuthorized()
            }
            return
        }
        current.input.stop()
        consumeInput(checkHealth: false)
        do {
            (current.deviceID, current.input) = try takeInput()
            current.lastCallbackHostTime = mach_absolute_time()
            try current.input.start()
            setActiveInput(current.deviceID)
            NetworkDebugLogger.logMessage("[Core Audio Recorder] Restarted input after a device change.")
        } catch {
            current.input.stop()
            current.error = error
        }
    }

    func defaultInputChanged() {
        guard settings.preferredMicrophoneID.isEmpty else { return }
        // Connecting a headset changes the system default, yet Automatic may keep
        // recording from the same wired input. Never interrupt that recording.
        if let current = session, (try? resolvedDeviceID()) == current.deviceID {
            return
        }
        if let currentWarm = warm, (try? resolvedDeviceID()) == currentWarm.id,
           InstantVoiceInputPolicy.isEffective(settings: settings, devices: devices) {
            return
        }
        inputChanged()
    }

    func observeDevice(_ id: AudioDeviceID) {
        invalidateDeviceObservation()
        guard observeChanges else { return }
        let observationID = deviceObservationID
        deviceObservation = CoreAudioDeviceObservation(deviceID: id, queue: queue) { [weak self] in
            guard let self, self.deviceObservationID == observationID else { return }
            self.inputChanged()
        }
    }

    func invalidateDeviceObservation() {
        deviceObservationID = UUID()
        deviceObservation = nil
    }

    func observeLifecycle() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .preferredMicrophoneDidChange, object: settings, queue: nil
            ) { [weak self] _ in self?.queue.async { [weak self] in self?.inputChanged() } }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .instantVoiceInputDidChange, object: settings, queue: nil
            ) { [weak self] _ in self?.queue.async { [weak self] in self?.instantVoiceInputSettingChanged() } }
        )
        defaultInputObservation = devices.observeDefaultInputDeviceChanges { [weak self] in
            self?.queue.async { [weak self] in self?.defaultInputChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(
                workspace.addObserver(forName: notification, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.suspended = true
                        self.cancelWarmWindow()
                        self.prepared = nil
                        self.invalidateDeviceObservation()
                        self.session?.input.stop()
                        self.outputMuter.endMutedSession()
                    }
                }
            )
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(
                workspace.addObserver(forName: notification, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.suspended else { return }
                        self.suspended = false
                        self.inputChanged()
                    }
                }
            )
        }
    }
}

final class CoreAudioDeviceObservation {
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
            kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyBufferFrameSize
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration
                    ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
    }

    deinit {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
    }
}
