import Foundation

/// What a result needs to become a note: its Markdown and where it came from.
/// AI prompt results carry one on their ⌘S action (`docs/design/ai-command-results.md`).
struct AskNoteDraft: Equatable, Sendable {
    /// The keyword's name, such as "Explain".
    var command: String
    /// The keyword typed, such as `ex`.
    var keyword: String
    /// The text the prompt worked on.
    var input: String
    var body: String
    var model: String?
    /// The app the launcher was opened over, when known.
    var sourceApp: String?
    var sourceBundleID: String?
}

/// A saved result in the notes window: Markdown the user may edit, with its origin kept read-only.
struct AskNote: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var body: String
    var command: String
    var keyword: String
    var input: String
    var model: String?
    var sourceApp: String?
    var sourceBundleID: String?
    var tags: [String]
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date
    /// When the user last changed the text; nil while it is still the result as generated.
    var editedAt: Date?

    /// The input characters a default title keeps.
    static let titleLength = 24

    init(id: UUID = UUID(), title: String, body: String, command: String, keyword: String, input: String,
         model: String? = nil, sourceApp: String? = nil, sourceBundleID: String? = nil, tags: [String] = [],
         pinned: Bool = false, createdAt: Date, updatedAt: Date, editedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.command = command
        self.keyword = keyword
        self.input = input
        self.model = model
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editedAt = editedAt
    }

    /// A new note from a result, titled after its command and input.
    init(draft: AskNoteDraft, id: UUID = UUID(), at date: Date) {
        self.init(id: id, title: Self.title(command: draft.command, input: draft.input, body: draft.body),
                  body: draft.body, command: draft.command, keyword: draft.keyword, input: draft.input,
                  model: draft.model, sourceApp: draft.sourceApp, sourceBundleID: draft.sourceBundleID,
                  createdAt: date, updatedAt: date)
    }

    var isEdited: Bool { editedAt != nil }

    /// "Explain · Comparative advantage": the command and the first characters of the
    /// input on one line, or of the result when there was no input.
    static func title(command: String, input: String, body: String = "") -> String {
        let source = oneLine(input).isEmpty ? oneLine(plainText(body)) : oneLine(input)
        let clipped = source.count > titleLength ? String(source.prefix(titleLength)) + "…" : source
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if clipped.isEmpty { return name }
        return name.isEmpty ? clipped : name + " · " + clipped
    }

    /// The first words of the note without Markdown, for lists.
    var excerpt: String { String(Self.oneLine(Self.plainText(body)).prefix(160)) }

    /// A tag as kept: trimmed, without a leading `#`, nil when nothing is left.
    static func normalizedTag(_ text: String) -> String? {
        var tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : String(tag.prefix(40))
    }

    /// Markdown with its markers taken out, close enough for an excerpt or a title.
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { lines.append(line); continue }
            // Table separator rows carry nothing to read.
            if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { continue }
            var text = line
            for prefix in ["#", ">"] { while text.hasPrefix(prefix) { text.removeFirst() } }
            text = text.trimmingCharacters(in: .whitespaces)
            if let marker = text.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                text.removeSubrange(marker)
            }
            text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[*_`~|]"#, with: "", options: .regularExpression)
            lines.append(text.trimmingCharacters(in: .whitespaces))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What the notes window and the `nb` keyword ask the store for.
struct AskNoteQuery: Equatable, Sendable {
    enum Scope: Hashable, Sendable {
        case all
        case pinned
        /// Notes made by one keyword, by its name.
        case command(String)
        case tag(String)
    }

    enum Sort: String, CaseIterable, Sendable {
        case updated, created
    }

    var scope: Scope = .all
    /// Matches the title, the text and the input.
    var text = ""
    var sort: Sort = .updated
    var limit = 500
    var offset = 0
}

/// A command or tag with how many notes have it, for the sidebar.
struct AskNoteFacet: Equatable, Sendable, Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

/// Where notes are kept; `SQLiteAskNoteStore` on this Mac, a memory store in tests.
protocol AskNoteStoring: AnyObject, Sendable {
    func note(id: UUID) -> AskNote?
    /// Inserts or replaces the note with its id.
    @discardableResult
    func save(_ note: AskNote) -> Bool
    func delete(ids: [UUID])
    /// Puts deleted notes back, as they were (undo).
    func restore(_ notes: [AskNote])
    /// Pinned notes first, then by the query's sort, newest first.
    func list(_ query: AskNoteQuery) -> [AskNote]
    func count(_ scope: AskNoteQuery.Scope) -> Int
    func commands() -> [AskNoteFacet]
    func tags() -> [AskNoteFacet]
}

extension Notification.Name {
    /// Posted on the main queue after the notes change.
    static let askNotesDidChange = Notification.Name("askNotesDidChange")
}
