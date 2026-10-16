import AppKit

struct AskBrowserSearchPlugin: AskLauncherPlugin {
    static let tabsID = "browserTabs"
    static let bookmarksID = "browserBookmarks"
    static let refreshOption = "browserRefresh"
    static let keywords = [
        AskKeyword(keyword: "tab", pluginID: tabsID),
        AskKeyword(keyword: "bmk", pluginID: bookmarksID)
    ]

    var kind: AskBrowserSearchEntry.Kind
    var service: any AskBrowserSearching
    var settings: @Sendable () -> AskBrowserSearchSettings
    var id: String {
        kind == .tab ? Self.tabsID : Self.bookmarksID
    }

    var title: String {
        L(kind == .tab ? "ask.browser.tabs" : "ask.browser.bookmarks")
    }

    var symbol: String {
        kind == .tab ? "rectangle.on.rectangle" : "bookmark"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords.filter { $0.pluginID == id }
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
        L("ask.browser.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        .init(mode: .live, title: title, debounce: .milliseconds(16))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let preferences = settings()
        let enabled = kind == .tab ? preferences.tabsEnabled : preferences.bookmarksEnabled
        guard enabled else { return output([notice("ask.browser.disabled")]) }
        let browsers = kind == .tab ? preferences.tabBrowsers : preferences.bookmarkBrowsers
        let snapshot: AskBrowserSearchSnapshot = if request.options[Self.refreshOption] == "true" {
            await service.refreshSnapshot(kind: kind, browsers: browsers, interactive: true)
        } else {
            await service.snapshot(kind: kind, browsers: browsers, interactive: true)
        }
        try Task.checkCancellation()
        let query = request.origin == .selection ? "" : request.text
        let entries = AskBrowserSearchEntry.search(snapshot.entries, query: query, limit: 100)
        var items = entries.map { $0.item(settings: preferences) }
        if items.isEmpty {
            items.append(notice(query.isEmpty ? "ask.browser.empty" : "ask.browser.noMatch"))
        }
        items += snapshot.issues.map(\.item)
        var result = output(items)
        result.rerunAfter = kind == .tab ? 3 : 6
        result.variables[Self.refreshOption] = ""
        return result
    }

    private func notice(_ key: String) -> AskPluginItem {
        .init(id: key, title: L(key), icon: .symbol(symbol), valid: false)
    }

    private func output(_ items: [AskPluginItem]) -> AskPluginOutput {
        .init(body: items.map(\.title).joined(separator: "\n"), original: "", meta: [], source: title,
              actions: [.init(
                  kind: .rerun([Self.refreshOption: "true"]),
                  title: L("ask.browser.refresh"),
                  symbol: "arrow.clockwise",
                  shortcut: .commandR
              )],
              items: items)
    }
}
