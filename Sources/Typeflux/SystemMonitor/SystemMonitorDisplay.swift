import AppKit
import SwiftUI

/// What a card (or a window row) says about one metric. Pure, so the wording is tested.
struct SystemMonitorMetricDisplay: Equatable {
    var metric: SystemMonitorMetric
    var value: String
    var unit: String
    var detail: String
    var level: SystemMonitorLevel

    static let placeholder = "—"

    // swiftlint:disable:next cyclomatic_complexity
    static func make(_ metric: SystemMonitorMetric, snapshot: SystemSnapshot?,
                     machine: SystemMachineInfo) -> Self {
        guard let snapshot else {
            return Self(metric: metric, value: placeholder, unit: metric == .network ? "" : "%", detail: " ",
                        level: .normal)
        }
        switch metric {
        case .cpu:
            let load = snapshot.loadAverage.first.map { String(format: "%.2f", $0) } ?? placeholder
            return Self(metric: metric, value: SystemMonitorFormat.percent(snapshot.cpu.total), unit: "%",
                        detail: L("system.monitor.cpu.detail", machine.cores, load),
                        level: .cpu(snapshot.cpu.total))
        case .memory:
            let memory = snapshot.memory
            return Self(metric: metric, value: SystemMonitorFormat.percent(memory.usedPercent), unit: "%",
                        detail: SystemMonitorFormat.memory(memory.used) + " / " + SystemMonitorFormat
                            .memory(memory.total),
                        level: memory.pressure.level)
        case .disk:
            let rates = L("system.monitor.disk.detail", SystemMonitorFormat.shortRate(snapshot.diskRead),
                          SystemMonitorFormat.shortRate(snapshot.diskWrite))
            guard let root = snapshot.rootVolume else {
                return Self(metric: metric, value: placeholder, unit: "%", detail: rates, level: .normal)
            }
            let used = root.usedPercent
            return Self(metric: metric, value: SystemMonitorFormat.percent(used), unit: "%", detail: rates,
                        level: used >= 95 ? .critical : used >= 90 ? .elevated : .normal)
        case .network:
            let down = SystemMonitorFormat.rateParts(snapshot.networkDown)
            var detail = "↑ " + SystemMonitorFormat.rate(snapshot.networkUp)
            if let interface = snapshot.interface { detail += " · " + interface.displayName }
            return Self(metric: metric, value: down.value, unit: down.unit + " ↓", detail: detail, level: .normal)
        }
    }

    static func title(_ metric: SystemMonitorMetric) -> String {
        switch metric {
        case .cpu: L("system.monitor.metric.cpu")
        case .memory: L("system.monitor.metric.memory")
        case .disk: L("system.monitor.metric.disk")
        case .network: L("system.monitor.metric.network")
        }
    }

    static func sortTitle(_ sort: SystemMonitorSort) -> String {
        switch sort {
        case .cpu: L("system.monitor.sort.cpu")
        case .memory: L("system.monitor.sort.memory")
        case .disk: L("system.monitor.sort.disk")
        }
    }

    static func symbol(_ metric: SystemMonitorMetric) -> String {
        switch metric {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        }
    }

    /// "Normal", "High", "Critical": memory pressure in words.
    static func pressureTitle(_ pressure: SystemMonitorMemoryPressure) -> String {
        switch pressure {
        case .normal: L("system.monitor.pressure.normal")
        case .warning: L("system.monitor.pressure.warning")
        case .critical: L("system.monitor.pressure.critical")
        }
    }

    static func thermalTitle(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: L("system.monitor.thermal.nominal")
        case .fair: L("system.monitor.thermal.fair")
        case .serious: L("system.monitor.thermal.serious")
        case .critical: L("system.monitor.thermal.critical")
        @unknown default: L("system.monitor.thermal.nominal")
        }
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> SystemMonitorLevel {
        switch state {
        case .nominal, .fair: .normal
        case .serious: .elevated
        case .critical: .critical
        @unknown default: .normal
        }
    }

