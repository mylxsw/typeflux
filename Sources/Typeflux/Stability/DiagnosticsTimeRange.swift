import Foundation

enum DiagnosticsTimeRange: String, CaseIterable, Sendable {
    case minute1, minute5, minute10, minute15, minute30, hour, day, all, custom

    var duration: TimeInterval? {
        switch self {
        case .minute1: 60
        case .minute5: 300
        case .minute10: 600
        case .minute15: 900
        case .minute30: 1800
        case .hour: 3600
        case .day: 86400
        case .all, .custom: nil
        }
    }

    func interval(at now: Date, start: Date, end: Date) -> DateInterval? {
        if let duration { return DateInterval(start: now.addingTimeInterval(-duration), end: now) }
        guard self == .custom, start <= end else { return nil }
        return DateInterval(start: start, end: end)
    }
}

extension DiagnosticsReport {
    static func exportFilename(at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return "typeflux-diagnostics-\(formatter.string(from: date)).json"
    }
}
