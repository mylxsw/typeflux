import Foundation

/// Searches the web for the text after its keyword, or the selection: `g` on
/// Google, `bd` on Baidu, `gh` on GitHub, or any URL template the user adds.
/// Nothing runs: Return opens the browser and ⌘C copies the link.
struct AskWebSearchPlugin: AskLauncherPlugin {
    static let id = "web"
    /// A built-in engine by name; ⇥ steps through them.
    static let engineOption = "engine"
    /// A user's own engine: its name, and a URL with `{query}` where the words go.
    static let titleOption = "title"
    static let urlOption = "url"
    static let queryToken = "{query}"

    enum Engine: String, CaseIterable, Sendable {
        case google, baidu, github

        var keyword: String {
            switch self {
            case .google: "g"
            case .baidu: "bd"
            case .github: "gh"
            }
        }

        var title: String {
            switch self {
            case .google: "Google"
            case .baidu: L("ask.plugin.web.baidu")
            case .github: "GitHub"
            }
        }

        var template: String {
            switch self {
            case .google: "https://www.google.com/search?q={query}"
            case .baidu: "https://www.baidu.com/s?wd={query}"
            case .github: "https://github.com/search?q={query}"
            }
        }
    }

    var id: String { Self.id }
    var title: String { L("ask.plugin.web.title") }
    var symbol: String { "magnifyingglass" }
    var optionName: String? { L("ask.plugin.web.option") }

    static let keywords = Engine.allCases.map {
        AskKeyword(keyword: $0.keyword, pluginID: id, options: [engineOption: $0.rawValue])
    }

    var defaultKeywords: [AskKeyword] { Self.keywords }

    /// The engine's name and URL template: a user's own when it has a URL, else a built-in one.
    static func engine(of options: [String: String]) -> (title: String, template: String) {
        if let template = options[urlOption]?.trimmingCharacters(in: .whitespaces), !template.isEmpty {
            let title = options[titleOption]?.trimmingCharacters(in: .whitespaces)
            return (title?.isEmpty == false ? title! : host(of: template) ?? L("ask.plugin.web.title"), template)
        }
        let engine = options[engineOption].flatMap(Engine.init(rawValue:)) ?? .google
        return (engine.title, engine.template)
    }

    /// The link for `query`: the words percent-encoded into `{query}`. Nil unless
    /// it makes an http(s) link with a host, so a template cannot open anything else.
    static func url(template: String, query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        guard template.contains(queryToken),
              let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: queryToken, with: encoded)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Why a URL template cannot be saved, or nil when it can.
    static func problem(with template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(queryToken) else { return L("ask.settings.plugins.web.problem.query") }
        guard url(template: trimmed, query: "test") != nil else { return L("ask.settings.plugins.web.problem.url") }
        return nil
    }

    static func host(of template: String) -> String? {
        URL(string: template.replacingOccurrences(of: queryToken, with: ""))?.host
    }

    func placeholder(selectionLines: Int?) -> String {
        guard let selectionLines, selectionLines > 0 else { return L("ask.plugin.web.placeholder") }
        return L("ask.plugin.web.placeholder.selection")
    }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        Self.engine(of: keyword.options).title
    }

    /// Searching only opens a link, so the plan is the result: Return opens it, ⌘C copies it.
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let engine = Self.engine(of: request.options)
        let query = request.text.replacingOccurrences(of: "\n", with: " ")
        let title = L("ask.plugin.web.search", engine.title, query)
        guard let url = Self.url(template: engine.template, query: query) else {
            return AskPluginPlan(mode: .onSubmit, title: title, meta: [AskPluginMeta(text: engine.title)])
        }
        return AskPluginPlan(mode: .onSubmit, title: title, meta: [AskPluginMeta(text: url.host ?? engine.title)],
                             values: [Self.urlOption: url.absoluteString],
                             actions: [
                                 AskPluginAction(kind: .open(url), title: L("ask.plugin.action.open"), symbol: "safari",
                                                 shortcut: .enter),
                                 AskPluginAction(kind: .copy(url.absoluteString), title: L("ask.plugin.action.copyLink"),
                                                 symbol: "link", shortcut: .commandC)
                             ])
    }

    /// Only reached when the template made no link: say so.
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        throw AskPluginFailure(message: L("ask.settings.plugins.web.problem.url"), retry: false)
    }

    /// ⇥ steps through the built-in engines from the current one.
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        let engines = Engine.allCases
        let current = request.options[Self.urlOption]?.isEmpty == false
            ? nil : request.options[Self.engineOption].flatMap(Engine.init(rawValue:)) ?? .google
        let index = current.flatMap { engines.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        let next = engines[((index + step) % engines.count + engines.count) % engines.count]
        // Clearing a user's URL lets the built-in engine take over.
        return [Self.engineOption: next.rawValue, Self.urlOption: "", Self.titleOption: ""]
    }
}
