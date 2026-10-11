import Foundation
import Testing
@testable import Typeflux

@Suite("System monitor calculations")
struct SystemMetricsCalculatorTests {
    typealias F = SystemMonitorFixtures

    @Test func coreUsageIsTheBusyShareOfEachCore() {
        let previous = [F.ticks(user: 100, system: 50, idle: 850), F.ticks(user: 0, idle: 1000)]
        let current = [F.ticks(user: 200, system: 100, idle: 900), F.ticks(user: 0, idle: 1100)]
        let usage = SystemMetricsCalculator.coreUsage(previous: previous, current: current)
        #expect(usage.count == 2)
        #expect(abs(usage[0] - 75) < 0.001)
        #expect(usage[1] == 0)
    }

    @Test func coresThatResetOrAreNewReadZero() {
        let previous = [F.ticks(user: 500, idle: 500)]
        let current = [F.ticks(user: 10, idle: 10), F.ticks(user: 5, idle: 5)]
        #expect(SystemMetricsCalculator.coreUsage(previous: previous, current: current) == [0, 0])
        // No time passed: nothing to divide by.
        #expect(SystemMetricsCalculator.coreUsage(previous: previous, current: previous) == [0])
    }

    @Test func cpuUsageSplitsUserAndSystemAcrossCores() {
        let previous = [F.ticks(user: 0, system: 0, idle: 0, nice: 0), F.ticks(user: 0, idle: 0)]
        let current = [F.ticks(user: 30, system: 10, idle: 50, nice: 10), F.ticks(user: 0, system: 0, idle: 100)]
        let usage = SystemMetricsCalculator.cpuUsage(previous: previous, current: current)
        // 40 user (nice counts as user) + 10 system out of 200 ticks.
        #expect(abs(usage.user - 20) < 0.001)
        #expect(abs(usage.system - 5) < 0.001)
        #expect(abs(usage.total - 25) < 0.001)
        #expect(usage.cores.count == 2)
    }

    @Test func cpuUsageWithoutElapsedTicksIsZero() {
        let same = [F.ticks(user: 10, idle: 10)]
        let usage = SystemMetricsCalculator.cpuUsage(previous: same, current: same)
        #expect(usage.total == 0 && usage.user == 0 && usage.system == 0)
        let reset = SystemMetricsCalculator.cpuUsage(previous: [F.ticks(user: 50, idle: 50)],
                                                      current: [F.ticks(user: 1, idle: 1)])
        #expect(reset.total == 0)
    }

    @Test func ratesIgnoreResetCountersAndEmptyIntervals() {
        #expect(SystemMetricsCalculator.difference(10, 25) == 15)
        #expect(SystemMetricsCalculator.difference(25, 10) == 0)
        #expect(SystemMetricsCalculator.rate(0, 3000, seconds: 2) == 1500)
        #expect(SystemMetricsCalculator.rate(3000, 0, seconds: 2) == 0)
        #expect(SystemMetricsCalculator.rate(0, 3000, seconds: 0) == 0)
    }

