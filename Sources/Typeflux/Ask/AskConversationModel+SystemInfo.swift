import Foundation

extension AskConversationModel {
    /// The launcher shows this Mac's configuration (`sys`) instead of a result card.
    var showsSystemInfo: Bool {
        plugins.keyword?.pluginID == AskSystemInfoPlugin.id
    }

    /// Carries out what a key or click in `sys` asked for.
    func performSystemInfoEffect(_ effect: SystemInfoEffect) -> PluginActionOutcome {
        switch effect {
        case .handled, .unhandled:
            return .stay
        case let .copy(text):
            copyPluginText(text)
            return .stay
        case let .copyReport(markdown):
            AskQuickResults.copy(markdown)
            confirm(L("system.info.report.copied"))
            return .stay
        case let .showSection(section):
            launcherDraft.text = ""
            systemInfo.show(section)
            return .stay
        case .openApp:
            guard let url = SystemInformationApp.url() else {
                confirm(L("system.info.openApp.failed"))
                return .stay
            }
            openApplication(url)
            finishPluginResult()
            return .close
        }
    }
}
