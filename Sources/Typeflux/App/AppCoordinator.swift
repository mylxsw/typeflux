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
    private lazy var helpWindowController = HelpWindowController.app(
        settings: di.settingsStore, ask: di.askConversationWindowController,
        openSettings: { [weak self] destination in self?.statusBarController?.showSettings(for: destination) }
    )

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
        let semanticSearch = SemanticFileSearchService.shared
        workflowController.onForegroundActivityChanged = { [weak semanticSearch] busy in semanticSearch?.setForegroundBusy(busy) }
        di.clipboardMonitor.start()
        if let ask = di.askConversationWindowController {
            ask.model.semanticSearch = semanticSearch
            workflowController.onAskRequested = { [weak ask] in ask?.toggleLauncher() }
            // Build the launcher while the app is idle, so the first ⌥Space shows it at once.
            DispatchQueue.main.async { [weak ask] in ask?.prewarmLauncher() }
            let voice = ask.model.voiceInput
            voice.recorder = WorkflowComposerRecording(workflowController)
            workflowController.composerVoiceInput = voice
            ask.model.recordingIsActive = { [weak workflowController] in workflowController?.isRecording ?? false }
            let monitor = ask.model.systemMonitorWindow
            monitor.openInLauncher = { [weak model = ask.model] focus in model?.openSystemMonitorInLauncher(focus: focus) }
            // The monitor window comes back when it was open at quit.
            DispatchQueue.main.async { monitor.restoreIfNeeded() }
        } else {
            workflowController.onAskRequested = {
                let alert = NSAlert()
                alert.messageText = L("ask.cache.failed")
                alert.runModal()
            }
        }

        let screenshotCoordinator = di.screenshotCoordinator
        let screenRecordingCoordinator = di.screenRecordingSessions
        screenRecordingCoordinator.offerRecovery()
        screenshotCoordinator.isRecordingActive = { [weak screenRecordingCoordinator] in
            screenRecordingCoordinator?.isCaptureActive ?? false
        }
        screenshotCoordinator.onRecordingRequested = { [weak screenRecordingCoordinator] format, region in
            screenRecordingCoordinator?.show(format: format, region: region)
        }
        di.hotkeyService.onScreenshotRequested = { [weak screenshotCoordinator] in
            screenshotCoordinator?.start(mode: .region)
        }
        if let model = di.askConversationWindowController?.model {
            model.onStartScreenshot = { [weak screenshotCoordinator] mode, followUp in
                screenshotCoordinator?.start(mode: mode, followUp: followUp)
            }
            model.screenshotTextRecognizer = TiledImageTextRecognizer(base: di.imageTextRecognizer)
            model.onTranslateScreenshot = { [weak self] image in self?.di.translationPanel.openScreenshot(image) }
            model.onMoveTranslationToPanel = { [weak self, weak model] session, close in
                guard let self, di.translationPanel.moveFromLauncher(session, closeLauncher: close) else { return false }
                // A new launcher run must not reset the fanout now owned by the panel.
                model?.translationFanout = di.translationEngines.makeSession()
                if let model { model.plugins.replacePlugins(model.makeLauncherPlugins()) }
                return true
            }
            // Text and questions stay in the launcher; translation opens its panel.
            di.translationPanel.otherScreenshotHandler = model
        }
        screenshotCoordinator.followUpHandler = di.translationPanel
        let translationPanelController = di.translationPanelController
        DispatchQueue.main.async { [weak translationPanelController] in
            translationPanelController?.prewarm()
        }
        di.translationPanelModel.onSettings = { [weak self] in
            guard let self else { return }
            SettingsWindowController.shared.show(settingsStore: di.settingsStore, historyStore: di.historyStore,
                initialSection: .launcher, launcherPane: .translation,
                modelManager: di.ollamaModelManager, localModelManager: di.localModelManager)
        }

        di.hotkeyService.onShortcutRequested = { [weak self, weak screenshotCoordinator] target in
            self?.handleShortcut(target, screenshotCoordinator: screenshotCoordinator)
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
            onOpenHelp: { [weak self] in self?.showHelp(query: "") },
            onOpenAskConversations: { [weak self] in
                self?.di.askConversationWindowController?.showConversation()
            },
            onScreenshot: { [weak screenshotCoordinator] in
                screenshotCoordinator?.start(mode: .region)
            },
            onScreenshotText: { [weak screenshotCoordinator] in
                screenshotCoordinator?.start(mode: .region, followUp: .recognizeText)
            },
            onScreenRecording: { [weak screenRecordingCoordinator] in screenRecordingCoordinator?.show() },
            pinnedScreenshots: { [weak screenshotCoordinator] in
                (screenshotCoordinator?.pins.pinCount ?? 0, screenshotCoordinator?.pins.clickThroughCount ?? 0)
            },
            onRestorePinnedScreenshots: { [weak screenshotCoordinator] in screenshotCoordinator?.pins.restoreMouse() },
            onClosePinnedScreenshots: { [weak screenshotCoordinator] in screenshotCoordinator?.pins.closeAll() }
        )
        statusBarController?.start()
        di.askConversationWindowController?.model.onOpenHelp = { [weak self] query in
            self?.showHelp(query: query)
        }
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

    var hasScreenRecording: Bool { di.screenRecordingSessions.isBusy }

    func finishScreenRecordingForTermination() async {
        await di.screenRecordingSessions.prepareForTermination()
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

    /// A feature or keyword shortcut from Settings → Shortcuts.
    private func handleShortcut(_ target: HotkeyTarget, screenshotCoordinator: ScreenshotCoordinator?) {
        switch target {
        case .builtIn:
            break
        case .action(.openChat):
            di.askConversationWindowController?.showConversation()
        case .action(.screenshotText):
            screenshotCoordinator?.start(mode: .region, followUp: .recognizeText)
        case .action(.translate):
            di.translationPanel.openSelection()
        case .action(.screenshotTranslation):
            screenshotCoordinator?.start(mode: .region, followUp: .translate)
        case .action(.openNotes):
            AskNotesWindowController.shared.show()
        case .action(.openWordBook):
            AskWordBookWindowController.shared.show()
        case .action(.openStudio):
            statusBarController?.showSettings(section: .home)
        case .action(.openHelp):
            showHelp(query: "")
        case let .keyword(id):
            guard let hotkey = di.settingsStore.keywordHotkeys.first(where: { $0.id == id }), hotkey.enabled,
                  let model = di.askConversationWindowController?.model else { return }
            workflowController?.cancelRecording()
            model.runKeywordShortcut(hotkey)
        }
    }

    /// Opens the usage guide window, closing the launcher it may have come from.
    func showHelp(query: String) {
        di.askConversationWindowController?.dismissLauncher()
        helpWindowController.show(query: query)
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