    @Test func processRatesComeFromTheirPreviousReading() {
        let previous = [F.process(1, "a", cpu: 1_000_000_000, read: 1000, written: 0),
                        F.process(2, "b", cpu: 0, read: nil, written: nil)]
        let current = [F.process(1, "a", cpu: 3_000_000_000, read: 5000, written: 1000),
                       F.process(2, "b", cpu: 500_000_000, read: nil, written: nil),
                       F.process(3, "new", cpu: 9_000_000_000, read: 100, written: 100)]
        let processes = SystemMetricsCalculator.processes(previous: previous, current: current, seconds: 2)
        #expect(processes.map(\.pid) == [1, 2, 3])
        // Two seconds of CPU in two seconds: one whole core.
        #expect(abs(processes[0].cpu - 100) < 0.001)
        #expect(processes[0].disk == 2500)
        #expect(abs(processes[1].cpu - 25) < 0.001)
        #expect(processes[1].disk == nil)
        // Seen for the first time: no rate yet.
        #expect(processes[2].cpu == 0)
        #expect(processes[2].disk == 0)
        #expect(SystemMetricsCalculator.processes(previous: nil, current: [F.process(4, "x", read: nil, written: nil)],
                                                  seconds: 1)[0].disk == nil)
    }

    @Test func snapshotCombinesRatesAndCarriesSlowDetailsOver() {
        let slow = SystemSlowInfo(volumes: [F.volume()],
                                  interface: SystemNetworkInterface(name: "en0", displayName: "Wi-Fi", address: nil),
                                  battery: SystemBattery(percent: 50, charging: false))
        let first = F.raw(time: 1, processes: [F.process(7, "seven", cpu: 0)], slow: slow)
        let second = F.raw(time: 2, busy: 50, processes: [F.process(7, "seven", cpu: 250_000_000)])
        let snapshot = SystemMetricsCalculator.snapshot(previous: first, current: second)
        #expect(snapshot.diskRead == 1_000_000 && snapshot.diskWrite == 500_000)
        #expect(snapshot.networkDown == 2_000_000 && snapshot.networkUp == 100_000)
        #expect(snapshot.processes?.first?.cpu == 25)
        #expect(snapshot.processCount == 2)
        // The first reading's slow details show at once, not ten seconds later.
        #expect(snapshot.volumes == slow.volumes && snapshot.battery?.percent == 50)
        let unread = SystemMetricsCalculator.snapshot(previous: second, current: F.raw(time: 3))
        #expect(unread.volumes.isEmpty && unread.interface == nil && unread.battery == nil)

        let withSlow = SystemMetricsCalculator.snapshot(previous: first, current: F.raw(time: 2, slow: slow))
        let carried = SystemMetricsCalculator.snapshot(previous: second, current: F.raw(time: 3), fallback: withSlow)
        #expect(carried.volumes == slow.volumes)
        #expect(carried.interface?.displayName == "Wi-Fi")
        #expect(carried.battery?.percent == 50)
        #expect(carried.processes == nil && carried.processCount == nil)
        #expect(carried.rootVolume?.name == "Macintosh HD")
    }

    @Test func memoryUsageAndPressure() {
        let usage = SystemMemoryUsage(counters: F.memory(pressure: .warning))
        #expect(usage.used == 9 * F.gib)
        #expect(abs(usage.usedPercent - 56.25) < 0.001)
        #expect(usage.pressurePercent == 30)
        #expect(usage.pressure.level == .elevated)
        var counters = F.memory()
        counters.availablePercent = nil
        counters.total = 0
        #expect(SystemMemoryUsage(counters: counters).usedPercent == 0)
        #expect(SystemMemoryUsage(counters: counters).pressurePercent == 0)
        #expect(SystemMonitorMemoryPressure.normal.level == .normal)
        #expect(SystemMonitorMemoryPressure.critical.level == .critical)
    }

    @Test func volumesAndLevels() {
        let volume = F.volume(total: 1000, available: 250)
        #expect(volume.used == 750 && volume.usedPercent == 75 && volume.id == "/")
        #expect(F.volume(total: 0, available: 0).usedPercent == 0)
        #expect(F.volume(total: 10, available: 20).used == 0)
        #expect(SystemMonitorLevel.cpu(79) == .normal)
        #expect(SystemMonitorLevel.cpu(80) == .elevated)
        #expect(SystemMonitorLevel.cpu(95) == .critical)
        #expect(SystemMonitorLevel.processCPU(39) == .normal)
        #expect(SystemMonitorLevel.processCPU(40) == .elevated)
        #expect(SystemMonitorLevel.processCPU(120) == .critical)
        #expect(SystemMonitorLevel.normal < .critical)
    }

    @Test func metricsNumberAndSortByFocus() {
        #expect(SystemMonitorMetric.allCases.map(\.number) == [1, 2, 3, 4])
        #expect(SystemMonitorMetric(number: 3) == .disk)
        #expect(SystemMonitorMetric(number: 0) == nil && SystemMonitorMetric(number: 5) == nil)
        #expect(SystemMonitorSort(focus: .cpu) == .cpu)
        #expect(SystemMonitorSort(focus: .memory) == .memory)
        #expect(SystemMonitorSort(focus: .disk) == .disk)
        #expect(SystemMonitorSort(focus: .network) == nil)
        #expect(F.ticks(user: 1, system: 2, idle: 3, nice: 4).busy == 7)
    }
}

