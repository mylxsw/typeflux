import AppKit
import OSLog

@MainActor
final class AppCoordinator {
    let di = DIContainer()

    var statusBarController: StatusBarController?
    var workflowController: WorkflowController?
    var ringController: RingController?
    private var onboardingWindowController: OnboardingWindowController?
    private let cloudEndpointProbeScheduler = CloudEndpointProbeScheduler()
    private let asrPublicConfigRefreshScheduler = TypefluxASRPublicConfigRefreshScheduler()
    private var authAnalyticsObserver: NSObjectProtocol?
    private var authLogoutObserver: NSObjectProtocol?
    private var authSubscriptionObserver: NSObjectProtocol?
    private var permissionAnalyticsTimer: Timer?
    private lazy var helpWindowController = HelpWindowController.app(
        settings: di.settingsStore, ask: di.askConversationWindowController,
        openSettings: { destination in
            if let data = try? JSONEncoder().encode(destination) { FeatureProcess.send(.init(destination: .host, action: "helpSettings", payload: data)) }
        },
        openFeedback: { destination in
            if let data = try? JSONEncoder().encode(destination) { FeatureProcess.send(.init(destination: .host, action: "helpFeedback", payload: data)) }
        }
    )

    var featurePreferenceChanges: FeaturePreferenceChanges?
    var featureIdlePolicy = FeatureIdlePolicy()
    var featureIdleRequest: Task<Void, Never>?
    var featureStatusTimer: Timer?
    var featureQuickUpdate: Task<Void, Never>?
    var lastFeatureQuickProgress: FeatureQuickProgress?
    let featureVoiceOwner = FeatureVoiceOwner()
    let featureTranslations = FeatureTranslationBridge()
    let featureScreenshotForwarder = FeatureScreenshotForwarder()
    private var moduleStartup: Task<Void, Never>?
    var featureModuleStartup: Task<Void, Never>?
    #if DEBUG
    var featureProbeDroppedHandoffCounts: [String: Int] = [:]
    #endif

