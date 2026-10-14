import Foundation

/// Opens the usage guide: `help` alone shows it, `help 截图` opens it searching for 截图.
struct AskHelpPlugin: AskLauncherPlugin {
    static let id = "help"
    static let keywords = [AskKeyword(keyword: "help", pluginID: id, aliases: ["帮助"])]
    var id: String { Self.id }
    var title: String { L("ask.plugin.help.title") }
    var symbol: String { "questionmark.circle" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.plugin.help.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let query = Self.query(request)
        return AskPluginPlan(mode: .onSubmit, title: title, actions: [
            AskPluginAction(kind: .openHelp(query: query), title: title, symbol: symbol, shortcut: .enter)
        ])
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // The launcher carries out the plan's action; nothing runs.
        throw CancellationError()
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }

    /// What to search the guide for: only text typed after the keyword, never the selection.
    static func query(_ request: AskPluginRequest) -> String {
        request.origin == .argument ? request.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}
