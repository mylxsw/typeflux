import Foundation

/// Enters the inline conversation surface. The conversation model owns execution.
struct AskQuickAskPlugin: AskLauncherPlugin {
    static let id = "quickAsk"
    static let keywords = [AskKeyword(keyword: "qa", pluginID: id)]
    var id: String { Self.id }
    var title: String { L("ask.quickAsk.title") }
    var symbol: String { "bubble.left.and.text.bubble.right" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var entersOnReturn: Bool { true }
    var usesSelectionInput: Bool { false }
    func placeholder(selectionLines: Int?) -> String { L("ask.quickAsk.placeholder") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .onSubmit, title: title)
    }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        throw CancellationError()
    }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
