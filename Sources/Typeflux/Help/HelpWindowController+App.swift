import AppKit
import Combine

extension HelpWindowController {
    /// The guide as the app shows it: it reads the launcher's keywords, the settings and the
    /// permissions, and hands "try it", "ask AI" and settings links back to the app.
    static func app(settings: SettingsStore, ask: AskConversationWindowController?,
                    openSettings: @escaping @MainActor (HelpSettingsDestination) -> Void,
                    openFeedback: @escaping @MainActor (FeedbackDestination) -> Void) -> HelpWindowController {
        let workflowChanges = ask?.model.workflows?.$workflows.map { _ in () }.eraseToAnyPublisher()
        let model = HelpGuideModel(sources: HelpGuideModel.Sources(
            keywords: { [weak ask] language in ask?.model.helpKeywordSources(language: language) ?? [] },
            usage: { [weak ask] in ask?.model.helpKeywordUsage ?? [:] },
            settings: settings,
            permissions: { [settings] in
                PrivacyGuard.requiredSnapshots(settingsStore: settings).map {
                    HelpPermissionStatus(id: $0.id, title: $0.title, detail: $0.detail, granted: $0.isGranted)
                }
            },
            refreshWorkflows: { [weak ask] in await ask?.model.refreshLauncherWorkflows() },
            workflowChanges: workflowChanges ?? Empty().eraseToAnyPublisher()
        ))
        let controller = HelpWindowController(settingsStore: settings, model: model)
        model.actions = HelpGuideModel.Actions(
            close: { [weak controller] in controller?.dismiss() },
            tryKeyword: { [weak ask] keyword, argument in
                ask?.model.tryKeywordFromHelp(keyword, argument: argument)
            },
            askAI: { [weak ask] question in ask?.model.askFromHelp(question) },
            openLauncher: { [weak ask] in ask?.showLauncher() },
            openSettings: openSettings,
            fixPermission: { id in Task { await PrivacyGuard.requestPermission(id) } },
            openFeedback: openFeedback,
            openURL: { url in NSWorkspace.shared.open(url) }
        )
        return controller
    }
}
