import AppKit

@MainActor
final class AppCoordinator {
    private let di = DIContainer()

    private var statusBarController: StatusBarController?
    private var workflowController: WorkflowController?

    func start() {
        let workflowController = WorkflowController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            hotkeyService: di.hotkeyService,
            audioRecorder: di.audioRecorder,
            sttRouter: di.sttRouter,
            llmService: di.llmService,
            textInjector: di.textInjector,
            clipboard: di.clipboard,
            historyStore: di.historyStore,
            overlayController: di.overlayController
        )
        self.workflowController = workflowController

        statusBarController = StatusBarController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            }
        )
        statusBarController?.start()
        self.workflowController?.start()
        presentPermissionGuidanceIfNeeded()
    }

    func stop() {
        workflowController?.stop()
        statusBarController?.stop()
    }

    private func presentPermissionGuidanceIfNeeded() {
        let missingSnapshots = PrivacyGuard.missingRequiredSnapshots(settingsStore: di.settingsStore)
        guard !missingSnapshots.isEmpty else {
            return
        }

        SettingsWindowController.shared.show(
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            initialSection: .settings,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            }
        )
    }
}