    /// The status line: "Apple M3 Pro · 12 cores · 36 GB".
    static func machineLine(_ machine: SystemMachineInfo) -> String {
        [machine.chip, L("system.monitor.cores", machine.cores), SystemMonitorFormat.memory(machine.memory)]
            .joined(separator: " · ")
    }

    /// The keyword's row in the launcher: "CPU 23% · Memory 65% · Disk 62% · ↓ 6.3 MB/s ↑ 181 KB/s".
    static func summary(_ snapshot: SystemSnapshot?) -> String {
        guard let snapshot else { return L("system.monitor.summary.loading") }
        var parts = [L("system.monitor.metric.cpu") + " " + SystemMonitorFormat.percent(snapshot.cpu.total) + "%",
                     L("system.monitor.metric.memory") + " " + SystemMonitorFormat
                         .percent(snapshot.memory.usedPercent) + "%"]
        if let root = snapshot.rootVolume {
            parts.append(L("system.monitor.metric.disk") + " " + SystemMonitorFormat.percent(root.usedPercent) + "%")
        }
        parts
            .append("↓ " + SystemMonitorFormat.rate(snapshot.networkDown) + " ↑ " + SystemMonitorFormat
                .rate(snapshot.networkUp))
        return parts.joined(separator: " · ")
    }
}

/// The series a metric draws: one line, or two (read and write, down and up) on one scale.
struct SystemMonitorChartSeries {
    var values: [[Double]]
    var colors: [Color]
    /// A fixed top (100 for percentages); nil scales to the highest value.
    var maximum: Double?

    static func make(_ metric: SystemMonitorMetric, history: SystemMonitorHistory) -> Self {
        switch metric {
        case .cpu: Self(values: [history.cpu.values], colors: [SystemMonitorMetric.cpu.color], maximum: 100)
        case .memory: Self(values: [history.memory.values], colors: [SystemMonitorMetric.memory.color], maximum: 100)
        case .disk: Self(values: [history.diskRead.values, history.diskWrite.values],
                         colors: [SystemMonitorMetric.disk.color, TypefluxColor.warning.color], maximum: nil)
        case .network: Self(values: [history.networkDown.values, history.networkUp.values],
                            colors: [SystemMonitorMetric.network.color, TypefluxColor.warning.color], maximum: nil)
        }
    }

    /// The top of the scale: the fixed maximum, or 15% above the highest value of any line.
    var top: Double {
        if let maximum { return maximum }
        return max(1, (values.flatMap { $0 }.max() ?? 0) * 1.15)
    }
}

/// A line of the last `capacity` values, right-aligned so new values enter on the right.
struct SystemMonitorSparklineShape: Shape {
    var values: [Double]
    var top: Double
    var capacity = SystemMonitorSeries.defaultCapacity
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, top > 0 else { return path }
        let step = rect.width / CGFloat(max(1, capacity - 1))
        let start = rect.maxX - CGFloat(values.count - 1) * step
        let points = values.enumerated().map { index, value in
            CGPoint(x: start + CGFloat(index) * step,
                    y: rect.maxY - CGFloat(min(max(value, 0), top) / top) * (rect.height - 1) - 0.5)
        }
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// One or two sparklines with a soft fill under the first.
struct SystemMonitorChart: View {
    var series: SystemMonitorChartSeries
    var lineWidth: CGFloat = 1.5
    var filled = true

    var body: some View {
        let top = series.top
        ZStack {
            ForEach(Array(series.values.enumerated()), id: \.offset) { index, values in
                let color = series.colors[min(index, series.colors.count - 1)]
                if filled, index == 0 {
                    SystemMonitorSparklineShape(values: values, top: top, closed: true)
                        .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                }
                SystemMonitorSparklineShape(values: values, top: top)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A process's icon: the app's own, or a generic one for everything else. Cached by PID.
@MainActor
enum SystemProcessIcons {
    private static var cache: [Int32: NSImage] = [:]

    static func icon(for pid: Int32) -> NSImage? {
        if let cached = cache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        if cache.count > 256 { cache.removeAll() }
        cache[pid] = icon
        return icon
    }
}
