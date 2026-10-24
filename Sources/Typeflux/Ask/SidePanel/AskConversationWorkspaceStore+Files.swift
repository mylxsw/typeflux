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
        var added: [FileRecord] = []
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { throw CocoaError(.fileNoSuchFile) }
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            guard bytes.count <= Self.addedFileLimit else { throw CocoaError(.fileReadTooLarge) }
            let prefix = String(AskToolPolicy.digest(UUID().uuidString).dropFirst(7).prefix(16))
            let key = String(AskToolPolicy.digest(source.path).dropFirst(7).prefix(16))
            let name = prefix + "-" + key + "-" + Self.addedName(source.lastPathComponent)
            try bytes.write(to: inputs.appendingPathComponent(name), options: .withoutOverwriting)
            added.append(.init(path: "inputs/" + name, source: "user_added", messageId: nil,
                               originalPath: source.path, byteSize: bytes.count))
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
