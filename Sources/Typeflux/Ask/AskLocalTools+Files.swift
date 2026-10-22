import Foundation

extension AskLocalTools {
    /// Both raw read dispatch and approval dispatch share this cancellation owner.
    /// Always await the detached worker, including on cancellation, so cleanup finishes.
    func executeFiles(_ args: [String: Any], conversationId: String,
                      approved: AskExecutionTarget? = nil) async throws -> AskLocalToolOutput {
        try Task.checkCancellation()
        var files = fileTools(conversationId: conversationId)
        let selected = try AskFileAccess.location(args["path"] as? String ?? "", roots: files.roots)
        // Capture exactly one authoritative source; validation never switches to a new source.
        let grantCheck: AskFileGrantCheck
        if workspaceURL(conversationId: conversationId)
            .map({ AskProjectFileAccess.normalizedRoot($0.path) }) == selected.root {
            grantCheck = .workspace(selected.root)
        } else if settings?.askFileAccessFolders.map(AskProjectFileAccess.normalizedRoot)
            .contains(selected.root) == true,
            let defaults = settings?.defaults {
            grantCheck = .settings(defaults, selected.root)
        } else if let scope = executionFolderScope(conversationId) {
            grantCheck = try .temporary(folderGrants, folderGrants.capture(selected.root, executionScope: scope))
        } else {
            throw AskFileAccess.denied
        }
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
                guard Self.fileApprovalTarget(path) == approved else {
                    throw AskToolPreparationFailure(AskFileAccess.conflict)
                }
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

/// Immutable source selection; detached workers use only thread-safe validation.
private enum AskFileGrantCheck: @unchecked Sendable {
    case workspace(String)
    case settings(UserDefaults, String)
    case temporary(AskFolderGrants, AskFolderGrants.GrantLease)

    func validate() throws {
        switch self {
        case .workspace: break // The descriptor worker independently pins and reopens this root.
        case let .settings(defaults, root):
            guard (defaults.stringArray(forKey: "ask.fileAccessFolders") ?? [])
                .map(AskProjectFileAccess.normalizedRoot).contains(root) else { throw AskFileAccess.denied }
        case let .temporary(store, lease): try store.validate(lease)
        }
    }
}
