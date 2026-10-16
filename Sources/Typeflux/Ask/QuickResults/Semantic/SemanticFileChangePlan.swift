import Foundation

/// Converts raw recursive FSEvents into work that can affect the content index.
struct SemanticFileChangePlan: Equatable {
    var files = Set<String>()
    var directories = Set<String>()
    var fullScan = false

    static func make(_ changes: [AskFileChange], scope: AskFileScope, indexDirectory: String) -> Self {
        var plan = Self()
        for change in changes {
            let path = AskFileScope.normalize(change.path)
            guard path.hasPrefix("/") else { continue }
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
                if scope.includes(path, isDirectory: false) { plan.files.insert(path) }
                continue
            }
        }
        if plan.fullScan { plan.files.removeAll(); plan.directories.removeAll() }
        return plan
    }
}
