import Foundation

/// Opens the application's System Settings page without forwarding launcher context.
struct AskSettingsPlugin: AskLauncherPlugin {
    static let id = "setting"
    static let keywords = [AskKeyword(keyword: "setting", pluginID: id)]
    var id: String { Self.id }
    var title: String { L("ask.plugin.setting.title") }
    var symbol: String { "gearshape" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    func placeholder(selectionLines: Int?) -> String { L("ask.settings.keywords.kind.setting.hint") }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .onSubmit, title: title, actions: [
            AskPluginAction(kind: .openSettings, title: title, symbol: symbol, shortcut: .enter)
        ])
    }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput { throw CancellationError() }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
