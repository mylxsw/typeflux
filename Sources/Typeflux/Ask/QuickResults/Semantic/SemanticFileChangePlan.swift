import Foundation

/// Converts raw recursive FSEvents into work that can affect the content index.
struct SemanticFileChangePlan: Equatable {
    var files = Set<String>()
    var subtrees = Set<String>()

    // Keep resource ownership, cancellation and state checks in one operation.
    // swiftlint:disable:next cyclomatic_complexity
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

            if change.rescan || (change.isDirectory == true && change.structureChanged) {
                // The database and model live inside a watched home folder, but cannot change search results.
                for root in scope.roots {
                    if AskFileScope.isInside(path, root) {
                        plan.subtrees.insert(path)
                    } else if AskFileScope.isInside(root, path) {
                        plan.subtrees.insert(root)
                    }
                }
                continue
            }
            if change.isDirectory == true {
                continue
            }
            if SemanticFilePolicy.allows(path) {
                if scope.includes(path, isDirectory: false) {
                    plan.files.insert(path)
                }
                continue
            }
            // Unknown structural events may describe a removed directory; recheck its subtree.
            if change.isDirectory == nil, change.structureChanged,
               !AskFileScope.isInside(path, indexDirectory) {
                for root in scope.roots {
                    if AskFileScope.isInside(path, root) {
                        plan.subtrees.insert(path)
                    } else if AskFileScope.isInside(root, path) {
                        plan.subtrees.insert(root)
                    }
                }
            }
        }
        var roots: [String] = []
        for path in plan.subtrees.sorted() where !roots.contains(where: { AskFileScope.isInside(path, $0) }) {
            roots.append(path)
        }
        plan.subtrees = Set(roots)
        plan.files = plan.files.filter { path in !roots.contains(where: { AskFileScope.isInside(path, $0) }) }
        return plan
    }
}
