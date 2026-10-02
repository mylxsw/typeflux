import CoreGraphics
import Foundation

/// Lays out the account page's daily credit chart and per-feature breakdown
/// from `CloudUsageBreakdown`. Pure, so the calendar arithmetic is testable.
enum AccountCreditChart {
    struct Bar: Equatable {
        let day: Date
        let credits: Int
        let isFuture: Bool
        let isToday: Bool
    }

    enum Feature: String, CaseIterable, Equatable {
        case voice
        case rewrite
        case ask
    }

    struct Share: Equatable {
        let feature: Feature
        let credits: Int
        /// Share of the period's credits, 0...1.
        let fraction: Double
    }

    /// A monthly period fits; longer ones show the latest month.
    static let maxBars = 31

    /// One bar per day of the period in the breakdown's time zone, days after
    /// today included (empty) so the chart reads as "how far through the period".
    static func bars(_ breakdown: CloudUsageBreakdown, now: Date = Date()) -> [Bar] {
        guard let start = ISO8601DateFormatter.typefluxBillingDate(from: breakdown.periodStart),
              let end = ISO8601DateFormatter.typefluxBillingDate(from: breakdown.periodEnd),
              end > start else { return [] }
        let calendar = calendar(for: breakdown)
        let firstDay = calendar.startOfDay(for: start)
        // The period end is exclusive.
        let lastDay = calendar.startOfDay(for: end.addingTimeInterval(-1))
        let today = calendar.startOfDay(for: now)

        var days: [Date] = []
        var day = firstDay
        while day <= lastDay, days.count < 400 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        if days.count > maxBars {
            // Keep the window ending at today (or the period's last day); before
            // the period starts, show its first days.
            let endIndex = days.lastIndex { $0 <= min(today, lastDay) } ?? 0
            let lower = max(0, endIndex - maxBars + 1)
            days = Array(days[lower ..< min(days.count, lower + maxBars)])
        }

        let formatter = dayFormatter(calendar)
        var credits: [String: Int] = [:]
        for entry in breakdown.days {
            credits[entry.date, default: 0] += entry.total
        }
        return days.map { day in
            Bar(day: day, credits: credits[formatter.string(from: day)] ?? 0,
                isFuture: day > today, isToday: day == today)
        }
    }

    /// Centre of the "Today" label under bar `index` of `count` across `width`,
    /// or nil when it would overlap the end labels (`clearance` from each edge).
    static func todayLabelCenter(index: Int, count: Int, width: CGFloat, clearance: CGFloat) -> CGFloat? {
        guard count > 0, index >= 0, index < count, width > clearance * 2 else { return nil }
        let center = width * (CGFloat(index) + 0.5) / CGFloat(count)
        return center < clearance || center > width - clearance ? nil : center
    }

    /// Voice, rewrite and Ask in a fixed order; empty when nothing was spent.
    static func shares(_ breakdown: CloudUsageBreakdown) -> [Share] {
        let total = breakdown.total
        guard total > 0 else { return [] }
        let values: [(Feature, Int)] = [(.voice, breakdown.voice), (.rewrite, breakdown.rewrite), (.ask, breakdown.ask)]
        return values.map { Share(feature: $0.0, credits: $0.1, fraction: Double($0.1) / Double(total)) }
    }

    static func calendar(for breakdown: CloudUsageBreakdown) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: breakdown.timezone) ?? .current
        return calendar
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
