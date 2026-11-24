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
/// For displays without a Core Audio mute control, prefer the display's own volume control.
/// If it is unavailable, temporarily route default playback to muted built-in speakers.
final class SystemAudioOutputMuter: SystemAudioOutputMuting {
    private enum State {
        case audioDevice(id: AudioDeviceID, unmuteOnEnd: Bool, switchedFrom: AudioDeviceID?)
        case display(DisplayAudioVolumeControlling, previousVolume: UInt16)
    }

    private let devices: AudioOutputDeviceAccessing
    private let displayVolume: (AudioDeviceID) -> DisplayAudioVolumeControlling?
    private let lock = NSLock()
    private var capturedState: State?

    init(
        devices: AudioOutputDeviceAccessing = CoreAudioOutputDeviceAccess(),
        displayVolume: @escaping (AudioDeviceID) -> DisplayAudioVolumeControlling? = DisplayAudioVolume.control(for:)
    ) {
        self.devices = devices
        self.displayVolume = displayVolume
    }

    deinit { endMutedSession() }

    func beginMutedSession() {
        lock.withLock {
            guard capturedState == nil, let originalID = devices.defaultOutputDeviceID() else { return }

            if let needsUnmute = muteIfSupported(originalID) {
                capturedState = .audioDevice(id: originalID, unmuteOnEnd: needsUnmute, switchedFrom: nil)
                return
            }
            if let display = displayVolume(originalID), let volume = display.volume(),
                devices.defaultOutputDeviceID() == originalID
            {
                if volume == 0 || (display.setVolume(0) && display.volume() == 0) {
                    capturedState = .display(display, previousVolume: volume)
                    return
                }
                // A display can accept a write without replying to the verification read.
                restoreDisplayVolume(display, previous: volume)
            }

            guard devices.defaultOutputDeviceID() == originalID, let builtInID = devices.builtInOutputDeviceID(),
                builtInID != originalID, let needsUnmute = muteIfSupported(builtInID)
            else { return }
            if devices.setDefaultOutputDeviceID(builtInID) {
                capturedState = .audioDevice(id: builtInID, unmuteOnEnd: needsUnmute, switchedFrom: originalID)
            } else if needsUnmute {
                _ = devices.setMute(false, for: builtInID)
            }
        }
    }

    func endMutedSession() {
        lock.withLock {
            guard let capturedState else { return }
            self.capturedState = nil
            switch capturedState {
            case let .audioDevice(deviceID, needsUnmute, originalID):
                if let originalID, devices.defaultOutputDeviceID() == deviceID {
                    _ = devices.setDefaultOutputDeviceID(originalID)
                }
                if needsUnmute { _ = devices.setMute(false, for: deviceID) }
            case let .display(display, volume):
                restoreDisplayVolume(display, previous: volume)
            }
        }
    }

    private func muteIfSupported(_ deviceID: AudioDeviceID) -> Bool? {
        guard let mute = devices.currentMuteState(for: deviceID) else { return nil }
        if mute != 0 { return false }
        return devices.setMute(true, for: deviceID) ? true : nil
    }

    private func restoreDisplayVolume(_ display: DisplayAudioVolumeControlling, previous: UInt16) {
        guard previous > 0 else { return }
        if let current = display.volume(), current != 0 { return }
        if !display.setVolume(previous) { _ = display.setVolume(previous) }
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
