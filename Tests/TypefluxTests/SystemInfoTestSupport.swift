import Foundation
@testable import Typeflux

/// A MacBook Pro and a Mac mini, as `DarwinSystemInfoReader` would describe them.
enum SystemInfoFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func laptop() -> SystemInfoFacts {
        SystemInfoFacts(
            productName: "MacBook Pro (14-inch, Nov 2023)", modelIdentifier: "Mac15,6", modelNumber: "MRX33CH/A",
            serialNumber: "C02XK4M1Q6L4", chip: "Apple M3 Pro", cores: 12, performanceCores: 6, efficiencyCores: 6,
            gpuName: "Apple M3 Pro", gpuCores: 18, supportsMetal3: true, architecture: "arm64", translated: false,
            rosettaInstalled: true, memory: 18 * 1_073_741_824, osVersion: "15.1", osBuild: "24B83",
            kernel: "Darwin 24.1.0", bootTime: now.addingTimeInterval(-(3 * 86400 + 4 * 3600)),
            hostName: "oras-mbp.local",
            localeIdentifier: "en_US",
            volumes: [
                .init(name: "Macintosh HD", total: 1_000_000_000_000, available: 382_000_000_000, format: "APFS",
                      isRoot: true, isInternal: true, isEncrypted: true),
                .init(name: "T7 Shield", total: 2_000_000_000_000, available: 900_000_000_000, format: "ExFAT",
                      isRoot: false, isInternal: false, isEncrypted: false)
            ],
            displays: [
                .init(name: "Built-in Liquid Retina XDR Display", pixelWidth: 3024, pixelHeight: 1964, pointWidth: 1512,
                      pointHeight: 982, refreshRate: 120, isBuiltIn: true, supportsHDR: true),
                .init(
                    name: "",
                    pixelWidth: 5120,
                    pixelHeight: 2880,
                    pointWidth: 2560,
                    pointHeight: 1440,
                    refreshRate: 60,
                    isBuiltIn: false,
                    supportsHDR: false
                )
            ],
            interfaces: [
                .init(name: "en0", displayName: "Wi-Fi", ipv4: ["192.168.1.23"], ipv6: ["fe80::1c2b:9aff:fe31:7d10"],
                      hardwareAddress: "a4:83:e7:2c:91:5f"),
                .init(
                    name: "en7",
                    displayName: "USB 10/100/1000 LAN",
                    ipv4: ["10.0.0.8"],
                    ipv6: [],
                    hardwareAddress: nil
                )
            ],
            primaryInterface: "en0", router: "192.168.1.1", dnsServers: ["223.5.5.5", "119.29.29.29"],
            proxies: ["HTTP 127.0.0.1:7890"],
            battery: .init(percent: 82, charging: true, onPower: true, cycleCount: 214, health: 91, adapterWatts: 96),
            lowPowerMode: false, appVersion: "1.42.0"
        )
    }

    /// A desktop on an Intel chip, offline, without a battery or anything optional.
    static func desktop() -> SystemInfoFacts {
        SystemInfoFacts(productName: nil, modelIdentifier: "Macmini8,1", chip: "Intel(R) Core(TM) i7-8700B", cores: 12,
                        architecture: "x86_64", memory: 32 * 1_073_741_824, osVersion: "13.6.9",
                        localeIdentifier: "zh_CN")
    }
}

/// Answers with fixed facts and counts the reads.
final class FakeSystemInfoReader: SystemInfoReading, @unchecked Sendable {
    var facts: SystemInfoFacts
    private(set) var reads = 0

    init(_ facts: SystemInfoFacts = SystemInfoFixtures.laptop()) {
        self.facts = facts
    }

    func read() async -> SystemInfoFacts {
        reads += 1
        return facts
    }
}
