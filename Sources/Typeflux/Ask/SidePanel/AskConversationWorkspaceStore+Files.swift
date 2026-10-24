import Foundation

extension AskConversationWorkspaceStore {
    /// A huge `work/` folder must not stall the panel; the newest files are rarely the ones cut.
    static let listedFileLimit = 2000
    static let addedFileLimit = 64 * 1024 * 1024

    /// The conversation's files under `inputs/`, `outputs/` and `work/`, with the message
    /// each was recorded with in `.typeflux/files.json`. Links and hidden files are skipped,
    /// and a workspace that does not exist yet has no files.
    func listFiles(owner: String, conversationId: String) throws -> [AskWorkspaceFile] {
        let root = url(owner: owner, conversationId: conversationId)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let messages = Self.recordedMessages(root: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey]
        var files: [AskWorkspaceFile] = []
        for folder in ["inputs", "outputs", "work"] {
            guard let origin = AskWorkspaceFile.Origin.folder(folder) else { continue }
            let base = root.appendingPathComponent(folder, isDirectory: true)
            // Never list through a linked folder: its files are outside the workspace.
            guard let values = try? base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(
                      at: base, includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }
            let depth = base.pathComponents.count
            for case let url as URL in enumerator {
                guard files.count < Self.listedFileLimit else { return files }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                let relative = ([folder] + url.pathComponents.dropFirst(depth)).joined(separator: "/")
                files.append(AskWorkspaceFile(relativePath: relative, size: Int64(values.fileSize ?? 0),
                                              modifiedAt: values.contentModificationDate ?? .distantPast,
                                              origin: origin, messageId: messages[relative]))
            }
        }
        return files
    }

    /// Copies files the user picks into `inputs/`. They belong to no message.
    @discardableResult
    func addFiles(_ sources: [URL], owner: String, conversationId: String) throws -> [String] {
        let root = try ensure(owner: owner, conversationId: conversationId)
        let inputs = try AskSecureDirectory.openRoot(root).child("inputs", create: true, privateDirectory: true).url
        // Check every file before copying any, so a folder or an oversized file in a drop
        // never leaves earlier copies behind without records.
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { throw CocoaError(.fileNoSuchFile) }
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= Self.addedFileLimit else { throw CocoaError(.fileReadTooLarge) }
        }
        var added: [FileRecord] = []
        do {
            for source in sources {
                let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
                guard bytes.count <= Self.addedFileLimit else { throw CocoaError(.fileReadTooLarge) }
                let prefix = String(AskToolPolicy.digest(UUID().uuidString).dropFirst(7).prefix(16))
                let key = String(AskToolPolicy.digest(source.path).dropFirst(7).prefix(16))
                let name = prefix + "-" + key + "-" + Self.addedName(source.lastPathComponent)
                try bytes.write(to: inputs.appendingPathComponent(name), options: .withoutOverwriting)
                added.append(.init(path: "inputs/" + name, source: "user_added", messageId: nil,
                                   originalPath: source.path, byteSize: bytes.count))
            }
        } catch {
            // Files copied before the failure stay listed with their records.
            try? appendRecords(added, root: root)
            throw error
        }
        try appendRecords(added, root: root)
        return added.compactMap(\.path)
    }

    private static func addedName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || $0 == "/" ? "_" : String($0) }.joined()
        let name = String(cleaned.prefix(100))
        return name.isEmpty || name == "." || name == ".." ? "file" : name
    }

    /// The first message recorded for each path.
    private static func recordedMessages(root: URL) -> [String: String] {
        let file = root.appendingPathComponent(".typeflux/files.json")
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([FileRecord].self, from: data) else { return [:] }
        var messages: [String: String] = [:]
        for record in records {
            guard let path = record.path, let message = record.messageId, messages[path] == nil else { continue }
            messages[path] = message
        }
        return messages
    }
}

extension AskConversationWorkspaceStore {
    /// Records the files a run added or modified with the run's answer, so the answer can
    /// list them again after the conversation is reloaded.
    func recordChanges(_ changes: [AskWorkspaceFileChange], messageId: String, owner: String,
                       conversationId: String) throws {
        guard !changes.isEmpty else { return }
        let root = try ensure(owner: owner, conversationId: conversationId)
        try appendRecords(changes.map { change in
            FileRecord(path: change.path, source: "run_change", messageId: messageId, originalPath: nil,
                       byteSize: nil, change: change.kind.rawValue,
                       writes: change.writes > 0 ? change.writes : nil,
                       edits: change.edits > 0 ? change.edits : nil)
        }, root: root)
    }

    /// Each answer's recorded file changes, keyed by message id and ordered by path. Records
    /// without a change (older ones, uploads, saved outputs) are not changes.
    nonisolated func listChanges(owner: String, conversationId: String) -> [String: [AskWorkspaceFileChange]] {
        let file = url(owner: owner, conversationId: conversationId).appendingPathComponent(".typeflux/files.json")
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return Self.changes(in: data)
    }

    nonisolated static func changes(in data: Data) -> [String: [AskWorkspaceFileChange]] {
        guard let records = try? JSONDecoder().decode([FileRecord].self, from: data) else { return [:] }
        var byMessage: [String: [String: AskWorkspaceFileChange]] = [:]
        for record in records {
            guard let path = record.path, let messageId = record.messageId,
                  let kind = record.change.flatMap(AskWorkspaceFileChange.Kind.init(rawValue:)) else { continue }
            byMessage[messageId, default: [:]][path] = AskWorkspaceFileChange(
                path: path, kind: kind, writes: record.writes ?? 0, edits: record.edits ?? 0)
        }
        return byMessage.mapValues { $0.values.sorted { $0.path < $1.path } }
    }
}
