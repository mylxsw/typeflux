import AppKit
import Foundation

/// A menu open over the Output step: adding an action, or inserting a placeholder.
enum AskWorkflowOutputMenu: Equatable {
    case add(AskWorkflowEditorModel.ActionList)
    case placeholder(AskWorkflowEditorModel.ActionList, index: Int, field: AskWorkflowAction.Field)
}

/// The "Output" step's edits to `workflow.json`'s `output`, and the test panel's
/// actions. See `docs/design/workflow-gallery-output-actions.md` §3.5 and §3.7.
extension AskWorkflowEditorModel {
    enum ActionList: String, CaseIterable {
        case onSuccess, onFailure
    }

    /// `output` as an object, whichever way the manifest writes it.
    var outputObject: [String: Any] {
        switch draft?.value(at: ["output"]) {
        case let display as String: ["display": display]
        case let object as [String: Any]: object
        default: [:]
        }
    }

    /// Changes `output`. A manifest that writes `"output": "text"` keeps that short
    /// form until something besides the display is set; an object stays an object.
    func setOutput(_ change: (inout [String: Any]) -> Void) {
        var object = outputObject
        change(&object)
        for key in ActionList.allCases.map(\.rawValue) where (object[key] as? [Any])?.isEmpty == true {
            object[key] = nil
        }
        for key in ["close", "scriptActions"] where object[key] as? Bool == false {
            object[key] = nil
        }
        let wasObject = draft?.value(at: ["output"]) is [String: Any]
        if !wasObject, Set(object.keys).isSubset(of: ["display"]) {
            set(object["display"], at: ["output"])
        } else {
            set(object, at: ["output"])
        }
    }

    func setDisplay(_ display: AskWorkflowManifest.Output.Display) {
        setOutput { $0["display"] = display.rawValue }
    }

    func setOutputFlag(_ key: String, _ value: Bool) {
        setOutput { $0[key] = value }
    }

    /// The list's actions as the manifest holds them, unknown fields included.
    func actions(_ list: ActionList) -> [[String: Any]] {
        outputObject[list.rawValue] as? [[String: Any]] ?? []
    }

    func addAction(_ kind: AskWorkflowAction.Kind, to list: ActionList) {
        setOutput { object in
            let actions = object[list.rawValue] as? [[String: Any]] ?? []
            guard actions.count < AskWorkflowManifest.Output.maximumActions else { return }
            object[list.rawValue] = actions + [kind.template.jsonObject]
        }
    }

    func removeAction(at index: Int, from list: ActionList) {
        setOutput { object in
            var actions = object[list.rawValue] as? [[String: Any]] ?? []
            guard actions.indices.contains(index) else { return }
            actions.remove(at: index)
            object[list.rawValue] = actions
        }
    }

    /// Moves an action to where another one is (drag and drop).
    func moveAction(from source: Int, to destination: Int, in list: ActionList) {
        setOutput { object in
            var actions = object[list.rawValue] as? [[String: Any]] ?? []
            guard source != destination, actions.indices.contains(source), actions.indices.contains(destination)
            else { return }
            actions.insert(actions.remove(at: source), at: destination)
            object[list.rawValue] = actions
        }
    }

    func setActionField(_ field: AskWorkflowAction.Field, to value: String, at index: Int, in list: ActionList) {
        setOutput { object in
            var actions = object[list.rawValue] as? [[String: Any]] ?? []
            guard actions.indices.contains(index) else { return }
            actions[index][field.rawValue] = value.isEmpty && field == .language ? nil : value
            object[list.rawValue] = actions
        }
    }

    // MARK: - Preview

    /// The last test run that got as far as running, for the preview and the placeholder menu.
    var lastRun: AskWorkflowTestResult? {
        results.last { $0.failure == nil }
    }

    /// Placeholder values from the last test run, or from the sample output before there is one.
    var placeholderValues: AskWorkflowPlaceholders {
        let manifest = draft?.manifest
        let keyword = manifest?.keywords.first { $0.keyword == testKeyword } ?? manifest?.keywords.first
        let options = keyword?.options ?? [:]
        if let run = lastRun {
            return run.placeholders(keyword: run.input.keyword ?? keyword?.keyword ?? "", options: options,
                                    timeout: manifest?.timeout ?? AskWorkflowManifest.defaultTimeout, folder: folder)
        }
        return AskWorkflowPlaceholders(output: L("ask.workflow.editor.preview.sample"),
                                       query: testQuery.isEmpty ? "100 usd jpy" : testQuery,
                                       selection: testUsesSelection ? testSelection : nil,
                                       keyword: keyword?.keyword ?? "", options: options)
    }

