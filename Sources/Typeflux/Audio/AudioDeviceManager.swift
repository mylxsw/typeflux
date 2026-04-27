import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

protocol AudioDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice]
    func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID?
    func defaultInputDeviceID() -> AudioDeviceID?
}

final class AudioDeviceManager: AudioDeviceManaging {
    static let automaticDeviceID = ""

    func availableInputDevices() -> [AudioInputDevice] {
        return allAudioDeviceIDs()
            .compactMap { deviceID in
                guard
                    deviceSupportsInput(deviceID),
                    let id = deviceUniqueID(for: deviceID),
                    let name = deviceName(for: deviceID)
                else {
                    return nil
                }

                return AudioInputDevice(id: id, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID? {
        guard !uniqueID.isEmpty else { return nil }

        for deviceID in allAudioDeviceIDs() {
            guard deviceSupportsInput(deviceID), deviceUniqueID(for: deviceID) == uniqueID else {
                continue
            }

            return deviceID
        }

        return nil
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                pointer,
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceSupportsInput(deviceID) else {
            return nil
        }

        return deviceID
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        guard let dataSize = propertyDataSize(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: &address,
        ) else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            var size = dataSize
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress,
            )
        }
        guard status == noErr else {
            return []
        }

        return deviceIDs
    }

    private func deviceSupportsInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain,
        )

        guard let size = propertyDataSize(objectID: deviceID, address: &address) else {
            return false
        }

        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func deviceUniqueID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return value.map { $0.takeUnretainedValue() as String }
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return value.map { $0.takeUnretainedValue() as String }
    }

    private func propertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
    ) -> UInt32? {
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return nil }
        return size
    }
}
