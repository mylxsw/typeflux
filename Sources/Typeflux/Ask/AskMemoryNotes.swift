import Foundation

struct AskMemoryNote: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var createdAt: Date
}

/// Facts the user asked Ask to remember, saved per account. Notes join the
/// device memory sent with new conversations; they never leave the device otherwise.
final class AskMemoryNoteStore: @unchecked Sendable {
    static let shared = AskMemoryNoteStore()
    static let maximumNotes = 50
    static let maximumNoteLength = 300

    private let lock = NSLock()
    private let fileURL: URL
    private let storage: any AskMemoryNoteFileStorage
    private var notes: [String: [AskMemoryNote]]

    init(fileURL: URL? = nil, storage: any AskMemoryNoteFileStorage = LocalAskMemoryNoteFileStorage()) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/ask-memory-notes.json")
        self.storage = storage
        let data = try? storage.read(from: self.fileURL)
        notes = data.flatMap { try? JSONDecoder().decode([String: [AskMemoryNote]].self, from: $0) } ?? [:]
    }

    func list(owner: String) -> [AskMemoryNote] {
        lock.lock(); defer { lock.unlock() }
        return notes[owner] ?? []
    }

    @discardableResult
    func add(_ text: String, owner: String, now: Date = Date()) throws -> AskMemoryNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumNoteLength else { throw AskLocalError.message(L("ask.memoryNotes.invalid")) }
        lock.lock(); defer { lock.unlock() }
        var list = notes[owner] ?? []
        if let existing = list.first(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing }
        guard list.count < Self.maximumNotes else { throw AskLocalError.message(L("ask.memoryNotes.full")) }
        let note = AskMemoryNote(id: String(UUID().uuidString.prefix(8)).lowercased(), text: trimmed, createdAt: now)
        list.append(note)
        var candidate = notes
        candidate[owner] = list
        try commit(candidate)
        return note
    }

    @discardableResult
    func remove(id: String, owner: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = notes[owner]?.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes
        candidate[owner]?.remove(at: index)
        try commit(candidate)
        return true
    }

    func clear(owner: String) throws {
        lock.lock(); defer { lock.unlock() }
        var candidate = notes
        candidate[owner] = nil
        try commit(candidate)
    }

    /// Called with the lock held so readers and later mutations see only commits.
    private func commit(_ candidate: [String: [AskMemoryNote]]) throws {
        try storage.writeAtomically(JSONEncoder().encode(candidate), to: fileURL)
        notes = candidate
    }

    /// Notes as a memory block, newest first, within `limit` characters.
    static func memoryText(_ notes: [AskMemoryNote], limit: Int) -> String? {
        guard !notes.isEmpty, limit > 20 else { return nil }
        var text = "Saved notes:"
        for note in notes.reversed() {
            let line = "\n- " + note.text
            if text.count + line.count > limit { break }
            text += line
        }
        return text == "Saved notes:" ? nil : text
    }

    static let definition: AskToolDefinition = {
        let schema: [String: Any] = [
            "type": "object", "required": ["action"], "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["list", "remember", "forget"]],
                "text": ["type": "string", "description": "remember: one short fact or preference"],
                "id": ["type": "string", "description": "forget: note id from list"]
            ]
        ]
        let description = "Manage facts the user explicitly asks you to remember for future conversations. " +
            "Only remember what the user asked for, one short fact per call; never store passwords, keys or secrets. " +
            "Saving or forgetting needs user approval; notes apply to new conversations."
        return AskToolDefinition(name: "memory", description: description,
                                 parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }()

    func execute(_ args: [String: Any], owner: String) throws -> String {
        switch args["action"] as? String {
        case "list":
            let notes = list(owner: owner)
            return notes.isEmpty ? "No saved notes." : notes.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
        case "remember":
            let note = try add(args["text"] as? String ?? "", owner: owner)
            return "Saved note \(note.id). It applies to new conversations."
        case "forget":
            guard let id = args["id"] as? String, try remove(id: id, owner: owner) else { throw AskLocalError.message(L("ask.memoryNotes.missing")) }
            return "Forgot note \(id)."
        default:
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
    }
}
