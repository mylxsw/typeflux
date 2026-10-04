import Darwin
import Foundation

/// A separate atomic journal prevents stale conversation saves from discarding
/// late usage. The advisory file lock also serializes two engine instances.
struct AskBudgetStore: Sendable {
    var directory: URL

    func update(conversation: String, root: String, initial: AskBudgetController? = nil,
                _ change: (inout AskBudgetController) throws -> Void) throws -> AskBudgetController {
        guard AskLocalEngine.validID(conversation), AskLocalEngine.validID(root) else { throw AskBudgetError.invalid }
        let folder = directory.appendingPathComponent("Budgets").appendingPathComponent(conversation)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent(root + ".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw AskBudgetError.invalid }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw AskBudgetError.invalid }
        defer { flock(lock, LOCK_UN) }
        let file = folder.appendingPathComponent(root + ".json")
        var value: AskBudgetController
        if FileManager.default.fileExists(atPath: file.path) {
            value = try AskCoding.decoder().decode(AskBudgetController.self, from: Data(contentsOf: file))
        } else if let initial {
            value = initial
        } else {
            throw AskBudgetError.missing
        }
        guard value.valid, value.runId == root else { throw AskBudgetError.invalid }
        var failure: Error?
        do { try change(&value) } catch { failure = error }
        guard value.valid else { throw AskBudgetError.invalid }
        // A reached-budget reason is durable even though the dispatch was denied.
        try AskCoding.encoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
        if let failure {
            throw failure
        }
        return value
    }
}
