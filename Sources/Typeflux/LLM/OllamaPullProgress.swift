import Foundation

/// Receives the progress of an Ollama model pull. Called from any thread.
protocol OllamaPullProgressReporting: AnyObject, Sendable {
    /// `cancel` stops the pull; the pull then throws `CancellationError`.
    func pullStarted(model: String, cancel: @escaping @Sendable () -> Void)
    func pullProgressed(model: String, completed: Int64, total: Int64)
    /// `error` is nil on success.
    func pullFinished(model: String, error: Error?)
}

final class NoopOllamaPullProgressReporter: OllamaPullProgressReporting {
    static let shared = NoopOllamaPullProgressReporter()
    func pullStarted(model _: String, cancel _: @escaping @Sendable () -> Void) {}
    func pullProgressed(model _: String, completed _: Int64, total _: Int64) {}
    func pullFinished(model _: String, error _: Error?) {}
}

/// Adds up the newline-delimited JSON that `POST /api/pull` streams: one line per
/// status change, with byte counts for each layer being downloaded.
struct OllamaPullProgress: Equatable {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    private(set) var layers: [String: (completed: Int64, total: Int64)] = [:]
    private(set) var succeeded = false
    private(set) var status = ""

    var completed: Int64 { layers.values.reduce(0) { $0 + min($1.completed, $1.total) } }
    var total: Int64 { layers.values.reduce(0) { $0 + $1.total } }

    /// Applies one line. Returns true when the byte counts changed; throws the
    /// error the server reported.
    @discardableResult
    mutating func apply(line: String) throws -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let event = try JSONDecoder().decode(Event.self, from: data)
        if let error = event.error { throw Failure(message: error) }
        if let status = event.status {
            self.status = status
            if status == "success" { succeeded = true }
        }
        guard let digest = event.digest, let total = event.total, total > 0 else { return false }
        let next = (completed: max(0, event.completed ?? 0), total: total)
        if let current = layers[digest], current == next { return false }
        layers[digest] = next
        return true
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.succeeded == rhs.succeeded && lhs.status == rhs.status && lhs.completed == rhs.completed
            && lhs.total == rhs.total
    }

    private struct Event: Decodable {
        var status: String?
        var digest: String?
        var total: Int64?
        var completed: Int64?
        var error: String?
    }
}
