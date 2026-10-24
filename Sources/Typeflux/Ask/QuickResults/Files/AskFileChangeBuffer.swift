import Foundation

/// FSEvents history can arrive as thousands of small callbacks. Filter before
/// scheduling index work, merge repeated paths, and keep the pending set bounded.
final class AskFileChangeBuffer: @unchecked Sendable {
    struct Batch {
        let changes: [AskFileChange]
        let lastEventID: UInt64
    }

    private let scope: AskFileScope
    private let maximumPaths: Int
    private let lock = NSLock()
    private var changes: [String: AskFileChange] = [:]
    private var order: [String] = []
    private var rescanRoots = Set<String>()
    private var lastEventID: UInt64 = 0
    private var scheduled = false

    init(scope: AskFileScope, maximumPaths: Int = 4096) {
        self.scope = scope
        self.maximumPaths = max(1, maximumPaths)
    }

    /// True only when the caller needs to schedule a drain. Empty, excluded-only
    /// batches still advance the cursor without starting a reader or publishing.
    func append(_ incoming: [AskFileChange], lastEventID: UInt64) -> Bool {
        let relevant = incoming.compactMap { change -> AskFileChange? in
            var change = change
            while change.path.count > 1, change.path.hasSuffix("/") { change.path.removeLast() }
            // A newly excluded kind can replace an indexed old kind at this
            // path. Keep either-kind candidates so reconciliation removes it.
            let directory = change.isDirectory ?? false
            let included = scope.includes(change.path, isDirectory: directory)
                || scope.includes(change.path, isDirectory: !directory)
            return included ? change : nil
        }
        return lock.withLock {
            self.lastEventID = max(self.lastEventID, lastEventID)
            for change in relevant {
                guard let root = scope.root(of: change.path), !rescanRoots.contains(root) else { continue }
                if var existing = changes[change.path] {
                    existing.rescan = existing.rescan || change.rescan
                    existing.structureChanged = existing.structureChanged || change.structureChanged
                    existing.renamed = existing.renamed || change.renamed
                    // The final metadata read decides the current kind. A directory
                    // replaced at the same path must reconcile its old children.
                    if existing.isDirectory == true || change.isDirectory == true { existing.isDirectory = true }
                    else { existing.isDirectory = change.isDirectory ?? existing.isDirectory }
                    changes[change.path] = existing
                } else {
                    changes[change.path] = change
                    order.append(change.path)
                }
                if changes.count > maximumPaths {
                    rescanRoots.formUnion(changes.keys.compactMap { scope.root(of: $0) })
                    changes.removeAll(keepingCapacity: true)
                    order.removeAll(keepingCapacity: true)
                }
            }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }

    func take() -> Batch? {
        lock.withLock {
            guard scheduled else { return nil }
            defer {
                changes.removeAll(keepingCapacity: true)
                order.removeAll(keepingCapacity: true)
                rescanRoots.removeAll(keepingCapacity: true)
                scheduled = false
            }
            var pending = order.compactMap { changes[$0] }
            pending = pending.map { change in
                var change = change
                if change.isDirectory == true, change.structureChanged { change.rescan = true }
                return change
            }
            let rescans = Set(pending.filter(\.rescan).map(\.path)).union(rescanRoots)
            pending.removeAll { change in
                guard let root = scope.root(of: change.path) else { return true }
                if rescanRoots.contains(root) { return true }
                if change.path == root { return false }
                var parent = (change.path as NSString).deletingLastPathComponent
                while AskFileScope.isInside(parent, root) {
                    if rescans.contains(parent) { return true }
                    if parent == root { break }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return false
            }
            pending.append(contentsOf: rescanRoots.sorted().map {
                AskFileChange(path: $0, rescan: true, isDirectory: true)
            })
            return Batch(changes: pending, lastEventID: lastEventID)
        }
    }
}
