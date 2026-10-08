import Foundation

/// Searches known chat titles on this Mac; typing never performs a network request.
struct AskHistoryPlugin: AskLauncherPlugin {
    struct Snapshot: Sendable {
        var account: String
        var conversations: [AskConversationSummary]
        static let empty = Snapshot(account: "", conversations: [])
    }
    static let id = "history"
    static let keywords = [AskKeyword(keyword: "history", pluginID: id)]
    var conversations: @MainActor @Sendable () async -> Snapshot

    var id: String { Self.id }
    var title: String { L("ask.plugin.history.title") }
    var symbol: String { "clock.arrow.circlepath" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.plugin.history.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .milliseconds(100))
    }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let query = request.origin == .argument ? request.text : ""
        let snapshot = await conversations()
        let matches = AskPresentation.filterHistory(snapshot.conversations, query: query).sorted { $0.updatedAt > $1.updatedAt }
        try Task.checkCancellation()
        let items = matches.map { conversation in
            AskPluginItem(id: conversation.id, title: conversation.title.isEmpty ? L("ask.new") : conversation.title,
                          subtitle: AskPresentation.historyTimeLabel(conversation.updatedAt), icon: .symbol("bubble.left.and.bubble.right"),
                          actions: [AskPluginAction(kind: .openConversation(conversation.id, account: snapshot.account), title: L("ask.plugin.history.open"),
                                                    symbol: "arrow.up.right", shortcut: .enter)])
        }
        return AskPluginOutput(body: items.isEmpty ? L("ask.plugin.history.noMatch") : items.map(\.title).joined(separator: "\n"),
                               original: query, meta: [], source: L("ask.plugin.source.device"),
                               note: L("ask.plugin.history.note"), actions: [], items: items)
    }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
