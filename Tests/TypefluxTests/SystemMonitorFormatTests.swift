import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Runs `body` with the interface in `language`, then puts the previous one back.
@MainActor
func withSystemMonitorLanguage(_ language: AppLanguage = .english, _ body: () throws -> Void) rethrows {
    let original = AppLocalization.shared.language
    AppLocalization.shared.setLanguage(language)
    defer { AppLocalization.shared.setLanguage(original) }
    try body()
}

@Suite("System monitor formatting", .exclusiveUIState)
@MainActor
struct SystemMonitorFormatTests {
    typealias F = SystemMonitorFixtures

    @Test func bytesUseBinaryForMemoryAndDecimalForStorage() {
        #expect(SystemMonitorFormat.memory(0) == "0 B")
        #expect(SystemMonitorFormat.memory(640 << 20) == "640 MB")
        #expect(SystemMonitorFormat.memory(3400 << 20) == "3.3 GB")
        #expect(SystemMonitorFormat.memory(36 << 30) == "36 GB")
        #expect(SystemMonitorFormat.memory(UInt64(1.2 * Double(1 << 40))) == "1.2 TB")
        #expect(SystemMonitorFormat.storage(382_000_000_000) == "382 GB")
        #expect(SystemMonitorFormat.storage(999_700) == "1 MB")
        #expect(SystemMonitorFormat.bytes(.infinity, base: 1000) == "0 B")
    }

    @Test func ratesNeverReadInBytes() {
        #expect(SystemMonitorFormat.rate(0) == "0 KB/s")
        #expect(SystemMonitorFormat.rate(-5) == "0 KB/s")
        #expect(SystemMonitorFormat.rate(181_000) == "181 KB/s")
        #expect(SystemMonitorFormat.rate(6_300_000) == "6.3 MB/s")
        #expect(SystemMonitorFormat.rate(12_000_000) == "12 MB/s")
        #expect(SystemMonitorFormat.shortRate(500) == "0.5K")
        #expect(SystemMonitorFormat.shortRate(181_000) == "181K")
        #expect(SystemMonitorFormat.shortRate(6_300_000) == "6.3M")
        #expect(SystemMonitorFormat.rateParts(6_300_000) == ("6.3", "MB/s"))
    }

    @Test func numbers() {
        #expect(SystemMonitorFormat.percent(22.6) == "23")
        #expect(SystemMonitorFormat.percent(-1) == "0")
        #expect(SystemMonitorFormat.processCPU(0.44) == "0.4")
        #expect(SystemMonitorFormat.processCPU(367.2) == "367")
        #expect(SystemMonitorFormat.interval(1) == "1")
        #expect(SystemMonitorFormat.interval(0.5) == "0.5")
        #expect(SystemMonitorFormat.load([3.051, 2.5, 2.1, 9]) == "3.05  2.50  2.10")
    }

    @Test func uptimeInWords() {
        withSystemMonitorLanguage {
            #expect(SystemMonitorFormat.uptime(3 * 86400 + 4 * 3600 + 59) == "3 d 4 h")
            #expect(SystemMonitorFormat.uptime(5 * 3600 + 12 * 60) == "5 h 12 min")
            #expect(SystemMonitorFormat.uptime(8 * 60) == "8 min")
            #expect(SystemMonitorFormat.uptime(-10) == "0 min")
        }
        withSystemMonitorLanguage(.simplifiedChinese) {
            #expect(SystemMonitorFormat.uptime(86400) == "1 天 0 小时")
        }
    }

    @Test func cardsDescribeEachMetric() {
        withSystemMonitorLanguage {
            let machine = SystemMachineInfo(chip: "Apple M3 Pro", cores: 12, performanceCores: 6, efficiencyCores: 6,
                                            memory: 36 << 30)
            let snapshot = F.snapshot(cpu: 23)
            let cpu = SystemMonitorMetricDisplay.make(.cpu, snapshot: snapshot, machine: machine)
            #expect(cpu.value == "23" && cpu.unit == "%" && cpu.detail == "12 cores · load 3.05" && cpu.level == .normal)
            let memory = SystemMonitorMetricDisplay.make(.memory, snapshot: snapshot, machine: machine)
            #expect(memory.value == "56" && memory.detail == "9 GB / 16 GB")
            let disk = SystemMonitorMetricDisplay.make(.disk, snapshot: snapshot, machine: machine)
            #expect(disk.value == "62" && disk.detail == "R 12M/s · W 3M/s" && disk.level == .normal)
            let network = SystemMonitorMetricDisplay.make(.network, snapshot: snapshot, machine: machine)
            #expect(network.value == "6.3" && network.unit == "MB/s ↓" && network.detail == "↑ 181 KB/s · Wi-Fi")

            let empty = SystemMonitorMetricDisplay.make(.network, snapshot: nil, machine: machine)
            #expect(empty.value == "—" && empty.unit.isEmpty)
            #expect(SystemMonitorMetricDisplay.make(.cpu, snapshot: nil, machine: machine).unit == "%")

            var noVolume = snapshot
            noVolume.volumes = []
            noVolume.interface = nil
            noVolume.loadAverage = []
            #expect(SystemMonitorMetricDisplay.make(.disk, snapshot: noVolume, machine: machine).value == "—")
            #expect(SystemMonitorMetricDisplay.make(.network, snapshot: noVolume, machine: machine).detail == "↑ 181 KB/s")
            #expect(SystemMonitorMetricDisplay.make(.cpu, snapshot: noVolume, machine: machine).detail == "12 cores · load —")
        }
    }

