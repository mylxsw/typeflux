import Foundation

extension AskLocalTools {
    /// Both raw read dispatch and approval dispatch share this cancellation owner.
    /// Always await the detached worker, including on cancellation, so cleanup finishes.
    func executeFiles(_ args: [String: Any], conversationId: String,
                      approved: AskExecutionTarget? = nil) async throws -> AskLocalToolOutput {
        try Task.checkCancellation()
        var files = fileTools(conversationId: conversationId)
        let selected = try AskFileAccess.location(args["path"] as? String ?? "", roots: files.roots)
        let grantCheck = AskFileGrantCheck(
            workspace: workspaceURL(conversationId: conversationId)?.path,
            defaults: settings?.defaults, grants: folderGrants,
            conversationId: conversationId, root: selected.root
        )
        let cancellation = AskFileCancellation()
        files.cancellation = cancellation
        files.hooks = fileOperationHooks
        let injectedCheck = files.hooks.validateGrant
        files.hooks.validateGrant = {
            try injectedCheck?()
            try grantCheck.validate()
        }
        let worker = Task.detached(priority: .userInitiated) { [files] in
            try Task.checkCancellation()
            if let approved {
                let path = try files.resolve(
                    args["path"] as? String ?? "",
                    forWriting: args["action"] as? String == "write"
                ).path
                guard Self.fileApprovalTarget(path) == approved else { throw AskFileAccess.conflict }
            }
            return try AskLocalToolOutput(content: files.execute(args))
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            cancellation.cancel()
        }
    }
}

/// UserDefaults supports concurrent reads/writes; AskFolderGrants has its own
/// lock. Only those thread-safe operations cross into the descriptor worker.
private struct AskFileGrantCheck: @unchecked Sendable {
    let workspace: String?
    let defaults: UserDefaults?
    let grants: AskFolderGrants
    let conversationId: String
    let root: String

    func validate() throws {
        let current = (workspace.map { [$0] } ?? []) +
            (defaults?.stringArray(forKey: "ask.fileAccessFolders") ?? []) + grants.folders(for: conversationId)
        guard current.map(AskProjectFileAccess.normalizedRoot).contains(root) else { throw AskFileAccess.denied }
    }
}
