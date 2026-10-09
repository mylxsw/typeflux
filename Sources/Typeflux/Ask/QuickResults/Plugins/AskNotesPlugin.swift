import Foundation

/// Finds saved notes from the launcher: `nb` alone lists the latest, `nb text` searches
/// titles, text and inputs on this Mac. Return opens a note in a result window. Not `note`:
/// typing "note" must still open the Notes app.
struct AskNotesPlugin: AskLauncherPlugin {
    static let id = "notes"
    static let keywords = [AskKeyword(keyword: "nb", pluginID: id), AskKeyword(keyword: "笔记", pluginID: id)]
    static let limit = 8
    static let openNotesItemID = "notes.open"

    var store: (any AskNoteStoring)?

    var id: String { Self.id }
    var title: String { L("ask.notes.title") }
    var symbol: String { "note.text" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.notes.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .milliseconds(100))
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let query = request.origin == .argument ? request.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let notes = store?.list(AskNoteQuery(text: query, limit: Self.limit)) ?? []
        try Task.checkCancellation()
        var items = notes.map { note in
            AskPluginItem(
                id: note.id.uuidString, title: note.title, subtitle: note.excerpt,
                icon: .symbol(note.pinned ? "pin.fill" : "note.text"),
                actions: [
                    AskPluginAction(kind: .openNote(note.id), title: L("ask.notes.openNote"),
                                    symbol: "macwindow.on.rectangle", shortcut: .enter),
                    AskPluginAction(kind: .copy(note.body), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc",
                                    shortcut: .commandC)
                ]
            )
        }
        if items.isEmpty {
            let notice = L(query.isEmpty ? "ask.notes.empty" : "ask.notes.noMatch")
            items = [AskPluginItem(id: "notice.notes", title: notice, icon: .symbol("note.text"), valid: false)]
        }
        items.append(AskPluginItem(id: Self.openNotesItemID, title: L("ask.notes.openWindow"),
                                   icon: .symbol("sidebar.left"),
                                   actions: [AskPromptPlugin.openNotesAction.with(shortcut: .enter)]))
        return AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: query, meta: [],
                               source: L("ask.plugin.source.device"), actions: [AskPromptPlugin.openNotesAction],
                               items: items)
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}

extension AskPluginAction {
    /// The same action on another key.
    func with(shortcut: Shortcut?) -> AskPluginAction {
        var action = self
        action.shortcut = shortcut
        return action
    }
}
