import Foundation

/// Searches indexed content directly, without mixing in filename or recent-file matches.
struct AskSemanticFileSearchPlugin: AskLauncherPlugin {
    static let id = "semanticFiles"
    static let keywords = [AskKeyword(keyword: "ss", pluginID: id, aliases: ["semanticsearch", "语义检索"])]

    var semantic: @MainActor @Sendable () -> (any SemanticFileSearching)?
    var settings: @Sendable () -> AskLauncherSearchSettings

    var id: String {
        Self.id
    }

    var title: String {
        L("semantic.title")
    }

    var symbol: String {
        "sparkle.magnifyingglass"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var runsWithoutInput: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        L("semantic.keyword.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: request.origin == .selection ? .onSubmit : .live, title: title,
                      debounce: .milliseconds(150))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        try Task.checkCancellation()
        guard let service = await semantic(), await service.isEnabled else {
            var notice = AskFileSearchPlugin.notice(L("semantic.keyword.unavailable"), symbol: "exclamationmark.circle")
            notice.valid = true
            notice.actions = [.init(kind: .openSettings, title: L("ask.plugin.setting.title"),
                                    symbol: "gearshape", shortcut: .enter)]
            return output([notice], request: request)
        }
        let text = request.origin == .selection ? request.text.split(whereSeparator: \.isNewline)
            .joined(separator: " ") : request.text
        guard SemanticFilePolicy.query(text) != nil else {
            return output([AskFileSearchPlugin.notice(L("semantic.keyword.query"), symbol: symbol)], request: request)
        }
        let pending = AskPluginItem(
            id: "semantic.searching",
            title: L("semantic.searching"),
            valid: false,
            loading: true
        )
        await progress(output([pending], request: request))
        let hits = await service.search(text, type: .all, limit: settings().limit)
        try Task.checkCancellation()
        let items = hits.isEmpty
            ? [AskFileSearchPlugin.notice(L("semantic.keyword.none"), symbol: "doc.questionmark")]
            : hits.map(AskFileSearchPlugin.item)
        return output(items, request: request)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    private func output(_ items: [AskPluginItem], request: AskPluginRequest) -> AskPluginOutput {
        var result = AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: request.text,
                                     meta: [], source: title, actions: [], items: items)
        result.selectedItem = result.selectableIndices.first ?? -1
        return result
    }
}