@Suite("System monitor history and process list")
struct SystemMonitorHistoryTests {
    typealias F = SystemMonitorFixtures

    @Test func seriesKeepTheLastValues() {
        var series = SystemMonitorSeries(capacity: 3)
        #expect(series.last == nil && series.peak == 0)
        for value in [1.0, 5, 2, 4] { series.append(value) }
        #expect(series.values == [5, 2, 4])
        #expect(series.last == 4 && series.peak == 5)
        series.append(.nan)
        #expect(series.values == [2, 4, 0])
        #expect(SystemMonitorSeries(capacity: 0).capacity == 1)
    }

    @Test func historyRecordsEverySeries() {
        var history = SystemMonitorHistory()
        history.append(F.snapshot(cpu: 40))
        #expect(history.cpu.values == [40])
        #expect(history.memory.values == [56.25])
        #expect(history.diskRead.values == [12_000_000] && history.diskWrite.values == [3_000_000])
        #expect(history.networkDown.values == [6_300_000] && history.networkUp.values == [181_000])
    }

    @Test func cpuAlertNeedsThirtySecondsAboveNinety() {
        var alert = SystemMonitorCPUAlert()
        alert.record(cpu: 95, at: 100)
        #expect(alert.sustained(at: 100) == nil)
        alert.record(cpu: 92, at: 120)
        #expect(alert.sustained(at: 129) == nil)
        alert.record(cpu: 99, at: 130)
        #expect(alert.sustained(at: 130) == 30)
        // Dropping below resets the clock.
        alert.record(cpu: 50, at: 131)
        #expect(alert.sustained(at: 200) == nil)
        alert.record(cpu: 91, at: 140)
        #expect(alert.sustained(at: 169) == nil)
    }

    @Test func filterMatchesNamesAndExactPIDs() {
        let processes = F.processes
        #expect(SystemMonitorProcessList.filter(processes, query: "  ").count == processes.count)
        #expect(SystemMonitorProcessList.filter(processes, query: "CHROME").map(\.pid) == [912])
        #expect(SystemMonitorProcessList.filter(processes, query: "912").map(\.pid) == [912])
        // A number that is no PID still matches names.
        #expect(SystemMonitorProcessList.filter(processes, query: "7").isEmpty)
        #expect(SystemMonitorProcessList.filter(processes, query: "o").map(\.pid) == [4821, 912, 1288, 344, 511])
    }

    @Test func sortingIsStable() {
        let processes = F.processes + [F.systemProcess(1, "idle twin", cpu: 42), F.systemProcess(2, "no disk", cpu: 0, disk: nil)]
        #expect(SystemMonitorProcessList.sorted(processes, by: .cpu).prefix(2).map(\.pid) == [1, 4821])
        #expect(SystemMonitorProcessList.sorted(processes, by: .memory).first?.pid == 912)
        #expect(SystemMonitorProcessList.sorted(processes, by: .disk).first?.pid == 511)
        #expect(SystemMonitorProcessList.sorted(processes, by: .disk).last?.pid == 2)
    }

    @Test func frozenRowsKeepTheirPlaces() {
        let processes = [F.systemProcess(1, "a", cpu: 1), F.systemProcess(2, "b", cpu: 2),
                         F.systemProcess(3, "c", cpu: 3), F.systemProcess(4, "new", cpu: 4)]
        let held = SystemMonitorProcessList.holding(processes, in: [3, 1, 2, 9])
        #expect(held.map(\.pid) == [3, 1, 2, 4])
        #expect(SystemMonitorProcessList.holding(processes, in: []).map(\.pid) == [1, 2, 3, 4])
        let twoNew = SystemMonitorProcessList.holding(processes, in: [2])
        #expect(twoNew.map(\.pid) == [2, 1, 3, 4])
    }

    @Test func busiestProcess() {
        #expect(SystemMonitorProcessList.busiest(F.processes)?.pid == 4821)
        #expect(SystemMonitorProcessList.busiest(nil) == nil)
        let tie = [F.systemProcess(9, "b", cpu: 5), F.systemProcess(3, "a", cpu: 5)]
        #expect(SystemMonitorProcessList.busiest(tie)?.pid == 3)
    }
}
