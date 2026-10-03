import Foundation

extension AskLocalTools {
    static func projectDefinition(roots: [String]) throws -> AskToolDefinition {
        let schema: [String: Any] = [
            "type": "object", "required": ["action"], "additionalProperties": false,
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["open", "list", "read", "write", "edit", "review", "export", "revert"]
                ],
                "root": ["type": "string", "description": "open: one exact authorized folder"],
                "workspace_id": ["type": "string", "description": "ID returned by open for this run"],
                "path": ["type": "string", "description": "Relative path; list defaults to '.'"],
                "expected_version": [
                    "type": "string",
                    "description": "write/edit: version returned by read; revert: workspace.version"
                ],
                "content": ["type": "string"], "old_text": ["type": "string"], "new_text": ["type": "string"],
                "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1]
            ]
        ]
        return try .init(name: "project_files", description: """
        Open a task workspace after approval, then read, stage edits, review and export a unified patch.
        Source files (including existing dirty files) are preserved. Edits live in a private change manifest;
        this tool does not apply patches to the source or run programs. Every call requires approval.
        open returns workspace.id and workspace.version. read returns a file version (or 'missing' for a
        new file), numbered UTF-8 lines and nextOffset. write/edit require that exact expected_version.
        Source changes cause conflicts: revert discards only this run's staged edits, then read again.
        review/export show a diff card; the user exports the full patch with its Save button.
        revert requires workspace.version and discards ALL changes in this workspace. Files up to 16 MiB
        can be read; writes up to 1 MB, total captured changes up to 4 MiB. No .git paths or symlinks.
        Authorized roots: \(roots.joined(separator: ", "))
        """, parameters: JSONValue(data: JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func bindExecution(ownerId: String, conversationId: String, runId: String) {
        let next = AskProjectScope(ownerId: ownerId, conversationId: conversationId, runId: runId)
        if let previous = projectScopes[conversationId], previous != next { projectRuntime?.cancel(scope: previous) }
        projectScopes[conversationId] = next
    }

    func projectScope(_ conversationId: String) throws -> AskProjectScope {
        guard projectModeEnabled, let scope = projectScopes[conversationId] else { throw AskProjectError.unavailable }
        return scope
    }

    func projectBinding(_ args: [String: Any], conversationId: String) throws -> AskExecutionTarget {
        let scope = try projectScope(conversationId)
        let roots = fileTools(conversationId: conversationId).roots
        if args["action"] as? String == "open" {
            guard let root = args["root"] as? String else { throw AskProjectError.invalid }
            let (ref, identity) = try projects.reference(root: root, scope: scope, authorizedRoots: roots)
            return .init(
                kind: "workspace",
                id: ref.id,
                version: identity,
                path: AskProjectFileAccess.normalizedRoot(root)
            )
        }
        guard let id = args["workspace_id"] as? String else { throw AskProjectError.invalid }
        // A list target is a directory, not a file snapshot.
        let path = args["action"] as? String == "list" ? nil : args["path"] as? String
        return try projects.binding(id, path: path, scope: scope, authorizedRoots: roots)
    }

    private func projectOutput(_ value: some Encodable) throws -> AskLocalToolOutput {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let content = try String(data: encoder.encode(value), encoding: .utf8) else {
            throw AskProjectError.invalid
        }
        return .init(content: content, outcome: .init(status: "ok", effectVerified: true))
    }

    func executeProject(_ args: [String: Any], conversationId: String) throws -> AskLocalToolOutput {
        let scope = try projectScope(conversationId)
        let roots = fileTools(conversationId: conversationId).roots
        do {
            if args["action"] as? String == "open" {
                guard let root = args["root"] as? String else { throw AskProjectError.invalid }
                return try projectOutput(["workspace": projects.open(root: root, scope: scope, authorizedRoots: roots)])
            }
            return try projectAction(args, scope: scope, roots: roots)
        } catch let error as AskProjectError {
            return .init(content: error.localizedDescription, isError: true,
                         outcome: .init(status: error == .denied ? "denied" : "invalid", effectVerified: false))
        }
    }

    private func projectAction(_ args: [String: Any], scope: AskProjectScope,
                               roots: [String]) throws -> AskLocalToolOutput {
        guard let id = args["workspace_id"] as? String else { throw AskProjectError.invalid }
        switch args["action"] as? String {
        case "list":
            let entries = try projects.list(
                id,
                path: args["path"] as? String ?? ".",
                scope: scope,
                authorizedRoots: roots
            )
            return try projectOutput(AskProjectListing(
                entries: Array(entries.prefix(500)),
                truncated: entries.count > 500
            ))
        case "read":
            guard let path = args["path"] as? String else { throw AskProjectError.invalid }
            return try projectOutput(projects.read(id, path: path, offset: args["offset"] as? Int ?? 0,
                                                   limit: args["limit"] as? Int ?? 200, scope: scope,
                                                   authorizedRoots: roots))
        case "write", "edit": return try stageProjectEdit(args, id: id, scope: scope, roots: roots)
        case "review", "export": return try projectOutput(projects.review(id, scope: scope, authorizedRoots: roots))
        case "revert":
            guard let version = args["expected_version"] as? String else { throw AskProjectError.invalid }
            return try projectOutput(["workspace": projects.revert(id, expectedVersion: version,
                                                                   scope: scope, authorizedRoots: roots)])
        default: throw AskProjectError.invalid
        }
    }

    private func stageProjectEdit(_ args: [String: Any], id: String, scope: AskProjectScope,
                                  roots: [String]) throws -> AskLocalToolOutput {
        let isWrite = args["action"] as? String == "write"
        guard let path = args["path"] as? String, let version = args["expected_version"] as? String,
              !isWrite || args["content"] is String else { throw AskProjectError.invalid }
        let content = isWrite ? args["content"] as? String : nil
        let ref = try projects.write(id, path: path, expectedVersion: version, content: content,
                                     old: args["old_text"] as? String, new: args["new_text"] as? String,
                                     scope: scope, authorizedRoots: roots)
        return try projectOutput(["workspace": ref])
    }

    /// Explicit user export remains available when rollout is disabled. A DTO
    /// from history cannot authorize access: verify the caller and live roots.
    func exportProjectPatch(_ ref: AskWorkspaceRef, ownerId: String, conversationId: String) throws -> Data {
        guard ref.ownerId == ownerId, ref.conversationId == conversationId else { throw AskProjectError.denied }
        return try projects.export(
            ref,
            scope: .init(ownerId: ownerId, conversationId: conversationId, runId: ref.runId),
            authorizedRoots: fileTools(conversationId: conversationId).roots
        )
    }
}

struct AskProjectListing: Codable {
    var entries: [String]
    var truncated: Bool
}