    @Test func levelsColourTheCards() {
        let machine = SystemMachineInfo(chip: "x", cores: 1, memory: 1)
        #expect(SystemMonitorMetricDisplay.make(.cpu, snapshot: F.snapshot(cpu: 85), machine: machine).level == .elevated)
        #expect(SystemMonitorMetricDisplay.make(.memory, snapshot: F.snapshot(pressure: .critical), machine: machine)
            .level == .critical)
        let nearlyFull = F.snapshot(volumes: [F.volume(total: 100, available: 8)])
        #expect(SystemMonitorMetricDisplay.make(.disk, snapshot: nearlyFull, machine: machine).level == .elevated)
        let full = F.snapshot(volumes: [F.volume(total: 100, available: 2)])
        #expect(SystemMonitorMetricDisplay.make(.disk, snapshot: full, machine: machine).level == .critical)
        #expect(SystemMonitorTheme.color(.normal) == nil)
        #expect(SystemMonitorTheme.color(.elevated) != nil && SystemMonitorTheme.color(.critical) != nil)
        for metric in SystemMonitorMetric.allCases { _ = SystemMonitorTheme.color(metric) }
        for pressure in [SystemMonitorMemoryPressure.normal, .warning, .critical] {
            _ = SystemMonitorTheme.pressureColor(pressure)
        }
    }

    @Test func wordsForStatesAndSummary() {
        withSystemMonitorLanguage {
            #expect(SystemMonitorMetric.allCases.map(SystemMonitorMetricDisplay.title) == ["CPU", "Memory", "Disk", "Network"])
            #expect(SystemMonitorSort.allCases.map(SystemMonitorMetricDisplay.sortTitle) == ["CPU", "Memory", "Disk"])
            #expect(Set(SystemMonitorMetric.allCases.map(SystemMonitorMetricDisplay.symbol)).count == 4)
            #expect(SystemMonitorMetricDisplay.pressureTitle(.warning) == "High")
            #expect([ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map(SystemMonitorMetricDisplay.thermalTitle)
                == ["Normal", "Fair", "Serious", "Critical"])
            #expect(SystemMonitorMetricDisplay.thermalLevel(.fair) == .normal)
            #expect(SystemMonitorMetricDisplay.thermalLevel(.serious) == .elevated)
            #expect(SystemMonitorMetricDisplay.thermalLevel(.critical) == .critical)
            let machine = SystemMachineInfo(chip: "Apple M3 Pro", cores: 12, memory: 36 << 30)
            #expect(SystemMonitorMetricDisplay.machineLine(machine) == "Apple M3 Pro · 12 cores · 36 GB")
            #expect(SystemMonitorMetricDisplay.summary(nil) == "Reading…")
            #expect(SystemMonitorMetricDisplay.summary(F.snapshot(cpu: 23))
                == "CPU 23% · Memory 56% · Disk 62% · ↓ 6.3 MB/s ↑ 181 KB/s")
            #expect(SystemMonitorMetricDisplay.summary(F.snapshot(cpu: 5, volumes: []))
                == "CPU 5% · Memory 56% · ↓ 6.3 MB/s ↑ 181 KB/s")
        }
    }

    @Test func alertWording() {
        withSystemMonitorLanguage {
            let process = F.systemProcess(4821, "node", cpu: 367.2)
            #expect(SystemMonitorLauncherView.alertText(.init(seconds: 31, process: process))
                == "CPU has stayed above 90% for 31 s, mostly node (PID 4821, 367%)")
            #expect(SystemMonitorLauncherView.alertText(.init(seconds: 30, process: nil))
                == "CPU has stayed above 90% for 30 s")
        }
    }

    @Test func chartsScaleToTheirValues() {
        var history = SystemMonitorHistory()
        history.append(F.snapshot(cpu: 40))
        history.append(F.snapshot(cpu: 60))
        let cpu = SystemMonitorChartSeries.make(.cpu, history: history)
        #expect(cpu.top == 100 && cpu.values == [[40, 60]])
        let network = SystemMonitorChartSeries.make(.network, history: history)
        #expect(network.values.count == 2 && abs(network.top - 6_300_000 * 1.15) < 1)
        #expect(SystemMonitorChartSeries.make(.disk, history: history).colors.count == 2)
        #expect(SystemMonitorChartSeries.make(.memory, history: history).maximum == 100)
        #expect(SystemMonitorChartSeries(values: [[]], colors: [.red], maximum: nil).top == 1)

        let rect = CGRect(x: 0, y: 0, width: 59, height: 30)
        let line = SystemMonitorSparklineShape(values: [0, 50, 100], top: 100).path(in: rect)
        #expect(!line.isEmpty)
        // New values enter on the right.
        #expect(abs(line.boundingRect.maxX - 59) < 0.01 && abs(line.boundingRect.minX - 57) < 0.01)
        let area = SystemMonitorSparklineShape(values: [10, 20], top: 100, closed: true).path(in: rect)
        #expect(abs(area.boundingRect.maxY - 30) < 0.01)
        #expect(SystemMonitorSparklineShape(values: [1], top: 100).path(in: rect).isEmpty)
        #expect(SystemMonitorSparklineShape(values: [1, 2], top: 0).path(in: rect).isEmpty)
    }
}
