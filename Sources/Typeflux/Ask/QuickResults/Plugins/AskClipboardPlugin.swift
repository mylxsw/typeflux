import Foundation

/// Searches the existing local clipboard history without changing the pasteboard while typing.
struct AskClipboardPlugin: AskLauncherPlugin {
    static let id = "clip"
    static let keywords = [AskKeyword(keyword: "clip", pluginID: id)]
    var entries: @MainActor @Sendable () -> [ClipboardEntry]

    var id: String {
        Self.id
    }

    var title: String {
        L("ask.plugin.clip.title")
    }

    var symbol: String {
        "doc.on.clipboard"
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
        L("ask.plugin.clip.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        // Opening history needs no typing debounce; keep it when filtering successive keystrokes.
        AskPluginPlan(mode: .live, title: title,
                      debounce: request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          ? .zero : .milliseconds(100))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let query = request.origin == .argument ? request.text : ""
        let snapshot = await entries()
        let matches = ClipboardFeed.filter(snapshot, category: .all, query: query).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.date > $1.date
        }
        try Task.checkCancellation()
        let now = Date()
        var items = matches.map { entry in
            let icon: AskPluginItem.Icon = if let path = entry.imagePath {
                .image(URL(fileURLWithPath: path))
            } else if let url = entry.fileURLs.first {
                .fileIcon(url)
            } else {
                .symbol(entry.kind == .link ? "link" : "doc.text")
            }
            return AskPluginItem(
                id: entry.id,
                title: String(entry.title.prefix(200)).split(whereSeparator: \.isWhitespace).joined(separator: " "),
                subtitle: ClipboardEntryFormatter.details(for: entry, now: now).joined(separator: " · "),
                icon: icon,
                actions: [
                    AskPluginAction(kind: .pasteClipboard(entry.id), title: L("clipboard.action.paste"),
                                    symbol: "doc.on.clipboard", shortcut: .enter),
                    AskPluginAction(kind: .copyClipboard(entry.id), title: L("clipboard.action.copy"),
                                    symbol: "doc.on.doc", shortcut: .commandC),
                    AskPluginAction(kind: .previewClipboard(entry.id), title: L("clipboard.action.quickLook"),
                                    symbol: "eye", shortcut: .optionEnter)
                ]
            )
        }
        if items.isEmpty {
            let empty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            items = [AskPluginItem(
                id: "notice.clip",
                title: L(empty ? "ask.plugin.clip.empty" : "ask.plugin.clip.noMatch"),
                icon: .symbol(symbol),
                valid: false
            )]
        }
        return AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: query,
                               meta: [], source: L("ask.plugin.source.device"), actions: [], items: items)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}
