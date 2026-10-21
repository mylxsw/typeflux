import CoreGraphics
import Foundation

/// What the launcher's results area offers once the question carries context
/// (a screenshot, files, quotes, tools): the home and quick results both step
/// aside then, and the area would otherwise stay empty. Pure, so every case can
/// be tested without a window. See `AskLauncherContextCanvas`.
enum AskLauncherContextHome {
    /// What the context is about; it picks the headline and the starters.
    enum Subject: Equatable {
        case screenshot
        case image
        case file
        case folder
        case quote
        /// Context of more than one kind.
        case mixed
        /// Only skills or MCP servers: nothing to look at, so no starters.
        case tools
        /// Attachments are still being read.
        case pending
    }

    /// A question the user can send with the context in one step.
    struct Starter: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var tint: AskLauncherHome.Tint
        /// What is sent; the title, so the transcript reads as the user chose it.
        var prompt: String { title }
    }

    struct Content: Equatable {
        var subject: Subject
        /// How many items the subject counts (images, files, quotes…).
        var count: Int
        /// The user has started typing the question.
        var typing: Bool
        var title: String
        var subtitle: String
        /// Empty while typing, while reading and for tools only.
        var starters: [Starter]
    }

    static let maximumStarters = 4

    /// The subject of a draft's context and how many items it counts; nil without context.
    static func subject(attachments: [AskAttachment], references: [AskReference], tools: Int,
                        loading: Bool) -> (subject: Subject, count: Int)? {
        if attachments.isEmpty, references.isEmpty {
            if loading { return (.pending, 0) }
            return tools > 0 ? (.tools, tools) : nil
        }
        if !attachments.isEmpty, !references.isEmpty {
            return (.mixed, attachments.count + references.count)
        }
        if attachments.isEmpty { return (.quote, references.count) }
        // The pieces of one long screenshot are one screenshot.
        if attachments.allSatisfy({ $0.screenshot == true }) { return (.screenshot, 1) }
        let kinds = Set(attachments.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return (.mixed, attachments.count) }
        switch kind {
        case .image: return (.image, attachments.count)
        case .file: return (.file, attachments.count)
        case .folder: return (.folder, attachments.count)
        }
    }

    static func content(_ draft: AskDraft, loading: Bool) -> Content? {
        let tools = (draft.skills ?? []).count + (draft.mcpServers ?? []).count
        guard let (subject, count) = subject(attachments: draft.attachments ?? [], references: draft.references ?? [],
                                             tools: tools, loading: loading) else { return nil }
        let typing = draft.hasText
        let title: String, subtitle: String
        if subject == .pending {
            title = L("ask.launcher.context.title.pending")
            subtitle = L("ask.launcher.context.subtitle.pending")
        } else if typing {
            title = subject == .tools ? L("ask.launcher.context.typing.tools")
                : L("ask.launcher.context.typing", noun(subject, count: count))
            subtitle = L("ask.launcher.context.subtitle.typing")
        } else {
            title = headline(subject, count: count)
            subtitle = L(subject == .tools ? "ask.launcher.context.subtitle.tools" : "ask.launcher.context.subtitle")
        }
        return Content(subject: subject, count: count, typing: typing, title: title, subtitle: subtitle,
                       starters: typing ? [] : starters(for: subject))
    }

    /// "What would you like to know about this screenshot?"
    static func headline(_ subject: Subject, count: Int) -> String {
        switch subject {
        case .screenshot: return L("ask.launcher.context.title.screenshot")
        case .image:
            return count > 1 ? L("ask.launcher.context.title.images", count) : L("ask.launcher.context.title.image")
        case .file:
            return count > 1 ? L("ask.launcher.context.title.files", count) : L("ask.launcher.context.title.file")
        case .folder:
            return count > 1 ? L("ask.launcher.context.title.folders", count) : L("ask.launcher.context.title.folder")
        case .quote: return L("ask.launcher.context.title.quote")
        case .mixed: return L("ask.launcher.context.title.mixed", count)
        case .tools: return L("ask.empty")
        case .pending: return L("ask.launcher.context.title.pending")
        }
    }

    /// What rides with the question: "the screenshot", "3 files".
    static func noun(_ subject: Subject, count: Int) -> String {
        switch subject {
        case .screenshot: return L("ask.launcher.context.noun.screenshot")
        case .image: return L("ask.launcher.context.noun.images", count)
        case .file: return L("ask.launcher.context.noun.files", count)
        case .folder: return L("ask.launcher.context.noun.folders", count)
        case .quote: return L("ask.launcher.context.noun.quotes", count)
        case .mixed, .tools, .pending: return L("ask.launcher.context.noun.items", count)
        }
    }

    /// The most common questions about the subject, most useful first.
    static func starters(for subject: Subject) -> [Starter] {
        let entries: [(String, String, AskLauncherHome.Tint)]
        switch subject {
        case .screenshot:
            entries = [("ocr", "text.viewfinder", .orange), ("explain", "questionmark.circle", .accent),
                       ("debug", "exclamationmark.triangle", .purple), ("translate", "character.bubble", .green)]
        case .image:
            entries = [("describe", "photo", .accent), ("ocr", "text.viewfinder", .orange),
                       ("translate", "character.bubble", .green), ("caption", "text.below.photo", .purple)]
        case .file:
            entries = [("summarize", "list.bullet", .accent), ("facts", "number", .orange),
                       ("translate", "character.bubble", .green), ("todo", "checklist", .purple)]
        case .folder:
            entries = [("overview", "folder", .accent), ("important", "star", .orange),
                       ("organize", "list.bullet.rectangle", .green)]
        case .quote:
            entries = [("translate", "character.bubble", .green), ("summarize", "list.bullet", .accent),
                       ("polish", "pencil", .purple), ("explain", "questionmark.circle", .orange)]
        case .mixed:
            entries = [("compare", "arrow.left.arrow.right", .accent), ("summarize", "list.bullet", .green),
                       ("merge", "doc.on.doc", .purple)]
        case .tools, .pending:
            entries = []
        }
        let group = key(subject)
        return entries.prefix(maximumStarters).map { name, symbol, tint in
            let base = "ask.launcher.context.\(group).\(name)"
            return Starter(id: "\(group).\(name)", title: L(base), detail: L(base + ".detail"),
                           symbol: symbol, tint: tint)
        }
    }

    private static func key(_ subject: Subject) -> String {
        switch subject {
        case .screenshot: return "screenshot"
        case .image: return "image"
        case .file: return "file"
        case .folder: return "folder"
        case .quote: return "quote"
        case .mixed: return "mixed"
        case .tools: return "tools"
        case .pending: return "pending"
        }
    }

    /// The first word of a starter and the space after it (the whole starter when it has
    /// no space): while the editor's text begins with it, it is not read as a keyword.
    static func plainTextLead(of prompt: String) -> String {
        guard let space = prompt.firstIndex(of: " ") else { return prompt }
        return String(prompt[...space])
    }

    // MARK: - Keyboard

    /// The highlight after ↑ (-1) or ↓ (+1); nil is the editor. ↓ enters the list and
    /// stops at its end; ↑ on the first item returns to the editor. Returns nil for ↑
    /// in the editor too: the caller lets that key through (input history).
    static func move(_ index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta > 0 ? 0 : nil }
        let next = index + delta
        if next < 0 { return nil }
        return min(next, count - 1)
    }

    // MARK: - Layout

    /// What fits in the results area: the orb goes first, then the preview shrinks.
    struct Layout: Equatable {
        var showsOrb: Bool
        var compactPreview: Bool
    }

    static let compactPreviewBelow: CGFloat = 330
    static let orbHiddenBelow: CGFloat = 260

    static func layout(viewport: CGFloat) -> Layout {
        Layout(showsOrb: viewport >= orbHiddenBelow, compactPreview: viewport < compactPreviewBelow)
    }
}

