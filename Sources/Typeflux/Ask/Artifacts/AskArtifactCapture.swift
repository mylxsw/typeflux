import Foundation

/// An explicit resource manifest, not a recursive copy of a mutable directory.
/// Callers must supply every resource needed by the entry page. Missing resources
/// fail visibly in PreviewHost; list truncation can never silently publish a site.
struct AskArtifactCapture {
    let projects: AskProjectWorkspace
    let store: AskArtifactStore
    var beforeRevalidation: (() throws -> Void)?

    func capture(workspace: AskWorkspaceRef, entry: String, paths: [String], scope: AskProjectScope,
                 authorizedRoots: () -> [String]) throws -> AskArtifactRef {
        guard paths.contains(entry), !paths.isEmpty, paths.count <= AskArtifactStore.maximumFiles,
              Set(paths).count == paths.count else { throw AskArtifactError.invalid }
        for path in paths {
            try AskArtifactStore.validatePath(path)
        }
        // Only private bounded bytes leave the callback; no descriptor or source URL does.
        let files = try projects.withValidatedSnapshot(
            workspace, scope: scope, authorizedRoots: authorizedRoots()
        ) { state, access -> [String: Data] in
            var result: [String: Data] = [:], versions: [String: String] = [:], total = 0
            for path in paths {
                let snapshot = try access.snapshot(path)
                versions[path] = snapshot.version
                guard let data = state.entries.first(where: { $0.path == path })?.updated ?? snapshot.data else {
                    throw AskArtifactError.unavailable
                }
                guard data.count <= AskArtifactStore.maximumBundleBytes - total else { throw AskArtifactError.tooLarge }
                result[path] = data
                total += data.count
            }
            try beforeRevalidation?()
            for path in paths where try access.snapshot(path).version != versions[path] {
                throw AskProjectError.conflict
            }
            return result
        }
        // Recheck live grants and the manifest after the entire snapshot operation succeeds.
        try projects.withValidatedSnapshot(workspace, scope: scope, authorizedRoots: authorizedRoots()) { _, _ in }
        return try store.publish(files: files, entry: entry, scope: scope, workspace: workspace)
    }
}
