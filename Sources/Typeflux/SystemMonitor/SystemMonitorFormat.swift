import Foundation

/// How the monitor writes its numbers. Memory counts in binary units (36 GB of
/// RAM), disks and rates in decimal ones, as macOS does.
enum SystemMonitorFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// "635 MB", "1.2 GB", "36 GB": one decimal below 10 (or 100 for GB and up), none above or when it is 0.
    static func bytes(_ value: Double, base: Double) -> String {
        let (scaled, unit) = scale(value, base: base)
        return number(scaled, unit: unit) + " " + units[unit]
    }

    static func memory(_ value: UInt64) -> String { bytes(Double(value), base: 1024) }
    static func storage(_ value: UInt64) -> String { bytes(Double(value), base: 1000) }

    /// "181 KB/s", "6.3 MB/s"; "0 KB/s" when idle.
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let (scaled, unit) = scale(value, base: 1000)
        // Rates never read in bytes: anything under 1 KB/s shows in KB/s.
        if unit == 0 { return number(value / 1000, unit: 1) + " KB/s" }
        return number(scaled, unit: unit) + " " + units[unit] + "/s"
    }

    /// The compact form for the mini bar: "6.3M", "181K", "0K".
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let (scaled, unit) = scale(value, base: 1000)
        if unit == 0 { return number(value / 1000, unit: 1) + "K" }
        return number(scaled, unit: unit) + String(units[unit].prefix(1))
    }

    /// A rate split into number and unit, for a card's large figure: ("6.3", "MB/s").
    static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let text = rate(bytesPerSecond)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    /// "23", rounding to whole percent.
    static func percent(_ value: Double) -> String {
        String(Int((max(0, value)).rounded()))
    }

    /// A process's CPU: "0.4", "18.2", "367".
    static func processCPU(_ value: Double) -> String {
        let value = max(0, value)
        return value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// A refresh interval in seconds: "1", "0.5".
    static func interval(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    static func load(_ values: [Double]) -> String {
        values.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    /// "3 days 4 hours", "5 hours 12 min", "8 min".
    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        let days = minutes / 1440, hours = minutes / 60 % 24, mins = minutes % 60
        if days > 0 { return L("system.monitor.uptime.days", days, hours) }
        if hours > 0 { return L("system.monitor.uptime.hours", hours, mins) }
        return L("system.monitor.uptime.minutes", mins)
    }

    private static func scale(_ value: Double, base: Double) -> (Double, Int) {
        var scaled = max(0, value.isFinite ? value : 0)
        var unit = 0
        // 999.6 KB would round up to "1000 KB"; it reads as 1.0 MB instead.
        while scaled >= base * 0.9995, unit < units.count - 1 {
            scaled /= base
            unit += 1
        }
        return (scaled, unit)
    }

    private static func number(_ value: Double, unit: Int) -> String {
        if unit == 0 { return String(Int(value.rounded())) }
        let decimals = value < 10 || (unit >= 3 && value < 100) ? 1 : 0
        let text = String(format: "%.\(decimals)f", value)
        // "36 GB", not "36.0 GB".
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
