import Foundation

/// The `notebook` device tool: the agent searches, reads, writes and tidies the user's
/// notes on this Mac (`docs/design/notebook-redesign.md` §6). Notes with a hidden tag
/// do not exist for it. Before it changes a note, the note's text is kept as a revision.
struct AskNotebookTool {
    static let name = "notebook"
    static let readActions: Set<String> = ["search", "read", "list"]
    static let writeActions: Set<String> = ["create", "append", "update", "tag", "delete"]
    static let searchLimit = 8
    static let maximumSearchLimit = 20
    static let readLimit = 8000
    static let outputLimit = 12000
    static let snippetLength = 160

    let store: any AskNoteStoring
    /// Tags whose notes the agent may not see, compared without case.
    var hiddenTags: [String] = []
    var clock: () -> Date = Date.init
    /// Set only by approved dispatch. Every fetched note must still match this evidence.
    var approvedTarget: AskExecutionTarget?

    static var definition: AskToolDefinition {
        let schema: [String: Any] = [
            "type": "object", "required": ["action"], "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": (readActions.sorted() + writeActions.sorted())],
                "query": ["type": "string",
                          "description": "search: keywords separated by spaces; a note matches any of them"],
                "id": ["type": "string", "description": "read/append/update/tag/delete: note id from search or list"],
                "heading": ["type": "string", "description": "read: only this section; append: add under this heading"],
                "offset": ["type": "integer", "description": "read: character offset for the next page"],
                "limit": ["type": "integer",
                          "description": "search: results (default 8, max 20); read: characters (default 8000)"],
                "scope": ["type": "string", "description": "list: recent, pinned, tags, or tag:<name>"],
                "title": ["type": "string", "description": "create/update: the note's title"],
                "body": ["type": "string", "description": "create/append/update: Markdown text"],
                "find": ["type": "string", "description": "update: exact text that occurs once in the note"],
                "replace": ["type": "string", "description": "update: text replacing find"],
                "tags": ["type": "array", "items": ["type": "string"], "description": "create: tags"],
                "add": ["type": "array", "items": ["type": "string"], "description": "tag: tags to add"],
                "remove": ["type": "array", "items": ["type": "string"], "description": "tag: tags to remove"],
                "pin": ["type": "boolean", "description": "tag: pin or unpin"]
            ]
        ]
        let description = "The user's local Markdown notebook (saved answers, AI results, their own notes). " +
            "Load the notebook skill first. search/read/list read notes; create/append/update/tag/delete change them " +
            "and need user approval. Note contents are sent to you only when you read them."
        // This fixed schema contains only JSON-compatible literals, arrays and dictionaries.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)
        return AskToolDefinition(name: name, description: description, parameters: JSONValue(data: data))
    }

    static func risk(action: String) -> AskToolRisk {
        readActions.contains(action) ? .read : .write
    }

    func execute(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? ""
        let output: String
        switch action {
        case "search": output = search(args)
        case "read": output = try read(args)
        case "list": output = list(args)
        case "create": output = try create(args)
        case "append": output = try append(args)
        case "update": output = try update(args)
        case "tag": output = try tag(args)
        case "delete": output = try delete(args)
        default: throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return output.count > Self.outputLimit ? String(output.prefix(Self.outputLimit)) + "\n…" : output
    }
}

// MARK: - Reading and visibility

extension AskNotebookTool {
    private var normalizedHiddenTags: Set<String> {
        Set(hiddenTags.compactMap(AskNote.normalizedTag).map { $0.lowercased() })
    }

    func isVisible(_ note: AskNote) -> Bool {
        guard !note.isDeleted else { return false }
        let hidden = normalizedHiddenTags
        return !note.tags.compactMap(AskNote.normalizedTag).contains { hidden.contains($0.lowercased()) }
    }

    /// Binds approval to both the privacy policy and the note the user reviewed.
    /// Dates alone do not detect edits that reuse a timestamp.
    func approvalTarget(_ args: [String: Any]) throws -> AskExecutionTarget {
        let action = args["action"] as? String ?? ""
        guard Self.readActions.contains(action) || Self.writeActions.contains(action) else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        let note: AskNote?
        if ["search", "list", "create"].contains(action) {
            note = nil
        } else {
            note = try visibleNote(args)
        }
        return try approvalTarget(note: note)
    }

