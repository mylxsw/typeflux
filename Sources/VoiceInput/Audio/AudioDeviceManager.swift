import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class AudioDeviceManager {
    static let automaticDeviceID = ""

    func availableInputDevices() -> [AudioInputDevice] {
        let devices: [AVCaptureDevice]
        if #available(macOS 14.0, *) {
            devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
        } else {
            devices = AVCaptureDevice.devices(for: .audio)
        }

        return devices
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
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

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let dataSize = propertyDataSize(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: &address
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
                baseAddress
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
            mElement: kAudioObjectPropertyElementMain
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
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard getPropertyData(objectID: deviceID, address: &address, value: &value, dataSize: size) == noErr else {
            return nil
        }

        return value.map { $0.takeUnretainedValue() as String }
    }

    private func propertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> UInt32? {
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return nil }
        return size
    }

    private func getPropertyData<T>(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        value: inout T,
        dataSize: UInt32
    ) -> OSStatus {
        var size = dataSize
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    }
}
