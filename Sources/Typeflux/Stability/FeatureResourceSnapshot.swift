import Darwin
import Foundation

/// Counters are cumulative; CPU percentage is derived only between matching PIDs
/// and start times. Footprint is reported separately from decoder working budgets.
struct FeatureResourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    let role: FeatureRole
    let pid: Int32
    let startedAt: UInt64
    let uptime: TimeInterval
    let footprintBytes: UInt64?
    let cpuNanoseconds: UInt64?
    let managedOperations: Int
    let helperSlots: Int
    var id: String {
        "\(pid):\(startedAt)"
    }

    static func capture(role: FeatureRole = FeatureProcess.role) -> Self {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        let cpu = Double(usage.ri_user_time &+ usage.ri_system_time) * Double(scale.numer) / Double(max(1, scale.denom))
        return .init(role: role, pid: getpid(), startedAt: usage.ri_proc_start_abstime,
                     uptime: ProcessInfo.processInfo.systemUptime,
                     footprintBytes: result == 0 ? usage.ri_phys_footprint : nil,
                     cpuNanoseconds: result == 0 ? UInt64(min(Double(UInt64.max), cpu)) : nil,
                     managedOperations: ManagedProcess.activeApplicationProcesses,
                     helperSlots: role == .background ? FeatureHelperBudget.shared.activeCount : 0)
    }

    func cpuPercent(since previous: Self) -> Double? {
        guard id == previous.id, uptime > previous.uptime, let cpuNanoseconds,
              let before = previous.cpuNanoseconds, cpuNanoseconds >= before else { return nil }
        return Double(cpuNanoseconds - before) / 1_000_000_000 / (uptime - previous.uptime) * 100
    }
}
