import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal
import SystemConfiguration

/// Reads the Mac's configuration.
protocol SystemInfoReading: Sendable {
    func read() async -> SystemInfoFacts
}

/// Public Darwin, IOKit and AppKit interfaces only: nothing asks for a permission
/// and nothing leaves the Mac.
struct DarwinSystemInfoReader: SystemInfoReading {
    typealias Sampler = DarwinSystemMetricsSampler

    func read() async -> SystemInfoFacts {
        // Screens belong to the main thread; the rest blocks briefly and runs off it.
        let displays = await MainActor.run { Self.displays() }
        var facts = await Task.detached(priority: .userInitiated) { Self.facts() }.value
        facts.displays = displays
        return facts
    }

    static func facts() -> SystemInfoFacts {
        let machine = DarwinSystemMetricsSampler().machineInfo()
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let osVersion = version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let gpu = MTLCreateSystemDefaultDevice()
        let primary = primaryNetwork()
        return SystemInfoFacts(
            productName: deviceTreeString("IODeviceTree:/product", "product-name"),
            modelIdentifier: Sampler.sysctlString("hw.model") ?? "Mac",
            modelNumber: platformString("model-number"),
            serialNumber: platformString(kIOPlatformSerialNumberKey),
            chip: machine.chip,
            cores: machine.cores,
            performanceCores: machine.performanceCores,
            efficiencyCores: machine.efficiencyCores,
            gpuName: gpu?.name,
            gpuCores: registryNumber("AGXAccelerator", "gpu-core-count"),
            supportsMetal3: gpu?.supportsFamily(.metal3) ?? false,
            architecture: hardwareArchitecture(),
            translated: Sampler.sysctl("sysctl.proc_translated", Int32.self) == 1,
            rosettaInstalled: FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta"),
            memory: machine.memory,
            osVersion: osVersion,
            osBuild: Sampler.sysctlString("kern.osversion"),
            kernel: Sampler.sysctlString("kern.osrelease").map { "Darwin " + $0 },
            bootTime: bootTime(),
            hostName: (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" },
            localeIdentifier: Locale.current.identifier,
            volumes: volumes(),
            interfaces: interfaces(),
            primaryInterface: primary.interface,
            router: primary.router,
            dnsServers: dnsServers(),
            proxies: proxies(),
            battery: battery(),
            lowPowerMode: process.isLowPowerModeEnabled,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    // MARK: Hardware

    static func hardwareArchitecture() -> String {
        if Sampler.sysctl("hw.optional.arm64", Int32.self) == 1 {
            return "arm64"
        }
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    static func bootTime() -> Date? {
        guard let time = Sampler.sysctl("kern.boottime", timeval.self), time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }

    static func platformString(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return string(IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue())
    }

    static func deviceTreeString(_ path: String, _ key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return string(IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue())
    }

    static func registryNumber(_ className: String, _ key: String) -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }

    /// Registry strings come as text or as NUL-terminated data.
    static func string(_ value: Any?) -> String? {
        let text: String? = if let data = value as? Data {
            String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
        } else {
            value as? String
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    // MARK: Storage

    static func volumes() -> [SystemInfoFacts.Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsEncryptedKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> SystemInfoFacts.Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false, values.volumeIsLocal != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
                ?? values.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? 0
            return SystemInfoFacts.Volume(
                name: values.volumeLocalizedName ?? url.lastPathComponent, total: UInt64(total),
                available: min(available, UInt64(total)), format: values.volumeLocalizedFormatDescription,
                isRoot: url.path == "/", isInternal: values.volumeIsInternal, isEncrypted: values.volumeIsEncrypted
            )
        }
        return volumes.sorted { lhs, rhs in lhs.isRoot != rhs.isRoot ? lhs.isRoot : lhs.name < rhs.name }
    }

    // MARK: Displays

    @MainActor
    static func displays() -> [SystemInfoFacts.Display] {
        NSScreen.screens.compactMap { screen -> SystemInfoFacts.Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = screen.backingScaleFactor
            let pixelWidth = mode?.pixelWidth ?? Int(screen.frame.width * scale)
            let pixelHeight = mode?.pixelHeight ?? Int(screen.frame.height * scale)
            let rate = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond
                : mode.map { Int($0.refreshRate.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
            return SystemInfoFacts.Display(
                name: screen.localizedName.trimmingCharacters(in: .whitespaces),
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                pointWidth: Int(screen.frame.width), pointHeight: Int(screen.frame.height),
                refreshRate: rate, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                supportsHDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
            )
        }
    }

    // MARK: Network

    static func primaryNetwork() -> (interface: String?, router: String?) {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return (global?["PrimaryInterface"] as? String, global?["Router"] as? String)
    }

    static func dnsServers() -> [String] {
        let dns = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        return dns?["ServerAddresses"] as? [String] ?? []
    }

    static func proxies() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        return proxyList(settings)
    }

    /// "HTTP 127.0.0.1:7890" for each enabled proxy, in a fixed order.
    static func proxyList(_ settings: [String: Any]) -> [String] {
        let kinds = [("HTTP", "HTTP"), ("HTTPS", "HTTPS"), ("SOCKS", "SOCKS")]
        var list = kinds.compactMap { name, key -> String? in
            guard (settings[key + "Enable"] as? NSNumber)?.boolValue == true,
                  let host = settings[key + "Proxy"] as? String, !host.isEmpty else { return nil }
            let port = (settings[key + "Port"] as? NSNumber).map { ":\($0.intValue)" } ?? ""
            return name + " " + host + port
        }
        if (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true,
           let url = settings["ProxyAutoConfigURLString"] as? String, !url.isEmpty {
            list.append("PAC " + url)
        }
        return list
    }

    /// Interfaces that are up with an address, as the Network settings name them.
    static func interfaces() -> [SystemInfoFacts.Interface] {
        let names = Dictionary((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { interface in
            (SCNetworkInterfaceGetBSDName(interface) as String?).map {
                ($0, SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? $0)
            }
        }, uniquingKeysWith: { first, _ in first })
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var byName: [String: SystemInfoFacts.Interface] = [:]
        var order: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            // Only the interfaces the Network settings list: no loopback, tunnels or bridges.
            guard let display = names[name], let address = entry.pointee.ifa_addr,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            if byName[name] == nil {
                byName[name] = .init(name: name, displayName: display, ipv4: [], ipv6: [], hardwareAddress: nil)
                order.append(name)
            }
            switch Int32(address.pointee.sa_family) {
            case AF_INET: if let text = numericHost(address) {
                    byName[name]?.ipv4.append(text)
                }
            case AF_INET6: if let text = numericHost(address) {
                    byName[name]?.ipv6.append(text)
                }
            case AF_LINK: byName[name]?.hardwareAddress = linkAddress(address)
            default: break
            }
        }
        // An interface with only a link-local address (a Thunderbolt bridge, say) is not connected.
        return order.compactMap { byName[$0] }.filter { interface in
            !interface.ipv4.isEmpty || interface.ipv6.contains { !isLinkLocal($0) }
        }
    }

    static func isLinkLocal(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fe80:")
    }

    static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                          NI_NUMERICHOST) == 0 else { return nil }
        // Drop the scope suffix of link-local IPv6 addresses ("fe80::1%en0").
        return String(cString: host).split(separator: "%").first.map(String.init)
    }

    /// "a4:83:e7:2c:91:5f" from a link-layer address. The name and address run past the
    /// declared 12 bytes of `sdl_data`, so they are read from the whole structure.
    static func linkAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let raw = UnsafeRawPointer(address)
        let link = raw.load(as: sockaddr_dl.self)
        guard link.sdl_alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
        let start = offset + Int(link.sdl_nlen)
        guard start + 6 <= Int(link.sdl_len) else { return nil }
        let bytes = UnsafeRawBufferPointer(start: raw + start, count: 6)
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: Power

    static func battery() -> SystemInfoFacts.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let raw = registryNumber("AppleSmartBattery", "AppleRawMaxCapacity")
            let design = registryNumber("AppleSmartBattery", "DesignCapacity")
            let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
            return SystemInfoFacts.Battery(
                percent: min(100, current * 100 / maximum),
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                cycleCount: registryNumber("AppleSmartBattery", "CycleCount"),
                health: health(raw: raw, design: design),
                adapterWatts: (adapter?[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
            )
        }
        return nil
    }

    static func health(raw: Int?, design: Int?) -> Int? {
        guard let raw, let design, raw > 0, design > 0 else { return nil }
        return min(100, Int((Double(raw) / Double(design) * 100).rounded()))
    }
}
