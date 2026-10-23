import AppKit
import Foundation

extension AppCoordinator {
    /// No status item, login refresh, shortcut registration, updater or indexer
    /// startup is duplicated in presentation processes.
    func startFeature() {
        featureStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishFeatureStatus() }
        }
        if FeatureProcess.role == .background {
            Task {
                await featureModuleStartup?.value
                AskFileIndex.shared.start()
                await SemanticFileSearchService.shared.startForApplication(using: di.moduleRegistry, startModules: false)
            }
            return
        }
        if FeatureProcess.role == .screenshot {
            configureFeatureCapture()
            return
        }
        let workflow = makeWorkflowController()
        workflowController = workflow
        workflow.onForegroundActivityChanged = { SemanticFileSearchService.shared.setForegroundBusy($0) }
        workflow.start(registerHotkeys: false, backgroundWarmup: FeatureProcess.role == .voice && !FeatureIsolationProbe.enabled)
        if FeatureProcess.role == .ring {
            startRing(screenshotCoordinator: di.screenshotCoordinator)
            di.hotkeyService.onShortcutReleased = { [weak self] in if $0 == .action(.ring) { self?.ringController?.pressEnded() } }
            di.hotkeyService.onShortcutCancelled = { [weak self] in if $0 == .action(.ring) { self?.ringController?.cancelPress() } }
        }
        workflow.clipboardHistoryStore = di.clipboardHistoryStore
        workflow.clipboardPanelPresenter = di.clipboardPanelController
        workflow.clipboardContentActions = SystemClipboardContentActions(textRecognizer: di.imageTextRecognizer)
        if FeatureProcess.role == .clipboard {
            if !FeatureIsolationProbe.enabled { di.clipboardMonitor.start() }
            workflow.enforceClipboardRetentionPolicy()
            di.clipboardPanelController.prewarm(workflow.historyPanelModel)
            workflow.prewarmHistoryPanelSnapshot()
        }
        if [FeatureRole.chat, .launcher, .notes, .wordBook, .help, .translation].contains(FeatureProcess.role),
           let controller = di.askConversationWindowController {
            let model = controller.model
            model.voiceInput.recorder = FeatureProcess.enabled ? FeatureVoiceRecording() : WorkflowComposerRecording(workflow)
            workflow.composerVoiceInput = model.voiceInput
            model.screenshotTextRecognizer = TiledImageTextRecognizer(base: di.imageTextRecognizer)
            di.translationPanel.otherScreenshotHandler = model
            model.recordingIsActive = { [weak workflow] in workflow?.isRecording ?? false }
            model.onStartScreenshot = { mode, followUp in
                FeatureProcess.send(FeatureScreenshotRequest(mode: mode, followUp: followUp).command)
            }
            model.onTranslateScreenshot = { [weak self] image in self?.di.translationPanel.openScreenshot(image) }
            model.onMoveTranslationToPanel = { [weak self, weak controller, weak model] session, _ in
                guard let self, let model else { return false }
                let source = model.launcherDraft
                return featureTranslations.move(session, accepted: { [weak controller, weak model] in
                    guard let model, model.launcherDraft == source else { return }
                    model.translationFanout = self.di.translationEngines.makeSession()
                    model.plugins.replacePlugins(model.makeLauncherPlugins())
                    controller?.dismissLauncher()
                }, failed: { [weak self] in self?.di.overlayController.showNotice(message: L("feature.unavailable")) })
            }
            model.onOpenHelp = { query in FeatureProcess.send(.init(destination: .host, action: "help", payload: Data(query.utf8))) }
            model.onOpenSettings = { section in
                FeatureProcess.send(.init(destination: .host, action: "settingsSection", payload: Data(section.rawValue.utf8)))
            }
            model.onOpenFeedback = { FeatureProcess.send(.init(destination: .host, action: "feedback")) }
            if FeatureProcess.role == .launcher {
                model.semanticSearch = SemanticFileSearchService.shared
                workflow.onForegroundActivityChanged = { SemanticFileSearchService.shared.setForegroundBusy($0) }
                let monitor = model.systemMonitorWindow
                monitor.openInLauncher = { [weak model] in model?.openSystemMonitorInLauncher(focus: $0) }
                if !FeatureIsolationProbe.enabled { monitor.restoreIfNeeded() }
                Task {
                    await featureModuleStartup?.value
                    guard !FeatureIsolationProbe.enabled else { controller.prewarmLauncher(); return }
                    try? await di.moduleRegistry.start(.mediaPreviews)
                    await SemanticFileSearchService.shared.startForApplication(using: di.moduleRegistry, startModules: false)
                    controller.prewarmLauncher()
                }
            }
        }
        if FeatureProcess.role == .translation {
            di.translationPanel.controller.prewarm()
            di.translationPanelModel.onSettings = { [weak self] in
                guard let self else { return }
                SettingsWindowController.shared.show(settingsStore: di.settingsStore, historyStore: di.historyStore,
                    initialSection: .launcher, launcherPane: .translation, modelManager: di.ollamaModelManager,
                    localModelManager: di.localModelManager)
            }
        }
        if FeatureProcess.role == .screenshot {
            let capture = di.screenshotCoordinator
            capture.prewarm()
            capture.followUpHandler = featureScreenshotForwarder
            capture.isRecordingActive = { [weak self] in self?.di.screenRecordingSessions.isCaptureActive ?? false }
            capture.onRecordingRequested = { [weak self] format, region in self?.di.screenRecordingSessions.show(format: format, region: region) }
        }
    }

    private func configureFeatureCapture() {
        let capture = di.screenshotCoordinator
        capture.prewarm()
        capture.followUpHandler = featureScreenshotForwarder
        capture.isRecordingActive = { [weak self] in self?.di.screenRecordingSessions.isCaptureActive ?? false }
        capture.onRecordingRequested = { [weak self] format, region in
            self?.di.screenRecordingSessions.show(format: format, region: region)
        }
    }

    var allowsFeatureRetirement: Bool {
        guard !NSApp.windows.contains(where: { $0.isVisible }), ManagedProcess.activeApplicationProcesses == 0,
              !featureScreenshotForwarder.isBusy, !FeatureScreenshotForwarder.shared.isBusy else { return false }
        switch FeatureProcess.role {
        case .chat: return di.existingAskConversationWindowController?.model.allowsFeatureRetirement ?? true
        case .screenshot:
            return di.screenshotCoordinator.state == .idle && di.screenshotCoordinator.pins.pinCount == 0 && !di.screenRecordingSessions.isBusy
        default: return false
        }
    }

    func publishFeatureStatus() {
        if FeatureProcess.enabled, featureIdleRequest == nil,
           featureIdlePolicy.shouldRetire(role: FeatureProcess.role, blocked: !allowsFeatureRetirement, uptime: ProcessInfo.processInfo.systemUptime) {
            featureIdleRequest = Task { [weak self] in
                defer { self?.featureIdleRequest = nil }
                _ = try? await FeatureProcess.route(.init(destination: .host, action: "retireFeature", payload: Data(FeatureProcess.role.rawValue.utf8)))
            }
        }
        let role = FeatureProcess.role
        let status = FeatureStatus(role: role,
            activity: di.existingAskConversationWindowController?.model.agentActivityInput ?? .init(),
            pins: role == .screenshot ? di.screenshotCoordinator.pins.pinCount : 0,
            clickThroughPins: role == .screenshot ? di.screenshotCoordinator.pins.clickThroughCount : 0,
            voiceStatus: role == .voice ? di.appState.status : nil,
            modules: Dictionary(uniqueKeysWithValues: di.moduleRegistry.registrations.compactMap {
                guard role.modules.contains($0.id), let health = $0.health.current else { return nil }
                return ($0.id, health)
            }))
        guard let payload = try? JSONEncoder().encode(status) else { return }
        FeatureProcess.send(.init(destination: .host, action: "status", payload: payload))
        if FeatureProcess.owns(.launcher), featureQuickUpdate == nil, let model = di.existingAskConversationWindowController?.model,
           model.quickAsk?.handedOff == true, let id = model.quickAsk?.conversationId, let run = model.snapshots[id]?.run {
            let value = FeatureQuickProgress(owner: model.owner, id: id, runID: run.id,
                complete: !run.isActive, progress: model.inferenceProgress[id])
            guard value != lastFeatureQuickProgress, let payload = try? JSONEncoder().encode(value) else { return }
            featureQuickUpdate = Task { [weak self] in
                defer { self?.featureQuickUpdate = nil }
                do {
                    _ = try await FeatureProcess.route(.init(destination: .chat, action: "quickProgress", payload: payload))
                    self?.lastFeatureQuickProgress = value
                } catch { /* Read-only progress can be delivered on the next tick. */ }
            }
        }
    }

    func handleFeatureCommand(_ command: FeatureCommand) async throws -> Data {
        #if DEBUG
        if FeatureIsolationProbe.enabled {
            if command.action == "probeChatState" {
                guard let model = di.askConversationWindowController?.model else { throw FeatureRPC.Failure.unavailable }
                return try JSONEncoder().encode(["text": model.draft.text, "canSend": String(model.canSend),
                    "selected": model.selectedId ?? "nil", "error": model.error ?? "nil",
                    "issue": model.submissionIssues[false]?.text ?? "nil", "owner": model.owner,
                    "busy": String(model.isBusy), "loading": String(model.isLoadingSelection),
                    "generation": String(AuthState.shared.sessionGeneration)])
            }
            if command.action == "probeStorage" {
                let id = UUID(uuidString: String(decoding: command.payload, as: UTF8.self))!
                if FeatureProcess.role == .notes {
                    _ = try await di.noteStore.save(.init(id: id, title: "Fixture note", body: "Cross-process note", command: "", keyword: "", input: "", createdAt: Date(), updatedAt: Date()))
                }
                _ = try await di.wordBookStore.count(.all)
                return try JSONEncoder().encode(try await di.noteStore.note(id: id)?.body)
            }
            if command.action == "probeProcessCleanup" {
                let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard fd >= 0 else { throw FeatureRPC.Failure.unavailable }
                defer { close(fd) }
                let child = Task {
                    try await ManagedProcess().run(.init(executable: "/bin/sleep", arguments: ["30"],
                        environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: fd, timeout: 35, outputLimit: 64))
                }
                try await Task.sleep(for: .milliseconds(150))
                ManagedProcess.cancelAllForApplicationExit()
                let result = try await child.value
                return try JSONEncoder().encode(result.termination == .cancelled)
            }
            if command.action == "probeFreeze" {
                let seconds = try JSONDecoder().decode(Double.self, from: command.payload)
                guard seconds > 0, seconds <= 10 else { throw FeatureRPC.Failure.invalidMessage }
                // Deliberately block this real AppKit main thread, not an RPC actor.
                FeatureIsolationProbe.blockMainThread(seconds: seconds)
                return Data()
            }
            if command.action == "probeExercise" {
                switch FeatureProcess.role {
                case .chat:
                    di.askConversationWindowController?.showConversation()
                    guard di.askConversationWindowController?.conversationWindow?.isVisible == true else { throw FeatureRPC.Failure.unavailable }
                case .launcher:
                    di.askConversationWindowController?.showLauncher()
                    guard di.askConversationWindowController?.launcherWindow?.isVisible == true else { throw FeatureRPC.Failure.unavailable }
                case .clipboard:
                    if di.historyStore.list().isEmpty {
                        di.historyStore.save(record: HistoryRecord(date: Date(), transcriptText: "Isolation fixture clipboard entry"))
                    }
                    if !di.clipboardPanelController.isPresented { workflowController?.handleHistoryPickerRequested() }
                    for _ in 0..<100 where workflowController?.isHistoryPickerLoading == true {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard di.clipboardPanelController.presentedWindow != nil else { throw FeatureRPC.Failure.unavailable }
                case .screenshot:
                    di.screenshotCoordinator.cancel()
                    di.screenshotCoordinator.start(mode: .region)
                    await di.screenshotCoordinator.pendingTask?.value
                    guard di.screenshotCoordinator.state == .selecting else { throw FeatureRPC.Failure.unavailable }
                    di.screenshotCoordinator.cancel()
                case .settings:
                    SettingsWindowController.shared.show(settingsStore: di.settingsStore, historyStore: di.historyStore)
                case .notes: AskNotesWindowController.shared.show()
                case .wordBook: AskWordBookWindowController.shared.show()
                case .help: showHelp(query: "")
                case .translation: di.translationPanel.openInput()
                case .monitor: SystemMonitorWindowController.shared.show(animated: false)
                case .ring: ringController?.pressBegan(); ringController?.cancelPress()
                default: break
                }
                return try JSONEncoder().encode(getpid())
            }
            if command.action == "probeWindows" {
                return try JSONEncoder().encode(NSApp.windows.filter(\.isVisible).map { $0.identifier?.rawValue ?? $0.title })
            }
        }
        #endif
        if command.action.hasPrefix("voice."), command.action != "voice.update" {
            guard FeatureProcess.role == .voice, let workflowController else { throw FeatureRPC.Failure.invalidMessage }
            return try await featureVoiceOwner.handle(command, workflow: workflowController)
        }
        if command.destination == .shortcuts {
            try FeatureShortcutHost.shared.handle(command)
            return Data()
        }
        switch command.action {
        case "voice.update": FeatureVoiceRecording.receive(try JSONDecoder().decode(FeatureVoiceUpdate.self, from: command.payload))
        case "indexSnapshot":
            let snapshot = try JSONDecoder().decode(FeatureIndexSnapshot.self, from: command.payload)
            AskFileIndex.shared.applyRemoteStatus(snapshot.names)
            SemanticFileSearchService.shared.applyRemoteSnapshot(snapshot.content)
        case "idleAllowed": return try JSONEncoder().encode(allowsFeatureRetirement)
        case "ping": return Data()
        case "recoverModule":
            let request = try JSONDecoder().decode(FeatureModuleRecovery.self, from: command.payload)
            guard FeatureProcess.role.modules.contains(request.id), let entry = di.moduleRegistry.registrations.first(where: { $0.id == request.id }) else { throw FeatureRPC.Failure.invalidMessage }
            return try JSONEncoder().encode(await entry.recover(request.reset))
        case "voiceStatus": di.appState.setStatus(try JSONDecoder().decode(AppStatus.self, from: command.payload))
        case "workflowPress":
            guard FeatureProcess.role == .voice else { throw FeatureRPC.Failure.invalidMessage }
            let request = try JSONDecoder().decode(FeatureWorkflowPress.self, from: command.payload)
            workflowController?.handlePressBegan(intent: request.asksSelection ? .askSelection : .dictation,
                startLocked: request.locked, hotkeyDetectedAt: request.detectedAt, hotkeyUptime: request.uptime, auxiliary: request.auxiliary)
        case "cancelRecording": workflowController?.cancelRecording()
        case "dictation": workflowController?.handlePressBegan(intent: .dictation, startLocked: true)
        case "persona": workflowController?.handlePersonaPickerRequested()
        case "retryHistory": workflowController?.retry(record: try JSONDecoder().decode(HistoryRecord.self, from: command.payload))
        case "shutdown":
            guard workflowController?.isRecording != true, workflowController?.processingTask == nil,
                  featureVoiceOwner.editorOwner == nil, !featureScreenshotForwarder.isBusy, !FeatureScreenshotForwarder.shared.isBusy,
                  di.existingAskConversationWindowController?.model.voiceInput.isOccupied != true else { throw FeatureRPC.Failure.busy }
            if FeatureProcess.role == .screenshot, di.screenRecordingSessions.isBusy { await di.screenRecordingSessions.prepareForTermination() }
            guard await di.existingAskConversationWindowController?.model.flushFeatureDrafts() != false else { throw FeatureRPC.Failure.unavailable }
            guard await prepareForTermination() else { throw FeatureRPC.Failure.unavailable }
            FeatureIsolationProbe.flushCoverage()
        case "settings":
            if FeatureProcess.role == .host { try FeatureShortcutHost.shared.handle(.init(destination: .shortcuts, action: "settings")) }
            di.modelLibrary.reloadFeaturePreferences()
            AskModelLibrary.shared.reloadFeaturePreferences()
            AppLocalization.shared.setLanguage(di.settingsStore.appLanguage)
            AppAppearance.apply(di.settingsStore.appearanceMode)
            for name in [Notification.Name.interfaceStyleDidChange, .appearanceModeDidChange, .agentConfigurationDidChange, .appLanguageDidChange, .appIconStyleDidChange, .voiceCapsuleDidChange, .preferredMicrophoneDidChange, .instantVoiceInputDidChange, .personaStoreDidChange, .personaSelectionDidChange, .ringSettingsDidChange, .clipboardRecordingPauseDidChange] {
                NotificationCenter.default.post(name: name, object: di.settingsStore)
            }
        case "stopConversation":
            di.existingAskConversationWindowController?.model.stop(id: String(decoding: command.payload, as: UTF8.self))
        case "quickProgress":
            if let value = try? JSONDecoder().decode(FeatureQuickProgress.self, from: command.payload) {
                di.askConversationWindowController?.model.applyFeatureQuickProgress(value)
            }
        case "translationInput": di.translationPanel.openInput()
        case "translationToggle": di.translationPanel.toggleSelection()
        case "translationSelection": di.translationPanel.openSelection()
        case "translationTransfer":
            let transfer = try JSONDecoder().decode(FeatureTranslationTransfer.self, from: command.payload)
            let accepted = di.translationPanelModel.receiveFeatureTransfer(transfer)
            if accepted, transfer.initial { di.translationPanelController.present() }
            return try JSONEncoder().encode(accepted)
        case "cancelTranslationTransfer": featureTranslations.cancel(String(decoding: command.payload, as: UTF8.self))
        case "showNotes": AskNotesWindowController.shared.show(selecting: UUID(uuidString: String(decoding: command.payload, as: UTF8.self)))
        case "newNote": AskNotesWindowController.shared.showNewNote(title: String(decoding: command.payload, as: UTF8.self))
        case "showWordBook": AskWordBookWindowController.shared.show(selecting: command.payload.isEmpty ? nil : String(decoding: command.payload, as: UTF8.self))
        case "lookupWord": AskWordBookWindowController.shared.show(lookingUp: String(decoding: command.payload, as: UTF8.self))
        case "showMonitor":
            let monitor = SystemMonitorWindowController.shared
            monitor.openInLauncher = { metric in FeatureProcess.send(.init(destination: .launcher, action: "monitorInLauncher", payload: Data((metric?.rawValue ?? "").utf8))) }
            monitor.show(sort: SystemMonitorSort(rawValue: String(decoding: command.payload, as: UTF8.self)))
        case "monitorInLauncher":
            di.askConversationWindowController?.model.openSystemMonitorInLauncher(focus: SystemMonitorMetric(rawValue: String(decoding: command.payload, as: UTF8.self)))
        case "helpSettings": statusBarController?.showSettings(for: try JSONDecoder().decode(HelpSettingsDestination.self, from: command.payload))
        case "helpFeedback": statusBarController?.showFeedback(try JSONDecoder().decode(FeedbackDestination.self, from: command.payload))
        case "toggleLauncher": di.askConversationWindowController?.toggleLauncher()
        case "hideLauncher": di.askConversationWindowController?.dismissLauncher()
        case "seedLauncher":
            let seed = try JSONDecoder().decode(FeatureLauncherSeed.self, from: command.payload)
            if let controller = di.askConversationWindowController {
                controller.showLauncher {
                    if seed.draft.hasChatInput { controller.model.launcherDraft = seed.draft }
                    if let id = seed.keywordID, let keyword = controller.model.plugins.availableKeywords.first(where: { $0.id == id }) {
                        controller.model.enterKeywordFromHelp(keyword, argument: seed.draft.text, refreshingWorkflows: true)
                    }
                }
            }
        case "showLauncher": di.askConversationWindowController?.showLauncher()
        case "showChat": di.askConversationWindowController?.showConversation()
        case "selectChat":
            guard let id = String(data: command.payload, encoding: .utf8), !id.isEmpty else { throw FeatureRPC.Failure.invalidMessage }
            di.askConversationWindowController?.showConversation()
            await di.askConversationWindowController?.model.select(id)
        case "handoff":
            guard let controller = di.askConversationWindowController else { throw FeatureRPC.Failure.unavailable }
            let transfer = try JSONDecoder().decode(FeatureChatHandoff.self, from: command.payload)
            return try JSONEncoder().encode(await controller.model.receiveFeatureHandoff(transfer))
        case "toggleClipboard": workflowController?.handleHistoryPickerRequested()
        case "screenRecording": di.screenRecordingSessions.show()
        case "screenshot":
            let value = command.payload.isEmpty ? FeatureScreenshotRequest(mode: .region, followUp: nil)
                : try JSONDecoder().decode(FeatureScreenshotRequest.self, from: command.payload)
            guard let mode = ScreenshotMode(rawValue: value.mode) else { throw FeatureRPC.Failure.invalidMessage }
            di.screenshotCoordinator.start(mode: mode, followUp: value.followUp.flatMap(ScreenshotFollowUp.init(rawValue:)))
        case "screenshotFollowUp":
            let value = try JSONDecoder().decode(FeatureScreenshotImage.self, from: command.payload)
            guard value.generation == AuthState.shared.sessionGeneration,
                  let kind = ScreenshotFollowUp(rawValue: value.followUp) else { throw FeatureRPC.Failure.invalidMessage }
            let image = try await Task.detached(priority: .userInitiated) { try FeatureImageTransfer.read(value.imageID) }.value
            guard value.generation == AuthState.shared.sessionGeneration else { throw FeatureRPC.Failure.cancelled }
            let snapshot = ScreenshotFollowUpImage(image: image, scale: value.scale, isLongImage: value.isLongImage)
            if kind == .translate { di.translationPanel.openScreenshot(snapshot) }
            else { di.askConversationWindowController?.model.handle(kind, image: snapshot) }
        case "restorePins": di.screenshotCoordinator.pins.restoreMouse()
        case "closePins": di.screenshotCoordinator.pins.closeAll()
        case "hotkey", "composerHotkey":
            let event = try JSONDecoder().decode(FeatureHotkeyEvent.self, from: command.payload)
            if FeatureProcess.role == .voice, let owner = featureVoiceOwner.editorOwner, event.target == nil {
                return try await FeatureProcess.route(.init(destination: owner, action: "composerHotkey", payload: command.payload))
            }
            if [.host, .chat].contains(FeatureProcess.role), event.target == nil,
               workflowController?.composerVoiceInput?.isOccupied != true,
               ((NSApp.keyWindow?.firstResponder as? AskComposerTextView.Editor).map { !$0.isEditable || $0.hasMarkedText() } ?? true) {
                return try await FeatureProcess.route(.init(destination: .voice, action: "hotkey", payload: command.payload))
            }
            if let target = event.target {
                if event.name == "onShortcutRequested" { handleShortcut(target, screenshotCoordinator: di.screenshotCoordinator) }
                else { (di.hotkeyService as? FeatureRemoteHotkeys)?.receive(event) }
            } else { (di.hotkeyService as? FeatureRemoteHotkeys)?.receive(event) }
        case "showSettings":
            let request = try JSONDecoder().decode(FeatureSettingsRequest.self, from: command.payload)
            SettingsWindowController.shared.show(settingsStore: di.settingsStore, historyStore: di.historyStore,
                initialSection: StudioSection(rawValue: request.section) ?? .settings,
                initialModelDomain: request.domain.flatMap(StudioModelDomain.init(rawValue:)),
                launcherPane: request.pane.flatMap(LauncherSettingsPane.init(rawValue:)),
                modelManager: di.ollamaModelManager, localModelManager: di.localModelManager,
                notificationService: di.notificationService,
                onRetryHistory: { [weak self] in self?.workflowController?.retry(record: $0) })
        case "settingsPane":
            if let pane = AppSettingsPane(rawValue: String(decoding: command.payload, as: UTF8.self)) {
                SettingsWindowController.shared.requestSettingsPane(pane)
            }
        case "refreshAuth", "refreshProfile", "refreshSubscription", "syncSubscription":
            guard FeatureProcess.role == .host,
                  try JSONDecoder().decode(Int.self, from: command.payload) == AuthState.shared.sessionGeneration
            else { throw FeatureRPC.Failure.invalidMessage }
            switch command.action {
            case "refreshProfile":
                guard await AuthState.shared.refreshProfile() != .failed else { throw FeatureRPC.Failure.unavailable }
            case "refreshSubscription":
                guard await AuthState.shared.refreshSubscription() != nil else { throw FeatureRPC.Failure.unavailable }
            case "syncSubscription": _ = try await AuthState.shared.syncSubscription()
            default: await AuthState.shared.refreshTokenIfNeeded()
            }
            let snapshot = FeatureAuth.capture()
            await FeatureProcess.supervisor?.updateAuth(snapshot)
            return try JSONEncoder().encode(snapshot)
        case "quit": NSApp.terminate(nil)
        case "loginURLs":
            await AppLoginURLRouter.handle(try JSONDecoder().decode([URL].self, from: command.payload),
                login: AuthState.shared.webLoginCoordinator, isLoggedIn: { AuthState.shared.isLoggedIn },
                showLogin: { LoginWindowController.shared.showWebLoginFailure() },
                handleBilling: { await BillingReturnLink.handle(auth: .shared) })
        case "login": LoginWindowController.shared.show()
        case "logout": AuthState.shared.logout()
        case "help": showHelp(query: String(decoding: command.payload, as: UTF8.self))
        case "settingsSection":
            if let section = StudioSection(rawValue: String(decoding: command.payload, as: UTF8.self)) {
                statusBarController?.showSettings(section: section)
            }
        case "feedback": statusBarController?.showFeedback(.direct)
        default: throw FeatureRPC.Failure.invalidMessage
        }
        return Data()
    }
}

