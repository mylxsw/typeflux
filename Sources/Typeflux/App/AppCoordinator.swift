import AppKit

@MainActor
final class AppCoordinator {
    private let di = DIContainer()

    private var statusBarController: StatusBarController?
    private var workflowController: WorkflowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let cloudEndpointProbeScheduler = CloudEndpointProbeScheduler()
    private let asrPublicConfigRefreshScheduler = TypefluxASRPublicConfigRefreshScheduler()
    private var authAnalyticsObserver: NSObjectProtocol?

    // swiftlint:disable:next function_body_length
    func start() {
        di.analyticsReporter.reportFirstOpenIfNeeded()
        authAnalyticsObserver = NotificationCenter.default.addObserver(
            forName: .authDidLogin,
            object: nil,
            queue: .main
        ) { [weak reporter = di.analyticsReporter] _ in
            reporter?.report(eventName: "app_login", properties: [:])
        }
        let settingsStore = di.settingsStore
        let localModelManager = di.localModelManager
        let workflowController = WorkflowController(
            appState: di.appState,
            settingsStore: settingsStore,
            hotkeyService: di.hotkeyService,
            audioRecorder: di.audioRecorder,
            sttRouter: di.sttRouter,
            llmService: di.llmService,
            llmAgentService: di.llmAgentService,
            textInjector: di.textInjector,
            clipboard: di.clipboard,
            historyStore: di.historyStore,
            agentJobStore: di.agentJobStore,
            agentExecutionRegistry: di.agentExecutionRegistry,
            mcpRegistry: di.mcpRegistry,
            overlayController: di.overlayController,
            askAnswerWindowController: di.askAnswerWindowController,
            agentClarificationWindowController: di.agentClarificationWindowController,
            soundEffectPlayer: di.soundEffectPlayer,
            liveTranscriptionPreviewer: LiveTranscriptionPreviewer(
                settingsStore: settingsStore,
                localBackendFactory: {
                    LocalModelLivePreviewBackend(
                        transcriberFactory: {
                            if settingsStore.sttProvider == .typefluxOfficial {
                                return self.di.autoModelDownloadService.makeTranscriberIfReady()
                                    ?? UnavailableTranscriber(providerName: "Typeflux Cloud local optimization model")
                            }
                            return LocalModelTranscriber(
                                settingsStore: settingsStore,
                                modelManager: localModelManager
                            )
                        }
                    )
                },
                openAIBackendFactory: { OpenAIRealtimePreviewBackend(settingsStore: settingsStore) },
                appleBackendFactory: { AppleSpeechPreviewBackend() }
            ),
            localModelManager: localModelManager,
            notificationService: di.notificationService,
            outputPostProcessor: di.outputPostProcessor
        )
        self.workflowController = workflowController

        statusBarController = StatusBarController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            agentJobStore: di.agentJobStore,
            modelManager: di.ollamaModelManager,
            localModelManager: di.localModelManager,
            notificationService: di.notificationService,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            },
            onOpenOnboarding: { [weak self] in
                self?.showOnboarding()
            },
            onOpenAgentJobs: { [weak self] in
                self?.di.agentJobsWindowController.showJobsList()
            },
            onOpenAgentJob: { [weak self] jobID in
                self?.di.agentJobsWindowController.showJob(id: jobID)
            }
        )
        statusBarController?.start()
        self.workflowController?.start()
        // Link the bundled SenseVoice copy before triggering the auto-model
        // download service: triggerIfNeeded() reads preparedModelInfo to decide
        // whether the local-first fallback route is available, so the record
        // must already exist.
        di.bundledModelAutoSetup.applyIfNeeded()
        di.autoModelDownloadService.triggerIfNeeded()
        AutoUpdater.shared.startAutoCheck(settingsStore: di.settingsStore)
        UsageStatsStore.shared.backfillIfNeeded(from: di.historyStore)
        cloudEndpointProbeScheduler.start()
        asrPublicConfigRefreshScheduler.start()
        Task { await AuthState.shared.refreshTokenIfNeeded() }

        if !di.settingsStore.isOnboardingCompleted {
            presentOnboarding()
        } else {
            presentPermissionGuidanceIfNeeded()
        }
    }

    func stop() {
        if let authAnalyticsObserver { NotificationCenter.default.removeObserver(authAnalyticsObserver) }
        authAnalyticsObserver = nil
        cloudEndpointProbeScheduler.stop()
        asrPublicConfigRefreshScheduler.stop()
        workflowController?.stop()
        statusBarController?.stop()
    }

    private func presentOnboarding() {
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        controller.show(
            settingsStore: di.settingsStore,
            localModelManager: di.localModelManager,
            notificationService: di.notificationService
        ) { [weak self] in
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
            modelManager: di.ollamaModelManager,
            localModelManager: di.localModelManager,
            notificationService: di.notificationService,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            }
        )
    }
}
