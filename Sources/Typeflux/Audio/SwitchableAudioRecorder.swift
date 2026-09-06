import AVFoundation
import Foundation

/// Chooses once per recording so settings changes cannot route stop() to another input.
final class SwitchableAudioRecorder: AudioRecorder {
    private let lock = NSLock()
    private let useCoreAudio: () -> Bool
    private let makeCoreAudio: () -> AudioRecorder
    private let makeLegacy: () -> AudioRecorder
    private var coreAudio: AudioRecorder?
    private var legacy: AudioRecorder?
    private var active: AudioRecorder?

    convenience init(settingsStore: SettingsStore, audioDeviceManager: AudioDeviceManaging) {
        self.init(
            useCoreAudio: {
                // The legacy path owns the optional warm microphone / pre-roll behavior.
                Self.usesCoreAudio(
                    instantVoiceInputEnabled: settingsStore.instantVoiceInputEnabled,
                    override: ProcessInfo.processInfo.environment["TYPEFLUX_AUDIO_CAPTURE"]
                )
            },
            makeCoreAudio: {
                CoreAudioRecorder(settingsStore: settingsStore, audioDeviceManager: audioDeviceManager)
            },
            makeLegacy: {
                AVFoundationAudioRecorder(settingsStore: settingsStore, audioDeviceManager: audioDeviceManager)
            })
    }

    static func usesCoreAudio(instantVoiceInputEnabled: Bool, override: String?) -> Bool {
        !instantVoiceInputEnabled && override != "legacy"
    }

    init(
        useCoreAudio: @escaping () -> Bool, makeCoreAudio: @escaping () -> AudioRecorder,
        makeLegacy: @escaping () -> AudioRecorder
    ) {
        self.useCoreAudio = useCoreAudio
        self.makeCoreAudio = makeCoreAudio
        self.makeLegacy = makeLegacy
        if useCoreAudio() { coreAudio = makeCoreAudio() } else { legacy = makeLegacy() }
    }

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { throw NSError(domain: "AudioRecorder", code: 1) }
        if useCoreAudio() {
            // Releasing legacy also releases its optional warm microphone.
            legacy = nil
            let recorder = coreAudio ?? makeCoreAudio()
            coreAudio = recorder
            do {
                try recorder.start(levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
                active = recorder
                return
            } catch {
                coreAudio = nil
                NetworkDebugLogger.logMessage("[Audio Recorder] Core Audio startup failed; trying compatible capture.")
            }
        } else {
            coreAudio = nil
        }
        let recorder = legacy ?? makeLegacy()
        legacy = recorder
        try recorder.start(levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
        active = recorder
    }

    func stop() throws -> AudioFile {
        lock.lock()
        defer { lock.unlock() }
        guard let recorder = active else { throw NSError(domain: "AudioRecorder", code: 1) }
        defer { active = nil }
        return try recorder.stop()
    }
}
