import Foundation

enum CloudLocalTranscriptionSource: String, Equatable {
    case cloud
    case local
}

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
        private var continuation: AsyncStream<Event>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var isFinished = false

        func install(
            continuation: AsyncStream<Event>.Continuation,
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
        local: @escaping @Sendable () async throws -> String
    ) async throws -> CloudLocalTranscriptionRaceResult {
        let raceTasks = RaceTasks()
        let stream = AsyncStream<Event> { continuation in
            let cloudTask = Task {
                await Self.run(source: .cloud, operation: cloud, continuation: continuation)
            }
            let localTask = Task {
                await Self.run(source: .local, operation: local, continuation: continuation)
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: priorityWindow))
                    continuation.yield(.priorityWindowExpired)
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
            return try await resolve(stream)
        } onCancel: {
            raceTasks.finishAndCancelTasks()
        }
    }

    private func resolve(_ stream: AsyncStream<Event>) async throws -> CloudLocalTranscriptionRaceResult {
        var resolver = Resolver()

        for await event in stream {
            try Task.checkCancellation()
            if let result = try resolver.receive(event) {
                return result
            }
        }

        try Task.checkCancellation()
        throw resolver.combinedError
    }

    private static func run(
        source: CloudLocalTranscriptionSource,
        operation: @escaping @Sendable () async throws -> String,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        do {
            let text = try await operation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continuation.yield(.completed(source, .failure(EmptyTranscriptionResultError(source: source))))
                return
            }
            continuation.yield(.completed(source, .success(text)))
        } catch {
            continuation.yield(.completed(source, .failure(error)))
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let clamped = min(max(0, interval), TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(clamped * 1_000_000_000)
    }
}
