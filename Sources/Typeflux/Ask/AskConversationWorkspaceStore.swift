import Foundation

/// Local files owned by a conversation. Ordinary chats retain their workspace.
actor AskConversationWorkspaceStore {
    struct FileRecord: Codable, Equatable {
        var path: String?
        var source: String
        var messageId: String?
        var originalPath: String?
        var byteSize: Int?
    }

    static let shared = AskConversationWorkspaceStore()

    nonisolated let rootURL: URL
    private var discardedConversations: Set<String> = []
    init(rootURL: URL = TypefluxDataDirectories.workspaces) {
        self.rootURL = rootURL
    }

    nonisolated func url(owner: String, conversationId: String) -> URL {
        let ownerKey = String(AskToolPolicy.digest(owner).dropFirst(7).prefix(16))
        let conversationKey = Self.conversationName(conversationId)
        return rootURL
            .appendingPathComponent(ownerKey, isDirectory: true)
            .appendingPathComponent(conversationKey, isDirectory: true)
    }

    @discardableResult
    func ensure(owner: String, conversationId: String) throws -> URL {
        guard !discardedConversations.contains(owner + "\0" + conversationId) else { throw CancellationError() }
        let root = try AskSecureDirectory.openRoot(rootURL, privateRoot: false)
        let ownerKey = String(AskToolPolicy.digest(owner).dropFirst(7).prefix(16))
        let conversationKey = Self.conversationName(conversationId)
        let account = try root.child(ownerKey, create: true, privateDirectory: true)
        let chat = try account.child(conversationKey, create: true, privateDirectory: true)
        for name in ["inputs", "work", "outputs", ".typeflux"] {
            _ = try chat.child(name, create: true, privateDirectory: true)
        }
        _ = try chat.child(".typeflux").child("tmp", create: true, privateDirectory: true)
        return try chat.url
    }

    /// Remove only this conversation's directory. Mark it first so in-flight work
    /// cannot recreate it after cleanup. Never follows links inside the workspace.
    func discard(owner: String, conversationId: String) throws {
        discardedConversations.insert(owner + "\0" + conversationId)
        let directory = url(owner: owner, conversationId: conversationId)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false, privateRoot: false)
        let ownerKey = String(AskToolPolicy.digest(owner).dropFirst(7).prefix(16))
        let account = try root.child(ownerKey, privateDirectory: true)
        try account.remove(Self.conversationName(conversationId))
    }

    /// Save original file bytes before dispatching the question. The local source
    /// path is never sent to a model or cloud service.
    func captureInputs(_ attachments: [AskAttachment], image: String?, messageId: String,
                       owner: String, conversationId: String) throws {
        let root = try ensure(owner: owner, conversationId: conversationId)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let prefix = String(AskToolPolicy.digest(messageId).dropFirst(7).prefix(16))
        var records: [FileRecord] = []
        for attachment in attachments where attachment.kind != .folder {
            let name: String = if let source = attachment.localSourcePath {
                safeName(URL(fileURLWithPath: source).lastPathComponent)
            } else if attachment.image != nil {
                safeName(attachment.name) + ".jpg"
            } else {
                safeName(attachment.name) + ".txt"
            }
            let kind = attachment.localSourcePath != nil ? "user_original"
                : attachment.image != nil ? "processed_image" : "extracted_text"
            let key = String(AskToolPolicy.digest(attachment.localSourcePath ?? attachment.id).dropFirst(7).prefix(16))
            let destination = inputs.appendingPathComponent(prefix + "-" + key + "-" + name)
            if FileManager.default.fileExists(atPath: destination.path) {
                records.append(.init(path: "inputs/" + destination.lastPathComponent, source: kind,
                                     messageId: messageId, originalPath: attachment.localSourcePath,
                                     byteSize: (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize))
                continue
            }
            if let source = attachment.localSourcePath {
                let sourceURL = URL(fileURLWithPath: source)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { throw CocoaError(.fileNoSuchFile) }
                let bytes = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                guard bytes.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                try bytes.write(to: destination, options: .atomic)
            } else if let image = attachment.image, let bytes = Self.dataURLBytes(image) {
                try bytes.write(to: destination, options: .atomic)
            } else if let text = attachment.text {
                try Data(text.utf8).write(to: destination, options: .atomic)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                records.append(.init(path: "inputs/" + destination.lastPathComponent, source: kind,
                                     messageId: messageId, originalPath: attachment.localSourcePath,
                                     byteSize: (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize))
            }
        }
        for attachment in attachments where attachment.kind == .folder {
            records.append(.init(path: nil, source: "external_folder", messageId: messageId,
                                 originalPath: attachment.path, byteSize: nil))
        }
        if let image, let bytes = Self.dataURLBytes(image) {
            let destination = inputs.appendingPathComponent(prefix + "-screenshot.jpg")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try bytes.write(to: destination, options: .atomic)
            }
            records.append(.init(path: "inputs/" + destination.lastPathComponent, source: "screenshot",
                                 messageId: messageId, originalPath: nil, byteSize: bytes.count))
        }
        try appendRecords(records, root: root)
    }

    func saveOutput(_ data: Data, name: String, owner: String, conversationId: String) throws -> URL {
        let root = try ensure(owner: owner, conversationId: conversationId)
        let output = root.appendingPathComponent("outputs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased() + "-" + safeName(name))
        try data.write(to: output, options: .atomic)
        try appendRecords([.init(path: "outputs/" + output.lastPathComponent, source: "generated",
                                 messageId: nil, originalPath: nil, byteSize: data.count)], root: root)
        return output
    }

    func saveConversation(_ conversation: AskConversation, owner: String) throws {
        let root = try ensure(owner: owner, conversationId: conversation.id)
        let destination = root.appendingPathComponent(".typeflux/conversation.json")
        if FileManager.default.fileExists(atPath: destination.path),
           let previous = try? AskCoding.decoder().decode(AskConversation.self, from: Data(contentsOf: destination)),
           previous.revision > conversation.revision ||
           (previous.revision == conversation.revision && previous.updatedAt > conversation.updatedAt) ||
           (previous.revision == conversation.revision && previous.updatedAt == conversation.updatedAt &&
            previous.messages.count > conversation.messages.count) {
            return
        }
        try AskCoding.encoder().encode(conversation).write(to: destination, options: .atomic)
    }

    private func safeName(_ raw: String) -> String {
        let name = URL(fileURLWithPath: raw).lastPathComponent
        let cleaned = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "/" ? "_" : String($0) }.joined()
        return String(cleaned.prefix(100)).isEmpty ? "file" : String(cleaned.prefix(100))
    }

    private nonisolated static func conversationName(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString.lowercased()
            ?? String(AskToolPolicy.digest(id.lowercased()).dropFirst(7))
    }

    private static func dataURLBytes(_ raw: String) -> Data? {
        guard raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ","),
              raw[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(raw[raw.index(after: comma)...]))
    }

    private func appendRecords(_ incoming: [FileRecord], root: URL) throws {
        guard !incoming.isEmpty else { return }
        let file = root.appendingPathComponent(".typeflux/files.json")
        var records: [FileRecord] = if FileManager.default.fileExists(atPath: file.path) {
            try JSONDecoder().decode([FileRecord].self, from: Data(contentsOf: file))
        } else { [] }
        for record in incoming where !records.contains(record) { records.append(record) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
    }
}
