import Foundation
@testable import Typeflux

/// Synthetic text only. Keep the production worker, budget, ownership and pinned helper unchanged.
final class StartupTrace: @unchecked Sendable {
    let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let output: URL
    init(_ output: URL) { self.output = output }
    func event(_ stage: String, _ fields: [String: Any] = [:]) {
        lock.withLock {
            var row = fields
            row["stage"] = stage
            row["seconds"] = ProcessInfo.processInfo.systemUptime - start
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
        }
    }
    func budget(_ budget: SemanticWorkBudget, stage: String) {
        let stats = budget.statistics
        event(stage, ["yields": stats.yields, "yield_milliseconds": stats.milliseconds,
                      "interruptions": stats.interruptions])
    }
}

@main
struct StartupProbe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let trace = StartupTrace(URL(fileURLWithPath: env["GUL405_TRACE"]!))
        let model = URL(fileURLWithPath: env["GUL405_MODEL"]!)
        let helper = URL(fileURLWithPath: env["GUL405_HELPER"]!)
        // Reserve time for cancellation and collection inside the runner's 60 s observation bound.
        let cutoff = trace.start + 50
        let ownership = SemanticEmbeddingOwnership()
        let budget = SemanticWorkBudget(enabled: true, onWaiting: { value in
            trace.event("budget-waiting", ["reason": value?.rawValue as Any? ?? NSNull()])
        })
        let monitor = Task.detached {
            while !Task.isCancelled {
                trace.budget(budget, stage: "budget-snapshot")
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        trace.event("operation-begin")
        let result: Result<[[Float]], Error> = await Task.detached(priority: .utility) {
            Result {
                try budget.perform(cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff }) {
                    trace.event("model-verify-begin")
                    try SemanticModel.verify(model, cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff })
                    trace.event("model-verify-end")
                    let worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true,
                        ownership: ownership)
                    defer { worker.release(); trace.event("worker-release-returned") }
                    trace.budget(budget, stage: "text-request")
                    let vectors = try worker.embed(["task: search result | query: warmup"],
                        cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff })
                    trace.event("text-response", ["dimensions": vectors.map(\.count),
                        "valid": vectors.allSatisfy(SemanticFileStore.valid)])
                    return vectors
                }
            }
        }.value
        trace.budget(budget, stage: "operation-returned")
        monitor.cancel()
        await monitor.value
        // release() schedules collection; wait for the exact native lineage before reporting cleanup.
        await ownership.native.waitUntilRetired()
        trace.event("ownership-retired", ["occupied": ownership.native.isOccupied])
        var report: [String: Any] = ["budget_enabled": true, "request_bound_seconds": 50,
            "wall_seconds": ProcessInfo.processInfo.systemUptime - trace.start,
            "ownership_retired": !ownership.native.isOccupied]
        switch result {
        case let .success(vectors):
            report["dimensions"] = vectors.map(\.count)
            report["valid"] = vectors.allSatisfy(SemanticFileStore.valid)
            report["complete"] = vectors.count == 1 && vectors.allSatisfy(SemanticFileStore.valid)
        case let .failure(error):
            report["error"] = String(describing: error)
            report["complete"] = false
        }
        let stats = budget.statistics
        report["yields"] = stats.yields
        report["yield_milliseconds"] = stats.milliseconds
        report["interruptions"] = stats.interruptions
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: env["GUL405_REPORT"]!), options: .atomic)
        if report["complete"] as? Bool != true { exit(1) }
    }
}