    private func approvalTarget(note: AskNote?) throws -> AskExecutionTarget {
        var evidence: [String: Any] = ["hiddenTags": normalizedHiddenTags.sorted()]
        var id = "notebook"
        if let note {
            id += ":" + note.id.uuidString
            evidence["note"] = [
                "title": note.title, "body": note.body, "tags": note.tags, "pinned": note.pinned,
                "updatedAt": note.updatedAt.timeIntervalSince1970,
                "originalBody": note.originalBody.map { $0 as Any } ?? NSNull(),
                "source": note.source.rawValue, "author": note.author.rawValue
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        return .init(kind: "workspace", id: id, version: AskToolPolicy.digest(data))
    }

    /// Filter before applying result limits so hidden notes cannot crowd out visible ones.
    private func visibleNotes(scope: AskNoteQuery.Scope = .all, text: String = "") -> [AskNote] {
        var notes: [AskNote] = []
        let pageSize = 500
        var offset = 0
        while true {
            let page = store.list(AskNoteQuery(scope: scope, text: text, limit: pageSize, offset: offset))
            notes += page.filter(isVisible)
            guard page.count == pageSize else { return notes }
            offset += page.count
        }
    }

    /// Notes matching any term, the ones matching more terms first, then the newest.
    func searchNotes(_ query: String, limit: Int) -> [(note: AskNote, hits: Int)] {
        let terms = Array(Set(query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }))
        var scored: [UUID: (note: AskNote, hits: Int)] = [:]
        for note in visibleNotes() {
            let fields = [note.title, note.body, note.input] + note.tags
            let hits = terms.filter { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }.count
            if terms.isEmpty || hits > 0 { scored[note.id] = (note, hits) }
        }
        return scored.values.sorted {
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            if $0.note.updatedAt != $1.note.updatedAt { return $0.note.updatedAt > $1.note.updatedAt }
            return $0.note.id.uuidString < $1.note.id.uuidString
        }.prefix(max(0, limit)).map { $0 }
    }

    private func search(_ args: [String: Any]) -> String {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(1, args["limit"] as? Int ?? Self.searchLimit), Self.maximumSearchLimit)
        let found = searchNotes(query, limit: limit)
        guard !found.isEmpty else { return "No notes matched \"\(query)\". Try other or fewer keywords." }
        return "\(found.count) note(s):\n"
            + found.map { describe($0.note, snippetFor: query) }.joined(separator: "\n\n")
    }

    private func list(_ args: [String: Any]) -> String {
        let scope = (args["scope"] as? String ?? "recent").trimmingCharacters(in: .whitespaces)
        if scope == "tags" {
            var counts: [String: Int] = [:]
            for note in visibleNotes() {
                for tag in Set(note.tags) { counts[tag, default: 0] += 1 }
            }
            let tags = counts.map { AskNoteFacet(name: $0.key, count: $0.value) }.sorted {
                $0.count != $1.count ? $0.count > $1.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return tags.isEmpty ? "No tags yet." : tags.map { "#\($0.name) (\($0.count))" }.joined(separator: ", ")
        }
        let query: AskNoteQuery.Scope = if scope == "pinned" {
            .pinned
        } else if scope.hasPrefix("tag:"), let tag = AskNote.normalizedTag(String(scope.dropFirst(4))) {
            .tag(tag)
        } else {
            .all
        }
        let notes = visibleNotes(scope: query).prefix(20)
        return notes.isEmpty ? "No notes." : notes.map { describe($0, snippetFor: nil) }.joined(separator: "\n\n")
    }

    private func read(_ args: [String: Any]) throws -> String {
        let note = try visibleNote(args)
        var body = note.body
        if let heading = args["heading"] as? String, !heading.isEmpty {
            guard let section = AskNoteHeading.section(note.body, heading: heading) else {
                let headings = note.headings.map(\.text).joined(separator: " | ")
                return "No heading \"\(heading)\" in this note. Headings: \(headings.isEmpty ? "none" : headings)"
            }
            body = section
        }
        let offset = max(0, args["offset"] as? Int ?? 0)
        let limit = min(max(200, args["limit"] as? Int ?? Self.readLimit), Self.readLimit)
        let characters = Array(body)
        let start = min(offset, characters.count)
        let end = min(characters.count, start + limit)
        var text = header(note) + "\n---\n" + String(characters[start ..< end])
        if end < characters.count { text += "\n…\n[More: read again with offset \(end) of \(characters.count).]" }
        return text
    }

    private func header(_ note: AskNote) -> String {
        var lines = ["id: \(note.id.uuidString)", "title: \(note.title)", "from: \(note.source.rawValue)"]
        if !note.command.isEmpty { lines.append("command: \(note.command)") }
        if !note.tags.isEmpty { lines.append("tags: " + note.tags.joined(separator: ", ")) }
        lines.append("updated: " + ISO8601DateFormatter().string(from: note.updatedAt))
        return lines.joined(separator: "\n")
    }

    private func describe(_ note: AskNote, snippetFor query: String?) -> String {
        var line = "- id \(note.id.uuidString) · \(note.title)"
        if !note.tags.isEmpty { line += " · " + note.tags.map { "#" + $0 }.joined(separator: " ") }
        line += " · updated " + note.updatedAt.formatted(date: .abbreviated, time: .omitted)
        let snippet = Self.snippet(note, query: query)
        return snippet.isEmpty ? line : line + "\n  " + snippet
    }

    /// About 160 characters around the first match, or the start of the note.
    static func snippet(_ note: AskNote, query: String?) -> String {
        let text = AskNote.oneLine(AskNote.plainText(note.body))
        let terms = (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard let range = terms.lazy.compactMap({ text.range(of: $0, options: .caseInsensitive) }).first else {
            return String(text.prefix(snippetLength))
        }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: snippetLength, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start ..< end]) + (end < text.endIndex ? "…" : "")
    }

