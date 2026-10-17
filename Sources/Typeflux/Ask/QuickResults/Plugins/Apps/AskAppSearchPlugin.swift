import Foundation

/// Searches installed applications without mixing in files or Settings panes.
struct AskAppSearchPlugin: AskLauncherPlugin {
    static let id = "appSearch"
    static let keywords = [AskKeyword(keyword: "app", pluginID: id)]

    var index: @MainActor @Sendable () -> (any AskAppSearching)?

    var id: String { Self.id }
    var title: String { L("ask.plugin.apps.title") }
    var symbol: String { "square.grid.2x2" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }

    func placeholder(selectionLines _: Int?) -> String { L("ask.plugin.apps.placeholder") }
    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? { nil }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        .init(mode: .live, title: title, debounce: .milliseconds(16))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        guard let index = await index() else { return output([], notice: "ask.plugin.apps.off") }
        index.refreshIfStale()
        let query = request.origin == .argument ? request.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let apps: [AskAppEntry]
        if query.isEmpty {
            apps = index.applications().filter { $0.kind == .application }
        } else {
            apps = index.search(query, limit: 200).map(\.entry).filter { $0.kind == .application }
        }
        try Task.checkCancellation()
        return output(apps, notice: query.isEmpty ? "ask.plugin.apps.empty" : "ask.plugin.apps.noMatch")
    }

    private func output(_ apps: [AskAppEntry], notice: String) -> AskPluginOutput {
        let items = apps.isEmpty
            ? [AskPluginItem(id: notice, title: L(notice), icon: .symbol(symbol), valid: false)]
            : apps.map { app in
                AskPluginItem(id: app.id, title: app.name,
                              subtitle: app.url.deletingLastPathComponent().path,
                              icon: .fileIcon(app.url),
                              actions: [.init(kind: .openApplication(app), title: L("ask.plugin.apps.open"),
                                              symbol: "arrow.up.right", shortcut: .enter)])
            }
        return .init(body: items.map(\.title).joined(separator: "\n"), original: "", meta: [],
                     source: title, actions: [], items: items)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? { nil }
}
