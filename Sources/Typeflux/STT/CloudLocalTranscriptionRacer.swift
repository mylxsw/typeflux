import Foundation

struct CloudLocalTranscriptionRaceResult: Equatable {
    let text: String
    let source: CloudLocalTranscriptionSource
}

struct CloudLocalTranscriptionRaceError: LocalizedError {
    let cloudError: Error?
    let localError: Error?

    var errorDescription: String? {
        let cloudMessage = cloudError?.localizedDescription ?? "no result"
        let localMessage = localError?.localizedDescription ?? "no result"
        return "Cloud and local transcription failed (cloud: \(cloudMessage); local: \(localMessage))."
    }
}

private struct EmptyTranscriptionResultError: LocalizedError {
    let source: CloudLocalTranscriptionSource

    var errorDescription: String? {
        "\(source.rawValue.capitalized) transcription returned an empty result."
    }
}

/// Runs cloud and local transcription concurrently while preserving a short
/// cloud-quality preference window. Once that window expires, the first usable
/// result wins. The losing task is cancelled without delaying the selected result.
final class CloudLocalTranscriptionRacer {
    enum Event {
        case completed(CloudLocalTranscriptionSource, Result<String, Error>)
        case priorityWindowExpired
    }

    struct TimedEvent {
        let event: Event
        let elapsedMilliseconds: Int
        let occurredAt: Date
    }

    struct DiagnosticsBuilder {
        let startedAt: Date
        let priorityWindowMilliseconds: Int
        private(set) var cloudAttempt: ASRAttemptDiagnostics?
        private(set) var localAttempt: ASRAttemptDiagnostics?
        private(set) var priorityWindowExpired = false

        mutating func receive(_ timedEvent: TimedEvent) {
            switch timedEvent.event {
            case let .completed(source, result):
                let attempt: ASRAttemptDiagnostics
                switch result {
                case .success:
                    attempt = ASRAttemptDiagnostics(
                        outcome: .succeeded,
                        durationMilliseconds: timedEvent.elapsedMilliseconds,
                        completedAt: timedEvent.occurredAt
                    )
                case let .failure(error):
                    let nsError = error as NSError
                    attempt = ASRAttemptDiagnostics(
                        outcome: .failed,
                        durationMilliseconds: timedEvent.elapsedMilliseconds,
                        completedAt: timedEvent.occurredAt,
                        errorDomain: nsError.domain,
                        errorCode: nsError.code
                    )
                }
                switch source {
                case .cloud:
                    cloudAttempt = attempt
                case .local:
                    localAttempt = attempt
                }

            case .priorityWindowExpired:
                priorityWindowExpired = true
            }
        }

        func finalize(
            selectedSource: CloudLocalTranscriptionSource?,
            selectionReason: ASRRaceSelectionReason,
            decision: TimedEvent
        ) -> ASRRaceDiagnostics {
            let decisionDuration = max(0, decision.elapsedMilliseconds)
            let cancelledAttempt = ASRAttemptDiagnostics(
                outcome: .cancelled,
                durationMilliseconds: decisionDuration
            )
            return ASRRaceDiagnostics(
                startedAt: startedAt,
                selectedAt: decision.occurredAt,
                priorityWindowMilliseconds: priorityWindowMilliseconds,
                decisionDurationMilliseconds: decisionDuration,
                selectedSource: selectedSource,
                selectionReason: selectionReason,
                cloudPriorityWindowExceeded: priorityWindowExpired ||
                    decisionDuration > priorityWindowMilliseconds,
                cloudAttempt: cloudAttempt ?? cancelledAttempt,
                localAttempt: localAttempt ?? cancelledAttempt
            )
        }
    }

    struct Resolver {
        private(set) var cachedLocalResult: String?
        private(set) var cloudError: Error?
        private(set) var localError: Error?
        private(set) var priorityWindowExpired = false

