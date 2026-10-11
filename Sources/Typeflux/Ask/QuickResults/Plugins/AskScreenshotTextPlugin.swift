import CoreGraphics
import Foundation

/// A screenshot whose text the launcher shows, read on this Mac while the launcher opens.
struct AskScreenshotTextSource: Sendable {
    var id = UUID()
    var pixelSize: CGSize
    /// The image fits in a question (`AskScreenshotAttachments`); a longer one is asked about by its text.
    var fitsQuestion: Bool
    var recognition: Task<RecognizedText, Error>
}

/// `ocr` / `取字`: frames a region and shows its text in the launcher. Return copies it, ⌥↩
/// types it into the app, ⇥ translates it, ⌘↩ asks the AI about the screenshot, ⌘S saves it
/// to the notes and ⌘R takes a new screenshot. Organize sends the recognized text to the
/// text-processing model and displays Markdown. With no screenshot waiting, Return starts one.
struct AskScreenshotTextPlugin: AskLauncherPlugin {
    static let id = "screenshot.text"
    static let keywords = [
        AskKeyword(keyword: "ocr", pluginID: id),
        AskKeyword(keyword: "取字", pluginID: id)
    ]
    /// The run reads the screenshot it was planned for, by this value.
    static let sourceValue = "screenshot"

    /// The screenshot waiting in the launcher, if any.
    var screenshot: @MainActor @Sendable () -> AskScreenshotTextSource? = { nil }
    var generator: (any AskTextGenerating)?
    var modelName: @Sendable () -> String = { "AI" }
    var savesNotes = false
    /// A read-only Screen Recording check; never prompts.
    var isPermissionGranted: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    var id: String { Self.id }
    var title: String { L("screenshot.text.title") }
    var symbol: String { "text.viewfinder" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }

    func placeholder(selectionLines: Int?) -> String { L("screenshot.text.placeholder") }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        isPermissionGranted() ? nil : L("screenshot.permission.needed")
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        if let source = await screenshot() {
            if request.options[Self.organizeOption] == source.id.uuidString {
                return AskPluginPlan(mode: .onSubmit, title: L("screenshot.text.organize"),
                                     values: [Self.sourceValue: source.id.uuidString,
                                              Self.organizeOption: source.id.uuidString])
            }
            return AskPluginPlan(mode: .live, title: title, values: [Self.sourceValue: source.id.uuidString],
                                 debounce: .zero)
        }
        let meta = isPermissionGranted() ? [] : [AskPluginMeta(text: L("screenshot.permission.needed"),
                                                               emphasized: true)]
        return AskPluginPlan(mode: .onSubmit, title: title, meta: meta, actions: [Self.recaptureAction(.enter)])
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        guard let source = await screenshot(), plan.values[Self.sourceValue] == source.id.uuidString else {
            throw CancellationError()
        }
        let recognized = try await source.recognition.value
        try Task.checkCancellation()
        if plan.values[Self.organizeOption] == source.id.uuidString {
            return try await organize(recognized, source: source, keyword: request.keyword.keyword,
                                      progress: progress)
        }
        return try Self.output(recognized, source: source, keyword: request.keyword.keyword, savesNotes: savesNotes)
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }

    /// The result card, or the empty state when no text was found.
    static func output(_ recognized: RecognizedText, source: AskScreenshotTextSource, keyword: String,
                       savesNotes: Bool) throws -> AskPluginOutput {
        let askAI = AskPluginAction(kind: .screenshotFollowUp(.askAI), title: L("screenshot.followUp.askAI"),
                                    symbol: "sparkles", shortcut: nil)
        guard let text = recognized.string else {
            throw AskPluginFailure(message: L("screenshot.text.empty"), retry: false,
                                   actions: [recaptureAction(.commandR), askAI])
        }
        var actions = [
            AskPluginAction(kind: .copy(text), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc",
                            shortcut: .enter),
            organizeAction(source.id),
            AskPluginAction(kind: .writeBack(text), title: L("screenshot.text.writeBack"), symbol: "text.insert",
                            shortcut: .optionEnter),
            AskPluginAction(kind: .translate(text), title: L("screenshot.followUp.translate"),
                            symbol: "character.bubble", shortcut: .tab),
            recaptureAction(.commandR),
            // A screenshot too long to send as images is asked about by its text.
            source.fitsQuestion ? askAI
                : AskPluginAction(kind: .askAI(L("screenshot.text.askAI", text)), title: L("screenshot.followUp.askAI"),
                                  symbol: "sparkles", shortcut: nil)
        ]
        if savesNotes {
            let draft = AskNoteDraft(command: L("screenshot.text.title"), keyword: keyword, input: "", body: text,
                                     source: .screenshot)
            actions += [AskPromptPlugin.noteAction(draft, saved: false)]
        }
        // One chip: the card shows several as "from → to".
        let size = "\(Int(source.pixelSize.width)) × \(Int(source.pixelSize.height)) px"
        let meta = L("screenshot.text.meta", recognized.lines.count, size)
        var output = AskPluginOutput(body: text, original: "", meta: [AskPluginMeta(text: meta)],
                                     source: L("screenshot.text.source"), actions: actions)
        output.starred = savesNotes ? false : nil
        return output
    }

    /// Takes a new screenshot and reads it.
    static func recaptureAction(_ shortcut: AskPluginAction.Shortcut) -> AskPluginAction {
        AskPluginAction(kind: .capture(mode: .region, followUp: .recognizeText),
                        title: L(shortcut == .enter ? "screenshot.action.start" : "screenshot.text.recapture"),
                        symbol: "text.viewfinder", shortcut: shortcut)
    }
}
