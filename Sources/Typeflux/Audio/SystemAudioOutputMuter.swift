import CoreAudio
import Foundation

protocol SystemAudioOutputMuting: AnyObject {
    func beginMutedSession()
    func endMutedSession()
}

/// Abstracts the CoreAudio output-device operations used by `SystemAudioOutputMuter`.
protocol AudioOutputDeviceAccessing {
    func defaultOutputDeviceID() -> AudioDeviceID?
    func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool
    /// Returns the first built-in device that has output streams (e.g. the MacBook speakers).
    func builtInOutputDeviceID() -> AudioDeviceID?
    /// Returns the master mute state, or nil when the device has no mute control.
    func currentMuteState(for deviceID: AudioDeviceID) -> UInt32?
    func setMute(_ isMuted: Bool, for deviceID: AudioDeviceID) -> Bool
}

/// Mutes the default output device while recording.
///
/// Some external displays (for example DisplayPort audio over USB-C) expose no software
/// mute control. In that case the default output is temporarily switched to the built-in
/// output device, which is muted instead, and the original default output is restored when
/// the session ends. Playback keeps running; it is only inaudible.
final class SystemAudioOutputMuter: SystemAudioOutputMuting {
    private struct State {
        let deviceID: AudioDeviceID
        let wasMuted: UInt32
        /// The original default output device, set only when the default output was switched.
        let switchedFromDeviceID: AudioDeviceID?
    }

    private let devices: AudioOutputDeviceAccessing
    private var capturedState: State?

    init(devices: AudioOutputDeviceAccessing = CoreAudioOutputDeviceAccess()) {
        self.devices = devices
    }

    func beginMutedSession() {
        guard capturedState == nil else { return }
        guard let originalDeviceID = devices.defaultOutputDeviceID() else { return }

        var targetDeviceID = originalDeviceID
        var switchedFrom: AudioDeviceID?
        var currentMute = devices.currentMuteState(for: originalDeviceID)

        if currentMute == nil,
           let builtInID = devices.builtInOutputDeviceID(),
           builtInID != originalDeviceID,
           let builtInMute = devices.currentMuteState(for: builtInID) {
            targetDeviceID = builtInID
            switchedFrom = originalDeviceID
            currentMute = builtInMute
        }
        guard let wasMuted = currentMute else { return }

        _ = devices.setMute(true, for: targetDeviceID)

        // Mute first, then switch, so nothing is audible on the built-in output.
        if switchedFrom != nil, !devices.setDefaultOutputDeviceID(targetDeviceID) {
            _ = devices.setMute(wasMuted != 0, for: targetDeviceID)
            return
        }

        capturedState = State(deviceID: targetDeviceID, wasMuted: wasMuted, switchedFromDeviceID: switchedFrom)
    }

    func endMutedSession() {
        guard let capturedState else { return }
        // Switch back first, then unmute, so nothing is audible on the built-in output.
        if let originalDeviceID = capturedState.switchedFromDeviceID {
            _ = devices.setDefaultOutputDeviceID(originalDeviceID)
        }
        _ = devices.setMute(capturedState.wasMuted != 0, for: capturedState.deviceID)
        self.capturedState = nil
    }
}

struct CoreAudioOutputDeviceAccess: AudioOutputDeviceAccessing {
    func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr else {
            return nil
        }

        return deviceID
    }

    func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &id
        ) == noErr
    }

    func builtInOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceIDs) == noErr else {
            return nil
        }

        return deviceIDs.first { hasOutputStreams($0) && transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn }
    }

    func currentMuteState(for deviceID: AudioDeviceID) -> UInt32? {
        var address = muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &mute) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return mute
    }

    func setMute(_ isMuted: Bool, for deviceID: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var mute: UInt32 = isMuted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute) == noErr
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
