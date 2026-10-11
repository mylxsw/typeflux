import Foundation

/// Turns two raw samples into what the monitor shows: percentages from tick
/// differences and rates from counter differences. Pure, so it is tested
/// without reading the machine.
enum SystemMetricsCalculator {
    /// The busy share of each core between two readings, 0...100. A core whose
    /// counters went backwards (a reset) or did not move reads 0.
    static func coreUsage(previous: [SystemCPUTicks], current: [SystemCPUTicks]) -> [Double] {
        current.indices.map { index in
            guard previous.indices.contains(index) else { return 0 }
            return busyPercent(previous[index], current[index])
        }
    }

    static func cpuUsage(previous: [SystemCPUTicks], current: [SystemCPUTicks]) -> SystemCPUUsage {
        let cores = coreUsage(previous: previous, current: current)
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for index in current.indices where previous.indices.contains(index) {
            let old = previous[index], new = current[index]
            guard new.total >= old.total, new.busy >= old.busy else { continue }
            user += difference(old.user &+ old.nice, new.user &+ new.nice)
            system += difference(old.system, new.system)
            total += new.total - old.total
        }
        guard total > 0 else { return SystemCPUUsage(total: 0, user: 0, system: 0, cores: cores) }
        let userPercent = Double(user) / Double(total) * 100
        let systemPercent = Double(system) / Double(total) * 100
        return SystemCPUUsage(total: min(100, userPercent + systemPercent), user: userPercent, system: systemPercent,
                              cores: cores)
    }

    private static func busyPercent(_ old: SystemCPUTicks, _ new: SystemCPUTicks) -> Double {
        guard new.total > old.total, new.busy >= old.busy else { return 0 }
        return min(100, Double(new.busy - old.busy) / Double(new.total - old.total) * 100)
    }

    /// `new - old`, or 0 when the counter went backwards.
    static func difference(_ old: UInt64, _ new: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    /// Per second over `seconds`; 0 for a counter that reset or a non-positive interval.
    static func rate(_ old: UInt64, _ new: UInt64, seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(difference(old, new)) / seconds
    }

    /// Each process's CPU (percent of one core) and disk rate since the previous
    /// reading. A process seen for the first time has no rate yet and reads 0.
    static func processes(previous: [SystemProcessCounters]?, current: [SystemProcessCounters],
                          seconds: TimeInterval) -> [SystemProcess] {
        let before = Dictionary((previous ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return current.map { process in
            let old = before[process.pid]
            var cpu = 0.0
            var disk: Double?
            if let old, seconds > 0 {
                cpu = Double(difference(old.cpuTime, process.cpuTime)) / (seconds * 1_000_000_000) * 100
                if let read = process.diskRead, let written = process.diskWritten,
                   let oldRead = old.diskRead, let oldWritten = old.diskWritten {
                    disk = rate(oldRead, read, seconds: seconds) + rate(oldWritten, written, seconds: seconds)
                }
            } else if process.diskRead != nil {
                disk = 0
            }
            return SystemProcess(pid: process.pid, name: process.name, uid: process.uid, cpu: max(0, cpu),
                                 memory: process.memory, disk: disk)
        }
    }

    /// The snapshot between two samples. Slow details come from the newer sample that
    /// read them, else carry over from `fallback`.
    static func snapshot(previous: SystemRawSample, current: SystemRawSample,
                         fallback: SystemSnapshot? = nil) -> SystemSnapshot {
        let seconds = current.time - previous.time
        let processes = current.processes.map {
            self.processes(previous: previous.processes, current: $0, seconds: seconds)
        }
        // The very first reading reads slow details too, but only ever serves as `previous`.
        let slow = current.slow ?? previous.slow
        return SystemSnapshot(
            cpu: cpuUsage(previous: previous.cores, current: current.cores),
            memory: SystemMemoryUsage(counters: current.memory),
            loadAverage: current.loadAverage,
            diskRead: rate(previous.diskRead, current.diskRead, seconds: seconds),
            diskWrite: rate(previous.diskWritten, current.diskWritten, seconds: seconds),
            networkDown: rate(previous.networkIn, current.networkIn, seconds: seconds),
            networkUp: rate(previous.networkOut, current.networkOut, seconds: seconds),
            volumes: slow?.volumes ?? fallback?.volumes ?? [],
            interface: slow.map(\.interface) ?? fallback?.interface,
            battery: slow.map(\.battery) ?? fallback?.battery,
            processes: processes,
            processCount: current.processTotal ?? current.processes?.count,
            uptime: current.uptime,
            thermal: current.thermal
        )
    }
}
