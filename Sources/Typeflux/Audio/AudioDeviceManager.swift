import CoreAudio
import Foundation
import IOKit

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

protocol AudioDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice]
    func resolveInputDeviceID(for uniqueID: String) -> AudioDeviceID?
    func defaultInputDeviceID() -> AudioDeviceID?
    func observeDefaultInputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> AudioInputDeviceChangeObservation?
    /// The input the Automatic microphone setting records from. It follows the system
    /// default except when that default is a Bluetooth headset (see
    /// `AutomaticInputDeviceSelector`).
    func automaticRecordingInputDeviceID() -> AudioDeviceID?
    func isBluetoothInputDevice(_ deviceID: AudioDeviceID) -> Bool
}

extension AudioDeviceManaging {
    func automaticRecordingInputDeviceID() -> AudioDeviceID? {
        defaultInputDeviceID()
    }

    func isBluetoothInputDevice(_: AudioDeviceID) -> Bool {
        false
    }
}

protocol AudioInputDeviceChangeObservation: AnyObject {
    func cancel()
}

final class AudioDeviceManager: AudioDeviceManaging {
    static let automaticDeviceID = ""
    private let defaultInputObservationQueue = DispatchQueue(label: "typeflux.audio.default-input-observation")
    private let substitutionLog = AutomaticInputDeviceSelector.SubstitutionLog()

    func availableInputDevices() -> [AudioInputDevice] {
        allAudioDeviceIDs()
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
            mElement: kAudioObjectPropertyElementMain
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
                pointer
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceSupportsInput(deviceID) else {
            return nil
        }

        return deviceID
    }

    func observeDefaultInputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> AudioInputDeviceChangeObservation? {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            defaultInputObservationQueue,
            listener
        )
        guard status == noErr else {
            return nil
        }

        return DefaultInputDeviceChangeObservation(
            objectID: objectID,
            address: address,
            queue: defaultInputObservationQueue,
            listener: listener
        )
    }

    func automaticRecordingInputDeviceID() -> AudioDeviceID? {
        let systemDefault = defaultInputDeviceID()
        let selected = AutomaticInputDeviceSelector.select(
            systemDefault: systemDefault,
            inputDeviceIDs: { allAudioDeviceIDs().filter(deviceSupportsInput) },
            transportType: transportType(for:),
            builtInMicrophoneIsUsable: { !Self.isClamshellClosed() }
        )
        if let message = substitutionLog.message(systemDefault: systemDefault, selected: selected) {
            NetworkDebugLogger.logMessage(message)
        }
        return selected
    }

    func isBluetoothInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        transportType(for: deviceID).map(AutomaticInputDeviceSelector.isBluetooth) ?? false
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// Desktop Macs do not publish a clamshell state, so their built-in input stays usable.
    static func isClamshellClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return (value as? Bool) ?? false
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
            mElement: kAudioObjectPropertyElementMain
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
        address: inout AudioObjectPropertyAddress
    ) -> UInt32? {
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return nil }
        return size
    }
}

private final class DefaultInputDeviceChangeObservation: AudioInputDeviceChangeObservation, @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var isActive = true

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.listener = listener
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
        lock.unlock()

        AudioObjectRemovePropertyListenerBlock(
            objectID,
            &address,
            queue,
            listener
        )
    }
}
