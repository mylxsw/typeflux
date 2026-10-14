import CoreGraphics
import Foundation

/// Starts a screenshot from the launcher: `jt` / `截图` frame a region, `jtqp` takes the
/// whole display, `jtgd` frames a region and captures it while it scrolls, `jtai` frames a
/// region and asks the AI about it. Return closes the launcher first, then the displays freeze.
struct AskScreenshotPlugin: AskLauncherPlugin {
    static let id = "screenshot"
    static let keywords = [
        AskKeyword(keyword: "jt", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.region.rawValue]),
        AskKeyword(keyword: "截图", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.region.rawValue]),
        AskKeyword(keyword: "jtqp", pluginID: id,
                   options: [ScreenshotMode.option: ScreenshotMode.fullScreen.rawValue]),
        AskKeyword(keyword: "jtgd", pluginID: id,
                   options: [ScreenshotMode.option: ScreenshotMode.scrolling.rawValue]),
        AskKeyword(keyword: "jtai", pluginID: id,
                   options: [ScreenshotMode.option: ScreenshotMode.region.rawValue,
                             ScreenshotFollowUp.option: ScreenshotFollowUp.askAI.rawValue]),
        AskKeyword(keyword: "lp", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.recording.rawValue]),
        AskKeyword(keyword: "录屏", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.recording.rawValue]),
        AskKeyword(keyword: "gif", pluginID: id, options: [ScreenshotMode.option: ScreenshotMode.gif.rawValue])
    ]

    /// Keywords that start a screenshot at once on Return, even before they are entered.
    static func startsCapture(_ keyword: AskKeyword) -> Bool {
        keyword.pluginID == id || keyword.pluginID == AskScreenshotTextPlugin.id
    }

    /// What Return on such a keyword does: `ocr` reads the region's text, the rest follow their options.
    static func captureKind(for keyword: AskKeyword) -> AskPluginAction.Kind {
        if keyword.pluginID == AskScreenshotTextPlugin.id {
            return .capture(mode: .region, followUp: .recognizeText)
        }
        return .capture(mode: ScreenshotMode(options: keyword.options),
                        followUp: ScreenshotFollowUp(options: keyword.options))
    }

    /// A read-only Screen Recording check; never prompts.
    var isPermissionGranted: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    var id: String {
        Self.id
    }

    var title: String {
        L("screenshot.title")
    }

    var symbol: String {
        "camera.viewfinder"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var optionName: String? {
        L("screenshot.plugin.option")
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
        L("screenshot.plugin.placeholder")
    }

    /// "Needs permission" until Screen Recording is granted; otherwise the mode, when not the usual one.
    func chipDetail(for keyword: AskKeyword, language _: AppLanguage) -> String? {
        guard isPermissionGranted() else { return L("screenshot.permission.needed") }
        if ScreenshotFollowUp(options: keyword.options) == .askAI {
            return L("screenshot.followUp.askAI")
        }
        return switch ScreenshotMode(options: keyword.options) {
        case .region: nil
        case .fullScreen: L("screenshot.mode.fullScreen.short")
        case .scrolling: L("screenshot.mode.scrolling.short")
        case .recording: L("recording.title")
        case .gif: L("recording.gif")
        }
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let mode = ScreenshotMode(options: request.options)
        let followUp = ScreenshotFollowUp(options: request.options)
        let meta = isPermissionGranted() ? [] : [AskPluginMeta(text: L("screenshot.permission.needed"),
                                                               emphasized: true)]
        let title = followUp == .askAI ? L("screenshot.mode.askAI") : Self.title(of: mode)
        return AskPluginPlan(mode: .onSubmit, title: title, meta: meta, actions: [
            AskPluginAction(kind: .capture(mode: mode, followUp: followUp), title: L("screenshot.action.start"),
                            symbol: symbol, shortcut: .enter)
        ])
    }

    func run(_: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // The launcher carries out the plan's action; there is nothing to run.
        throw CancellationError()
    }

    /// ⇥ cycles through framing a region, the whole display and a scrolling capture.
    func nextOptions(after _: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        let mode = ScreenshotMode(options: request.options)
        let modes: [ScreenshotMode] = mode == .recording || mode == .gif
            ? [.recording, .gif] : [.region, .fullScreen, .scrolling]
        let current = modes.firstIndex(of: ScreenshotMode(options: request.options)) ?? 0
        return [ScreenshotMode.option: modes[(current + step % modes.count + modes.count) % modes.count].rawValue]
    }

    static func title(of mode: ScreenshotMode) -> String {
        switch mode {
        case .region: L("screenshot.mode.region")
        case .fullScreen: L("screenshot.mode.fullScreen")
        case .scrolling: L("screenshot.mode.scrolling")
        case .recording: L("recording.title")
        case .gif: L("recording.gif")
        }
    }
}
