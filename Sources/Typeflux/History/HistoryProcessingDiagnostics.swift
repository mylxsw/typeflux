import Foundation

enum CloudLocalTranscriptionSource: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

enum ASRAttemptOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

struct ASRAttemptDiagnostics: Codable, Equatable, Sendable {
    let outcome: ASRAttemptOutcome
    let durationMilliseconds: Int
    let completedAt: Date?
    let errorDomain: String?
    let errorCode: Int?

    init(
        outcome: ASRAttemptOutcome,
        durationMilliseconds: Int,
        completedAt: Date? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) {
        self.outcome = outcome
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.completedAt = completedAt
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

enum ASRRaceSelectionReason: String, Codable, Equatable, Sendable {
    case cloudWithinPriorityWindow
    case cloudAfterPriorityWindow
    case localAtPriorityDeadline
    case localAfterPriorityWindow
    case localAfterCloudFailure
    case bothFailed
}

struct ASRRaceDiagnostics: Codable, Equatable, Sendable {
    let startedAt: Date
    let selectedAt: Date
    let priorityWindowMilliseconds: Int
    let decisionDurationMilliseconds: Int
    let selectedSource: CloudLocalTranscriptionSource?
    let selectionReason: ASRRaceSelectionReason
    let cloudPriorityWindowExceeded: Bool
    let cloudAttempt: ASRAttemptDiagnostics
    let localAttempt: ASRAttemptDiagnostics
}

final class ASRRaceDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ASRRaceDiagnostics?

    func record(_ diagnostics: ASRRaceDiagnostics) {
        lock.lock()
        value = diagnostics
        lock.unlock()
    }

    func snapshot() -> ASRRaceDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum LLMProcessingOutcome: String, Codable, Equatable, Sendable {
    case completed
    case emptyResponseFallback
    case timedOutFallback
    case serviceOverloadedFallback
    case configurationUnavailableFallback
    case billingFallback
    case cancelled
    case failed
}

struct LLMProcessingOutcomeDiagnostics: Codable, Equatable, Sendable {
    let startedAt: Date
    let completedAt: Date
    let timeoutMilliseconds: Int?
    let durationMilliseconds: Int
    let outcome: LLMProcessingOutcome
    let usedTranscriptFallback: Bool

    init(
        startedAt: Date,
        completedAt: Date,
        timeoutMilliseconds: Int?,
        outcome: LLMProcessingOutcome,
        usedTranscriptFallback: Bool
    ) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.timeoutMilliseconds = timeoutMilliseconds.map { max(0, $0) }
        durationMilliseconds = Self.clampedMilliseconds(
            for: completedAt.timeIntervalSince(startedAt)
        )
        self.outcome = outcome
        self.usedTranscriptFallback = usedTranscriptFallback
    }

    static func clampedMilliseconds(for interval: TimeInterval) -> Int {
        guard interval.isFinite else {
            return interval == .infinity ? Int.max : 0
        }
        let milliseconds = interval * 1_000
        guard milliseconds > 0 else { return 0 }
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds.rounded())
    }
}
