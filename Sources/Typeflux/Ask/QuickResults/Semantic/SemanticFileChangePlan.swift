import Foundation

/// Converts raw recursive FSEvents into work that can affect the content index.
struct SemanticFileChangePlan: Equatable, Sendable {
    var files = Set<String>()
    var directories = Set<String>()
    var fullScan = false
    var subtrees: Set<String> {
        get { directories }
        set { directories = newValue }
    }

    // Bounds retained handoff state, not the caller's input array or the index queue.
    static let handoffPaths = 512
    static let handoffBytes = 128 * 1024

    mutating func mergeForHandoff(_ other: Self) {
        guard !fullScan else { return }
        if other.fullScan { requireFullScan(); return }
        var bytes = files.reduce(0) { $0 + $1.utf8.count } + directories.reduce(0) { $0 + $1.utf8.count }
        for (paths, directory) in [(other.files, false), (other.directories, true)] {
            for path in paths {
                if directory ? directories.contains(path) : files.contains(path) { continue }
                let size = path.utf8.count
                guard files.count + directories.count < Self.handoffPaths,
                      size <= Self.handoffBytes - bytes else { requireFullScan(); return }
                if directory { directories.insert(path) } else { files.insert(path) }
                bytes += size
            }
        }
    }

    private mutating func requireFullScan() {
        fullScan = true; files.removeAll(); directories.removeAll()
    }

    static func make(_ changes: [AskFileChange], scope: AskFileScope, indexDirectory: String) -> Self {
        var plan = Self()
        for change in changes {
            let path = AskFileScope.normalize(change.path)
            guard path.hasPrefix("/") else { continue }
            let sharedRoot = path == indexDirectory && scope.roots.contains(path)
                && !AskFileScope.isInside(path, SemanticModel.directory.path)
            guard sharedRoot || !SemanticFilePolicy.isIndexArtifact(path, directory: indexDirectory) else { continue }
            let included = scope.includes(path, isDirectory: change.isDirectory == true)
            let inScope = included || scope.roots.contains(where: { AskFileScope.isInside($0, path) })
            guard inScope else { continue }
            if !scope.roots.contains(indexDirectory), AskFileScope.isInside(path, indexDirectory) { continue }

            if change.rescan {
                // The database and model live inside a watched home folder, but cannot change search results.
                if change.isDirectory != true, included, SemanticFilePolicy.allows(path) {
                    plan.files.insert(path)
                } else if included { plan.directories.insert(path) }
                else { plan.fullScan = true }
                continue
            }
            if change.renamed {
                let parent = (path as NSString).deletingLastPathComponent
                if scope.includes(parent, isDirectory: true) { plan.directories.insert(parent) }
                else { plan.fullScan = true }
                continue
            }
            if change.isDirectory == true && change.structureChanged {
                if included { plan.directories.insert(path) } else { plan.fullScan = true }
                continue
            }
            if change.isDirectory == true { continue }
            if change.isDirectory == nil && change.structureChanged {
                let parent = (path as NSString).deletingLastPathComponent
                if scope.includes(parent, isDirectory: true) { plan.directories.insert(parent) }
                else { plan.fullScan = true }
                continue
            }
            if SemanticFilePolicy.allows(path) {
                if scope.includes(path, isDirectory: false) {
                    plan.files.insert(path)
                }
                continue
            }
        }
        if plan.fullScan { plan.files.removeAll(); plan.directories.removeAll() }
        return plan
    }
}