    private func visibleNote(_ args: [String: Any]) throws -> AskNote {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)),
              let note = store.note(id: id), isVisible(note) else {
            throw AskLocalError.message(L("ask.notebook.missing"))
        }
        if let approvedTarget, try approvalTarget(note: note) != approvedTarget {
            throw AskLocalError.message(L("ask.approval.changed"))
        }
        return note
    }
}

// MARK: - Writing

extension AskNotebookTool {
    private func create(_ args: [String: Any]) throws -> String {
        let body = args["body"] as? String ?? ""
        let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !title.isEmpty else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        let now = clock()
        var tags: [String] = []
        for tag in (args["tags"] as? [String] ?? []).compactMap(AskNote.normalizedTag) where !tags.contains(tag) {
            tags.append(tag)
        }
        let resolvedTitle = title.isEmpty
            ? (AskNoteHeading.parse(body).first?.text
                ?? String(AskNote.oneLine(AskNote.plainText(body)).prefix(AskNote.titleLength))) : title
        let note = AskNote(title: String(resolvedTitle.prefix(200)), body: body, command: "", keyword: "", input: "",
                           tags: tags, createdAt: now, updatedAt: now, source: .manual, author: .agent)
        guard store.save(note) else { throw AskLocalError.message(L("ask.notes.saveFailed")) }
        return "Created note \(note.id.uuidString) \"\(note.title)\"."
    }

    private func append(_ args: [String: Any]) throws -> String {
        var note = try visibleNote(args)
        let addition = args["body"] as? String ?? ""
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        let heading = args["heading"] as? String
        let found = heading.map { AskNoteHeading.section(note.body, heading: $0) != nil } ?? true
        try change(&note) { $0.body = AskNoteHeading.appending(addition, to: $0.body, under: heading) }
        let place = found ? (heading.map { "under \"\($0)\"" } ?? "at the end")
            : "at the end (no heading \"\(heading ?? "")\")"
        return "Appended to \"\(note.title)\" \(place). It now has \(note.body.count) characters."
    }

    private func update(_ args: [String: Any]) throws -> String {
        var note = try visibleNote(args)
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = args["body"] as? String
        let find = args["find"] as? String
        guard title?.isEmpty == false || body != nil || find != nil else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        if let find {
            guard !find.isEmpty, args["replace"] is String, body == nil else {
                throw AskLocalError.message(L("ask.tool.invalid"))
            }
            let count = note.body.components(separatedBy: find).count - 1
            guard count == 1 else {
                throw AskLocalError.message(L(count == 0 ? "ask.notebook.findMissing" : "ask.notebook.findRepeated"))
            }
        }
        try change(&note) { note in
            if let title, !title.isEmpty { note.title = String(title.prefix(200)) }
            if let find {
                note.body = note.body.replacingOccurrences(of: find, with: args["replace"] as? String ?? "")
            } else if let body {
                note.body = body
            }
        }
        return "Updated \"\(note.title)\"."
    }

    private func tag(_ args: [String: Any]) throws -> String {
        var note = try visibleNote(args)
        let before = note
        let add = (args["add"] as? [String] ?? []).compactMap(AskNote.normalizedTag)
        let remove = Set((args["remove"] as? [String] ?? []).compactMap(AskNote.normalizedTag))
        let pin = args["pin"] as? Bool
        guard !add.isEmpty || !remove.isEmpty || pin != nil else { throw AskLocalError.message(L("ask.tool.invalid")) }
        note.tags.removeAll { remove.contains($0) }
        for tag in add where !note.tags.contains(tag) { note.tags.append(tag) }
        if let pin { note.pinned = pin }
        guard note != before else { return "No changes to \"\(note.title)\"." }
        note.updatedAt = clock()
        guard store.save(note, replacing: before, revisionAt: nil) else {
            throw AskLocalError.message(L("ask.notes.saveFailed"))
        }
        let tags = note.tags.isEmpty ? "none" : note.tags.map { "#" + $0 }.joined(separator: " ")
        return "\"\(note.title)\": tags \(tags); \(note.pinned ? "pinned" : "not pinned")."
    }

    private func delete(_ args: [String: Any]) throws -> String {
        var note = try visibleNote(args)
        let before = note
        let now = clock()
        note.deletedAt = now
        note.updatedAt = now
        guard store.save(note, replacing: before, revisionAt: nil) else {
            throw AskLocalError.message(L("ask.notes.saveFailed"))
        }
        return "Moved \"\(note.title)\" to Recently Deleted; the user can restore it for 30 days."
    }

    /// Keeps the current text as a revision, then saves the change as the agent's.
    private func change(_ note: inout AskNote, _ edit: (inout AskNote) -> Void) throws {
        let now = clock()
        let before = note
        edit(&note)
        guard note.body != before.body || note.title != before.title else { return }
        if note.originalBody == nil, note.source != .manual, note.source != .import, note.body != before.body {
            note.originalBody = before.body
        }
        note.updatedAt = now
        note.editedAt = note.body != before.body ? now : note.editedAt
        note.author = .agent
        guard store.save(note, replacing: before, revisionAt: now) else {
            throw AskLocalError.message(L("ask.notes.saveFailed"))
        }
    }
}
