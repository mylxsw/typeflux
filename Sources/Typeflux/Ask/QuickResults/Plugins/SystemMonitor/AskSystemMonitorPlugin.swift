import Foundation

/// `top` (or `监控`) opens the system monitor in the launcher; what follows the
/// keyword filters its processes. The launcher draws the monitor itself
/// (`SystemMonitorLauncherView`): a run only says what the filter is.
struct AskSystemMonitorPlugin: AskLauncherPlugin {
    static let id = "systemMonitor"
    static let keywords = [AskKeyword(keyword: "top", pluginID: id), AskKeyword(keyword: "监控", pluginID: id)]
    static let symbol = "gauge.medium"

    var id: String { Self.id }
    var title: String { L("system.monitor.title") }
    var symbol: String { Self.symbol }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }

    func placeholder(selectionLines _: Int?) -> String { L("system.monitor.placeholder") }
    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? { nil }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .zero)
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let filter = request.origin == .argument ? request.text : ""
        return AskPluginOutput(body: filter, original: filter, meta: [], source: L("ask.plugin.source.device"),
                               actions: [])
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? { nil }
}
