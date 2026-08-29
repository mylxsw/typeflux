import Foundation

struct ProcessingProgressTimeline {
    static let initialStageProgress: CGFloat = 0.5
    static let initialStageDuration: TimeInterval = 1.5
    static let maximumIncompleteProgress: CGFloat = 0.95

    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = max(timeout, 0.001)
    }

    func progress(elapsed: TimeInterval) -> CGFloat {
        progress(elapsed: elapsed, contentProcessingStartedAt: initialStageDuration)
    }

    func progress(
        elapsed: TimeInterval,
        contentProcessingStartedAt: TimeInterval?
    ) -> CGFloat {
        let elapsed = min(max(elapsed, 0), timeout)

        // Give transcription immediate visual momentum, then reserve the
        // remaining progress for the slower content-processing phase.
        if elapsed <= initialStageDuration {
            let normalizedElapsed = elapsed / initialStageDuration
            let easedProgress = 1 - pow(1 - normalizedElapsed, 3)
            return CGFloat(easedProgress) * Self.initialStageProgress
        }

        guard let contentProcessingStartedAt else {
            return Self.initialStageProgress
        }

        let normalizedContentProcessingStart = min(
            max(contentProcessingStartedAt, initialStageDuration),
            timeout
        )
        guard elapsed > normalizedContentProcessingStart else {
            return Self.initialStageProgress
        }

        let remainingDuration = timeout - normalizedContentProcessingStart
        let normalizedElapsed = min(
            (elapsed - normalizedContentProcessingStart) / remainingDuration,
            1
        )
        let easedProgress = log1p(9 * normalizedElapsed) / log(10)
        let remainingProgress = Self.maximumIncompleteProgress - Self.initialStageProgress
        return Self.initialStageProgress + CGFloat(easedProgress) * remainingProgress
    }

    private var initialStageDuration: TimeInterval {
        min(Self.initialStageDuration, timeout / 2)
    }
}
