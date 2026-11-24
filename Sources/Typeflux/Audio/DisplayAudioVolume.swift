import CoreAudio
import Foundation
import IOKit

protocol DisplayAudioVolumeControlling {
    func volume() -> UInt16?
    func setVolume(_ value: UInt16) -> Bool
}

enum DisplayAudioVolume {
    static func control(for deviceID: AudioDeviceID) -> DisplayAudioVolumeControlling? {
        #if arch(arm64)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout.size(ofValue: uid))
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
                let uid, let displayID = UUID(uuidString: uid.takeRetainedValue() as String),
                let ddc = AppleSiliconDisplayVolumeAPI.shared
            else { return nil }
            return ddc.control(for: displayID)
        #else
            return nil
        #endif
    }
}

#if arch(arm64)
    /// DDC/CI accesses the display's own volume; it does not capture or reroute audio.
    private final class AppleSiliconDisplayVolumeAPI: @unchecked Sendable {
        typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
        typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

        static let shared = AppleSiliconDisplayVolumeAPI()

        private let create: Create
        private let read: Read
        private let write: Write

        private init?() {
            // These IOKit entry points are private and may be absent on other macOS versions.
            guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
            guard let create = dlsym(library, "IOAVServiceCreateWithService"),
                let read = dlsym(library, "IOAVServiceReadI2C"),
                let write = dlsym(library, "IOAVServiceWriteI2C")
            else {
                dlclose(library)
                return nil
            }
            self.create = unsafeBitCast(create, to: Create.self)
            self.read = unsafeBitCast(read, to: Read.self)
            self.write = unsafeBitCast(write, to: Write.self)
        }

        func control(for id: UUID) -> DisplayAudioVolumeControlling? {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
            else { return nil }
            defer { IOObjectRelease(iterator) }

            var match: MonitorVolume?
            while case let proxy = IOIteratorNext(iterator), proxy != 0 {
                defer { IOObjectRelease(proxy) }
                guard property("Location", on: proxy) == "External",
                    let service = create(kCFAllocatorDefault, proxy)?.takeRetainedValue(),
                    readEDID(from: service) == id
                else { continue }
                // Identical EDIDs are possible. Never change volume when the match is ambiguous.
                guard match == nil else { return nil }
                match = MonitorVolume(service: service, chipAddress: ddcAddress(for: proxy), read: read, write: write)
            }
            return match
        }

        private func readEDID(from service: CFTypeRef) -> UUID? {
            var bytes = [UInt8](repeating: 0, count: 128)
            let status = bytes.withUnsafeMutableBytes { buffer in
                read(service, 0x50, 0, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard status == kIOReturnSuccess, bytes.prefix(8).elementsEqual([0, 255, 255, 255, 255, 255, 255, 0]),
                bytes.reduce(0, &+) == 0
            else { return nil }
            // CoreAudio uses the first 16 EDID identification bytes as its display-audio device UID.
            return UUID(uuid: (bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
                               bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23]))
        }

        private func ddcAddress(for proxy: io_service_t) -> UInt32 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { return 0x37 }
            defer { IOObjectRelease(parent) }
            // These bridges use a different I2C address for DDC/CI.
            return property("EPICProviderClass", on: parent) == "AppleDCPMCDP29XX" ? 0xB7 : 0x37
        }

        private func property(_ key: String, on service: io_service_t) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }

        private struct MonitorVolume: DisplayAudioVolumeControlling {
            let service: CFTypeRef
            let chipAddress: UInt32
            let read: Read
            let write: Write

            private static let speakerVolume: UInt8 = 0x62
            private static let hostAddress: UInt32 = 0x51

            func volume() -> UInt16? {
                for _ in 0..<2 {
                    guard send([0x82, 0x01, Self.speakerVolume]) else { continue }
                    Thread.sleep(forTimeInterval: 0.05)
                    var reply = [UInt8](repeating: 0, count: 12)
                    let status = reply.withUnsafeMutableBytes { buffer in
                        read(service, chipAddress, Self.hostAddress, buffer.baseAddress!, UInt32(buffer.count))
                    }
                    guard status == kIOReturnSuccess, reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
                        reply[4] == Self.speakerVolume, reply.prefix(10).reduce(0x50, ^) == reply[10]
                    else { continue }
                    guard reply[3] == 0 else { return nil }
                    return UInt16(reply[8]) << 8 | UInt16(reply[9])
                }
                return nil
            }

            func setVolume(_ value: UInt16) -> Bool {
                send([0x84, 0x03, Self.speakerVolume, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)])
            }

            private func send(_ command: [UInt8]) -> Bool {
                let packet = command + [command.reduce(0x6E ^ UInt8(Self.hostAddress), ^)]
                // Some displays (including the RV100 Max) reply only after the command is repeated.
                for _ in 0..<2 {
                    Thread.sleep(forTimeInterval: 0.01)
                    let status = packet.withUnsafeBytes { buffer in
                        write(service, chipAddress, Self.hostAddress, buffer.baseAddress!, UInt32(buffer.count))
                    }
                    if status != kIOReturnSuccess { return false }
                }
                return true
            }
        }
    }
#endif
