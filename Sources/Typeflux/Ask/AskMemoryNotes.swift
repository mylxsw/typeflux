import Foundation

struct AskMemoryNote: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var createdAt: Date
    var provenance: MemoryProvenance?
    var deletedAt: Date?
}

/// Facts the user asked Ask to remember, saved per account. Notes join the
/// device memory sent with new conversations; they never leave the device otherwise.
final class AskMemoryNoteStore: @unchecked Sendable {
    static let shared: AskMemoryNoteStore = {
        let store = AskMemoryNoteStore(
            correctionsEnabled: MemoryRollout.enabled(),
            onChange: { MemoryInvalidationStore.shared.invalidate(owner: $0) }
        )
        store.recoverInvalidations(using: .shared)
        return store
    }()

    static let maximumNotes = 50
    static let maximumNoteLength = 300

    private let lock = NSLock()
    private let fileURL: URL
    private let storage: any AskMemoryNoteFileStorage
    private let correctionsEnabled: Bool
    private let onChange: @Sendable (String) -> Void
    private var notes: [String: [AskMemoryNote]]

    init(fileURL: URL? = nil, storage: any AskMemoryNoteFileStorage = LocalAskMemoryNoteFileStorage(),
         correctionsEnabled: Bool = false,
         onChange: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/ask-memory-notes.json")
        self.storage = storage
        self.correctionsEnabled = correctionsEnabled
        self.onChange = onChange
        let data = try? storage.read(from: self.fileURL)
        notes = data.flatMap { try? JSONDecoder().decode([String: [AskMemoryNote]].self, from: $0) } ?? [:]
        for owner in notes.keys {
            notes[owner] = notes[owner]?.map { note in
                var note = note
                if note.provenance == nil {
                    note.provenance = .init(id: note.id, source: .explicit, owner: owner, scope: "account",
                                            createdAt: note.createdAt, updatedAt: note.createdAt)
                }
                return note
            }
        }
    }

    func recoverInvalidations(using invalidations: MemoryInvalidationStore) {
        lock.lock(); defer { lock.unlock() }
        for (owner, list) in notes {
            guard let latest = list.compactMap(\.deletedAt).max(),
                  latest > (invalidations.cutoff(owner: owner) ?? .distantPast) else { continue }
            invalidations.invalidate(owner: owner, at: latest, notify: false)
        }
    }

