import Foundation

extension AskConversationModel {
    /// The launcher shows the system monitor (`top`) instead of a result card.
    var showsSystemMonitor: Bool { plugins.keyword?.pluginID == AskSystemMonitorPlugin.id }

    /// From the monitor window: the launcher opens on the monitor, focused on `focus`.
    func openSystemMonitorInLauncher(focus: SystemMonitorMetric?) {
        let enter: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let keyword = plugins.availableKeywords.first { $0.enabled && $0.pluginID == AskSystemMonitorPlugin.id }
                ?? AskSystemMonitorPlugin.keywords[0]
            launcherDraft.text = ""
            systemMonitor.reset()
            systemMonitor.setFocus(focus)
            if plugins.keyword?.pluginID != AskSystemMonitorPlugin.id { plugins.enter(keyword) }
            plugins.update(text: "", selection: launcherDraft.sentSelection,
                           language: AppLocalization.shared.language, runWhenPlanned: true)
        }
        guard let onShowLauncher else { enter(); return }
        onShowLauncher(enter)
    }

    /// Carries out what a key or click in the monitor asked for.
    func performSystemMonitorEffect(_ effect: SystemMonitorEffect) -> PluginActionOutcome {
        switch effect {
        case .handled, .unhandled:
            return .stay
        case let .activate(process):
            guard SystemProcessActions.activate(process.pid) else {
                confirm(L("system.monitor.gone", process.name))
                return .stay
            }
            finishPluginResult()
            return .close
        case let .copy(text):
            copyPluginText(text)
            return .stay
        case .popOut:
            systemMonitorWindow.show(sort: systemMonitor.sort)
            finishPluginResult()
            return .close
        case let .terminated(process, success):
            confirm(L(success ? "system.monitor.terminated" : "system.monitor.terminate.failed", process.name))
            return .stay
        case let .refused(process, eligibility):
            confirm(L(eligibility == .typeflux ? "system.monitor.refused.typeflux" : "system.monitor.refused.system",
                      process.name))
            return .stay
        }
    }
}