struct FeatureScreenshotRequest: Codable, Sendable {
    let mode: String
    let followUp: String?
    init(mode: ScreenshotMode, followUp: ScreenshotFollowUp?) { self.mode = mode.rawValue; self.followUp = followUp?.rawValue }
    var command: FeatureCommand {
        .init(destination: .screenshot, action: "screenshot", payload: (try? JSONEncoder().encode(self)) ?? Data())
    }
}

struct FeatureScreenshotImage: Codable, Sendable {
    let imageID: UUID
    let generation: Int
    let scale: CGFloat
    let isLongImage: Bool
    let followUp: String
}

@MainActor
final class FeatureScreenshotForwarder: ScreenshotFollowUpHandling {
    static let shared = FeatureScreenshotForwarder()
    private let toast = ScreenshotToastController()
    private var pendingTransfers = 0
    var isBusy: Bool { pendingTransfers > 0 }

    func handle(_ followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage) {
        pendingTransfers += 1
        let generation = AuthState.shared.sessionGeneration
        Task {
            defer { pendingTransfers -= 1 }
            do {
                let png = try await Task.detached { try ScreenshotImageExporter.png(image.image, scale: image.scale) }.value
                let outcome = try await FeatureImageDelivery.deliver(png, send: { id in
                    let value = FeatureScreenshotImage(imageID: id, generation: generation, scale: image.scale,
                        isLongImage: image.isLongImage, followUp: followUp.rawValue)
                    _ = try await FeatureProcess.route(.init(destination: followUp == .translate ? .translation : .launcher,
                        action: "screenshotFollowUp", payload: JSONEncoder().encode(value)))
                }, save: { data in
                    let directory = SettingsStore().screenshotSaveDirectory
                    return try await Task.detached { try ScreenshotOutput().save(data, in: directory, date: Date()) }.value
                })
                if case let .saved(url) = outcome { toast.show(.followUpSaved(url)) }
            } catch {
                toast.show(.failed)
                ErrorLogStore.shared.log("Screenshot follow-up could not be delivered or saved")
            }
        }
    }
}

struct FeatureLauncherSeed: Codable, Sendable {
    let draft: AskDraft
    let keywordID: String?
}

struct FeatureSettingsRequest: Codable, Sendable {
    let section: String
    let domain: String?
    let pane: String?
}
