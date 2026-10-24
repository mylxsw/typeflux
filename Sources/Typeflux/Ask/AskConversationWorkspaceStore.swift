import Darwin
import Foundation

/// Local files owned by a conversation. Ordinary chats retain their workspace.
actor AskConversationWorkspaceStore {
    struct FileRecord: Codable, Equatable {
        var path: String?
        var source: String
        var messageId: String?
        var originalPath: String?
        var byteSize: Int?
        /// `added` or `modified` when a run changed the file; `messageId` is then that run's
        /// answer. Records written before change tracking have none.
        var change: String? = nil
        /// The run's `files` writes and edits of the path, for the change's one-line note.
        var writes: Int? = nil
        var edits: Int? = nil
    }

    // NSCache is thread-safe; synchronous tool descriptions share resolved paths
    // with the actor without walking every dated directory on each update.
    private final class Locations: @unchecked Sendable {
        let values = NSCache<NSString, NSString>()
    }

    static let shared = AskConversationWorkspaceStore()
    private nonisolated let locations = Locations()

    nonisolated let rootURL: URL
    private var discardedConversations: Set<String> = []
    init(rootURL: URL = TypefluxDataDirectories.workspaces) {
        self.rootURL = rootURL
    }

    private nonisolated func ownerName(_ owner: String) -> String {
        String(AskToolPolicy.digest(owner).dropFirst(7).prefix(16))
    }

    nonisolated func url(owner: String, conversationId: String) -> URL {
        let accountURL = rootURL.appendingPathComponent(ownerName(owner), isDirectory: true)
        if let account = try? AskSecureDirectory.openRoot(accountURL, create: false),
           let existing = existingPath(account: account, id: conversationId),
           let canonicalAccount = try? account.url {
            return canonicalAccount.appendingPathComponent(existing, isDirectory: true)
        }
        return accountURL.appendingPathComponent(Self.datedName(conversationId, date: Date()), isDirectory: true)
    }

    private nonisolated func existingPath(account: AskSecureDirectory, id: String) -> String? {
        let key = Self.conversationName(id)
        guard let accountPath = try? account.url.path else { return nil }
        let cacheKey = (accountPath + "\0" + key) as NSString
        if let cached = locations.values.object(forKey: cacheKey) { return cached as String }
        if (try? account.child(key)) != nil {
            locations.values.setObject(key as NSString, forKey: cacheKey)
            return key
        }
        for day in account.entries().sorted() where Self.isDateDirectory(day) {
            guard let directory = try? account.child(day, privateDirectory: true) else { continue }
            for name in directory.entries().sorted() where name.count == key.count + 7 && name.hasSuffix("-" + key) {
                if (try? directory.child(name, privateDirectory: true)) != nil {
                    let relative = day + "/" + name
                    locations.values.setObject(relative as NSString, forKey: cacheKey)
                    return relative
                }
            }
        }
        return nil
    }

    private nonisolated static func isDateDirectory(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private nonisolated static func datedName(_ id: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd/HHmmss"
        return formatter.string(from: date) + "-" + conversationName(id)
    }

    private static func creationDate(_ conversation: AskConversation) -> Date {
        conversation.messages.map(\.createdAt).min() ?? conversation.updatedAt
    }

    @discardableResult
    func ensure(owner: String, conversationId: String, createdAt: Date? = nil) throws -> URL {
        guard !discardedConversations.contains(owner + "\0" + conversationId) else { throw CancellationError() }
        let root = try AskSecureDirectory.openRoot(rootURL, privateRoot: false)
        let account = try root.child(ownerName(owner), create: true, privateDirectory: true)
        let existing = existingPath(account: account, id: conversationId)
        let legacy = Self.conversationName(conversationId)
        var date = createdAt
        if existing == legacy, date == nil {
            let old = try account.child(legacy, privateDirectory: true)
            if let bytes = try? old.readFile(".typeflux/conversation.json", limit: 64 * 1024 * 1024),
               let conversation = try? AskCoding.decoder().decode(AskConversation.self, from: bytes) {
                date = Self.creationDate(conversation)
            } else {
                date = try old.url.resourceValues(forKeys: [.creationDateKey]).creationDate
            }
        }
        let relative = existing.flatMap { $0 == legacy ? nil : $0 }
            ?? Self.datedName(conversationId, date: date ?? Date())
        let parts = relative.split(separator: "/").map(String.init)
        let day = try account.child(parts[0], create: true, privateDirectory: true)
        if existing == legacy {
            // Exclusive rename preserves files and never replaces a conflicting destination.
            guard renameatx_np(account.descriptor, legacy, day.descriptor, parts[1], UInt32(RENAME_EXCL)) == 0 else {
                throw AskSecureDirectory.failure("migrate conversation workspace")
            }
        }
        let chat = try day.child(parts[1], create: true, privateDirectory: true)
        if existing == legacy {
            // Remove only empty legacy directories, without following symlinks.
            for name in ["inputs", "outputs", "work"] {
                _ = unlinkat(chat.descriptor, name, AT_REMOVEDIR)
            }
        }
        let cacheKey = (try account.url.path + "\0" + legacy) as NSString
        locations.values.setObject(relative as NSString, forKey: cacheKey)
        return try chat.url
    }

    /// Mark first so in-flight work cannot recreate a discarded temporary chat.
    func discard(owner: String, conversationId: String) throws {
        discardedConversations.insert(owner + "\0" + conversationId)
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false, privateRoot: false)
        guard root.entries().contains(ownerName(owner)) else { return }
        let account = try root.child(ownerName(owner), privateDirectory: true)
        guard let relative = existingPath(account: account, id: conversationId) else { return }
        let cacheKey = (try account.url.path + "\0" + Self.conversationName(conversationId)) as NSString
        locations.values.removeObject(forKey: cacheKey)
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count == 1 { try account.remove(parts[0]) } else {
            try account.child(parts[0], privateDirectory: true).remove(parts[1])
            _ = unlinkat(account.descriptor, parts[0], AT_REMOVEDIR)
        }
    }

    private func directory(_ name: String, root: URL) throws -> URL {
        try AskSecureDirectory.openRoot(root).child(name, create: true, privateDirectory: true).url
    }

    /// Save original file bytes before dispatching the question. The local source
    /// path is never sent to a model or cloud service.
    func captureInputs(_ attachments: [AskAttachment], image: String?, messageId: String,
                       owner: String, conversationId: String) throws {
        let root = try ensure(owner: owner, conversationId: conversationId)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let prefix = String(AskToolPolicy.digest(messageId).dropFirst(7).prefix(16))
        var records: [FileRecord] = []
        for attachment in attachments {
            guard let name = Self.inputName(attachment, messageId: messageId) else { continue }
            let kind = attachment.localSourcePath != nil ? "user_original"
                : attachment.image != nil ? "processed_image" : "extracted_text"
            let destination = inputs.appendingPathComponent(name)
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
                _ = try directory("inputs", root: root)
                try bytes.write(to: destination, options: .atomic)
            } else if let image = attachment.image, let bytes = Self.dataURLBytes(image) {
                _ = try directory("inputs", root: root)
                try bytes.write(to: destination, options: .atomic)
            } else if let text = attachment.text {
                _ = try directory("inputs", root: root)
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
                _ = try directory("inputs", root: root)
                try bytes.write(to: destination, options: .atomic)
            }
            records.append(.init(path: "inputs/" + destination.lastPathComponent, source: "screenshot",
                                 messageId: messageId, originalPath: nil, byteSize: bytes.count))
        }
        try appendRecords(records, root: root)
    }

    /// The name a sent file is kept under in `inputs/`; folders are not copied.
    nonisolated static func inputName(_ attachment: AskAttachment, messageId: String) -> String? {
        guard attachment.kind != .folder else { return nil }
        let prefix = String(AskToolPolicy.digest(messageId).dropFirst(7).prefix(16))
        let name: String = if let source = attachment.localSourcePath {
            safeName(URL(fileURLWithPath: source).lastPathComponent)
        } else if attachment.image != nil {
            safeName(attachment.name) + ".jpg"
        } else {
            safeName(attachment.name) + ".txt"
        }
        let key = String(AskToolPolicy.digest(attachment.localSourcePath ?? attachment.id).dropFirst(7).prefix(16))
        return prefix + "-" + key + "-" + name
    }

    /// Where a sent file is kept inside the workspace, such as `inputs/<digest>-<digest>-a.pdf`.
    nonisolated static func inputPath(_ attachment: AskAttachment, messageId: String) -> String? {
        inputName(attachment, messageId: messageId).map { "inputs/" + $0 }
    }

    func saveOutput(_ data: Data, name: String, owner: String, conversationId: String) throws -> URL {
        let root = try ensure(owner: owner, conversationId: conversationId)
        let output = try directory("outputs", root: root)
            .appendingPathComponent(UUID().uuidString.lowercased() + "-" + Self.safeName(name))
        try data.write(to: output, options: .atomic)
        try appendRecords([.init(path: "outputs/" + output.lastPathComponent, source: "generated",
                                 messageId: nil, originalPath: nil, byteSize: data.count)], root: root)
        return output
    }

    func saveConversation(_ conversation: AskConversation, owner: String) throws {
        let root = try ensure(owner: owner, conversationId: conversation.id, createdAt: Self.creationDate(conversation))
        _ = try directory(".typeflux", root: root)
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

    private nonisolated static func safeName(_ raw: String) -> String {
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

    func appendRecords(_ incoming: [FileRecord], root: URL) throws {
        guard !incoming.isEmpty else { return }
        _ = try directory(".typeflux", root: root)
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