/// The launcher's home when it has nothing to list (no recent applications, or
/// application search is off): the conversation window's empty state, scaled to the
/// launcher, with the keyword chips as starting points.
enum AskLauncherWelcome {
    struct Layout: Equatable {
        /// Zero hides the orb.
        var orbSize: CGFloat
        var showsHint: Bool
    }

    static func layout(viewport: CGFloat) -> Layout {
        if viewport < 200 { return Layout(orbSize: 0, showsHint: false) }
        if viewport < 300 { return Layout(orbSize: 0, showsHint: true) }
        return Layout(orbSize: viewport < 380 ? 52 : 72, showsHint: true)
    }

    /// The chip highlight after an arrow key; nil is the editor. ↓ or → enters the
    /// chips; ← and → move along them, wrapping; ↑ returns to the editor. Keys it
    /// does not handle (`handled` false) go on to the editor.
    static func move(_ index: Int?, key: AskLauncherHomeKeyMonitor.Key, count: Int)
        -> (handled: Bool, highlight: Int?) {
        guard count > 0 else { return (false, nil) }
        switch key {
        case let .vertical(delta):
            if delta > 0 { return (true, min(index ?? 0, count - 1)) }
            return (index != nil, nil)
        case let .horizontal(delta):
            guard let index else { return (delta > 0, delta > 0 ? 0 : nil) }
            return (true, ((index + delta) % count + count) % count)
        case .number, .tab:
            return (false, index)
        }
    }
}

/// Where a search that found nothing can go instead of AI: the web and file contents.
enum AskLauncherNoMatch {
    struct Destination: Equatable, Identifiable {
        var keyword: AskKeyword
        var title: String
        var detail: String
        var symbol: String

        var id: String { keyword.id }
    }

    /// The first enabled web search keyword, then the first file search keyword.
    static func destinations(_ keywords: [AskLauncherHome.KeywordChoice], query: String) -> [Destination] {
        var result: [Destination] = []
        if let web = keywords.first(where: { $0.keyword.pluginID == AskWebSearchPlugin.id }) {
            result.append(Destination(keyword: web.keyword, title: L("ask.launcher.noMatch.web", web.title, query),
                                      detail: web.keyword.keyword + " " + query, symbol: "globe"))
        }
        if let files = keywords.first(where: { $0.keyword.pluginID == AskFileSearchPlugin.id }) {
            result.append(Destination(keyword: files.keyword, title: L("ask.launcher.noMatch.files"),
                                      detail: files.keyword.keyword + " " + query, symbol: "doc.text.magnifyingglass"))
        }
        return result
    }

    /// The highlight after ↑/↓; nil is the Ask AI row. Stops at both ends.
    static func move(_ index: Int?, by delta: Int, count: Int) -> Int? {
        AskLauncherContextHome.move(index, by: delta, count: count)
    }
}
