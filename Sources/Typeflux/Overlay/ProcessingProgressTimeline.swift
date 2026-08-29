import Foundation

struct ProcessingProgressTimeline {
    static let initialProgress: CGFloat = 0.5
    static let recognitionCompleteProgress: CGFloat = 0.7
    static let maximumIncompleteProgress: CGFloat = 0.95

    private static let recognitionResponseTime: TimeInterval = 0.45
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = max(timeout, 0.001)
    }

    func progress(
        elapsed: TimeInterval,
        contentProcessingStartedAt: TimeInterval?
    ) -> CGFloat {
        let elapsed = min(max(elapsed, 0), timeout)

        guard let contentProcessingStartedAt else {
            return recognitionProgress(elapsed: elapsed)
        }

        let normalizedContentProcessingStart = min(
            max(contentProcessingStartedAt, 0),
            timeout
        )
        guard elapsed > normalizedContentProcessingStart else {
            return Self.recognitionCompleteProgress
        }

        let remainingDuration = timeout - normalizedContentProcessingStart
        let normalizedElapsed = min(
            (elapsed - normalizedContentProcessingStart) / remainingDuration,
            1
        )
        let easedProgress = log1p(9 * normalizedElapsed) / log(10)
        let remainingProgress = Self.maximumIncompleteProgress - Self.recognitionCompleteProgress
        return Self.recognitionCompleteProgress + CGFloat(easedProgress) * remainingProgress
    }

    private func recognitionProgress(elapsed: TimeInterval) -> CGFloat {
        // Approach 70% asymptotically so recognition keeps moving without
        // reaching its phase boundary before transcription actually finishes.
        let easedProgress = 1 - exp(-elapsed / Self.recognitionResponseTime)
        let recognitionProgress = Self.recognitionCompleteProgress - Self.initialProgress
        return Self.initialProgress + CGFloat(easedProgress) * recognitionProgress
    }
}
