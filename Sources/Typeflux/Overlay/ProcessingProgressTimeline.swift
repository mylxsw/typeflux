import Foundation

struct ProcessingProgressTimeline {
    static let maximumIncompleteProgress: CGFloat = 0.95

    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = max(timeout, 0.001)
    }

    func progress(elapsed: TimeInterval) -> CGFloat {
        let normalizedElapsed = min(max(elapsed, 0) / timeout, 1)
        let easedProgress = log1p(9 * normalizedElapsed) / log(10)
        return CGFloat(easedProgress) * Self.maximumIncompleteProgress
    }
}
