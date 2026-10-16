import Foundation

/// Where a note came from; the notes window groups notes by it.
enum AskNoteSource: String, CaseIterable, Sendable {
    /// An AI prompt result saved with ⌘S.
    case command
    /// An answer, or part of one, saved from a conversation.
    case chat
    /// Text read from a screenshot.
    case screenshot
    /// Written in the notes window, or by the agent.
    case manual
    /// A Markdown file brought in from disk.
    case `import`

    var symbol: String {
        switch self {
        case .command: "wand.and.stars"
        case .chat: "bubble.left"
        case .screenshot: "text.viewfinder"
        case .manual: "pencil"
        case .import: "square.and.arrow.down"
        }
    }

    var title: String { L("ask.notes.source." + rawValue) }
}

/// Who last changed a note's text.
enum AskNoteAuthor: String, Sendable {
    case user, agent
}

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
    var source: AskNoteSource = .command
    /// The conversation and message an answer was saved from.
    var conversationID: String?
    var messageID: String?
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
    var source: AskNoteSource
    var conversationID: String?
    var messageID: String?
    /// The generated text, kept as a source snapshot when an AI note is first edited.
    var originalBody: String?
    /// Set while the note is in Recently Deleted.
    var deletedAt: Date?
    var author: AskNoteAuthor

    /// The input characters a default title keeps.
    static let titleLength = 24

    init(id: UUID = UUID(), title: String, body: String, command: String, keyword: String, input: String,
         model: String? = nil, sourceApp: String? = nil, sourceBundleID: String? = nil, tags: [String] = [],
         pinned: Bool = false, createdAt: Date, updatedAt: Date, editedAt: Date? = nil,
         source: AskNoteSource = .command, conversationID: String? = nil, messageID: String? = nil,
         originalBody: String? = nil, deletedAt: Date? = nil, author: AskNoteAuthor = .user) {
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
        self.source = source
        self.conversationID = conversationID
        self.messageID = messageID
        self.originalBody = originalBody
        self.deletedAt = deletedAt
        self.author = author
    }

    /// A new note from a result, titled after its command and input.
    init(draft: AskNoteDraft, id: UUID = UUID(), at date: Date) {
        self.init(id: id, title: Self.title(command: draft.command, input: draft.input, body: draft.body),
                  body: draft.body, command: draft.command, keyword: draft.keyword, input: draft.input,
                  model: draft.model, sourceApp: draft.sourceApp, sourceBundleID: draft.sourceBundleID,
                  createdAt: date, updatedAt: date, source: draft.source, conversationID: draft.conversationID,
                  messageID: draft.messageID)
    }

    var isEdited: Bool { editedAt != nil }

    var isDeleted: Bool { deletedAt != nil }

    /// The headings (`#` to `###`) outside code blocks, for the outline.
    var headings: [AskNoteHeading] { AskNoteHeading.parse(body) }

    /// Characters other than whitespace, for the word count.
    var characterCount: Int {
        Self.plainText(body).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// Done and total task items (`- [x]`, `- [ ]`).
    var taskProgress: (done: Int, total: Int) {
        var done = 0, total = 0
        for line in AskNoteTasks.taskLines(body) {
            total += 1
            if line.done { done += 1 }
        }
        return (done, total)
    }

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
        var fence = AskNoteFenceState()
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if fence.consumeDelimiter(raw) { continue }
            if fence.isOpen { lines.append(line); continue }
            // Table separator rows carry nothing to read.
            if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { continue }
            var text = line
            for prefix in ["#", ">"] { while text.hasPrefix(prefix) { text.removeFirst() } }
            text = text.trimmingCharacters(in: .whitespaces)
            if let marker = text.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                text.removeSubrange(marker)
            }
            // A task's box is not text to read.
            if let box = text.range(of: #"^\[[ xX]\]\s*"#, options: .regularExpression) { text.removeSubrange(box) }
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
        /// Updated in the last seven days.
        case recent
        /// Notes made by one keyword, by its name.
        case command(String)
        case source(AskNoteSource)
        case tag(String)
        /// Recently Deleted; every other scope leaves deleted notes out.
        case trash
    }

    enum Sort: String, CaseIterable, Sendable {
        case updated, created, title
    }

    /// How long "recent" reaches back, and how long deleted notes are kept.
    static let recentInterval: TimeInterval = 7 * 86400
    static let trashRetention: TimeInterval = 30 * 86400

    var scope: Scope = .all
    /// Matches the title, the text and the input.
    var text = ""
    var sort: Sort = .updated
    var limit = 500
    var offset = 0
    /// Restricts chat favorites to their originating conversation without scanning all notes.
    var conversationID: String?
}

/// A command or tag with how many notes have it, for the sidebar.
struct AskNoteFacet: Equatable, Sendable, Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

/// An earlier text of a note, kept before the agent changed it.
struct AskNoteRevision: Equatable, Sendable {
    var noteID: UUID
    var title: String
    var body: String
    var createdAt: Date
}

/// Where notes are kept; `SQLiteAskNoteStore` on this Mac, a memory store in tests.
protocol AskNoteStoring: AnyObject, Sendable {
    /// The note, deleted or not.
    func note(id: UUID) async throws -> AskNote?
    /// Inserts or replaces the note with its id.
    @discardableResult
    func save(_ note: AskNote) async throws -> Bool
    /// Saves only if the stored note still matches the caller's snapshot. An optional
    /// revision and the replacement commit together, so failed writes never create undo entries.
    @discardableResult
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) async throws -> Bool
    /// Removes notes for good.
    func delete(ids: [UUID]) async throws
    /// Puts deleted notes back, as they were (undo).
    func restore(_ notes: [AskNote]) async throws
    /// Pinned notes first, then by the query's sort, newest first.
    func list(_ query: AskNoteQuery) async throws -> [AskNote]
    func count(_ scope: AskNoteQuery.Scope) async throws -> Int
    func commands() async throws -> [AskNoteFacet]
    /// Note counts per `AskNoteSource` raw value.
    func sources() async throws -> [AskNoteFacet]
    func tags() async throws -> [AskNoteFacet]
    /// Moves notes to Recently Deleted.
    func trash(ids: [UUID], at date: Date) async throws
    /// Removes notes deleted before `date` for good.
    func purgeTrash(before date: Date) async throws
    /// Keeps the note's current text before the agent changes it; the newest 20 per note stay.
    func saveRevision(_ note: AskNote, at date: Date) async throws
    /// Newest first.
    func revisions(of id: UUID) async throws -> [AskNoteRevision]
    func deleteRevision(of id: UUID, at date: Date) async throws
}

extension Notification.Name {
    /// Posted on the main queue after the notes change.
    static let askNotesDidChange = Notification.Name("askNotesDidChange")
}
