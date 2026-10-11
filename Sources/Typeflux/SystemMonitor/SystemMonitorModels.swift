import Foundation

/// The four things the monitor watches, in the order its cards show them.
enum SystemMonitorMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, disk, network

    /// The card's ⌘ number, 1...4.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    init?(number: Int) {
        guard Self.allCases.indices.contains(number - 1) else { return nil }
        self = Self.allCases[number - 1]
    }
}

/// What the process list is sorted by.
enum SystemMonitorSort: String, CaseIterable, Codable, Sendable {
    case cpu, memory, disk

    /// Focusing a metric sorts the list by it; the network has no per-process figure.
    init?(focus: SystemMonitorMetric) {
        switch focus {
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .disk: self = .disk
        case .network: return nil
        }
    }
}

/// How a value compares with its thresholds: the colour of a card or a number.
enum SystemMonitorLevel: Int, Comparable, Sendable {
    case normal, elevated, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// CPU: 80% is elevated, 90% critical.
    static func cpu(_ percent: Double) -> Self {
        percent >= 90 ? .critical : percent >= 80 ? .elevated : .normal
    }

    /// One process: past 40% stands out, past a whole core is critical.
    static func processCPU(_ percent: Double) -> Self {
        percent >= 100 ? .critical : percent >= 40 ? .elevated : .normal
    }
}

/// macOS's memory pressure (`kern.memorystatus_vm_pressure_level`): the colour of
/// memory, since caches filling it is normal.
enum SystemMonitorMemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var level: SystemMonitorLevel {
        switch self {
        case .normal: .normal
        case .warning: .elevated
        case .critical: .critical
        }
    }
}

// MARK: - Raw counters

/// One core's tick counters since boot.
struct SystemCPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

/// Memory as the VM reports it, in bytes.
struct SystemMemoryCounters: Equatable, Sendable {
    var total: UInt64
    /// Anonymous memory apps use (internal pages less purgeable ones).
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// File-backed and purgeable memory the system can take back at once.
    var cached: UInt64
    var swapUsed: UInt64
    var pressure: SystemMonitorMemoryPressure
    /// `kern.memorystatus_level`: the percentage of memory still available.
    var availablePercent: Double?

    var used: UInt64 { app &+ wired &+ compressed }
}

/// A mounted volume's capacity.
struct SystemVolume: Equatable, Sendable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var total: UInt64
    var available: UInt64
    var isRoot: Bool

    var used: UInt64 { total > available ? total - available : 0 }
    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

/// The interface the Mac reaches the network through.
struct SystemNetworkInterface: Equatable, Sendable {
    var name: String
    var displayName: String
    var address: String?
}

/// A process's counters since it started.
struct SystemProcessCounters: Equatable, Sendable {
    var pid: Int32
    var name: String
    var uid: UInt32
    /// User plus system CPU time, in nanoseconds.
    var cpuTime: UInt64
    /// Physical footprint, or resident size when the footprint cannot be read.
    var memory: UInt64
    /// Bytes read from and written to disk; nil when they cannot be read.
    var diskRead: UInt64?
    var diskWritten: UInt64?
}

/// What changes slowly (volumes, the network interface, the battery): read every few seconds.
struct SystemSlowInfo: Equatable, Sendable {
    var volumes: [SystemVolume] = []
    var interface: SystemNetworkInterface?
    /// "82%", "82% · Charging"; nil without a battery.
    var battery: SystemBattery?
}

struct SystemBattery: Equatable, Sendable {
    var percent: Int
    var charging: Bool
}

/// Everything one sampling pass reads, before rates are worked out.
struct SystemRawSample: Equatable, Sendable {
    /// Seconds on a monotonic clock.
    var time: TimeInterval
    var cores: [SystemCPUTicks]
    var memory: SystemMemoryCounters
    var loadAverage: [Double]
    var diskRead: UInt64
    var diskWritten: UInt64
    var networkIn: UInt64
    var networkOut: UInt64
    /// Nil when processes were not asked for.
    var processes: [SystemProcessCounters]?
    /// Every process listed, including those that could not be read.
    var processTotal: Int?
    var slow: SystemSlowInfo?
    var uptime: TimeInterval
    var thermal: ProcessInfo.ThermalState
}

// MARK: - Snapshot

/// One process with its rates over the last interval.
struct SystemProcess: Equatable, Sendable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var uid: UInt32
    /// Percent of one core: 250 is two and a half cores.
    var cpu: Double
    var memory: UInt64
    /// Bytes per second read plus written; nil when unknown.
    var disk: Double?
}

struct SystemCPUUsage: Equatable, Sendable {
    var total: Double
    var user: Double
    var system: Double
    var cores: [Double]
}

struct SystemMemoryUsage: Equatable, Sendable {
    var counters: SystemMemoryCounters

    var total: UInt64 { counters.total }
    var used: UInt64 { min(counters.used, counters.total) }
    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
    var pressure: SystemMonitorMemoryPressure { counters.pressure }
    /// How much of the memory is spoken for, 0...100, from the kernel's availability.
    var pressurePercent: Double {
        counters.availablePercent.map { max(0, min(100, 100 - $0)) } ?? usedPercent
    }
}

/// What the monitor shows at one moment.
struct SystemSnapshot: Equatable, Sendable {
    var cpu: SystemCPUUsage
    var memory: SystemMemoryUsage
    var loadAverage: [Double]
    /// Bytes per second.
    var diskRead: Double
    var diskWrite: Double
    var networkDown: Double
    var networkUp: Double
    var volumes: [SystemVolume]
    var interface: SystemNetworkInterface?
    var battery: SystemBattery?
    var processes: [SystemProcess]?
    var processCount: Int?
    var uptime: TimeInterval
    var thermal: ProcessInfo.ThermalState

    var rootVolume: SystemVolume? { volumes.first(where: \.isRoot) ?? volumes.first }
}

/// What the status line says about this Mac; read once.
struct SystemMachineInfo: Equatable, Sendable {
    var chip: String
    var cores: Int
    var performanceCores: Int?
    var efficiencyCores: Int?
    var memory: UInt64
}
