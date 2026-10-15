import Foundation

/// Converts raw recursive FSEvents into work that can affect the content index.
struct SemanticFileChangePlan: Equatable {
    var files = Set<String>()
    var fullScan = false

    static func make(_ changes: [AskFileChange], scope: AskFileScope, indexDirectory: String) -> Self {
        var plan = Self()
        for change in changes {
            let path = AskFileScope.normalize(change.path)
            guard path.hasPrefix("/") else { continue }
            let included = scope.includes(path, isDirectory: change.isDirectory == true)
            let inScope = included || scope.roots.contains(where: { AskFileScope.isInside($0, path) })
            guard inScope else { continue }

            if change.rescan || (change.isDirectory == true && change.structureChanged) {
                // The database and model live inside a watched home folder, but cannot change search results.
                if !AskFileScope.isInside(path, indexDirectory) { plan.fullScan = true }
                continue
            }
            if change.isDirectory == true { continue }
            if SemanticFilePolicy.allows(path) {
                if scope.includes(path, isDirectory: false) { plan.files.insert(path) }
                continue
            }
            // Unknown structural events may describe a removed directory; preserve correctness.
            if change.isDirectory == nil, change.structureChanged,
               !AskFileScope.isInside(path, indexDirectory) {
                plan.fullScan = true
            }
        }
        if plan.fullScan { plan.files.removeAll() }
        return plan
    }
}
