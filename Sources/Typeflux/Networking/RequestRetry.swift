import Foundation

enum RequestRetry {
    static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(500),
        .seconds(2)
    ]

    typealias RetryCallback = @Sendable (_ retryNumber: Int, _ error: Error, _ delay: Duration) async -> Void
    typealias SleepClosure = @Sendable (Duration) async throws -> Void

    static func perform<T>(
        operationName: String,
        onRetry: RetryCallback? = nil,
        sleep: SleepClosure = { duration in try await defaultSleep(for: duration) },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0

        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < retryDelays.count else {
                    NetworkDebugLogger.logError(
                        context: "\(operationName) failed after \(attempt + 1) attempts",
                        error: error
                    )
                    throw error
                }

                let retryNumber = attempt + 1
                let delay = retryDelays[attempt]
                NetworkDebugLogger.logError(
                    context: "\(operationName) attempt \(attempt + 1) failed; scheduling retry \(retryNumber)",
                    error: error
                )
                await onRetry?(retryNumber, error, delay)
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    private static func defaultSleep(for duration: Duration) async throws {
        guard !isZero(duration) else { return }
        try await Task.sleep(for: duration)
    }

    private static func isZero(_ duration: Duration) -> Bool {
        let components = duration.components
        return components.seconds == 0 && components.attoseconds == 0
    }
}
