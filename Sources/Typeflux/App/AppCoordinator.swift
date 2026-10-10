import AppKit

@MainActor
final class AppCoordinator {
    private let di = DIContainer()

    private var statusBarController: StatusBarController?
    private var workflowController: WorkflowController?
    private var mouseVoiceInputController: MouseVoiceInputController?
    private var onboardingWindowController: OnboardingWindowController?
    private let cloudEndpointProbeScheduler = CloudEndpointProbeScheduler()
    private let asrPublicConfigRefreshScheduler = TypefluxASRPublicConfigRefreshScheduler()
    private var authAnalyticsObserver: NSObjectProtocol?
    private var authLogoutObserver: NSObjectProtocol?
    private var authSubscriptionObserver: NSObjectProtocol?
    private var permissionAnalyticsTimer: Timer?

    // swiftlint:disable:next function_body_length
    func start() {
        di.analyticsReporter.reportFirstOpenIfNeeded()
        di.analyticsReporter.report(
            eventName: "app_launch",
            properties: ["launch_type": LaunchAtLoginManager.isEnabled ? "login_item" : "manual"]
        )
        di.permissionStatusAnalyticsMonitor.observeCurrentStatuses()
        permissionAnalyticsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.di.permissionStatusAnalyticsMonitor.observeCurrentStatuses()
            }
        }
        authAnalyticsObserver = NotificationCenter.default.addObserver(
            forName: .authDidLogin,
            object: nil,
            queue: .main
        ) { [weak reporter = di.analyticsReporter] _ in
            reporter?.report(eventName: "app_login", properties: [:])
            Task {
                await CloudEndpointRegistry.shared.probeAll()
                await TypefluxOfficialASRRouteCache.shared.invalidate()
                if let token = await MainActor.run(body: {
                    AuthState.shared.canUseCloudASR ? AuthState.shared.accessToken : nil
                }) {
                    await TypefluxOfficialASRRouteCache.shared.prefetch(accessToken: token)
                }
            }
        }
        authLogoutObserver = NotificationCenter.default.addObserver(
            forName: .authDidLogout,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await CloudEndpointRegistry.shared.probeAll()
                await TypefluxOfficialASRRouteCache.shared.invalidate()
            }
        }
        authSubscriptionObserver = NotificationCenter.default.addObserver(
            forName: .authSubscriptionDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await TypefluxOfficialASRRouteCache.shared.invalidate()
                if let token = await MainActor.run(body: {
                    AuthState.shared.canUseCloudASR ? AuthState.shared.accessToken : nil
                }) {
                    await TypefluxOfficialASRRouteCache.shared.prefetch(accessToken: token)
                }
            }
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
            mcpRegistry: di.mcpRegistry,
            overlayController: di.overlayController,
            askAnswerWindowController: di.askAnswerWindowController,
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
                appleBackendFactory: { AppleSpeechPreviewBackend() },
                canUseCloudASR: {
                    await MainActor.run { AuthState.shared.canUseCloudASR }
                }
            ),
            localModelManager: localModelManager,
            notificationService: di.notificationService,
            outputPostProcessor: di.outputPostProcessor,
            analyticsReporter: di.analyticsReporter
        )
        self.workflowController = workflowController
        workflowController.clipboardHistoryStore = di.clipboardHistoryStore
        workflowController.clipboardPanelPresenter = di.clipboardPanelController
        workflowController.clipboardContentActions = SystemClipboardContentActions(
            textRecognizer: di.imageTextRecognizer
        )
        workflowController.enforceClipboardRetentionPolicy()
        di.clipboardMonitor.start()
        if let ask = di.askConversationWindowController {
            workflowController.onAskRequested = { [weak ask] in ask?.toggleLauncher() }
            // Build the launcher while the app is idle, so the first ⌥Space shows it at once.
            DispatchQueue.main.async { [weak ask] in ask?.prewarmLauncher() }
            let voice = ask.model.voiceInput
            voice.recorder = WorkflowComposerRecording(workflowController)
            workflowController.composerVoiceInput = voice
            ask.model.recordingIsActive = { [weak workflowController] in workflowController?.isRecording ?? false }
        } else {
            workflowController.onAskRequested = {
                let alert = NSAlert()
                alert.messageText = L("ask.cache.failed")
                alert.runModal()
            }
        }

        let screenshotCoordinator = di.screenshotCoordinator
        di.hotkeyService.onScreenshotRequested = { [weak screenshotCoordinator] in
            screenshotCoordinator?.start(mode: .region)
        }
        di.askConversationWindowController?.model.onStartScreenshot = { [weak screenshotCoordinator] mode in
            screenshotCoordinator?.start(mode: mode)
        }

        let mouseVoiceInputController = MouseVoiceInputController(
            settingsStore: settingsStore,
            targetResolver: MouseVoiceTargetResolver(injector: di.textInjector)
        )
        mouseVoiceInputController.onRecordingRequested = { [weak workflowController] mode in
            workflowController?.handlePressBegan(
                intent: .dictation,
                startLocked: mode == .locked,
                allowsQuickInput: false
            )
        }
        mouseVoiceInputController.onRecordingReleaseRequested = { [weak workflowController] in
            workflowController?.handlePressEnded()
        }
        mouseVoiceInputController.onRecordingStopRequested = { [weak workflowController] in
            workflowController?.finishRecordingFromCurrentMode()
        }
        mouseVoiceInputController.recordingStateProvider = { [weak workflowController] in
            workflowController?.isRecording ?? false
        }
        self.mouseVoiceInputController = mouseVoiceInputController

        statusBarController = StatusBarController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            modelManager: di.ollamaModelManager,
            localModelManager: di.localModelManager,
            notificationService: di.notificationService,
            onRetryHistory: { [weak self] record in
                self?.workflowController?.retry(record: record)
            },
            onOpenOnboarding: { [weak self] in
                self?.showOnboarding()
            },
            onOpenAskConversations: { [weak self] in
                self?.di.askConversationWindowController?.showConversation()
            },
            onScreenshot: { [weak screenshotCoordinator] in
                screenshotCoordinator?.start(mode: .region)
            }
        )
        statusBarController?.start()
        di.askConversationWindowController?.model.onOpenSettings = { [weak self] section in
            self?.statusBarController?.showSettings(section: section)
        }
        self.workflowController?.start()
        self.mouseVoiceInputController?.start()
        // Link the bundled SenseVoice copy before triggering the auto-model
        // download service: triggerIfNeeded() reads preparedModelInfo to decide
        // whether the local-first fallback route is available, so the record
        // must already exist.
        di.bundledModelAutoSetup.applyIfNeeded()
        di.autoModelDownloadService.triggerIfNeeded()
        AutoUpdater.shared.startAutoCheck(settingsStore: di.settingsStore)
        UsageStatsStore.shared.backfillIfNeeded(from: di.historyStore) { [weak self] in
            guard let self else { return }
            di.usageDailySummaryReporter.reportIfNeeded(snapshot: .current(from: UsageStatsStore.shared))
        }
        cloudEndpointProbeScheduler.start()
        asrPublicConfigRefreshScheduler.start()
        Task {
            await AuthState.shared.refreshTokenIfNeeded()
            if let token = await MainActor.run(body: {
                AuthState.shared.canUseCloudASR ? AuthState.shared.accessToken : nil
            }) {
                await TypefluxOfficialASRRouteCache.shared.prefetch(accessToken: token)
            }
        }

        if !di.settingsStore.isOnboardingCompleted {
            presentOnboarding()
        } else {
            presentPermissionGuidanceIfNeeded()
        }
    }

    func stop() {
        if let authAnalyticsObserver { NotificationCenter.default.removeObserver(authAnalyticsObserver) }
        if let authLogoutObserver { NotificationCenter.default.removeObserver(authLogoutObserver) }
        if let authSubscriptionObserver { NotificationCenter.default.removeObserver(authSubscriptionObserver) }
        authAnalyticsObserver = nil
        authLogoutObserver = nil
        authSubscriptionObserver = nil
        permissionAnalyticsTimer?.invalidate()
        permissionAnalyticsTimer = nil
        cloudEndpointProbeScheduler.stop()
        asrPublicConfigRefreshScheduler.stop()
        Task { await TypefluxOfficialASRRouteCache.shared.invalidate() }
        di.clipboardMonitor.stop()
        workflowController?.stop()
        mouseVoiceInputController?.stop()
        statusBarController?.stop()
    }

    private func presentOnboarding() {
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        controller.show(
            settingsStore: di.settingsStore,
            localModelManager: di.localModelManager,
            notificationService: di.notificationService,
            analyticsReporter: di.analyticsReporter,
            permissionStatusAnalyticsMonitor: di.permissionStatusAnalyticsMonitor
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
