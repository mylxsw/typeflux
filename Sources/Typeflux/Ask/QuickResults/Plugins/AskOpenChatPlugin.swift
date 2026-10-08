import Foundation

/// Opens the workspace only after confirmation; never invokes a model.
struct AskOpenChatPlugin: AskLauncherPlugin {
    static let id = "chat"
    static let keywords = [AskKeyword(keyword: "chat", pluginID: id)]
    var id: String { Self.id }
    var title: String { L("ask.openChat") }
    var symbol: String { "macwindow" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.openChat.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .onSubmit, title: title, actions: [
            AskPluginAction(kind: .openChat, title: title, symbol: symbol, shortcut: .enter)
        ])
    }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // The launcher handles the plan's action; there is no executable request.
        throw CancellationError()
    }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
