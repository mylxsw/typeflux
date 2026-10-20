import Foundation

enum InstantVoiceInputPolicy {
    static func isEffective(settings: SettingsStore, devices: AudioDeviceManaging) -> Bool {
        guard settings.instantVoiceInputEnabled else { return false }
        let preferred = settings.preferredMicrophoneID
        let deviceID = preferred.isEmpty
            ? devices.automaticRecordingInputDeviceID()
            : devices.resolveInputDeviceID(for: preferred) ?? devices.automaticRecordingInputDeviceID()
        guard let deviceID else { return false }
        return !devices.isBuiltInInputDevice(deviceID)
    }
}
