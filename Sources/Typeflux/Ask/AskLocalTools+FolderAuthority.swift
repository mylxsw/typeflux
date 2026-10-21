import Foundation

extension AskLocalTools {
    var fileTools: AskFileTools { AskFileTools(roots: settings?.askFileAccessFolders ?? []) }

    /// Settings folders plus the folders attached to this conversation.
    func fileTools(conversationId: String?) -> AskFileTools {
        var roots = conversationId.flatMap { workspaceURL(conversationId: $0)?.path }.map { [$0] } ?? []
        roots.append(contentsOf: fileTools.roots.filter { !roots.contains($0) })
        let scope = conversationId.flatMap(executionFolderScope)
        for path in scope.map(folderGrants.roots(for:)) ?? [] where !roots.contains(path) {
            roots.append(path)
        }
        return AskFileTools(roots: roots)
    }

    /// Without host-command access, a browser preview must respect the same folder grants as `files`.
    func validateBrowserLocalFile(_ args: [String: Any], conversationId: String) throws {
        guard args["action"] as? String == "open_file" else { return }
        let url = try AskEmbeddedBrowserTool.validatedLocalHTML(args["path"])
        if settings?.askCodeExecutionEnabled != true {
            _ = try fileTools(conversationId: conversationId).resolve(url.path)
        }
    }

    func folderScope(_ conversationId: String, task: UUID? = nil, run: String? = nil) -> AskFolderGrants.Scope {
        folderGrants.scope(ownerId: owner(), deviceId: commandDeviceId, conversationId: conversationId,
                           taskIdentity: task, runId: run)
    }

    func stageFolders(_ paths: [String], lifetime: AskFolderGrants.Lifetime, ownerId: String,
                      deviceId: String, conversationId: String, messageID: String, generation: UUID) throws {
        guard ownerId == owner() else { throw AskFileAccess.denied }
        commandDeviceId = deviceId
        let scope = folderScope(conversationId, task: generation)
        // A new local submission replaces only this conversation's task grants.
        folderGrants.revokeTask(scope: folderScope(conversationId))
        folderExecutions[conversationId] = nil
        try folderGrants.stage(paths, lifetime: lifetime, submissionScope: scope, messageID: messageID)
        folderSubmissions[messageID] = scope
    }

    func admitFolders(messageID: String, conversationId: String, runId: String) throws {
        guard let scope = folderSubmissions[messageID], scope.ownerId == owner(),
              scope.conversationId == conversationId else { return }
        try folderGrants.bindSubmission(messageID: messageID, admittedRun: runId, trustedScope: scope)
        var execution = scope; execution.runId = runId
        folderExecutions[conversationId] = execution
        folderSubmissions[messageID] = nil
    }

    func discardFolderSubmission(messageID: String) {
        guard let scope = folderSubmissions.removeValue(forKey: messageID) else { return }
        folderGrants.revokeSubmission(messageID: messageID, scope: scope)
        folderGrants.revokeTask(scope: scope)
    }

    func temporaryFolders(conversationId: String) -> [AskFolderGrants.Grant] {
        folderGrants.list(scope: folderScope(conversationId))
    }

    func revokeFolder(_ id: UUID?, conversationId: String) {
        if let id {
            folderGrants.revoke(id, scope: folderScope(conversationId))
        } else {
            folderGrants.revokeConversation(scope: folderScope(conversationId))
        }
    }

    func revokeTaskFolders(conversationId: String, runId: String? = nil) {
        if let runId, folderExecutions[conversationId]?.runId != runId {
            return
        }
        folderGrants.revokeTask(scope: folderScope(conversationId))
        folderExecutions[conversationId] = nil
        for (messageID, scope) in folderSubmissions where scope.conversationId == conversationId {
            discardFolderSubmission(messageID: messageID)
        }
    }

    func resetFolderSession() {
        folderGrants.resetSession(); folderSubmissions = [:]; folderExecutions = [:]
    }

    func executionFolderScope(_ conversationId: String) -> AskFolderGrants.Scope? {
        guard let project = projectScopes[conversationId], project.ownerId == owner() else { return nil }
        if let admitted = folderExecutions[conversationId], admitted.ownerId == owner(),
           admitted.deviceId == commandDeviceId, admitted.runId == project.runId {
            return admitted
        }
        // A session grant can serve another admitted run; it cannot mint task authority.
        return folderScope(conversationId, run: project.runId)
    }

    func fileAuthorityRevision(path: String, conversationId: String) throws -> String {
        let root = try AskFileAccess.location(path, roots: fileTools(conversationId: conversationId).roots).root
        if workspaceURL(conversationId: conversationId).map({ AskProjectFileAccess.normalizedRoot($0.path) }) == root {
            return "workspace:" + root
        }
        if settings?.askFileAccessFolders.map(AskProjectFileAccess.normalizedRoot).contains(root) == true {
            return "settings:" + root
        }
        guard let scope = executionFolderScope(conversationId) else { throw AskFileAccess.denied }
        let lease = try folderGrants.capture(root, executionScope: scope)
        return "attachment:" + lease.grant.id.uuidString + ":" + lease.grant.revision.uuidString
    }

    func folderMetadataRoots(_ conversationId: String) -> [String] {
        // Pending local selections may describe tool capabilities, never executable roots.
        temporaryFolders(conversationId: conversationId).map(\.root)
    }
}
