import Foundation

struct AskBrowserTabTarget: Equatable, Sendable {
    var browser: AskSearchBrowser
    var windowID: String
    var tabID: String
    var index: Int
    var url: String
}

struct AskBrowserSearchEntry: Equatable, Sendable, Identifiable {
    private struct Ranked {
        var rank: Int
        var order: Int
        var entry: AskBrowserSearchEntry
    }
    enum Kind: String, Sendable { case tab, bookmark }
    var id: String
    var kind: Kind
    var browser: AskSearchBrowser
    var title: String
    var url: String
    var folder = ""
    var profile = ""
    var target: AskBrowserTabTarget?

    var subtitle: String {
        [browser.title, profile, folder, url].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Every word may match a different field; exact names precede URL matches.
    static func search(_ entries: [Self], query: String, limit: Int) -> [Self] {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let text = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.enumerated().compactMap { index, entry -> Ranked? in
            let title = normalized(entry.title)
            let fields = [title, normalized(entry.url), normalized(entry.folder), normalized(entry.profile)]
            guard words.allSatisfy({ word in fields.contains { $0.contains(word) } }) else { return nil }
            let rank = text.isEmpty ? 3 : title == text ? 0 : title.hasPrefix(text) ? 1 : title.contains(text) ? 2 : 3
            return Ranked(rank: rank, order: index, entry: entry)
        }.sorted { $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank }
            .prefix(max(0, limit)).map(\.entry)
    }

    func item(settings: AskBrowserSearchSettings, icon: AskPluginItem.Icon? = nil) -> AskPluginItem {
        let action: AskPluginAction.Kind
        if let target { action = .focusBrowserTab(target) } else if let link = Self.bookmarkURL(url) {
            let browser = AskSearchBrowser(rawValue: settings.bookmarkBrowser) ?? browser
            action = settings.bookmarkBrowser == "default" ? .open(link) : .openIn(link, application: browser.bundleID)
        } else {
            return .init(id: id, title: title, subtitle: subtitle, valid: false)
        }
        return .init(id: id, title: title.isEmpty ? url : title, subtitle: subtitle,
                     icon: icon ?? .symbol(kind == .tab ? "rectangle.on.rectangle" : "bookmark"), actions: [
                         .init(kind: action, title: L(kind == .tab ? "ask.browser.focus" : "ask.quick.action.open"),
                               symbol: "arrow.up.forward.app", shortcut: .enter),
                         .init(kind: .copy(url), title: L("ask.browser.copy"), symbol: "link", shortcut: .commandC)
                     ])
    }

    /// Bookmarklets must never execute as a side effect of search.
    static func bookmarkURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              ["http", "https", "file", "ftp"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct AskBrowserSearchIssue: Equatable, Sendable {
    enum Reason: Sendable { case automation, diskAccess, unreadable }
    var browser: AskSearchBrowser
    var reason: Reason

    var item: AskPluginItem {
        let key: String
        let pane: String
        switch reason {
        case .automation: key = "ask.browser.automation"; pane = "Privacy_Automation"
        case .diskAccess: key = "ask.browser.diskAccess"; pane = "Privacy_AllFiles"
        case .unreadable: key = "ask.browser.unreadable"; pane = ""
        }
        let action = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)
        return .init(id: "browser.issue." + browser.id, title: L(key, browser.title),
                     icon: .symbol("exclamationmark.circle"), valid: !pane.isEmpty,
                     actions: pane.isEmpty ? [] : [.init(kind: .open(action!), title: L("ask.browser.permissions"),
                                                         symbol: "gearshape", shortcut: .enter)])
    }
}

struct AskBrowserSearchSnapshot: Sendable {
    var entries: [AskBrowserSearchEntry] = []
    var issues: [AskBrowserSearchIssue] = []
}
