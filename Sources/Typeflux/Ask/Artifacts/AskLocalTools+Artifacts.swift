import Foundation

extension AskLocalTools {
    static var artifactDefinition: AskToolDefinition {
        let properties: [String: Any] = [
            "workspace_id": ["type": "string"],
            "expected_version": ["type": "string"],
            "entry": ["type": "string", "description": "Relative entry file, e.g. output/index.html"],
            "resources": ["type": "array", "minItems": 1, "maxItems": 128,
                          "items": ["type": "string"],
                          "description": "Complete explicit file list including entry; paths are workspace-relative"]
        ]
        return .init(name: "artifact", description: """
        After approval, preserve an immutable device-only artifact from a project workspace. Uses staged edits.
        Supply the current workspace version and EVERY required resource, including the entry. No directory
        traversal or automatic resource discovery. 128 files, 16 MiB each, 32 MiB total; retained for 30 days.
        HTML uses isolated offline preview; unsupported types remain downloadable. Never uploads files.
        Return the artifact ID to the user, never an internal path. Images and logs can be entry files.
        """, parameters: AskTypedContent.json([
            "type": "object", "properties": properties, "additionalProperties": false,
            "required": ["workspace_id", "expected_version", "entry", "resources"]
        ]))
    }

    func artifactWorkspace(_ args: [String: Any], conversationId: String) throws -> AskWorkspaceRef {
        guard artifactCreationEnabled else { throw AskArtifactError.unavailable }
        let scope = try projectScope(conversationId)
        guard let id = args["workspace_id"] as? String, let version = args["expected_version"] as? String else {
            throw AskArtifactError.invalid
        }
        return .init(id: id, ownerId: scope.ownerId, conversationId: scope.conversationId, runId: scope.runId,
                     version: version, cleanup: "user_managed")
    }

    func artifactBinding(_ args: [String: Any], conversationId: String) throws -> AskExecutionTarget {
        let ref = try artifactWorkspace(args, conversationId: conversationId)
        guard let paths = args["resources"] as? [String], let entry = args["entry"] as? String,
              paths.contains(entry), !paths.isEmpty, paths.count <= AskArtifactStore.maximumFiles else {
            throw AskArtifactError.invalid
        }
        let scope = try projectScope(conversationId)
        let roots = fileTools(conversationId: conversationId).roots
        let versions = try projects.withValidatedSnapshot(ref, scope: scope, authorizedRoots: roots) { _, access in
            try paths.map { path -> String in
                try AskArtifactStore.validatePath(path)
                return try path + ":" + access.snapshot(path).version
            }
        }
        return .init(kind: "workspace", id: ref.id,
                     version: AskToolPolicy.digest(ref.version + ":" + versions.joined(separator: "\n")))
    }

    func executeArtifact(_ args: [String: Any], conversationId: String) throws -> AskLocalToolOutput {
        let workspace = try artifactWorkspace(args, conversationId: conversationId)
        guard let entry = args["entry"] as? String, let paths = args["resources"] as? [String] else {
            throw AskArtifactError.invalid
        }
        try artifactStore.cleanupExpired()
        let ref = try AskArtifactCapture(projects: projects, store: artifactStore).capture(
            workspace: workspace, entry: entry, paths: paths, scope: projectScope(conversationId),
            authorizedRoots: { self.fileTools(conversationId: conversationId).roots }
        )
        let receipt = AskArtifactReceipt(artifact: ref, notice: "Device only; no upload. Retained for 30 days.")
        guard let text = try String(data: JSONEncoder().encode(receipt), encoding: .utf8) else {
            throw AskArtifactError.invalid
        }
        return .init(content: text, outcome: .init(status: "ok", content: [AskTypedContent.json([
            "type": "text", "text": text
        ])], artifacts: [ref], effectVerified: true))
    }

    func loadArtifact(_ ref: AskArtifactRef, ownerId: String, conversationId: String) throws -> AskArtifactBundle {
        try artifactStore.cleanupExpired()
        let scope = AskProjectScope(ownerId: ownerId, conversationId: conversationId, runId: ref.runId)
        return try artifactStore.load(ref, scope: scope) { workspace in
            // Retained copies survive later edits. Live root identity/ownership/grants remain required.
            _ = try self.projects.binding(workspace.id, path: nil, scope: scope,
                                          authorizedRoots: self.fileTools(conversationId: conversationId).roots)
        }
    }

    func validateArtifact(_ ref: AskArtifactRef, ownerId: String, conversationId: String) throws {
        let scope = AskProjectScope(ownerId: ownerId, conversationId: conversationId, runId: ref.runId)
        try artifactStore.validate(ref, scope: scope) { workspace in
            _ = try self.projects.binding(workspace.id, path: nil, scope: scope,
                                          authorizedRoots: self.fileTools(conversationId: conversationId).roots)
        }
    }
}

struct AskArtifactReceipt: Codable {
    var artifact: AskArtifactRef
    var notice: String
}
