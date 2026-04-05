import AppKit

@MainActor
final class AppCoordinator {
    private let di = DIContainer()

    private var statusBarController: StatusBarController?
    private var workflowController: WorkflowController?
    private var onboardingWindowController: OnboardingWindowController?

    func start() {
        let workflowController = WorkflowController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            hotkeyService: di.hotkeyService,
            audioRecorder: di.audioRecorder,
            sttRouter: di.sttRouter,
            llmService: di.llmService,
            llmAgentService: di.llmAgentService,
            textInjector: di.textInjector,
            clipboard: di.clipboard,
            historyStore: di.historyStore,
            agentJobStore: di.agentJobStore,
            overlayController: di.overlayController,
            askAnswerWindowController: di.askAnswerWindowController,
            soundEffectPlayer: di.soundEffectPlayer,
        )
        self.workflowController = workflowController

        statusBarController = StatusBarController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            },
            onOpenOnboarding: { [weak self] in
                self?.showOnboarding()
            },
        )
        statusBarController?.start()
        self.workflowController?.start()
        UsageStatsStore.shared.backfillIfNeeded(from: di.historyStore)

        if !di.settingsStore.isOnboardingCompleted {
            presentOnboarding()
        } else {
            presentPermissionGuidanceIfNeeded()
        }
    }

    func stop() {
        workflowController?.stop()
        statusBarController?.stop()
    }

    private func presentOnboarding() {
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        controller.show(settingsStore: di.settingsStore) { [weak self] in
            self?.onboardingWindowController = nil
            self?.presentPermissionGuidanceIfNeeded()
        }
    }

    func showOnboarding() {
        // Reset the flag so the onboarding starts fresh from step 1
        di.settingsStore.isOnboardingCompleted = false
        if let existing = onboardingWindowController {
            existing.bringToFront()
            return
        }
        presentOnboarding()
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
            },
        )
    }
}
