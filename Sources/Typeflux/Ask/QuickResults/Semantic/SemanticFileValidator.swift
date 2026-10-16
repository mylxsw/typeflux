import Foundation

/// Reuse a private metadata helper. Every publication checks permissions again; no permission cache is kept.
final class SemanticFileValidator: @unchecked Sendable {
    private let lock = NSLock()
    private let preparationLock = NSLock()
    private var preparation: AskSearchCancellation?
    private var validations = 0
    private let reader: any AskFileReading
    private var warm = false
    private let budget: TimeInterval
    private let startupBudget: TimeInterval

    init(reader: any AskFileReading, budget: TimeInterval = 0.08, startupBudget: TimeInterval = 3) {
        self.reader = reader; self.budget = budget; self.startupBudget = startupBudget
    }

    func warm(scope: AskFileScope, cancelled: @escaping () -> Bool) throws {
        guard let root = scope.roots.first, !cancelled() else { return }
        let token = preparationLock.withLock { () -> AskSearchCancellation? in
            guard validations == 0, preparation == nil else { return nil }
            let token = AskSearchCancellation(); preparation = token; return token
        }
        guard let token else { return }
        defer { preparationLock.withLock { preparation = nil } }
        // Preparation never queues behind an interactive request. A new validation cancels it
        // before waiting for the helper lock, including slow/network root resolution.
        guard lock.try() else { return }
        defer { lock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + startupBudget
        let stopped = { cancelled() || token.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
        guard !stopped() else { return }
        do {
            let response = try reader.read(
                .init(operation: .resolve, path: root, blocked: scope.blocked),
                isCancelled: stopped
            )
            warm = !stopped() && response.error == nil
        } catch {
            warm = false
            throw error
        }
    }

    struct Result {
        var hits: [AskFileHit]
        var complete: Bool
    }

    func validate(_ hits: [AskFileHit], scope: AskFileScope, limit: Int,
                  cancelled: @escaping () -> Bool) -> [AskFileHit] {
        validateBatch(hits, scope: scope, limit: limit, cancelled: cancelled).hits
    }

    /// A slow file cannot multiply a per-file I/O timeout by TopK. The helper polls cancellation at 50 ms;
    /// on a deadline it is disposed, unvalidated files are withheld, and the caller reports degraded results.
    func validateBatch(_ hits: [AskFileHit], scope: AskFileScope, limit: Int,
                       cancelled: @escaping () -> Bool) -> Result {
        let waiting = ProcessInfo.processInfo.systemUptime
        preparationLock.withLock { validations += 1; preparation?.cancel() }
        defer { preparationLock.withLock { validations -= 1 } }
        return lock.withLock {
            SemanticSearchTrace.current?.measure("metadata-lock-wait",
                                                 milliseconds: (ProcessInfo.processInfo.systemUptime - waiting) * 1000)
            guard limit > 0 else { return Result(hits: [], complete: true) }
            let deadline = ProcessInfo.processInfo.systemUptime + (warm ? budget : startupBudget)
            let stopped = { cancelled() || ProcessInfo.processInfo.systemUptime >= deadline }
            var valid: [AskFileHit] = []
            for hit in hits {
                guard !stopped() else { return Result(hits: valid, complete: false) }
                guard scope.includes(hit.path, isDirectory: false),
                      SemanticFilePolicy.allows(hit.path) else { continue }
                do {
                    let response = try reader.read(
                        .init(operation: .content, path: hit.path, scope: scope, readText: false),
                        isCancelled: stopped
                    )
                    warm = true
                    guard !stopped(), response.error == nil, response.modified == hit.modified,
                          hit.evidence?.version == nil || hit.evidence?.version == response.version else { continue }
                    valid.append(hit)
                    if valid.count >= limit {
                        break
                    }
                } catch {
                    warm = false
                    if stopped() || (error as? AskFileReadError) == .unavailable ||
                        (error as? AskFileReadError) == .cancelled {
                        return Result(hits: valid, complete: false)
                    }
                }
            }
            return Result(hits: valid, complete: !stopped())
        }
    }
}
