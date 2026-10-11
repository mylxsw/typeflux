import Foundation
@testable import Typeflux

/// Samples handed out in order, so tests drive the store without reading the machine.
final class FakeSystemMetricsSampler: SystemMetricsSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [SystemRawSample]
    private var requests: [(processes: Bool, slow: Bool)] = []
    var machine = SystemMachineInfo(chip: "Apple M3 Pro", cores: 4, performanceCores: 2, efficiencyCores: 2,
                                    memory: 16 << 30)

    init(_ samples: [SystemRawSample] = []) {
        queued = samples
    }

    func machineInfo() -> SystemMachineInfo { machine }

    func sample(processes: Bool, slow: Bool) -> SystemRawSample {
        lock.lock()
        defer { lock.unlock() }
        requests.append((processes, slow))
        let next = queued.isEmpty ? SystemMonitorFixtures.raw(time: Double(requests.count)) : queued.removeFirst()
        return next
    }

    var firstRequest: (processes: Bool, slow: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

enum SystemMonitorFixtures {
    static let gib: UInt64 = 1 << 30

    static func ticks(user: UInt64, system: UInt64 = 0, idle: UInt64, nice: UInt64 = 0) -> SystemCPUTicks {
        SystemCPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    static func memory(pressure: SystemMonitorMemoryPressure = .normal) -> SystemMemoryCounters {
        SystemMemoryCounters(total: 16 * gib, app: 6 * gib, wired: 2 * gib, compressed: 1 * gib, cached: 3 * gib,
                             swapUsed: gib / 2, pressure: pressure, availablePercent: 70)
    }

    static func process(_ pid: Int32, _ name: String, cpu: UInt64 = 0, memory: UInt64 = 100 << 20,
                        read: UInt64? = 0, written: UInt64? = 0, uid: UInt32 = 501) -> SystemProcessCounters {
        SystemProcessCounters(pid: pid, name: name, uid: uid, cpuTime: cpu, memory: memory, diskRead: read,
                              diskWritten: written)
    }

    /// A reading `time` seconds in: every counter grows with time, CPU at `busy` percent.
    static func raw(time: TimeInterval, busy: Double = 25, processes: [SystemProcessCounters]? = nil,
                    slow: SystemSlowInfo? = nil, pressure: SystemMonitorMemoryPressure = .normal) -> SystemRawSample {
        let total = UInt64(time * 1000)
        let used = UInt64(Double(total) * busy / 100)
        let core = ticks(user: used, idle: total - used)
        return SystemRawSample(time: time, cores: [core, core], memory: memory(pressure: pressure),
                               loadAverage: [1.5, 1.2, 1.0], diskRead: UInt64(time * 1_000_000),
                               diskWritten: UInt64(time * 500_000), networkIn: UInt64(time * 2_000_000),
                               networkOut: UInt64(time * 100_000), processes: processes,
                               processTotal: processes.map { $0.count + 1 }, slow: slow, uptime: 3 * 86400 + time,
                               thermal: .nominal)
    }

    static func volume(_ name: String = "Macintosh HD", root: Bool = true, total: UInt64 = 1000,
                       available: UInt64 = 380) -> SystemVolume {
        SystemVolume(name: name, path: root ? "/" : "/Volumes/" + name, total: total, available: available,
                     isRoot: root)
    }

    static func snapshot(cpu: Double = 23, processes: [SystemProcess]? = nil,
                         pressure: SystemMonitorMemoryPressure = .normal,
                         volumes: [SystemVolume] = [volume()]) -> SystemSnapshot {
        SystemSnapshot(
            cpu: SystemCPUUsage(total: cpu, user: cpu * 0.6, system: cpu * 0.4, cores: [cpu, cpu]),
            memory: SystemMemoryUsage(counters: memory(pressure: pressure)),
            loadAverage: [3.05, 2.5, 2.1], diskRead: 12_000_000, diskWrite: 3_000_000,
            networkDown: 6_300_000, networkUp: 181_000, volumes: volumes,
            interface: SystemNetworkInterface(name: "en0", displayName: "Wi-Fi", address: "192.168.1.23"),
            battery: SystemBattery(percent: 82, charging: true), processes: processes,
            processCount: processes.map { $0.count + 3 }, uptime: 3 * 86400 + 4 * 3600, thermal: .nominal
        )
    }

    static func systemProcess(_ pid: Int32, _ name: String, cpu: Double, memory: UInt64 = 100 << 20,
                              disk: Double? = 0, uid: UInt32 = 501) -> SystemProcess {
        SystemProcess(pid: pid, name: name, uid: uid, cpu: cpu, memory: memory, disk: disk)
    }

    static let processes: [SystemProcess] = [
        systemProcess(4821, "node", cpu: 42, memory: 1200 << 20),
        systemProcess(912, "Google Chrome", cpu: 18, memory: 3400 << 20),
        systemProcess(1288, "Xcode", cpu: 9.5, memory: 2800 << 20, disk: 340_000),
        systemProcess(344, "WindowServer", cpu: 8, memory: 640 << 20, uid: 88),
        systemProcess(511, "mds_stores", cpu: 2, memory: 180 << 20, disk: 1_600_000, uid: 0)
    ]
}
