import Foundation

enum RequestRetry {
    static let paidCloudNoReplayKey = "TypefluxPaidCloudNoReplay"
    static let responseBodyKey = "TypefluxCloudResponseBody"

    /// An uncertain paid invocation must stay terminal across nested retry loops.
    static func protectingPaidCloudFailure(_ error: Error) -> Error {
        if error is CancellationError
            || TypefluxCloudBillingError.fromError(error) != nil
            || TypefluxCloudLoginRequiredError.fromError(error) != nil
            || TypefluxCloudASRDirectiveError.fromError(error) != nil {
            return error
        }
        let original = error as NSError
        if original.code == 503,
           let data = original.userInfo[responseBodyKey] as? Data,
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           envelope["code"] as? String == "BILLING_SYNC_PENDING" {
            return error
        }
        var info = original.userInfo
        info[NSLocalizedDescriptionKey] = error.localizedDescription
        info[paidCloudNoReplayKey] = true
        info[NSUnderlyingErrorKey] = error
        return NSError(domain: original.domain, code: original.code, userInfo: info)
    }

    static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(500),
        .seconds(2)
    ]

    typealias RetryCallback = @Sendable (_ retryNumber: Int, _ error: Error, _ delay: Duration) async -> Void
    typealias RetryPredicate = @Sendable (_ error: Error) -> Bool
    typealias SleepClosure = @Sendable (Duration) async throws -> Void

    static func perform<T>(
        operationName: String,
        onRetry: RetryCallback? = nil,
        shouldRetry: @escaping RetryPredicate = { _ in true },
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
                if (error as NSError).userInfo[paidCloudNoReplayKey] as? Bool == true {
                    throw error
                }
                if TypefluxCloudBillingError.fromError(error) != nil {
                    throw error
                }
                if TypefluxCloudLoginRequiredError.fromError(error) != nil {
                    throw error
                }
                if TypefluxCloudASRDirectiveError.fromError(error) != nil {
                    throw error
                }
                guard shouldRetry(error) else {
                    throw error
                }

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
