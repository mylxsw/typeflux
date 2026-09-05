// swiftlint:disable file_length function_body_length line_length type_body_length
import AppKit
import Foundation
import os

struct RecordingStartupContext: Sendable, Equatable {
    let hotkeyDetectedAt: Date
    let recordingWorkflowStartedAt: Date
}

final class WorkflowController {
    let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "WorkflowController")
    static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes
    /// Last-resort protection for a processing pipeline that remains stuck.
    /// User-configured recognition wait time controls fallback selection instead.
    static let processingWatchdogTimeoutSeconds: TimeInterval = 30
    static let minimumRecordingDuration: TimeInterval = 0.35
    static let recordingTailCaptureDuration: Duration = .milliseconds(200)
    static let shortAudioRetryDuration: TimeInterval = 1.5
    /// Ambiguous short releases stay recoverable by switching to locked recording.
    /// Keep this above `minimumRecordingDuration` so a release is never classified
    /// as hold-to-talk and then immediately rejected as too short.
    static let tapToLockThreshold: TimeInterval = 0.60
    static let automaticVocabularyObservationWindow: TimeInterval = 30
    static let automaticVocabularyPollInterval: Duration = .seconds(1)
    // Bumped from 600ms to 900ms so the paste fallback path has time for focus and
    // pasteboard restoration before we start reading the AX baseline.
    static let automaticVocabularyStartupDelay: Duration = .milliseconds(900)
    static let automaticVocabularyBaselineRetryDelay: Duration = .milliseconds(400)
    static let automaticVocabularyBaselineRetryCount = 6
    // Retry the initial editable-focus snapshot a few times — Electron/web targets
    // frequently report non-editable roles on the first AX query after insertion.
    static let automaticVocabularyInitialSnapshotRetryCount = 3
    static let automaticVocabularyInitialSnapshotRetryDelay: Duration = .milliseconds(400)
    /// Dropped from 8s to 4s so real editing sessions have a realistic chance to
    /// complete before the next dictation arrives.
    static let automaticVocabularyIdleSettleDelay: TimeInterval = 4
    // Raised from 0.6 to 0.8 so short dictations with a delete+retype edit are
    // still considered for analysis.
    static let automaticVocabularyEditRatioLimit: Double = 0.8
    static let localModelPreheatDebounce: Duration = .milliseconds(180)
    static let recordingHintAutoHideDelay: TimeInterval = 3.0
    static let audioStartupMaxAttemptCount = 3
    // Bluetooth routes can need several seconds to publish a stable input format.
    // At the 250ms retry interval this allows about 2.75 seconds to settle.
    static let audioReconfigurationStartupMaxAttemptCount = 12
    static let audioStartupRetryDelay: Duration = .milliseconds(250)
    static let llmTimeoutAfterTranscriptionSeconds: TimeInterval = 3
    static let paidCreditExhaustedPromptSuppressionInterval: TimeInterval = 60 * 60
    private var llmTimeoutAfterTranscriptionOverride: TimeInterval?
    var llmTimeoutAfterTranscription: TimeInterval {
        get { llmTimeoutAfterTranscriptionOverride ?? settingsStore.voiceProcessingTimeout.seconds }
        set { llmTimeoutAfterTranscriptionOverride = max(0, newValue) }
    }
    struct LLMRequestTimeoutError: LocalizedError {
        let timeoutSeconds: TimeInterval

        var errorDescription: String? {
            "Persona rewrite timed out after \(Int(timeoutSeconds)) seconds, inserting transcript as fallback"
        }
    }

    enum RecordingMode {
        case holdToTalk
        case locked
    }

    enum RecordingIntent {
        case dictation
        case askSelection

        var traceName: String {
            switch self {
            case .dictation:
                "dictation"
            case .askSelection:
                "ask"
            }
        }
    }

    enum ApplyOutcome {
        case inserted
        case pasted
        case unconfirmed
        case cancelled
        case presentedInDialog
        case copiedToClipboard

        var wasInserted: Bool { self == .inserted || self == .pasted }

        var historyStatus: HistoryRecord.StepStatus {
            switch self {
            case .inserted, .pasted, .copiedToClipboard: .succeeded
            case .cancelled, .unconfirmed: .skipped
            case .presentedInDialog: .failed
            }
        }

        var message: String {
            switch self {
            case .inserted, .pasted:
                L("workflow.apply.inserted")
            case .unconfirmed:
                L("workflow.apply.dispatchedUnverified")
            case .cancelled:
                L("workflow.cancel.newRecording")
            case .presentedInDialog:
                L("workflow.apply.presentedInDialog")
            case .copiedToClipboard:
                L("workflow.apply.copiedToClipboard")
            }
        }
    }

    let appState: AppStateStore
    let settingsStore: SettingsStore
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let sttRouter: STTRouter
    let llmService: LLMService
    let llmAgentService: LLMAgentService
    let textInjector: TextInjector
    let clipboard: ClipboardService
    let historyStore: HistoryStore
    let agentJobStore: AgentJobStore
    let agentExecutionRegistry: AgentExecutionRegistry
    let mcpRegistry: MCPRegistry
    let overlayController: OverlayController
    let askAnswerWindowController: AskAnswerWindowController
    let agentClarificationWindowController: AgentClarificationWindowController
    let soundEffectPlayer: SoundEffectPlayer
    let liveTranscriptionPreviewer: (any LiveTranscriptionPreviewing)?
    let localModelManager: (any LocalSTTModelManaging)?
    let notificationService: LocalNotificationSending
    let localModelDownloadAlertPresenter: any LocalModelDownloadAlertPresenting
    let outputPostProcessor: OutputPostProcessing
    let analyticsReporter: AnalyticsEventReporting
    let sleep: @Sendable (Duration) async -> Void
    let monotonicNow: () -> TimeInterval

    var currentSelectedText: String?
    var isRecording = false
    var isAudioRecorderStarted = false
    var isAudioRecorderStarting = false
    var shouldFinishRecordingAfterAudioStart = false
    var pendingRecordingStartID: UUID?
    var suppressActivationTapUntil: Date?
    var recordingMode: RecordingMode = .holdToTalk
    var recordingIntent: RecordingIntent = .dictation
    var hotkeyPressedAt: TimeInterval?
    var audioRecorderStartedAt: TimeInterval?
    var recordingStartupContext: RecordingStartupContext?
    var recordingTimeoutTask: Task<Void, Never>?
    var processingWatchdogTask: Task<Void, Never>?
    var selectionTask: Task<TextSelectionSnapshot, Never>?
    var inputContextTask: Task<InputContextSnapshot?, Never>?
    var processingTask: Task<Void, Never>?
    var activeRealtimeTranscriptionSession: (any RealtimeTranscriptionSession)?
    var activeRealtimeAudioBufferPump: RealtimeAudioBufferPump?
    var automaticVocabularyObservationTask: Task<Void, Never>?
    /// Latest snapshot of the currently running automatic-vocabulary observation.
    /// Kept in sync by the observation task so that an incoming `scheduleAutomatic…`
    /// call can finalize-then-cancel instead of dropping partially-observed work.
    var automaticVocabularyActiveSession: AutomaticVocabularyActiveSession?
    var processingSessionID = UUID()
    var activeProcessingRecordID: UUID?
    var lastRetryableFailureRecord: HistoryRecord?
    var lastDialogResultText: String?
    var latestRecordingPreviewText = ""
    var shouldPreserveLLMConfigurationNotice = false
    var localModelPreheatTask: Task<Void, Never>?
    var lastLocalModelPreheatConfiguration: LocalSTTConfiguration?
    var localModelPreheatObserver: NSObjectProtocol?
    var localModelPreparationTask: Task<Void, Never>?
    var localModelPreparationConfiguration: LocalSTTConfiguration?
    var localModelDownloadAlertTask: Task<Void, Never>?
    var suppressNextActivationTapAfterLocalModelDownloadAlert = false
    var isPersonaPickerPresented = false
    var personaPickerItems: [PersonaPickerEntry] = []
    var personaPickerSelectedIndex = 0
    var personaPickerMode: PersonaPickerMode = .switchDefault
    var isHistoryPickerPresented = false
    var historyPickerItems: [HistoryPickerEntry] = []
    var historyPickerSelectedIndex = 0
    var lastPaidCreditExhaustedPromptPresentedAt: Date?
    let analyticsLock = NSLock()
    var pendingDictationAnalyticsContext: DictationAnalyticsContext?
    var dictationAnalyticsContexts: [UUID: DictationAnalyticsContext] = [:]

    // Clarification mode: set when the agent workflow is paused waiting for a user voice reply.
    var pendingClarificationContinuation: CheckedContinuation<String, Error>?
    var isClarificationRecording = false

    struct PersonaPickerEntry {
        let id: UUID?
        let title: String
        let subtitle: String
    }

    struct HistoryPickerEntry {
        let id: UUID
        let title: String
        let subtitle: String
        let text: String
        let record: HistoryRecord
    }

    struct PersonaSelectionContext {
        let snapshot: TextSelectionSnapshot
        let selectedText: String
    }

    enum PersonaPickerMode {
        case switchDefault
        case switchApplication(PersonaAppBinding)
        case applySelection(PersonaSelectionContext)
    }

    init(
        appState: AppStateStore,
        settingsStore: SettingsStore,
        hotkeyService: HotkeyService,
        audioRecorder: AudioRecorder,
        sttRouter: STTRouter,
        llmService: LLMService,
        llmAgentService: LLMAgentService,
        textInjector: TextInjector,
        clipboard: ClipboardService,
        historyStore: HistoryStore,
        agentJobStore: AgentJobStore,
        agentExecutionRegistry: AgentExecutionRegistry,
        mcpRegistry: MCPRegistry,
        overlayController: OverlayController,
        askAnswerWindowController: AskAnswerWindowController,
        agentClarificationWindowController: AgentClarificationWindowController,
        soundEffectPlayer: SoundEffectPlayer,
        liveTranscriptionPreviewer: (any LiveTranscriptionPreviewing)? = nil,
        localModelManager: (any LocalSTTModelManaging)? = nil,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        localModelDownloadAlertPresenter: any LocalModelDownloadAlertPresenting =
            SystemLocalModelDownloadAlertPresenter(),
        outputPostProcessor: OutputPostProcessing,
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.audioRecorder = audioRecorder
        self.sttRouter = sttRouter
        self.llmService = llmService
        self.llmAgentService = llmAgentService
        self.textInjector = textInjector
        self.clipboard = clipboard
        self.historyStore = historyStore
        self.agentJobStore = agentJobStore
        self.agentExecutionRegistry = agentExecutionRegistry
        self.mcpRegistry = mcpRegistry
        self.overlayController = overlayController
        self.askAnswerWindowController = askAnswerWindowController
        self.agentClarificationWindowController = agentClarificationWindowController
        self.soundEffectPlayer = soundEffectPlayer
        self.liveTranscriptionPreviewer = liveTranscriptionPreviewer
        self.localModelManager = localModelManager
        self.notificationService = notificationService
        self.localModelDownloadAlertPresenter = localModelDownloadAlertPresenter
        self.outputPostProcessor = outputPostProcessor
        self.analyticsReporter = analyticsReporter
        self.sleep = sleep
        self.monotonicNow = monotonicNow
        self.overlayController.setRecordingActionHandlers(
            onCancel: { [weak self] in
                guard let self else { return }
                if isRecording {
                    cancelRecording()
                } else {
                    cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.userCancelled"))
                }
            },
            onConfirm: { [weak self] in self?.confirmLockedRecording() }
        )
        self.overlayController.setResultDialogHandler(
            onCopy: { [weak self] in self?.copyLastResultFromDialog() }
        )
        self.overlayController.setFailureRetryHandler(
            onRetry: { [weak self] in
                guard let self, let record = lastRetryableFailureRecord else { return }
                retry(record: record)
            }
        )
        self.overlayController.setPersonaPickerHandlers(
            onMoveUp: { [weak self] in self?.moveOverlayPickerSelection(delta: -1) },
            onMoveDown: { [weak self] in self?.moveOverlayPickerSelection(delta: 1) },
            onSelect: { [weak self] index in self?.selectOverlayPickerSelection(at: index) },
            onConfirm: { [weak self] in self?.confirmOverlayPickerSelection() },
            onCancel: { [weak self] in self?.dismissOverlayPicker() }
        )
        self.overlayController.setHistoryPickerActionHandlers(
            onCopy: { [weak self] index in self?.copyHistorySelection(at: index) },
            onInsert: { [weak self] index in self?.insertHistorySelection(at: index) },
            onRetry: { [weak self] index in self?.retryHistorySelection(at: index) }
        )
        self.agentClarificationWindowController.onDismiss = { [weak self] in
            self?.dismissClarification()
        }
    }

    func presentAskAnswer(question: String, selectedText: String?, answerMarkdown: String) {
        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Sending content to window
            Question Length: \(question.count)
            Question Preview: \(String(question.prefix(120)))
            Selected Text Length: \(selectedText?.count ?? 0)
            Answer Markdown Length: \(answerMarkdown.count)
            Answer Markdown Preview: \(String(answerMarkdown.prefix(160)))
            """
        )
        overlayController.dismissImmediately()
        askAnswerWindowController.show(
            title: L("workflow.ask.answerTitle"),
            question: question,
            selectedText: selectedText,
            answerMarkdown: answerMarkdown
        )
    }

    func start() {
        hotkeyService.onActivationTap = { [weak self] context in
            self?.handleActivationTap(hotkeyDetectedAt: context.detectedAt)
        }
        hotkeyService.onActivationPressBegan = { [weak self] context in
            self?.handlePressBegan(
                intent: .dictation,
                startLocked: false,
                hotkeyDetectedAt: context.detectedAt
            )
        }
        hotkeyService.onActivationPressEnded = { [weak self] in
            self?.handlePressEnded()
        }
        hotkeyService.onActivationCancelled = { [weak self] in
            self?.cancelRecording()
        }
        hotkeyService.onAskPressBegan = { [weak self] context in
            self?.handlePressBegan(
                intent: .askSelection,
                startLocked: true,
                hotkeyDetectedAt: context.detectedAt
            )
        }
        hotkeyService.onAskPressEnded = { [weak self] in
            self?.handleAskPressEnded()
        }
        hotkeyService.onPersonaPickerRequested = { [weak self] in
            self?.handlePersonaPickerRequested()
        }
        hotkeyService.onHistoryRequested = { [weak self] in
            self?.handleHistoryPickerRequested()
        }
        hotkeyService.onError = { [weak self] message in
            guard let self else { return }
            ErrorLogStore.shared.log(message)
            Task { @MainActor in
                self.soundEffectPlayer.play(.error)
                self.appState.setStatus(.failed(message: message))
                self.overlayController.showFailure(message: message)
                self.overlayController.dismiss(after: 3.0)
            }
        }

        hotkeyService.start()

        // Pre-warm the local STT model on startup, and re-warm whenever
        // the user switches provider or model in Settings.
        preheatLocalModelIfNeeded()
        localModelPreheatObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.preheatLocalModelIfNeeded()
        }
    }

    func preheatLocalModelIfNeeded() {
        guard settingsStore.sttProvider == .localModel else {
            localModelPreheatTask?.cancel()
            localModelPreheatTask = nil
            lastLocalModelPreheatConfiguration = nil
            Task { [weak self] in await self?.sttRouter.cancelPreparedRecording() }
            return
        }

        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        guard configuration != lastLocalModelPreheatConfiguration else {
            return
        }

        lastLocalModelPreheatConfiguration = configuration
        localModelPreheatTask?.cancel()
        localModelPreheatTask = Task { [weak self, configuration] in
            try? await Task.sleep(for: Self.localModelPreheatDebounce)
            guard let self, !Task.isCancelled else { return }
            guard settingsStore.sttProvider == .localModel,
                  LocalSTTConfiguration(settingsStore: settingsStore) == configuration
            else {
                return
            }
            await sttRouter.prepareForRecording()
        }
    }

    func stop() {
        hotkeyService.stop()
        dismissPersonaPicker()
        dismissHistoryPicker()
        askAnswerWindowController.dismiss()
        agentClarificationWindowController.dismiss()
        cancelRecording()
        cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.stopping"))
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil
        localModelPreheatTask?.cancel()
        localModelPreheatTask = nil
        lastLocalModelPreheatConfiguration = nil
        localModelPreparationTask?.cancel()
        localModelPreparationTask = nil
        localModelPreparationConfiguration = nil
        localModelDownloadAlertTask?.cancel()
        localModelDownloadAlertTask = nil
        suppressNextActivationTapAfterLocalModelDownloadAlert = false
        if let obs = localModelPreheatObserver {
            NotificationCenter.default.removeObserver(obs)
            localModelPreheatObserver = nil
        }
    }

    func retry(record: HistoryRecord) {
        guard !isRecording else { return }
        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.retry"))

        let sessionID = beginProcessingSession()
        let fallbackWaitSeconds = settingsStore.voiceProcessingTimeout.seconds
        startProcessingWatchdog(sessionID: sessionID)
        processingTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.appState.setStatus(.processing)
                self.overlayController.showProcessing(timeout: fallbackWaitSeconds)
            }
            await reprocess(record: record, sessionID: sessionID)
            cancelProcessingWatchdog()
            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.processingTask = nil
                    self.activeProcessingRecordID = nil
                }
            }
        }
    }

    /// Force cancel any ongoing recording
    func cancelRecording() {
        guard isRecording else { return }
        discardPendingDictationAnalytics()
        isRecording = false
        let shouldStopAudioRecorder = isAudioRecorderStarted
        isAudioRecorderStarted = false
        isAudioRecorderStarting = false
        shouldFinishRecordingAfterAudioStart = false
        audioRecorderStartedAt = nil
        recordingStartupContext = nil
        pendingRecordingStartID = nil
        suppressActivationTapUntil = nil
        recordingMode = .holdToTalk
        recordingIntent = .dictation
        hotkeyPressedAt = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        if shouldStopAudioRecorder {
            _ = try? audioRecorder.stop()
        }
        latestRecordingPreviewText = ""
        activeRealtimeAudioBufferPump?.cancel()
        activeRealtimeAudioBufferPump = nil
        Task {
            await liveTranscriptionPreviewer?.cancel()
            await activeRealtimeTranscriptionSession?.cancel()
            activeRealtimeTranscriptionSession = nil
            await sttRouter.cancelPreparedRecording()
        }
        selectionTask?.cancel()
        selectionTask = nil
        inputContextTask?.cancel()
        inputContextTask = nil
        Task { @MainActor in
            appState.setStatus(.idle)
            overlayController.dismiss(after: 0.3)
        }
        NSLog("[Workflow] Recording cancelled")
    }

    func shouldUseLiveTranscriptionPreview() -> Bool {
        guard liveTranscriptionPreviewer != nil else { return false }
        return settingsStore.sttProvider == .localModel
    }

    func startLiveTranscriptionPreviewIfNeeded(_ previewer: (any LiveTranscriptionPreviewing)?) {
        guard let previewer, shouldUseLiveTranscriptionPreview() else { return }

        Task { [weak self] in
            do {
                try await previewer.start { [weak self] text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        guard let self, isRecording else { return }
                        latestRecordingPreviewText = trimmed
                        overlayController.updateRecordingPreviewText(trimmed)
                    }
                }
            } catch {
                NetworkDebugLogger.logError(context: "Live transcription preview failed to start", error: error)
                await previewer.cancel()
            }
        }
    }

    func startProcessingWatchdog(
        sessionID: UUID,
        timeoutSeconds: TimeInterval = WorkflowController.processingWatchdogTimeoutSeconds
    ) {
        let timeoutNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        processingWatchdogTask?.cancel()
        processingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            NSLog("[Workflow] Processing watchdog fired after %llu seconds", timeoutNanoseconds / 1_000_000_000)
            await self?.handleProcessingWatchdog(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
        }
    }

    func cancelProcessingWatchdog() {
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
    }

    func handleProcessingWatchdog(sessionID: UUID, timeoutSeconds: TimeInterval) async {
        guard processingSessionID == sessionID else { return }
        let recordID = activeProcessingRecordID
        let timeoutRecord = recordID.flatMap { historyStore.record(id: $0) }
        if let timeoutRecord {
            reportDictationTerminal(
                record: timeoutRecord,
                forcedFailure: (stage: "processing", kind: "processing_timeout")
            )
        }
        let timeoutSeconds = Int(timeoutSeconds)
        cancelCurrentProcessing(resetUI: false, reason: L("workflow.timeout.reason", timeoutSeconds))
        await MainActor.run {
            self.lastRetryableFailureRecord = timeoutRecord
            self.soundEffectPlayer.play(.error)
            self.appState.setStatus(.failed(message: L("workflow.timeout.status")))
            self.overlayController.showTimeoutFailure(timeoutSeconds: timeoutSeconds)
        }
    }

    func handleActivationTap(hotkeyDetectedAt: Date = Date()) {
        if suppressNextActivationTapAfterLocalModelDownloadAlert {
            suppressNextActivationTapAfterLocalModelDownloadAlert = false
            RecordingStartupLatencyTrace.shared.mark("workflow.activation_tap_suppressed.local_model_download")
            return
        }
        if let suppressActivationTapUntil, Date() < suppressActivationTapUntil {
            self.suppressActivationTapUntil = nil
            RecordingStartupLatencyTrace.shared.mark("workflow.activation_tap_suppressed")
            return
        }
        suppressActivationTapUntil = nil
        handlePressBegan(
            intent: .dictation,
            startLocked: true,
            hotkeyDetectedAt: hotkeyDetectedAt
        )
    }

    func handlePressBegan(
        intent: RecordingIntent,
        startLocked: Bool,
        hotkeyDetectedAt: Date = Date()
    ) {
        RecordingStartupLatencyTrace.shared.mark("workflow.press_began.\(intent.traceName)")
        if isPersonaPickerPresented {
            dismissPersonaPicker()
        }
        if isHistoryPickerPresented {
            dismissHistoryPicker()
        }

        if !isRecording, isAudioRecorderStarted {
            NSLog("[Workflow] Audio recorder is still stopping, ignoring press")
            return
        }

        if isRecording {
            if intent == .askSelection, recordingIntent == .dictation {
                promoteActiveRecordingToAskSelection()
                return
            }

            if startLocked, recordingMode == .holdToTalk {
                lockActiveRecording()
                return
            }

            guard recordingMode == .locked else {
                NSLog("[Workflow] Already recording, ignoring press")
                return
            }

            if !startLocked {
                suppressActivationTapUntil = Date().addingTimeInterval(Self.tapToLockThreshold + 0.2)
            }
            confirmLockedRecording()
            return
        }

        if showSelectedLocalModelDownloadAlertIfNeeded() {
            if !startLocked {
                suppressNextActivationTapAfterLocalModelDownloadAlert = true
            }
            return
        }

        if !PrivacyGuard.isRunningInAppBundle {
            Task { @MainActor in
                let msg = L("workflow.devApp.requiredMessage")
                self.soundEffectPlayer.play(.error)
                appState.setStatus(.failed(message: L("workflow.devApp.requiredStatus")))
                overlayController.showFailure(message: msg)
                overlayController.dismiss(after: 3.0)
                ErrorLogStore.shared.log(msg)
            }
            return
        }

        // Clarification follow-up is intentionally disabled for now. A hotkey press
        // should always start a fresh recording, independent of any existing Ask
        // Anything or clarification window.
        if pendingClarificationContinuation != nil {
            dismissClarification()
        }

        hotkeyPressedAt = startLocked ? nil : monotonicNow()
        recordingStartupContext = RecordingStartupContext(
            hotkeyDetectedAt: hotkeyDetectedAt,
            recordingWorkflowStartedAt: Date()
        )

        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        isRecording = true
        isAudioRecorderStarted = false
        isAudioRecorderStarting = true
        shouldFinishRecordingAfterAudioStart = false
        recordingMode = startLocked ? .locked : .holdToTalk
        recordingIntent = intent
        let startID = UUID()
        pendingRecordingStartID = startID
        Task { [weak self] in
            await self?.beginRecording(intent: intent, startLocked: startLocked, startID: startID)
        }
    }

    func showSelectedLocalModelDownloadAlertIfNeeded() -> Bool {
        guard settingsStore.sttProvider == .localModel else { return false }

        let selectedModel = settingsStore.localSTTModel
        if case let .downloading(model, progress) = LocalModelDownloadProgressCenter.shared.status,
           model == selectedModel {
            showLocalModelDownloadAlert(model: model, progress: progress)
            return true
        }

        guard let localModelManager, !localModelManager.isModelAvailable(selectedModel) else {
            return false
        }

        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        startSelectedLocalModelDownloadIfNeeded(configuration: configuration)
        showLocalModelDownloadAlert(model: selectedModel, progress: 0.02)
        return true
    }

    private func showLocalModelDownloadAlert(model: LocalSTTModel, progress: Double) {
        guard localModelDownloadAlertTask == nil else { return }
        localModelDownloadAlertTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.localModelDownloadAlertTask = nil
            }
            localModelDownloadAlertPresenter.showDownloadingAlert(
                model: model,
                progress: progress
            )
        }
    }

    private func startSelectedLocalModelDownloadIfNeeded(configuration: LocalSTTConfiguration) {
        guard let localModelManager else { return }
        if localModelPreparationConfiguration == configuration, localModelPreparationTask != nil {
            return
        }

        localModelPreparationTask?.cancel()
        localModelPreparationConfiguration = configuration
        LocalModelDownloadProgressCenter.shared.reportDownloading(model: configuration.model, progress: 0.02)
        localModelPreparationTask = Task { [weak self, localModelManager, notificationService, configuration] in
            do {
                try await localModelManager.prepareModel(configuration: configuration) { update in
                    LocalModelDownloadProgressCenter.shared.reportDownloading(
                        model: configuration.model,
                        progress: update.progress
                    )
                }
                guard !Task.isCancelled else { return }
                LocalModelDownloadProgressCenter.shared.clear()
                await notificationService.sendLocalNotification(
                    title: L("notification.localModelReady.title"),
                    body: L("notification.localModelReady.body"),
                    identifier: "ai.gulu.app.typeflux.local-model-ready"
                )
            } catch {
                guard !Task.isCancelled else {
                    LocalModelDownloadProgressCenter.shared.clear()
                    return
                }
                NetworkDebugLogger.logError(context: "Workflow local STT model download failed", error: error)
                LocalModelDownloadProgressCenter.shared.reportFailed(
                    model: configuration.model,
                    message: error.localizedDescription
                )
            }
            await MainActor.run { [weak self, configuration] in
                guard let self, localModelPreparationConfiguration == configuration else { return }
                localModelPreparationTask = nil
                localModelPreparationConfiguration = nil
            }
        }
    }

    private func promoteActiveRecordingToAskSelection() {
        RecordingStartupLatencyTrace.shared.mark("workflow.promote_to_ask")
        recordingIntent = .askSelection
        recordingMode = .locked
        hotkeyPressedAt = nil
        let prePromotionSelectionTask = selectionTask
        let prePromotionInputContextTask = inputContextTask
        selectionTask = Task {
            if let snapshot = await prePromotionSelectionTask?.value,
               snapshot.hasAskSelectionContext {
                NetworkDebugLogger.logMessage(
                    "[Ask Flow] preserved pre-promotion selection capture for Ask Anything recording"
                )
                return snapshot
            }
            return TextSelectionSnapshot(
                processName: Self.isTypefluxFrontmostApplication() ? "Typeflux" : nil,
                bundleIdentifier: Self.isTypefluxFrontmostApplication() ? Bundle.main.bundleIdentifier : nil,
                source: "ask-promoted-isolated",
                isEditable: false,
                isFocusedTarget: false
            )
        }
        inputContextTask = prePromotionInputContextTask
        activeRealtimeAudioBufferPump?.cancel()
        activeRealtimeAudioBufferPump = nil
        Task {
            await self.liveTranscriptionPreviewer?.cancel()
            await self.activeRealtimeTranscriptionSession?.cancel()
            self.activeRealtimeTranscriptionSession = nil
        }
        Task { @MainActor in
            guard self.isRecording else { return }
            self.overlayController.showLockedRecording(hintText: L("overlay.ask.guidance"))
        }
    }

    private func lockActiveRecording() {
        RecordingStartupLatencyTrace.shared.mark("workflow.lock_active_recording")
        recordingMode = .locked
        hotkeyPressedAt = nil
        let recordingHint = currentRecordingHintPresentation()
        Task { @MainActor in
            guard self.isRecording else { return }
            self.overlayController.showLockedRecording(
                hintText: recordingHint.text,
                autoHideHintAfter: recordingHint.autoHideAfter
            )
        }
    }

    func handlePersonaPickerRequested() {
        guard !isRecording else {
            Task { @MainActor in
                self.overlayController.showNotice(message: L("workflow.persona.finishRecordingFirst"))
            }
            return
        }

        guard processingTask == nil else {
            Task { @MainActor in
                self.overlayController.showNotice(message: L("workflow.persona.waitForProcessing"))
            }
            return
        }

        if isPersonaPickerPresented {
            dismissPersonaPicker()
            return
        }
        if isHistoryPickerPresented {
            dismissHistoryPicker()
        }

        let personaHotkeyAppliesToSelection = settingsStore.personaHotkeyAppliesToSelection
        logger.debug(
            "handlePersonaPickerRequested — personaHotkeyAppliesToSelection=\(personaHotkeyAppliesToSelection)"
        )
        Task { [weak self] in
            guard let self else { return }

            let selectionSnapshot: TextSelectionSnapshot = if settingsStore.personaHotkeyAppliesToSelection {
                await textInjector.selectionSnapshot(for: .explicitSelectionAction)
            } else {
                TextSelectionSnapshot()
            }

            logger
                .debug(
                    "snapshot: isFocusedTarget=\(selectionSnapshot.isFocusedTarget) isEditable=\(selectionSnapshot.isEditable) hasSelection=\(selectionSnapshot.hasSelection) source=\(selectionSnapshot.source) selectedTextLength=\(selectionSnapshot.selectedText?.utf16.count ?? 0)"
                )

            let selectedText = selectionContextText(from: selectionSnapshot)
            let frontmostApplicationContext = Self.frontmostApplicationContext()
            let appName = selectionSnapshot.processName ?? frontmostApplicationContext.appName
            let bundleIdentifier = selectionSnapshot.bundleIdentifier ?? frontmostApplicationContext.bundleIdentifier
            let applicationIcon = Self.applicationIcon(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                frontmostApplicationContext: frontmostApplicationContext
            )
            let mode: PersonaPickerMode
            let items: [PersonaPickerEntry]

            if let selectedText, !selectedText.isEmpty, settingsStore.personaHotkeyAppliesToSelection {
                logger.debug("mode=applySelection")
                mode = .applySelection(PersonaSelectionContext(snapshot: selectionSnapshot, selectedText: selectedText))
                items = personaPickerEntries(includeNoneOption: false)
            } else if let appBinding = settingsStore.activePersonaAppBinding(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            ) {
                logger
                    .debug(
                        "mode=switchApplication appName=\(appName ?? "nil") bundleIdentifier=\(bundleIdentifier ?? "nil")"
                    )
                mode = .switchApplication(appBinding)
                items = personaPickerEntries(includeNoneOption: true)
            } else {
                logger
                    .debug(
                        "mode=switchDefault  selectedText=\(selectedText ?? "nil")  hotkeyApplies=\(settingsStore.personaHotkeyAppliesToSelection)"
                    )
                mode = .switchDefault
                items = personaPickerEntries(includeNoneOption: true)
            }

            guard !items.isEmpty else { return }

            let activeID = switch mode {
            case .switchDefault, .applySelection:
                settingsStore.personaRewriteEnabled ? UUID(uuidString: settingsStore.activePersonaID) : nil
            case let .switchApplication(binding):
                binding.personaID
            }
            let selectedIndex = items.firstIndex(where: { $0.id == activeID }) ?? 0

            await MainActor.run {
                guard !self.isRecording, self.processingTask == nil, !self.isPersonaPickerPresented else { return }
                self.personaPickerMode = mode
                self.personaPickerItems = items
                self.personaPickerSelectedIndex = selectedIndex
                self.isPersonaPickerPresented = true
                self.overlayController.showPersonaPicker(
                    items: items.map {
                        OverlayController.PersonaPickerItem(
                            id: $0.id?.uuidString ?? "plain-dictation",
                            title: $0.title,
                            subtitle: $0.subtitle
                        )
                    },
                    selectedIndex: selectedIndex,
                    title: self.personaPickerTitle(for: mode),
                    instructions: self.personaPickerInstructions(for: mode),
                    icon: self.personaPickerIcon(for: mode, applicationIcon: applicationIcon)
                )
            }
        }
    }

    private struct FrontmostApplicationContext {
        let appName: String?
        let bundleIdentifier: String?
        let icon: NSImage?
    }

    struct RecordingHintPresentation: Equatable {
        let text: String?
        let autoHideAfter: TimeInterval?
    }

    private static func frontmostApplicationContext() -> FrontmostApplicationContext {
        let application = NSWorkspace.shared.frontmostApplication
        let isTypeflux = application?.bundleIdentifier == Bundle.main.bundleIdentifier
        return FrontmostApplicationContext(
            appName: isTypeflux ? nil : application?.localizedName,
            bundleIdentifier: isTypeflux ? nil : application?.bundleIdentifier,
            icon: isTypeflux ? nil : application?.icon
        )
    }

    private static func isTypefluxFrontmostApplication() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private static func isTypefluxAskAnswerWindowFrontmost() -> Bool {
        guard isTypefluxFrontmostApplication() else { return false }
        return TypefluxWindowIdentity.isAskAnswerWindow(NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private static func applicationIcon(
        appName: String?,
        bundleIdentifier: String?,
        frontmostApplicationContext: FrontmostApplicationContext
    ) -> NSImage? {
        if PersonaAppBinding.normalize(bundleIdentifier) == PersonaAppBinding
            .normalize(frontmostApplicationContext.bundleIdentifier)
            || PersonaAppBinding.normalize(appName) == PersonaAppBinding
            .normalize(frontmostApplicationContext.appName) {
            return frontmostApplicationContext.icon
        }

        if let bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }

    func recordingHintPresentation(
        intent: RecordingIntent,
        recordingMode: RecordingMode,
        appName: String?,
        bundleIdentifier: String?
    ) -> RecordingHintPresentation {
        if intent == .askSelection {
            return RecordingHintPresentation(text: L("overlay.ask.guidance"), autoHideAfter: nil)
        }

        if shouldUseQuickInput(recordingMode: recordingMode, recordingIntent: intent) {
            return RecordingHintPresentation(
                text: L("overlay.recording.quickInputHint"),
                autoHideAfter: Self.recordingHintAutoHideDelay
            )
        }

        guard let persona = settingsStore.effectivePersona(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ) else {
            return RecordingHintPresentation(text: nil, autoHideAfter: nil)
        }

        return RecordingHintPresentation(
            text: L("overlay.recording.personaHint", persona.name),
            autoHideAfter: Self.recordingHintAutoHideDelay
        )
    }

    func shouldOptimizeTypefluxASR(
        intent: RecordingIntent,
        recordingMode: RecordingMode,
        appName: String?,
        bundleIdentifier: String?
    ) -> Bool {
        guard intent == .dictation else { return true }
        if shouldUseQuickInput(recordingMode: recordingMode, recordingIntent: intent) {
            return true
        }
        guard let persona = settingsStore.effectivePersona(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ) else {
            return true
        }
        return settingsStore.resolvedPersonaPrompt(for: persona)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    func currentRecordingHintPresentation() -> RecordingHintPresentation {
        let frontmostApplicationContext = Self.frontmostApplicationContext()
        return recordingHintPresentation(
            intent: recordingIntent,
            recordingMode: recordingMode,
            appName: frontmostApplicationContext.appName,
            bundleIdentifier: frontmostApplicationContext.bundleIdentifier
        )
    }

    func beginRecording(intent: RecordingIntent, startLocked: Bool, startID: UUID? = nil) async {
        if let startID, pendingRecordingStartID != startID {
            RecordingStartupLatencyTrace.shared.mark("workflow.begin_recording_cancelled")
            return
        }
        RecordingStartupLatencyTrace.shared.mark("workflow.begin_recording")
        let effectiveIntent = recordingIntent == .askSelection && intent == .dictation
            ? RecordingIntent.askSelection
            : intent
        let effectiveStartLocked = recordingMode == .locked || startLocked
        isRecording = true
        isAudioRecorderStarted = false
        isAudioRecorderStarting = true
        shouldFinishRecordingAfterAudioStart = false
        audioRecorderStartedAt = nil
        recordingMode = effectiveStartLocked ? .locked : .holdToTalk
        recordingIntent = effectiveIntent
        lastRetryableFailureRecord = nil
        latestRecordingPreviewText = ""
        let frontmostApplicationContext = Self.frontmostApplicationContext()
        beginDictationAnalytics(
            intent: effectiveIntent,
            mode: recordingMode,
            targetBundleIdentifier: frontmostApplicationContext.bundleIdentifier
        )
        let recordingHint = recordingHintPresentation(
            intent: effectiveIntent,
            recordingMode: recordingMode,
            appName: frontmostApplicationContext.appName,
            bundleIdentifier: frontmostApplicationContext.bundleIdentifier
        )
        let optimizeASR = shouldOptimizeTypefluxASR(
            intent: effectiveIntent,
            recordingMode: recordingMode,
            appName: frontmostApplicationContext.appName,
            bundleIdentifier: frontmostApplicationContext.bundleIdentifier
        )
        NSLog("[Workflow] Recording started")

        Task { @MainActor in
            guard self.isRecording else { return }
            appState.setStatus(.recording)
            if effectiveStartLocked {
                if effectiveIntent == .askSelection {
                    overlayController.showLockedRecording(hintText: L("overlay.ask.guidance"))
                } else {
                    overlayController.showLockedRecording(
                        hintText: recordingHint.text,
                        autoHideHintAfter: recordingHint.autoHideAfter
                    )
                }
            } else {
                overlayController.show(
                    hintText: recordingHint.text,
                    autoHideHintAfter: recordingHint.autoHideAfter
                )
            }
        }

        do {
            RecordingStartupLatencyTrace.shared.mark("workflow.audio_start_enter")
            let livePreviewer = liveTranscriptionPreviewer
            let canUseRealtimeTranscription = effectiveIntent != .askSelection
            let usesLivePreview = canUseRealtimeTranscription && shouldUseLiveTranscriptionPreview()
            let recordingAudioBufferRelay = canUseRealtimeTranscription
                ? RecordingStartupAudioBufferRelay()
                : nil
            try await startAudioRecorderWithStartupRetry(
                levelHandler: { [weak self] level in
                    self?.overlayController.updateLevel(level)
                },
                audioBufferHandler: recordingAudioBufferRelay.map { relay in
                    { buffer in relay.append(buffer) }
                }
            )
            RecordingStartupLatencyTrace.shared.mark("workflow.audio_start_return")
            isAudioRecorderStarting = false
            isAudioRecorderStarted = true
            audioRecorderStartedAt = monotonicNow()
            pendingRecordingStartID = nil

            guard isRecording else {
                recordingAudioBufferRelay?.cancel()
                isAudioRecorderStarted = false
                audioRecorderStartedAt = nil
                _ = try? audioRecorder.stop()
                Task { await livePreviewer?.cancel() }
                return
            }

            if shouldFinishRecordingAfterAudioStart {
                recordingAudioBufferRelay?.cancel()
                shouldFinishRecordingAfterAudioStart = false
                finishRecordingFromCurrentMode()
                return
            }

            if usesLivePreview {
                await livePreviewer?.prepareForStart()
            }
            let realtimeSession: (any RealtimeTranscriptionSession)? = if canUseRealtimeTranscription {
                await sttRouter.makeRealtimeTranscriptionSession(
                    scenario: .voiceInput,
                    optimize: optimizeASR,
                    onUpdate: { [weak self] snapshot in
                        let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task { @MainActor [weak self] in
                            guard let self, isRecording else { return }
                            latestRecordingPreviewText = trimmed
                            overlayController.updateRecordingPreviewText(trimmed)
                        }
                    }
                )
            } else {
                nil
            }
            guard isRecording else {
                recordingAudioBufferRelay?.cancel()
                await realtimeSession?.cancel()
                return
            }
            if effectiveIntent == .askSelection {
                NetworkDebugLogger
                    .logMessage("[Ask Flow] realtime transcription disabled for isolated Ask Anything recording")
            }
            let realtimeAudioBufferPump = realtimeSession.map { RealtimeAudioBufferPump(session: $0) }
            activeRealtimeTranscriptionSession = realtimeSession
            activeRealtimeAudioBufferPump = realtimeAudioBufferPump
            await realtimeSession?.start()
            guard isRecording else {
                recordingAudioBufferRelay?.cancel()
                realtimeAudioBufferPump?.cancel()
                await realtimeSession?.cancel()
                return
            }
            if usesLivePreview || realtimeAudioBufferPump != nil {
                recordingAudioBufferRelay?.activate { buffer in
                    realtimeAudioBufferPump?.append(buffer)
                    Task {
                        if usesLivePreview {
                            await livePreviewer?.append(buffer)
                        }
                    }
                }
            } else {
                recordingAudioBufferRelay?.cancel()
            }
            if usesLivePreview {
                startLiveTranscriptionPreviewIfNeeded(livePreviewer)
            }

            let askAnswerWindowIsFrontmost = Self.isTypefluxAskAnswerWindowFrontmost()
            let shouldSkipSelectionCapture = effectiveIntent == .askSelection || askAnswerWindowIsFrontmost
            selectionTask = Task { [
                weak self,
                shouldSkipSelectionCapture,
                askAnswerWindowIsFrontmost,
                effectiveIntent
            ] in
                guard let self else { return TextSelectionSnapshot() }
                if shouldSkipSelectionCapture {
                    let source = effectiveIntent == .askSelection ? "ask-isolated" : "typeflux-ask-answer-window"
                    NetworkDebugLogger.logMessage(
                        "[Ask Flow] skipped selection capture source=\(source)"
                    )
                    return TextSelectionSnapshot(
                        processName: askAnswerWindowIsFrontmost ? "Typeflux" : nil,
                        bundleIdentifier: askAnswerWindowIsFrontmost ? Bundle.main.bundleIdentifier : nil,
                        source: source,
                        isEditable: false,
                        isFocusedTarget: false
                    )
                }
                return await textInjector.selectionSnapshot(for: .automaticInsertion)
            }
            if settingsStore.inputContextOptimizationEnabled, !shouldSkipSelectionCapture {
                let selectionTask = selectionTask
                inputContextTask = Task { [weak self] in
                    guard let self else { return nil }
                    let selectionSnapshot = await selectionTask?.value ?? TextSelectionSnapshot()
                    let inputSnapshot = await textInjector.currentInputTextSnapshot()
                    let context = InputContextSnapshot.make(
                        inputSnapshot: inputSnapshot,
                        selectionSnapshot: selectionSnapshot
                    )
                    InputContextSnapshot.logCapture(
                        inputSnapshot: inputSnapshot,
                        selectionSnapshot: selectionSnapshot,
                        context: context
                    )
                    return context
                }
            } else {
                inputContextTask = nil
            }

            Task { [weak self] in
                await self?.sttRouter.prepareForRecording()
            }

            // Set a timeout to auto-stop recording after 10 minutes
            recordingTimeoutTask?.cancel()
            recordingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.recordingTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                NSLog("[Workflow] Recording timeout - auto stopping")
                self?.finishRecordingFromCurrentMode()
            }
        } catch {
            Task { await liveTranscriptionPreviewer?.cancel() }
            activeRealtimeAudioBufferPump?.cancel()
            Task { await activeRealtimeTranscriptionSession?.cancel() }
            activeRealtimeTranscriptionSession = nil
            activeRealtimeAudioBufferPump = nil
            isRecording = false
            isAudioRecorderStarted = false
            isAudioRecorderStarting = false
            shouldFinishRecordingAfterAudioStart = false
            audioRecorderStartedAt = nil
            let startupContext = recordingStartupContext
            recordingStartupContext = nil
            pendingRecordingStartID = nil
            suppressActivationTapUntil = nil
            recordingMode = .holdToTalk
            var record = HistoryRecord(
                date: Date(),
                recordingStatus: .failed,
                transcriptionStatus: .skipped,
                processingStatus: .skipped,
                applyStatus: .skipped
            )
            record.pipelineTiming = HistoryPipelineTiming(
                hotkeyDetectedAt: startupContext?.hotkeyDetectedAt,
                recordingWorkflowStartedAt: startupContext?.recordingWorkflowStartedAt
            )
            let userMessage = Self.audioStartFailureMessage(for: error)
            record.errorMessage = userMessage
            saveHistoryRecord(record)
            bindPendingDictationAnalytics(to: record.id)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)
            NetworkDebugLogger.logError(context: "Audio recorder failed to start", error: error)
            Task { @MainActor in
                self.soundEffectPlayer.play(.error)
                appState.setStatus(.failed(message: userMessage))
                overlayController.showFailure(message: userMessage)
                overlayController.dismiss(after: 6.0)
                ErrorLogStore.shared.log(userMessage)
            }
        }
    }

    func handlePressEnded() {
        // Prevent double-end or end without start
        guard isRecording else {
            NSLog("[Workflow] Not recording, ignoring release")
            return
        }

        // If in clarification recording mode, finish the clarification recording.
        if isClarificationRecording {
            finishClarificationRecording()
            return
        }

        guard recordingMode == .holdToTalk else { return }

        let releasedAt = monotonicNow()
        let pressDuration = hotkeyPressedAt.map { max(0, releasedAt - $0) } ?? .infinity
        hotkeyPressedAt = nil

        let recordedDuration = audioRecorderStartedAt.map { max(0, releasedAt - $0) } ?? 0
        if pressDuration < Self.tapToLockThreshold
            || isAudioRecorderStarting
            || recordedDuration < Self.minimumRecordingDuration {
            lockActiveRecording()
            return
        }

        finishRecordingFromCurrentMode()
    }

    func handleAskPressEnded() {
        guard isRecording, recordingIntent == .askSelection else { return }
        // Ask recordings are toggle-based; release should not end the recording.
    }

    func confirmLockedRecording() {
        guard isRecording, recordingMode == .locked else { return }
        finishRecordingFromCurrentMode()
    }

    func shouldUseQuickInput(recordingMode: RecordingMode, recordingIntent: RecordingIntent) -> Bool {
        settingsStore.quickInputEnabled
            && recordingIntent == .dictation
            && recordingMode == .holdToTalk
    }

    func finishRecordingFromCurrentMode() {
        guard isRecording else { return }

        let shouldStopAudioRecorder = isAudioRecorderStarted
        if !shouldStopAudioRecorder, isAudioRecorderStarting {
            shouldFinishRecordingAfterAudioStart = true
            recordingMode = .holdToTalk
            hotkeyPressedAt = nil
            recordingTimeoutTask?.cancel()
            recordingTimeoutTask = nil
            return
        }

        let useQuickInput = shouldUseQuickInput(
            recordingMode: recordingMode,
            recordingIntent: recordingIntent
        )
        let startupContext = recordingStartupContext
        recordingStartupContext = nil
        isRecording = false
        if !shouldStopAudioRecorder {
            isAudioRecorderStarted = false
        }
        pendingRecordingStartID = nil
        recordingMode = .holdToTalk
        hotkeyPressedAt = nil
        audioRecorderStartedAt = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        NSLog("[Workflow] Recording stopped")
        let recordingStoppedAt = Date()

        guard shouldStopAudioRecorder else {
            selectionTask?.cancel()
            selectionTask = nil
            inputContextTask?.cancel()
            inputContextTask = nil
            Task { await liveTranscriptionPreviewer?.cancel() }
            Task { @MainActor in
                self.appState.setStatus(.idle)
                self.overlayController.showNotice(message: L("workflow.recording.tooShort"))
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await finishRecordingAndProcess(
                recordingStoppedAt: recordingStoppedAt,
                startupContext: startupContext,
                bypassPersonaRewrite: useQuickInput
            )
        }
    }

    // MARK: - Clarification recording

    func beginClarificationRecording() async {
        isRecording = true
        isAudioRecorderStarted = false
        agentClarificationWindowController.updateRecordingState(.recording)
        NSLog("[Workflow] Clarification recording started")

        do {
            try audioRecorder.start(
                levelHandler: { _ in },
                audioBufferHandler: nil
            )
            isAudioRecorderStarted = true
        } catch {
            isRecording = false
            isAudioRecorderStarted = false
            isClarificationRecording = false
            agentClarificationWindowController.updateRecordingState(.waitingForReply)
            let userMessage = Self.audioStartFailureMessage(for: error)
            NetworkDebugLogger.logError(context: "Clarification recording failed to start", error: error)
            Task { @MainActor in
                self.soundEffectPlayer.play(.error)
                self.appState.setStatus(.failed(message: userMessage))
                self.overlayController.showFailure(message: userMessage)
                self.overlayController.dismiss(after: 6.0)
            }
        }
    }

    func finishClarificationRecording() {
        guard isRecording, isClarificationRecording else { return }
        isRecording = false
        isAudioRecorderStarted = false
        isClarificationRecording = false
        agentClarificationWindowController.updateRecordingState(.transcribing)
        NSLog("[Workflow] Clarification recording stopped, transcribing")

        Task { [weak self] in
            guard let self else { return }
            guard let audioFile = try? audioRecorder.stop() else {
                agentClarificationWindowController.updateRecordingState(.waitingForReply)
                return
            }

            do {
                let transcript = try await sttRouter.transcribe(audioFile: audioFile)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    agentClarificationWindowController.updateRecordingState(.waitingForReply)
                    return
                }
                resumeClarificationWithReply(trimmed)
            } catch {
                NSLog("[Workflow] Clarification transcription failed: \(error)")
                agentClarificationWindowController.updateRecordingState(.waitingForReply)
            }
        }
    }

    func resumeClarificationWithReply(_ reply: String) {
        guard let continuation = pendingClarificationContinuation else { return }
        pendingClarificationContinuation = nil
        agentClarificationWindowController.dismiss()
        continuation.resume(returning: reply)
    }

    func dismissClarification() {
        guard let continuation = pendingClarificationContinuation else { return }
        pendingClarificationContinuation = nil
        agentClarificationWindowController.dismiss()
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - LLM Configuration Validation

    func validateLLMConfiguration() async -> LLMConfigurationStatus {
        let isLoggedIn = await MainActor.run { AuthState.shared.isLoggedIn }
        let validator = LLMConfigurationValidator(
            settingsStore: settingsStore,
            isLoggedIn: isLoggedIn
        )
        return validator.validate()
    }

    func presentLLMNotConfigured(_ status: LLMConfigurationStatus) async {
        guard case let .notConfigured(reason) = status else { return }
        let presentation = LLMConfigurationReminderPolicy(settingsStore: settingsStore)
            .presentation(for: status)
        await MainActor.run {
            self.shouldPreserveLLMConfigurationNotice = true

            guard presentation == .actionDialog else {
                self.appState.setStatus(.idle)
                self.overlayController.showNotice(message: L("workflow.llmNotConfigured.notice.localFallback"))
                return
            }

            self.soundEffectPlayer.play(.error)

            let actions: [OverlayFailureAction] = [
                OverlayFailureAction(
                    title: L("workflow.llmNotConfigured.action.loginCloud"),
                    isRetry: false,
                    handler: {
                        LoginWindowController.shared.show()
                    }
                ),
                OverlayFailureAction(
                    title: L("workflow.llmNotConfigured.action.configureCustomModel"),
                    isRetry: false,
                    style: .secondary,
                    trailingSystemImage: "gearshape",
                    handler: { [weak self] in
                        guard let self else { return }
                        SettingsWindowController.shared.show(
                            settingsStore: settingsStore,
                            historyStore: historyStore,
                            initialSection: .models
                        )
                    }
                )
            ]

            self.overlayController.showFailureWithActions(
                message: reason.localizedMessage,
                actions: actions
            )
        }
    }

    func presentTypefluxCloudLoginRequired() async {
        await presentLLMNotConfigured(.notConfigured(reason: .cloudNotLoggedIn))
    }

    func presentCloudBillingError(_ error: TypefluxCloudBillingError) async {
        await MainActor.run {
            let hasPaidSubscription = AuthState.shared.subscription.hasPaidSubscription
            let billingEnabled = AuthState.shared.subscription.billingEnabled
            guard self.shouldPresentCloudBillingError(
                error,
                hasPaidSubscription: hasPaidSubscription
            ) else {
                return
            }

            self.shouldPreserveLLMConfigurationNotice = true
            self.soundEffectPlayer.play(.tip)

            let primaryAction = error.primaryAction(
                hasPaidSubscription: hasPaidSubscription,
                billingEnabled: billingEnabled
            )

            let actions: [OverlayFailureAction] = [
                OverlayFailureAction(
                    title: error.primaryActionTitle(
                        hasPaidSubscription: hasPaidSubscription,
                        billingEnabled: billingEnabled
                    ),
                    isRetry: false,
                    trailingSystemImage: "arrow.up.right",
                    handler: { [weak self] in
                        guard let self else { return }
                        switch primaryAction {
                        case .openAccount:
                            SettingsWindowController.shared.show(
                                settingsStore: settingsStore,
                                historyStore: historyStore,
                                initialSection: .account
                            )
                        case .openPlans:
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                do {
                                    let url = try await AccountBillingFlow.destination(
                                        for: .subscribe,
                                        requestBillingPageToken: {
                                            try await AuthState.shared.requestBillingPageToken()
                                        },
                                        createPortalSession: {
                                            try await AuthState.shared.createBillingPortalSession()
                                        }
                                    )
                                    NSWorkspace.shared.open(url)
                                } catch {
                                    self.logger.error(
                                        "Failed to open Typeflux Cloud plans: \(error.localizedDescription, privacy: .public)"
                                    )
                                    SettingsWindowController.shared.show(
                                        settingsStore: self.settingsStore,
                                        historyStore: self.historyStore,
                                        initialSection: .account
                                    )
                                }
                            }
                        }
                    }
                ),
                OverlayFailureAction(
                    title: L("cloud.billing.action.switchModel"),
                    isRetry: false,
                    style: .text,
                    handler: { [weak self] in
                        guard let self else { return }
                        SettingsWindowController.shared.show(
                            settingsStore: settingsStore,
                            historyStore: historyStore,
                            initialSection: .models
                        )
                    }
                )
            ]

            self.overlayController.showFailureWithActions(
                title: error.title(hasPaidSubscription: hasPaidSubscription, billingEnabled: billingEnabled),
                message: error.message(hasPaidSubscription: hasPaidSubscription, billingEnabled: billingEnabled),
                tone: .billing,
                actions: actions
            )
        }
    }

    @MainActor
    func shouldPresentCloudBillingError(
        _ error: TypefluxCloudBillingError,
        hasPaidSubscription: Bool,
        now: Date = Date()
    ) -> Bool {
        guard error.reason == .quotaExceeded, hasPaidSubscription else {
            return true
        }

        if let lastPaidCreditExhaustedPromptPresentedAt,
           now.timeIntervalSince(lastPaidCreditExhaustedPromptPresentedAt)
           < Self.paidCreditExhaustedPromptSuppressionInterval {
            return false
        }

        lastPaidCreditExhaustedPromptPresentedAt = now
        return true
    }
}

// swiftlint:enable file_length function_body_length line_length type_body_length