        mutating func receive(_ event: Event) throws -> CloudLocalTranscriptionRaceResult? {
            switch event {
            case let .completed(.cloud, .success(text)):
                return CloudLocalTranscriptionRaceResult(text: text, source: .cloud)

            case let .completed(.local, .success(text)):
                if priorityWindowExpired || cloudError != nil {
                    return CloudLocalTranscriptionRaceResult(text: text, source: .local)
                }
                cachedLocalResult = text

            case let .completed(.cloud, .failure(error)):
                cloudError = error
                if let cachedLocalResult {
                    return CloudLocalTranscriptionRaceResult(text: cachedLocalResult, source: .local)
                }
                if localError != nil {
                    throw combinedError
                }

            case let .completed(.local, .failure(error)):
                localError = error
                if cloudError != nil {
                    throw combinedError
                }

            case .priorityWindowExpired:
                priorityWindowExpired = true
                if let cachedLocalResult {
                    return CloudLocalTranscriptionRaceResult(text: cachedLocalResult, source: .local)
                }
            }
            return nil
        }

        var combinedError: CloudLocalTranscriptionRaceError {
            CloudLocalTranscriptionRaceError(cloudError: cloudError, localError: localError)
        }
    }

    private final class RaceTasks: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<TimedEvent>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var isFinished = false

        func install(
            continuation: AsyncStream<TimedEvent>.Continuation,
            tasks: [Task<Void, Never>]
        ) {
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                tasks.forEach { $0.cancel() }
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finishAndCancelTasks() {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let continuation = continuation
            let tasks = tasks
            self.continuation = nil
            self.tasks = []
            lock.unlock()

            continuation?.finish()
            tasks.forEach { $0.cancel() }
        }
    }

    let priorityWindow: TimeInterval

    init(priorityWindow: TimeInterval) {
        self.priorityWindow = max(0, priorityWindow)
    }

