import CoreGraphics
import Foundation

/// Starts a screenshot from the launcher: `jt` / `截图` frame a region, `jtqp` takes the
/// whole display. Return closes the launcher first, then the displays freeze.
struct AskScreenshotPlugin: AskLauncherPlugin {
    static let id = "screenshot"
    static let keywords = [
        AskKeyword(keyword: "jt", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.region.rawValue]),
        AskKeyword(keyword: "截图", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.region.rawValue]),
        AskKeyword(keyword: "jtqp", pluginID: id,
                   options: [ScreenshotMode.option: ScreenshotMode.fullScreen.rawValue])
    ]

    /// A read-only Screen Recording check; never prompts.
    var isPermissionGranted: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    var id: String { Self.id }
    var title: String { L("screenshot.title") }
    var symbol: String { "camera.viewfinder" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var optionName: String? { L("screenshot.plugin.option") }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }

    func placeholder(selectionLines: Int?) -> String { L("screenshot.plugin.placeholder") }

    /// "Needs permission" until Screen Recording is granted; otherwise the mode, when not the usual one.
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        guard isPermissionGranted() else { return L("screenshot.permission.needed") }
        return ScreenshotMode(options: keyword.options) == .region ? nil : L("screenshot.mode.fullScreen.short")
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let mode = ScreenshotMode(options: request.options)
        let meta = isPermissionGranted() ? [] : [AskPluginMeta(text: L("screenshot.permission.needed"),
                                                               emphasized: true)]
        return AskPluginPlan(mode: .onSubmit, title: Self.title(of: mode), meta: meta, actions: [
            AskPluginAction(kind: .capture(mode: mode), title: L("screenshot.action.start"), symbol: symbol,
                            shortcut: .enter)
        ])
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // The launcher carries out the plan's action; there is nothing to run.
        throw CancellationError()
    }

    /// ⇥ switches between framing a region and the whole display.
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        let modes = ScreenshotMode.allCases
        let current = modes.firstIndex(of: ScreenshotMode(options: request.options)) ?? 0
        return [ScreenshotMode.option: modes[(current + step % modes.count + modes.count) % modes.count].rawValue]
    }

    static func title(of mode: ScreenshotMode) -> String {
        switch mode {
        case .region: L("screenshot.mode.region")
        case .fullScreen: L("screenshot.mode.fullScreen")
        }
    }
}