    /// What the success actions would do with the last run's output: "This run would…".
    var successPreview: [AskWorkflowActionStep] {
        guard let manifest = draft?.manifest, let folder = folder ?? draft?.folder else { return [] }
        var values = placeholderValues
        values.error = nil
        let keyword = manifest.keywords.first { $0.keyword == testKeyword } ?? manifest.keywords.first
        return AskWorkflowActionRunner.steps(for: manifest.output.onSuccess, placeholders: values, folder: folder,
                                             name: manifest.name, chain: keyword.map { [$0.keyword] } ?? [])
    }

    /// "Text · 2 actions" for the step strip.
    static func outputSummary(_ output: AskWorkflowManifest.Output) -> String {
        let display = L("ask.workflow.editor.outputShort." + output.display.rawValue)
        let count = output.onSuccess.count + output.onFailure.count
        return count == 0 ? display : display + " · " + L("ask.workflow.editor.actionsCount", count)
    }

    // MARK: - Test runs

    /// After a test run: lists its actions (preview only), or runs them, asking
    /// before writing back or opening anything.
    func runTestActions(of result: AskWorkflowTestResult) async -> [AskWorkflowActionOutcome] {
        let host = AskWorkflowEditorActionHost(model: self)
        return await AskWorkflowActionRunner.run(result.actionSteps, host: host, perform: !previewActionsOnly) { step in
            await host.confirm(step)
        }
    }
}

/// The test panel's side of a workflow's actions: the real clipboard, notifications
/// and links, with a question before anything leaves the editor. There is no app to
/// write back into, so writing back copies instead and says so; bar notes show in the
/// panel's action list.
@MainActor
final class AskWorkflowEditorActionHost: AskWorkflowActionHost {
    private weak var model: AskWorkflowEditorModel?
    /// Asks before writing back or opening; tests answer for the user.
    var ask: (String) -> Bool = { text in
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: L("ask.workflow.action.confirm.run"))
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The system side of each action; tests record them instead.
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Puts "keyword argument" in the launcher, where Return runs it; false when there is no launcher.
    var openInLauncher: (String) -> Bool = { text in
        AskWorkflowEditorWindowController.shared.openInLauncher?(text) ?? false
    }
    var openApplication: (String) -> Bool = { AskWorkflowLauncherActionHost.openApplication($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var speakText: (String, String) -> Void = { AskSpeaker.shared.speak($0, language: $1) }
    var notifyUser: (String, String) async -> Bool = { title, body in
        await SystemLocalNotificationService.shared.deliverLocalNotification(
            title: title, body: body, identifier: "workflow.test." + UUID().uuidString
        )
    }

    init(model: AskWorkflowEditorModel) {
        self.model = model
    }

    func confirm(_ step: AskWorkflowActionStep) async -> Bool {
        ask(L("ask.workflow.action.confirm", step.title, step.detail))
    }

    func copy(_ text: String) {
        AskQuickResults.copy(text)
    }

    func writeBack(_ text: String) {
        AskQuickResults.copy(text)
        model?.message = L("ask.workflow.action.writeBackInTest")
    }

    func notify(title: String, body: String) async -> Bool {
        await notifyUser(title, body)
    }

    /// The test panel's action list shows the note; the editor's banner is for warnings.
    func hud(_: String) {}

    func open(_ target: AskWorkflowOpenTarget) -> Bool {
        switch target {
        case let .link(url), let .file(url): openURL(url)
        case let .application(name): openApplication(name)
        }
    }

    func reveal(_ url: URL) -> Bool {
        revealFile(url)
        return true
    }

    func speak(_ text: String, language: String?) {
        speakText(text, language ?? AskWorkflowLauncherActionHost.language(of: text))
    }

    func askAI(_: String) {}

    /// A test run has no launcher session to chain in: after the question (as for
    /// writing back), the launcher opens with the keyword and argument typed in.
    func runKeyword(_ keyword: String, argument: String, chain _: [String]) -> Bool {
        openInLauncher(argument.isEmpty ? keyword + " " : keyword + " " + argument)
    }

    /// The test run already asked before opening the link.
    func approve(host _: String) async -> Bool {
        true
    }
}