    func race(
        cloud: @escaping @Sendable () async throws -> String,
        local: @escaping @Sendable () async throws -> String,
        diagnosticsRecorder: ASRRaceDiagnosticsRecorder? = nil
    ) async throws -> CloudLocalTranscriptionRaceResult {
        let raceTasks = RaceTasks()
        let clock = ContinuousClock()
        let startedInstant = clock.now
        let startedAt = Date()
        let stream = AsyncStream<TimedEvent> { continuation in
            let cloudTask = Task {
                await Self.run(
                    source: .cloud,
                    operation: cloud,
                    continuation: continuation,
                    clock: clock,
                    startedInstant: startedInstant
                )
            }
            let localTask = Task {
                await Self.run(
                    source: .local,
                    operation: local,
                    continuation: continuation,
                    clock: clock,
                    startedInstant: startedInstant
                )
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: priorityWindow))
                    continuation.yield(
                        Self.timedEvent(
                            .priorityWindowExpired,
                            clock: clock,
                            startedInstant: startedInstant
                        )
                    )
                } catch {
                    // Cancellation means another result was selected or the parent stopped.
                }
            }
            raceTasks.install(
                continuation: continuation,
                tasks: [cloudTask, localTask, timeoutTask]
            )
            continuation.onTermination = { @Sendable _ in
                raceTasks.finishAndCancelTasks()
            }
        }

        return try await withTaskCancellationHandler {
            defer { raceTasks.finishAndCancelTasks() }
            return try await resolve(
                stream,
                startedAt: startedAt,
                diagnosticsRecorder: diagnosticsRecorder
            )
        } onCancel: {
            raceTasks.finishAndCancelTasks()
        }
    }

    private func resolve(
        _ stream: AsyncStream<TimedEvent>,
        startedAt: Date,
        diagnosticsRecorder: ASRRaceDiagnosticsRecorder?
    ) async throws -> CloudLocalTranscriptionRaceResult {
        var resolver = Resolver()
        var diagnostics = DiagnosticsBuilder(
            startedAt: startedAt,
            priorityWindowMilliseconds: Self.milliseconds(for: priorityWindow)
        )
        var lastEvent = TimedEvent(event: .priorityWindowExpired, elapsedMilliseconds: 0, occurredAt: startedAt)

        for await timedEvent in stream {
            try Task.checkCancellation()
            lastEvent = timedEvent
            let previousResolver = resolver
            diagnostics.receive(timedEvent)
            do {
                if let result = try resolver.receive(timedEvent.event) {
                    let snapshot = diagnostics.finalize(
                        selectedSource: result.source,
                        selectionReason: Self.selectionReason(
                            for: result.source,
                            event: timedEvent,
                            previousResolver: previousResolver,
                            priorityWindowMilliseconds: diagnostics.priorityWindowMilliseconds
                        ),
                        decision: timedEvent
                    )
                    if let diagnosticsRecorder {
                        diagnosticsRecorder.record(snapshot)
                    }
                    return result
                }
            } catch {
                let snapshot = diagnostics.finalize(
                    selectedSource: nil,
                    selectionReason: .bothFailed,
                    decision: timedEvent
                )
                if let diagnosticsRecorder {
                    diagnosticsRecorder.record(snapshot)
                }
                throw error
            }
        }

        try Task.checkCancellation()
        let snapshot = diagnostics.finalize(
            selectedSource: nil,
            selectionReason: .bothFailed,
            decision: lastEvent
        )
        if let diagnosticsRecorder {
            diagnosticsRecorder.record(snapshot)
        }
        throw resolver.combinedError
    }

    private static func run(
        source: CloudLocalTranscriptionSource,
        operation: @escaping @Sendable () async throws -> String,
        continuation: AsyncStream<TimedEvent>.Continuation,
        clock: ContinuousClock,
        startedInstant: ContinuousClock.Instant
    ) async {
        do {
            let text = try await operation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continuation.yield(
                    timedEvent(
                        .completed(source, .failure(EmptyTranscriptionResultError(source: source))),
                        clock: clock,
                        startedInstant: startedInstant
                    )
                )
                return
            }
            continuation.yield(
                timedEvent(
                    .completed(source, .success(text)),
                    clock: clock,
                    startedInstant: startedInstant
                )
            )
        } catch {
            continuation.yield(
                timedEvent(
                    .completed(source, .failure(error)),
                    clock: clock,
                    startedInstant: startedInstant
                )
            )
        }
    }

    private static func selectionReason(
        for source: CloudLocalTranscriptionSource,
        event: TimedEvent,
        previousResolver: Resolver,
        priorityWindowMilliseconds: Int
    ) -> ASRRaceSelectionReason {
        switch source {
        case .cloud:
            return previousResolver.priorityWindowExpired ||
                event.elapsedMilliseconds > priorityWindowMilliseconds
                ? .cloudAfterPriorityWindow
                : .cloudWithinPriorityWindow

        case .local:
            if previousResolver.cloudError != nil {
                return .localAfterCloudFailure
            }
            switch event.event {
            case .completed(.cloud, .failure):
                return .localAfterCloudFailure
            case .priorityWindowExpired:
                return .localAtPriorityDeadline
            default:
                return .localAfterPriorityWindow
            }
        }
    }

    private static func timedEvent(
        _ event: Event,
        clock: ContinuousClock,
        startedInstant: ContinuousClock.Instant
    ) -> TimedEvent {
        TimedEvent(
            event: event,
            elapsedMilliseconds: milliseconds(from: startedInstant, to: clock.now),
            occurredAt: Date()
        )
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: end).components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(clamping: milliseconds))
    }

    private static func milliseconds(for interval: TimeInterval) -> Int {
        LLMProcessingOutcomeDiagnostics.clampedMilliseconds(for: interval)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite else {
            return interval == .infinity ? UInt64.max : 0
        }
        let clamped = min(max(0, interval), TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(clamped * 1_000_000_000)
    }
}
