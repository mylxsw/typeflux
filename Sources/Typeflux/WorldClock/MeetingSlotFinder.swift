import Foundation

/// Finds when several places can meet: a time inside everyone's working hours, or
/// the three times that disturb them least (late evenings, early mornings, nights and weekends cost more).
struct MeetingSlotFinder {
    struct Slot: Equatable {
        var start: Date
        /// Hours outside working time, summed over the places; nights and weekends weigh more.
        var penalty: Double
        /// Every place is inside its working hours for the whole meeting.
        var fits: Bool
    }

    struct Result: Equatable {
        /// When everyone is at work, as [first start, last end], for the first stretch found.
        var overlap: ClosedRange<Date>?
        /// Up to three starts, earliest first.
        var suggestions: [Slot]
    }

    var preferences: WorldClockPreferences
    var duration: TimeInterval = 3600
    var horizon: TimeInterval = 48 * 3600
    var step: TimeInterval = 1800

    func find(_ zones: [TimeZone], after now: Date) -> Result {
        guard !zones.isEmpty else { return Result(overlap: nil, suggestions: []) }
        let first = (now.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        var slots: [Slot] = []
        var start = Date(timeIntervalSinceReferenceDate: first)
        let end = now.addingTimeInterval(horizon)
        while start < end {
            var penalty = 0.0, fits = true
            for zone in zones {
                let cost = cost(of: start, in: zone)
                penalty += cost
                fits = fits && cost == 0
            }
            slots.append(Slot(start: start, penalty: penalty, fits: fits))
            start = start.addingTimeInterval(step)
        }
        var overlap: ClosedRange<Date>?
        if let firstFit = slots.firstIndex(where: \.fits) {
            var last = firstFit
            while last + 1 < slots.count, slots[last + 1].fits { last += 1 }
            overlap = slots[firstFit].start ... slots[last].start.addingTimeInterval(duration)
        }
        var picked: [Slot] = []
        for slot in slots.sorted(by: { $0.penalty != $1.penalty ? $0.penalty < $1.penalty : $0.start < $1.start })
            where picked.allSatisfy({ distinct($0.start, slot.start) }) {
            picked.append(slot)
            if picked.count == 3 { break }
        }
        return Result(overlap: overlap, suggestions: picked.sorted { $0.start < $1.start })
    }

    /// Different starts, and different hours of the day: tomorrow's copy of a time is not a new choice.
    private func distinct(_ first: Date, _ second: Date) -> Bool {
        let gap = abs(first.timeIntervalSince(second)).truncatingRemainder(dividingBy: 86400)
        return min(gap, 86400 - gap) >= 3600
    }

    /// 0 inside working hours for the whole meeting; otherwise how far outside, with extra for nights and weekends.
    func cost(of start: Date, in zone: TimeZone) -> Double {
        let calendar = WorldClockFormat.calendar(zone)
        var total = 0.0
        for moment in [start, start.addingTimeInterval(duration - 60)] {
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: moment)
            let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            let open = Double(preferences.workStart), close = Double(preferences.workEnd)
            if minutes < open {
                total += (open - minutes) / 60
            } else if minutes >= close {
                total += (minutes - close) / 60 + 0.5
            }
            if minutes < 7 * 60 || minutes >= 22 * 60 { total += 4 }
            if !preferences.workdays.contains(parts.weekday ?? 1) { total += 6 }
        }
        return total
    }
}
