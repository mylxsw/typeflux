import Foundation

/// A local directory of the launcher's actual keywords, including aliases and workflows.
struct AskPrefixPlugin: AskLauncherPlugin {
    struct Entry: Equatable, Sendable {
        var keyword: AskKeyword
        var title: String
        var detail = ""
        var symbol: String
        var unavailableReason: String?

        var canEnter: Bool { keyword.enabled && unavailableReason == nil }
    }

    static let id = "prefix"
    static let keywords = [AskKeyword(keyword: "prefix", pluginID: id)]
    var entries: @MainActor @Sendable (AppLanguage) -> [Entry]

    var id: String { Self.id }
    var title: String { L("ask.plugin.prefix.title") }
    var symbol: String { "list.bullet.rectangle" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.plugin.prefix.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .zero)
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let query = request.origin == .argument ? request.text : ""
        let matches = Self.filter(await entries(request.interfaceLanguage), query: query)
        let items = matches.map { entry in
            var subtitle = [entry.title, entry.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            if let reason = entry.unavailableReason {
                subtitle += " · " + reason
            } else if !entry.keyword.enabled {
                subtitle += " · " + L("ask.plugin.prefix.disabled")
            }
            return AskPluginItem(
                id: entry.keyword.pluginID + ":" + entry.keyword.id,
                title: entry.keyword.keyword, subtitle: subtitle, icon: .symbol(entry.symbol), valid: entry.canEnter,
                actions: entry.canEnter ? [
                    AskPluginAction(kind: .enterKeyword(entry.keyword.id), title: L("ask.plugin.prefix.enter"),
                                    symbol: "arrow.right", shortcut: .enter)
                ] : []
            )
        }
        return AskPluginOutput(
            body: items.isEmpty ? L("ask.plugin.prefix.noMatch", query) : items.map(\.title).joined(separator: "\n"),
            original: query, meta: [], source: L("ask.plugin.source.device"), actions: [], items: items
        )
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }

    /// Exact matches, then starts, then substrings; unavailable rows come last.
    /// Ties preserve the configured order rather than moving while the user browses.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func rank(_ entry: Entry) -> Int? {
            if query.isEmpty { return 0 }
            let fields = [entry.keyword.keyword, entry.title, entry.detail].map { $0.lowercased() }
            if fields.contains(query) { return 0 }
            if fields.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if fields.contains(where: { $0.contains(query) }) { return 2 }
            return nil
        }
        return entries.enumerated().compactMap { index, entry -> (Int, Entry, Int)? in
            rank(entry).map { (index, entry, $0) }
        }.sorted { left, right in
            if left.1.canEnter != right.1.canEnter { return left.1.canEnter }
            if left.2 != right.2 { return left.2 < right.2 }
            return left.0 < right.0
        }.map { $0.1 }
    }
}