    func list(owner: String, query: String = "", at date: Date = Date()) -> [AskMemoryNote] {
        lock.lock(); defer { lock.unlock() }
        var candidate = notes
        var expired = false
        for index in 0 ..< (candidate[owner]?.count ?? 0) {
            if let expiry = candidate[owner]?[index].provenance?.expiry,
               expiry <= date, candidate[owner]?[index].deletedAt == nil {
                candidate[owner]?[index].text = ""
                candidate[owner]?[index].deletedAt = expiry
                expired = true
            }
        }
        // A failed cleanup never makes an expired note eligible for injection.
        if expired {
            try? commit(candidate)
        }
        let all = notes[owner] ?? []
        let superseded = Set(all.compactMap { $0.provenance?.supersedes })
        return all.filter {
            $0.deletedAt == nil && !superseded.contains($0.id)
                && ($0.provenance?.isActive(owner: owner, at: date) ?? true)
                && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
    }

    @discardableResult
    func add(_ text: String, owner: String, now: Date = Date(), expiry: Date? = nil) throws -> AskMemoryNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !trimmed.isEmpty, trimmed.count <= Self.maximumNoteLength,
              expiry.map({ $0 > now }) ?? true else { throw AskLocalError.message(L("ask.memoryNotes.invalid")) }
        lock.lock(); defer { lock.unlock() }
        var list = notes[owner] ?? []
        if let existing = list
            .first(where: {
                $0.deletedAt == nil && ($0.provenance?.expiry.map { $0 > now } ?? true) && $0.text
                    .caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
            return existing
        }
        guard list.filter({ $0.deletedAt == nil && ($0.provenance?.expiry.map { $0 > now } ?? true) }).count < Self
            .maximumNotes
        else { throw AskLocalError.message(L("ask.memoryNotes.full")) }
        let id = UUID().uuidString.lowercased()
        let note = AskMemoryNote(id: id, text: trimmed, createdAt: now,
                                 provenance: .init(id: id, source: .explicit, owner: owner, scope: "account",
                                                   createdAt: now, updatedAt: now, expiry: expiry))
        list.append(note)
        var candidate = notes
        candidate[owner] = list
        try commit(candidate)
        return note
    }

    @discardableResult
    func remove(id: String, owner: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = notes[owner]?.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        var candidate = notes
        candidate[owner]?[index].text = ""
        candidate[owner]?[index].deletedAt = Date()
        try commit(candidate)
        onChange(owner)
        return true
    }

    func clear(owner: String) throws {
        lock.lock(); defer { lock.unlock() }
        var candidate = notes
        candidate[owner] = candidate[owner]?.map { value in
            var value = value; value.text = ""; value.deletedAt = Date(); return value
        }
        try commit(candidate)
        onChange(owner)
    }

    /// Compare the version presented to the user, so a stale editor cannot overwrite a correction.
    @discardableResult
    func correct(id: String, text: String, owner: String, expectedVersion: Int,
                 expiry: Date? = nil, now: Date = Date()) throws -> AskMemoryNote {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maximumNoteLength,
              expiry.map({ $0 > now }) ?? true else { throw AskLocalError.message(L("ask.memoryNotes.invalid")) }
        lock.lock(); defer { lock.unlock() }
        guard let index = notes[owner]?.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              let old = notes[owner]?[index], (old.provenance?.version ?? 1) == expectedVersion else {
            throw AskLocalError.message(L("ask.memoryNotes.missing"))
        }
        let nextID = UUID().uuidString.lowercased()
        let next = AskMemoryNote(id: nextID, text: text, createdAt: now,
                                 provenance: .init(id: nextID, source: .correction, owner: owner, scope: "account",
                                                   version: expectedVersion + 1, createdAt: now, updatedAt: now,
                                                   expiry: expiry, supersedes: id))
        var candidate = notes
        candidate[owner]?[index].text = ""
        candidate[owner]?[index].deletedAt = now
        candidate[owner]?.append(next)
        try commit(candidate)
        onChange(owner)
        return next
    }

    /// Called with the lock held so readers and later mutations see only commits.
    private func commit(_ candidate: [String: [AskMemoryNote]]) throws {
        try storage.writeAtomically(JSONEncoder().encode(candidate), to: fileURL)
        notes = candidate
    }

    /// Notes as a memory block, newest first, within `limit` characters.
    static func memoryText(_ notes: [AskMemoryNote], limit: Int) -> String? {
        guard !notes.isEmpty, limit > 20 else { return nil }
        let selected = injectionNotes(notes, limit: limit)
        guard !selected.isEmpty else { return nil }
        return "Saved notes:" + selected.map { "\n- " + $0.text }.joined()
    }

    static func injectionNotes(_ notes: [AskMemoryNote], limit: Int) -> [AskMemoryNote] {
        var room = limit - "Saved notes:".unicodeScalars.count
        var result: [AskMemoryNote] = []
        for note in notes.reversed() {
            let size = 3 + note.text.unicodeScalars.count
            guard size <= room else { break }
            room -= size
            result.append(note)
        }
        return result
    }

    static var definition: AskToolDefinition {
        let schema: [String: Any] = [
            "type": "object", "required": ["action"], "additionalProperties": false,
            "properties": [
                "action": [
                    "type": "string",
                    "enum": MemoryRollout.enabled() ? ["list", "remember", "forget", "correct"] : [
                        "list",
                        "remember",
                        "forget"
                    ]
                ],
                "text": ["type": "string", "description": "remember: one short fact or preference"],
                "id": ["type": "string", "description": "forget/correct: note id from list"],
                "version": ["type": "integer", "description": "correct: version from list"]
            ]
        ]
        let description = "Manage facts the user explicitly asks you to remember for future conversations. " +
            "Only remember what the user asked for, one short fact per call; never store passwords, keys or secrets. " +
            "Saving, correcting or forgetting needs user approval; notes apply to new conversations."
        return AskToolDefinition(name: "memory", description: description,
                                 parameters: JSONValue(data: try! JSONSerialization.data(
                                     withJSONObject: schema,
                                     options: .sortedKeys
                                 )))
    }

    func execute(_ args: [String: Any], owner: String) throws -> String {
        switch args["action"] as? String {
        case "list":
            let notes = list(owner: owner)
            return notes.isEmpty ? "No saved notes." : notes
                .map { "\($0.id) v\($0.provenance?.version ?? 1): \($0.text)" }
                .joined(separator: "\n")
        case "remember":
            let note = try add(args["text"] as? String ?? "", owner: owner)
            return "Saved note \(note.id). It applies to new conversations."
        case "correct":
            guard correctionsEnabled else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let note = try correct(id: args["id"] as? String ?? "", text: args["text"] as? String ?? "",
                                   owner: owner, expectedVersion: args["version"] as? Int ?? 0)
            return "Corrected note \(note.id). Earlier source snapshots are invalidated; conversation history is retained."
        case "forget":
            guard let id = args["id"] as? String,
                  try remove(id: id, owner: owner) else { throw AskLocalError.message(L("ask.memoryNotes.missing")) }
            return "Forgot note \(id)."
        default:
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
    }
}