    // swiftlint:disable:next function_body_length
    func start() {
        featurePreferenceChanges = FeaturePreferenceChanges(defaults: di.settingsStore.defaults)
        FeatureProcess.handle = { [weak self] command in
            guard let self else { throw FeatureRPC.Failure.unavailable }
            return try await self.handleFeatureCommand(command)
        }
        if FeatureProcess.enabled {
            featureModuleStartup = Task { [di] in
                await withTaskGroup(of: Void.self) { group in
                    for module in FeatureProcess.role.modules {
                        group.addTask { try? await di.moduleRegistry.start(module) }
                    }
                }
            }
            FeatureProcess.configure(api: AskConversationWindowController.makeAPI(settings: di.settingsStore, modelLibrary: di.modelLibrary), cache: di.conversationCache, preparation: FeatureProcess.role == .screenshot ? nil : featureModuleStartup)
            if FeatureProcess.role != .host { startFeature(); return }
            FeatureShortcutHost.shared.start()
            featureStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publishFeatureStatus() }
            }
        }
        moduleStartup?.cancel()
        moduleStartup = Task { [di] in
            guard FeatureProcess.owns(.launcher) else { return }
            // Start the preview pool first and pay the helper/LaunchServices cold
            // start before the first launcher search needs an application icon.
            let previewReady = (try? await di.moduleRegistry.start(.mediaPreviews)) != nil
            async let iconWarmup = previewReady
                ? (try? AskFinderIcon.decode(.init(kind: .type, value: "public.folder"))) : nil
            if !FeatureProcess.enabled { await SemanticFileSearchService.shared.startForApplication(using: di.moduleRegistry) }
            else { SemanticFileSearchService.shared.start() }
            _ = await iconWarmup
        }
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
        let workflowController = makeWorkflowController()
        self.workflowController = workflowController
        workflowController.clipboardHistoryStore = di.clipboardHistoryStore
        workflowController.clipboardPanelPresenter = di.clipboardPanelController
        workflowController.clipboardContentActions = SystemClipboardContentActions(
            textRecognizer: di.imageTextRecognizer
        )
        if FeatureProcess.owns(.clipboard) { workflowController.enforceClipboardRetentionPolicy() }
        let clipboardPanelController = di.clipboardPanelController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak clipboardPanelController, weak workflowController] in
            guard let model = workflowController?.historyPanelModel else { return }
            clipboardPanelController?.prewarm(model)
        }
        let semanticSearch = SemanticFileSearchService.shared
        workflowController.onForegroundActivityChanged = { [weak semanticSearch] busy in semanticSearch?.setForegroundBusy(busy) }
        if FeatureProcess.owns(.clipboard) { di.clipboardMonitor.start() }
        if let ask = di.askConversationWindowController {
            ask.model.semanticSearch = semanticSearch
            workflowController.onAskRequested = { [weak ask] in ask?.toggleLauncher() }
            // Build the launcher while the app is idle, so the first ⌥Space shows it at once.
            DispatchQueue.main.async { [weak ask] in ask?.prewarmLauncher() }
            let voice = ask.model.voiceInput
            voice.recorder = FeatureProcess.enabled ? FeatureVoiceRecording() : WorkflowComposerRecording(workflowController)
            workflowController.composerVoiceInput = voice
            ask.model.recordingIsActive = { [weak workflowController] in workflowController?.isRecording ?? false }
            let monitor = ask.model.systemMonitorWindow
            monitor.openInLauncher = { [weak model = ask.model] focus in model?.openSystemMonitorInLauncher(focus: focus) }
            // The monitor window comes back when it was open at quit.
            DispatchQueue.main.async { if FeatureProcess.owns(.launcher) { monitor.restoreIfNeeded() } }
        } else {
            workflowController.onAskRequested = {
                let alert = NSAlert()
                alert.messageText = L("ask.cache.failed")
                alert.runModal()
            }
        }

        let screenshotCoordinator = di.screenshotCoordinator
        let screenRecordingCoordinator = di.screenRecordingSessions
        screenshotCoordinator.isRecordingActive = { [weak screenRecordingCoordinator] in
            screenRecordingCoordinator?.isCaptureActive ?? false
        }
        screenshotCoordinator.onRecordingRequested = { [weak screenRecordingCoordinator] format, region in
            screenRecordingCoordinator?.show(format: format, region: region)
        }
        di.hotkeyService.onScreenshotRequested = { [weak screenshotCoordinator] in
            if FeatureProcess.enabled { FeatureProcess.send(FeatureScreenshotRequest(mode: .region, followUp: nil).command) }
            else { screenshotCoordinator?.start(mode: .region) }
        }
        if let model = di.askConversationWindowController?.model {
            model.onStartScreenshot = { [weak screenshotCoordinator] mode, followUp in
                if FeatureProcess.enabled { FeatureProcess.send(FeatureScreenshotRequest(mode: mode, followUp: followUp).command) }
                else { screenshotCoordinator?.start(mode: mode, followUp: followUp) }
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
            if FeatureProcess.owns(.launcher) { translationPanelController?.prewarm() }
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
        di.hotkeyService.onShortcutReleased = { [weak self] target in
            if target == .action(.ring) { self?.ringController?.pressEnded() }
        }
        di.hotkeyService.onShortcutCancelled = { [weak self] target in
            if target == .action(.ring) { self?.ringController?.cancelPress() }
        }
        if FeatureProcess.owns(.ring) { startRing(screenshotCoordinator: screenshotCoordinator) }

        statusBarController = StatusBarController(
            appState: di.appState,
            settingsStore: di.settingsStore,
            historyStore: di.historyStore,
            audioDeviceManager: di.audioDeviceManager,
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
                if FeatureProcess.enabled { FeatureProcess.send(FeatureScreenshotRequest(mode: .region, followUp: nil).command) }
            else { screenshotCoordinator?.start(mode: .region) }
            },
            onScreenshotText: { [weak screenshotCoordinator] in
                if FeatureProcess.enabled { FeatureProcess.send(FeatureScreenshotRequest(mode: .region, followUp: .recognizeText).command) }
                else { screenshotCoordinator?.start(mode: .region, followUp: .recognizeText) }
            },
            onScreenRecording: { [weak screenRecordingCoordinator] in
                if FeatureProcess.enabled { FeatureProcess.send(.init(destination: .screenshot, action: "screenRecording")) }
                else { screenRecordingCoordinator?.show() }
            },
            pinnedScreenshots: { [weak screenshotCoordinator] in
                FeatureProcess.enabled ? (FeatureActivityMirror.shared.pins, FeatureActivityMirror.shared.clickThroughPins) : (screenshotCoordinator?.pins.pinCount ?? 0, screenshotCoordinator?.pins.clickThroughCount ?? 0)
            },
            onRestorePinnedScreenshots: { [weak screenshotCoordinator] in
                if FeatureProcess.enabled { FeatureProcess.send(.init(destination: .screenshot, action: "restorePins")) }
                else { screenshotCoordinator?.pins.restoreMouse() }
            },
            onClosePinnedScreenshots: { [weak screenshotCoordinator] in
                if FeatureProcess.enabled { FeatureProcess.send(.init(destination: .screenshot, action: "closePins")) }
                else { screenshotCoordinator?.pins.closeAll() }
            },
            activityCenter: di.backgroundActivityCenter
        )
        di.backgroundActivityCenter.onOpen = { [weak self] route in self?.openBackgroundActivity(route) }
        statusBarController?.start()
        di.askConversationWindowController?.model.onOpenHelp = { [weak self] query in
            self?.showHelp(query: query)
        }
        di.askConversationWindowController?.model.onOpenSettings = { [weak self] section in
            self?.statusBarController?.showSettings(section: section)
        }
        di.askConversationWindowController?.model.onOpenFeedback = { [weak self] in
            self?.statusBarController?.showFeedback(.direct)
        }
        self.workflowController?.start(backgroundWarmup: FeatureProcess.owns(.voice))
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

    func makeWorkflowController() -> WorkflowController {
        let settingsStore = di.settingsStore
        let localModelManager = di.localModelManager
        return WorkflowController(
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
    }

    private func openBackgroundActivity(_ route: BackgroundActivity.Route) {
        switch route {
        case .speechModels:
            statusBarController?.showSpeechModels()
        case .contentSearchSettings:
            statusBarController?.showLauncherSettings(.search)
        case let .conversation(id):
            di.askConversationWindowController?.model.openConversationFromLauncher(id)
        }
    }

    var hasScreenRecording: Bool { di.screenRecordingSessions.isBusy }

    func finishScreenRecordingForTermination() async {
        await di.screenRecordingSessions.prepareForTermination()
    }

    @discardableResult
    func prepareForTermination() async -> Bool {
        FeatureProcess.preventWarmup()
        if FeatureProcess.owns(.host), FeatureProcess.enabled { try? FeatureShortcutHost.shared.handle(.init(destination: .shortcuts, action: "stop")) }
        let model = di.existingAskConversationWindowController?.model
        let draftsSaved = await model?.flushFeatureDrafts()
        if model?.voiceInput.isOccupied == true || draftsSaved == false {
            Logger(subsystem: "ai.gulu.app.typeflux", category: "Shutdown").error("Host save check refused: voiceBusy=\(model?.voiceInput.isOccupied == true), draftsSaved=\(draftsSaved != false)")
            if FeatureProcess.owns(.host), FeatureProcess.enabled { try? FeatureShortcutHost.shared.handle(.init(destination: .shortcuts, action: "start")) }
            di.overlayController.showNotice(message: L("feature.quitNotReady"))
            return false
        }
        await model?.shutdownCommandJobs()
        if FeatureProcess.role == .host, await FeatureProcess.supervisor?.shutdown() == false {
            try? FeatureShortcutHost.shared.handle(.init(destination: .shortcuts, action: "start"))
            di.overlayController.showNotice(message: L("feature.quitNotReady"))
            return false
        }
        featureStatusTimer?.invalidate(); featureStatusTimer = nil
        featureQuickUpdate?.cancel(); featureQuickUpdate = nil
        featureModuleStartup?.cancel()
        await featureVoiceOwner.cancel()
        await di.existingAskConversationWindowController?.model.shutdownCommandJobs()
        await di.existingAskConversationWindowController?.model.discardTemporaryConversationForTermination()
        workflowController?.clipboardAction.preventNewWork()
        di.existingAskConversationWindowController?.model.clipboardAction.preventNewWork()
        moduleStartup?.cancel()
        moduleStartup = nil
        di.moduleRegistry.preventNewWork()
        di.nativeSystemCommands.preventNewWork()
        di.localInferenceWorkers.preventNewWork()
        di.mediaWorkers.preventNewWork()
        di.mediaPreviewWorkers.preventNewWork()
        di.clipboardThumbnailWorkers.preventNewWork()
        di.clipboardPlaybackWorkers.preventNewWork()
        di.frameRegistrationWorkers.preventNewWork()
        di.textRecognitionWorkers.preventNewWork()
        di.clipboardOCRWorkers.preventNewWork()
        di.clipboardMetadataWorkers.preventNewWork()
        di.recordingExportWorkers.preventNewWork()
        di.recordingTimelineWorkers.preventNewWork()
        await di.nativeSystemCommands.shutdown()
        await di.localInferenceWorkers.shutdown()
        await di.mediaWorkers.shutdown()
        await di.mediaPreviewWorkers.shutdown()
        await di.clipboardThumbnailWorkers.shutdown()
        await di.clipboardPlaybackWorkers.shutdown()
        await di.frameRegistrationWorkers.shutdown()
        await di.textRecognitionWorkers.shutdown()
        await di.clipboardOCRWorkers.shutdown()
        await di.clipboardMetadataWorkers.shutdown()
        await di.recordingExportWorkers.shutdown()
        await di.recordingTimelineWorkers.shutdown()
        await di.moduleRegistry.shutdown()
        await di.mcpRegistry.shutdown()
        return true
    }

    func stop() {
        featureStatusTimer?.invalidate(); featureStatusTimer = nil
        featureQuickUpdate?.cancel(); featureQuickUpdate = nil
        featureModuleStartup?.cancel()
        workflowController?.clipboardAction.preventNewWork()
        di.existingAskConversationWindowController?.model.clipboardAction.preventNewWork()
        moduleStartup?.cancel()
        moduleStartup = nil
        di.moduleRegistry.preventNewWork()
        di.nativeSystemCommands.preventNewWork()
        di.localInferenceWorkers.preventNewWork()
        di.mediaWorkers.preventNewWork()
        di.mediaPreviewWorkers.preventNewWork()
        di.clipboardThumbnailWorkers.preventNewWork()
        di.clipboardPlaybackWorkers.preventNewWork()
        di.frameRegistrationWorkers.preventNewWork()
        di.textRecognitionWorkers.preventNewWork()
        di.clipboardOCRWorkers.preventNewWork()
        di.clipboardMetadataWorkers.preventNewWork()
        di.recordingExportWorkers.preventNewWork()
        di.recordingTimelineWorkers.preventNewWork()
        Task { [di] in await di.moduleRegistry.shutdown() }
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
        statusBarController?.stop()
    }

    /// A feature or keyword shortcut from Settings → Shortcuts.
    func handleShortcut(_ target: HotkeyTarget, screenshotCoordinator: ScreenshotCoordinator?) {
        let destination = FeatureHotkeyEvent.destination(for: target)
        if !FeatureProcess.owns(destination), let data = try? JSONEncoder().encode(FeatureHotkeyEvent(name: "onShortcutRequested", target: target)) {
            FeatureProcess.send(.init(destination: destination, action: "hotkey", payload: data)); return
        }
        switch target {
        case .builtIn:
            break
        case .action(.openChat):
            di.askConversationWindowController?.showConversation()
        case .action(.screenshotText):
            screenshotCoordinator?.start(mode: .region, followUp: .recognizeText)
        case .action(.translate):
            di.translationPanel.toggleSelection()
        case .action(.screenshotTranslation):
            screenshotCoordinator?.start(mode: .region, followUp: .translate)
        case .action(.openNotes):
            AskNotesWindowController.shared.show()
        case .action(.openWordBook):
            AskWordBookWindowController.shared.show()
        case .action(.openStudio):
            SettingsWindowController.shared.show(settingsStore: di.settingsStore, historyStore: di.historyStore,
                initialSection: .home, modelManager: di.ollamaModelManager, localModelManager: di.localModelManager,
                notificationService: di.notificationService,
                onRetryHistory: { [weak self] in self?.workflowController?.retry(record: $0) })
        case .action(.openHelp):
            showHelp(query: "")
        case .action(.ring):
            ringController?.pressBegan()
        case let .keyword(id):
            guard let hotkey = di.settingsStore.keywordHotkeys.first(where: { $0.id == id }), hotkey.enabled,
                  let model = di.askConversationWindowController?.model else { return }
            workflowController?.cancelRecording()
            model.runKeywordShortcut(hotkey)
        }
    }

    func startRing(screenshotCoordinator: ScreenshotCoordinator) {
        let executor = RingActionExecutor(environment: LiveRingSystemEnvironment())
        executor.handlers = RingActionExecutor.Handlers(
            feature: { [weak self, weak screenshotCoordinator] feature in
                self?.runRingFeature(feature, screenshotCoordinator: screenshotCoordinator)
            },
            keyword: { [weak self] hotkey in
                guard let model = self?.di.askConversationWindowController?.model else { return }
                self?.workflowController?.cancelRecording()
                model.runKeywordShortcut(hotkey)
            }
        )
        executor.onFailure = { [weak overlay = di.overlayController] message in overlay?.showNotice(message: message) }
        let controller = RingController(settingsStore: di.settingsStore, menu: OpieRingMenu(soundEffectPlayer: di.soundEffectPlayer), executor: executor)
        controller.isRecordingActive = { [weak self] in self?.workflowController?.isRecording ?? false }
        ringController = controller
    }

    /// The ring's Typeflux features use the same entry points as their shortcuts.
    private func runRingFeature(_ feature: RingFeature, screenshotCoordinator: ScreenshotCoordinator?) {
        if let action = feature.shortcutAction {
            return handleShortcut(.action(action), screenshotCoordinator: screenshotCoordinator)
        }
        switch feature {
        case .dictation:
            if !FeatureProcess.owns(.voice) { FeatureProcess.send(.init(destination: .voice, action: "dictation")); return }
            workflowController?.handlePressBegan(intent: .dictation, startLocked: true)
        case .ask:
            di.askConversationWindowController?.toggleLauncher()
        case .screenshot:
            if FeatureProcess.enabled { FeatureProcess.send(FeatureScreenshotRequest(mode: .region, followUp: nil).command) }
            else { screenshotCoordinator?.start(mode: .region) }
        case .clipboard:
            workflowController?.handleHistoryPickerRequested()
        case .persona:
            if !FeatureProcess.owns(.voice) { FeatureProcess.send(.init(destination: .voice, action: "persona")); return }
            workflowController?.handlePersonaPickerRequested()
        default:
            break
        }
    }

    /// Opens the usage guide window, closing the launcher it may have come from.
    func showHelp(query: String) {
        if !FeatureProcess.owns(.help) { FeatureProcess.send(.init(destination: .help, action: "help", payload: Data(query.utf8))); return }
        if FeatureProcess.enabled { FeatureProcess.send(.init(destination: .launcher, action: "hideLauncher")) }
        else { di.askConversationWindowController?.dismissLauncher() }
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
