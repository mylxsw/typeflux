import Foundation

/// Finds saved notes from the launcher: `nb` alone lists the latest, `nb text` searches
/// titles, text and inputs on this Mac. Return opens a note in a result window.
/// Apple's Notes uses separate `note` (create) and `notes` (search) keywords.
struct AskNotesPlugin: AskLauncherPlugin {
    static let id = "notes"
    static let windowOption = "openWindow"
    static func opensWindow(_ keyword: AskKeyword) -> Bool {
        keyword.pluginID == id && keyword.options[windowOption] == "true"
    }

    static let keywords = [AskKeyword(keyword: "nb", pluginID: id), AskKeyword(keyword: "笔记", pluginID: id),
                           AskKeyword(
                               keyword: "notebook",
                               pluginID: id,
                               options: [windowOption: "true"],
                               aliases: ["笔记本"]
                           )]

    func inputChipTitle(for keyword: AskKeyword) -> String {
        Self.opensWindow(keyword) ? L("ask.notes.openWindow") : title
    }

    static let limit = 8
    static let openNotesItemID = "notes.open"
    static let newNoteItemID = "notes.new"

    var store: (any AskNoteStoring)?

    var id: String {
        Self.id
    }

    var title: String {
        L("ask.notes.title")
    }

    var symbol: String {
        "note.text"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var runsWithoutInput: Bool {
        true
    }

    var usesSelectionInput: Bool {
        false
    }

    var entersOnReturn: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        L("ask.notes.placeholder")
    }

    func chipDetail(for keyword: AskKeyword, language _: AppLanguage) -> String? {
        Self.opensWindow(keyword) ? L("ask.notes.openWindow") : nil
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        if Self.opensWindow(request.keyword) {
            return AskPluginPlan(mode: .onSubmit, title: L("ask.notes.openWindow"),
                                 actions: [AskPromptPlugin.openNotesAction.with(shortcut: .enter)])
        }
        return AskPluginPlan(mode: .live, title: title, debounce: .milliseconds(100))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let query = request.origin == .argument ? request.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let notes: [AskNote]
        do {
            guard let store else { throw LocalStoreFailure.unavailable }
            notes = try await store.list(AskNoteQuery(text: query, limit: Self.limit))
        } catch {
            throw AskPluginFailure(message: L("ask.notes.storageUnavailable"))
        }
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
        if !query.isEmpty {
            items.append(AskPluginItem(id: Self.newNoteItemID, title: L("ask.notes.newTitled", query),
                                       icon: .symbol("square.and.pencil"),
                                       actions: [AskPluginAction(kind: .createNote(query), title: L("ask.notes.new"),
                                                                 symbol: "square.and.pencil", shortcut: .enter)]))
        }
        items.insert(AskPluginItem(id: Self.openNotesItemID, title: L("ask.notes.openWindow"),
                                   subtitle: L("ask.notes.openWindow.detail"), icon: .symbol("macwindow"),
                                   actions: [AskPromptPlugin.openNotesAction.with(shortcut: .enter)]), at: 0)
        return AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: query, meta: [],
                               source: L("ask.plugin.source.device"), actions: [AskPromptPlugin.openNotesAction],
                               items: items,
                               selectedItem: query
                                   .isEmpty ? 0 : (items.indices.dropFirst().first { items[$0].valid } ?? 0))
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}

extension AskPluginAction {
    /// The same action on another key.
    func with(shortcut: Shortcut?) -> AskPluginAction {
        var action = self
        action.shortcut = shortcut
        return action
    }
}
