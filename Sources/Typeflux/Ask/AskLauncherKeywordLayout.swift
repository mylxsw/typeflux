import Foundation

/// Fit whole keyword chips, bringing the keyboard's current chip into the visible range.
enum AskLauncherKeywordLayout {
    static func fitting(widths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat, selected: Int = 0) -> [Int] {
        guard !widths.isEmpty, availableWidth.isFinite, availableWidth >= 0,
              widths.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [] }
        let current = min(max(selected, 0), widths.count - 1)
        guard widths[current] <= availableWidth else { return [] }
        let gap = max(0, spacing)
        var lower = current
        var upper = current
        var used = widths[current]
        while lower > 0, used + gap + widths[lower - 1] <= availableWidth {
            lower -= 1
            used += gap + widths[lower]
        }
        while upper + 1 < widths.count, used + gap + widths[upper + 1] <= availableWidth {
            upper += 1
            used += gap + widths[upper]
        }
        return Array(lower ... upper)
    }
}
