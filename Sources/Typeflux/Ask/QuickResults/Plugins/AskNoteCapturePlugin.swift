import Foundation

/// A private, manual capture surface. Only the model's explicit submit action writes notes.
struct AskNoteCapturePlugin: AskLauncherPlugin {
    static let id = "noteCapture"
    static let keywords = [AskKeyword(keyword: "n", pluginID: id, aliases: ["记"])]
    var id: String {
        Self.id
    }

    var title: String {
        L("ask.noteCapture.title")
    }

    var symbol: String {
        "square.and.pencil"
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

    var preservesInputWhitespace: Bool {
        true
    }

    var entersOnReturn: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        L("ask.noteCapture.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .onSubmit, title: title)
    }

    func run(_: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        throw CancellationError()
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}
