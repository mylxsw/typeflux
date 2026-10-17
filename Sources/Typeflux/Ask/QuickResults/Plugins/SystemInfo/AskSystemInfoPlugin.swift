import Foundation

/// `sys` (or `about`, `本机`, `配置`) shows this Mac's configuration in the launcher;
/// what follows the keyword finds rows. The launcher draws it itself
/// (`SystemInfoLauncherView`): a run only says what the filter is.
struct AskSystemInfoPlugin: AskLauncherPlugin {
    static let id = "systemInfo"
    static let keywords = [AskKeyword(keyword: "sys", pluginID: id, aliases: ["about", "本机", "配置"])]
    static let symbol = "info.circle"

    var id: String {
        Self.id
    }

    var title: String {
        L("system.info.title")
    }

    var symbol: String {
        Self.symbol
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
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
        L("system.info.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .zero)
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let filter = request.origin == .argument ? request.text : ""
        return AskPluginOutput(body: filter, original: filter, meta: [], source: L("ask.plugin.source.device"),
                               actions: [])
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}
