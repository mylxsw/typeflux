import Foundation

/// What the Mac says about itself, before it is turned into labelled rows.
/// Every part is optional or empty when macOS does not tell.
struct SystemInfoFacts: Equatable, Sendable {
    struct Volume: Equatable, Sendable {
        var name: String
        var total: UInt64
        var available: UInt64
        var format: String?
        var isRoot: Bool
        var isInternal: Bool?
        var isEncrypted: Bool?
    }

    struct Display: Equatable, Sendable {
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        var pointWidth: Int
        var pointHeight: Int
        var refreshRate: Int?
        var isBuiltIn: Bool
        var supportsHDR: Bool
    }

    struct Interface: Equatable, Sendable {
        /// The BSD name: "en0".
        var name: String
        /// "Wi-Fi", "Ethernet".
        var displayName: String
        var ipv4: [String]
        var ipv6: [String]
        var hardwareAddress: String?
    }

    struct Battery: Equatable, Sendable {
        var percent: Int
        var charging: Bool
        var onPower: Bool
        var cycleCount: Int?
        /// Maximum capacity against design capacity, in percent.
        var health: Int?
        var adapterWatts: Int?
    }

    var productName: String?
    var modelIdentifier: String
    var modelNumber: String?
    var serialNumber: String?
    var chip: String
    var cores: Int
    var performanceCores: Int?
    var efficiencyCores: Int?
    var gpuName: String?
    var gpuCores: Int?
    var supportsMetal3 = false
    /// "arm64" or "x86_64": the hardware's, not this process's.
    var architecture: String
    /// Typeflux runs under Rosetta.
    var translated = false
    var rosettaInstalled = false
    var memory: UInt64
    /// "15.1".
    var osVersion: String
    var osBuild: String?
    /// "Darwin 24.1.0".
    var kernel: String?
    var bootTime: Date?
    var hostName: String?
    var localeIdentifier: String
    var volumes: [Volume] = []
    var displays: [Display] = []
    var interfaces: [Interface] = []
    var primaryInterface: String?
    var router: String?
    var dnsServers: [String] = []
    /// "HTTP 127.0.0.1:7890"; empty when no proxy is set.
    var proxies: [String] = []
    var battery: Battery?
    var lowPowerMode = false
    var appVersion: String?

    var isAppleSilicon: Bool {
        architecture == "arm64"
    }
}
