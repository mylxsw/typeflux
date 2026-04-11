import Foundation

enum ConnectionTestError: LocalizedError, Equatable {
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            L("settings.models.connectionTimeout", seconds)
        }
    }
}

enum ConnectionTestSupport {
    static let timeoutSeconds = 30
    static let timeoutDuration: Duration = .seconds(timeoutSeconds)

    static func runWithTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeoutDuration)
                throw ConnectionTestError.timedOut(seconds: timeoutSeconds)
            }

            let result = try await group.next()
            group.cancelAll()

            guard let result else {
                throw CancellationError()
            }
            return result
        }
    }
}
