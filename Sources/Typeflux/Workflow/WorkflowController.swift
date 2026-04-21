// swiftlint:disable file_length function_body_length line_length type_body_length
import Foundation
import os

final class WorkflowController {
    let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "WorkflowController")
    static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes
    static let processingTimeoutNanoseconds: UInt64 = 120_000_000_000 // 2 minutes
    static let tapToLockThreshold: TimeInterval = 0.22
    static let minimumRecordingDuration: TimeInterval = 0.35
    static let selectionRestoreDelayMicroseconds: useconds_t = 120_000
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
    // Dropped from 8s to 4s so real editing sessions have a realistic chance to
    // complete before the next dictation arrives.
    static let automaticVocabularyIdleSettleDelay: TimeInterval = 4
    // Raised from 0.6 to 0.8 so short dictations with a delete+retype edit are
    // still considered for analysis.
    static let automaticVocabularyEditRatioLimit: Double = 0.8
    static let localModelPreheatDebounce: Duration = .milliseconds(180)
    static let llmTimeoutAfterTranscriptionSeconds: TimeInterval = 120
    static let recordingStartCueLeadIn: Duration = .milliseconds(60)

    struct LLMRequestTimeoutError: LocalizedError {
        var errorDescription: String? {
            "Persona rewrite timed out after \(Int(WorkflowController.llmTimeoutAfterTranscriptionSeconds)) seconds, inserting transcript as fallback"
        }
    }

    enum RecordingMode {
        case holdToTalk
        case locked
    }

    enum RecordingIntent {
        case dictation
        case askSelection
    }

    enum ApplyOutcome {
        case inserted
        case presentedInDialog

        var message: String {
            switch self {
            case .inserted:
                L("workflow.apply.inserted")
            case .presentedInDialog:
                L("workflow.apply.presentedInDialog")
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
    let sleep: @Sendable (Duration) async -> Void

    var currentSelectedText: String?
    var isRecording = false
    var recordingMode: RecordingMode = .holdToTalk
    var recordingIntent: RecordingIntent = .dictation
    var hotkeyPressedAt: Date?
    var recordingTimeoutTask: Task<Void, Never>?
    var processingTimeoutTask: Task<Void, Never>?
    var selectionTask: Task<TextSelectionSnapshot, Never>?
    var processingTask: Task<Void, Never>?
    var automaticVocabularyObservationTask: Task<Void, Never>?
    /// Latest snapshot of the currently running automatic-vocabulary observation.
    /// Kept in sync by the observation task so that an incoming `scheduleAutomatic…`
    /// call can finalize-then-cancel instead of dropping partially-observed work.
    var automaticVocabularyActiveSession: AutomaticVocabularyActiveSession?
    var processingSessionID = UUID()
    var activeProcessingRecordID: UUID?
    var lastRetryableFailureRecord: HistoryRecord?
    var lastDialogResultText: String?
    var localModelPreheatTask: Task<Void, Never>?
    var lastLocalModelPreheatConfiguration: LocalSTTConfiguration?
    var localModelPreheatObserver: NSObjectProtocol?
    var isPersonaPickerPresented = false
    var personaPickerItems: [PersonaPickerEntry] = []
    var personaPickerSelectedIndex = 0
    var personaPickerMode: PersonaPickerMode = .switchDefault

    // Clarification mode: set when the agent workflow is paused waiting for a user voice reply.
    var pendingClarificationContinuation: CheckedContinuation<String, Error>?
    var isClarificationRecording = false

    struct PersonaPickerEntry {
        let id: UUID?
        let title: String
        let subtitle: String
    }

    struct PersonaSelectionContext {
        let snapshot: TextSelectionSnapshot
        let selectedText: String
    }

    enum PersonaPickerMode {
        case switchDefault
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
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
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
        self.sleep = sleep
        self.overlayController.setRecordingActionHandlers(
            onCancel: { [weak self] in
                guard let self else { return }
                if isRecording {
                    cancelRecording()
                } else {
                    cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.userCancelled"))
                }
            },
            onConfirm: { [weak self] in self?.confirmLockedRecording() },
        )
        self.overlayController.setResultDialogHandler(
            onCopy: { [weak self] in self?.copyLastResultFromDialog() },
        )
        self.overlayController.setFailureRetryHandler(
            onRetry: { [weak self] in
                guard let self, let record = lastRetryableFailureRecord else { return }
                retry(record: record)
            },
        )
        self.overlayController.setPersonaPickerHandlers(
            onMoveUp: { [weak self] in self?.movePersonaSelection(delta: -1) },
            onMoveDown: { [weak self] in self?.movePersonaSelection(delta: 1) },
            onSelect: { [weak self] index in self?.selectPersonaSelection(at: index) },
            onConfirm: { [weak self] in self?.confirmPersonaSelection() },
            onCancel: { [weak self] in self?.dismissPersonaPicker() },
        )
        self.agentClarificationWindowController.onDismiss = { [weak self] in
            self?.dismissClarification()
        }
    }

    func presentAskAnswer(question: String, selectedText: String?, answerMarkdown: String) {
        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Sending content to window
            Question: \(question)
            Selected Text: \(selectedText ?? "<empty>")
            Answer Markdown: \(answerMarkdown)
            """,
        )
        overlayController.dismissImmediately()
        askAnswerWindowController.show(
            title: L("workflow.ask.answerTitle"),
            question: question,
            selectedText: selectedText,
            answerMarkdown: answerMarkdown,
        )
    }

    func start() {
        hotkeyService.onActivationTap = { [weak self] in
            self?.handleActivationTap()
        }
        hotkeyService.onActivationPressBegan = { [weak self] in
            self?.handlePressBegan(intent: .dictation, startLocked: false)
        }
        hotkeyService.onActivationPressEnded = { [weak self] in
            self?.handlePressEnded()
        }
        hotkeyService.onAskPressBegan = { [weak self] in
            self?.handlePressBegan(intent: .askSelection, startLocked: true)
        }
        hotkeyService.onAskPressEnded = { [weak self] in
            self?.handleAskPressEnded()
        }
        hotkeyService.onPersonaPickerRequested = { [weak self] in
            self?.handlePersonaPickerRequested()
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
            queue: .main,
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
        askAnswerWindowController.dismiss()
        agentClarificationWindowController.dismiss()
        cancelRecording()
        cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.stopping"))
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil
        localModelPreheatTask?.cancel()
        localModelPreheatTask = nil
        lastLocalModelPreheatConfiguration = nil
        if let obs = localModelPreheatObserver {
            NotificationCenter.default.removeObserver(obs)
            localModelPreheatObserver = nil
        }
    }

    func retry(record: HistoryRecord) {
        guard !isRecording else { return }
        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.retry"))

        let sessionID = beginProcessingSession()
        startProcessingTimeout(sessionID: sessionID)
        processingTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.appState.setStatus(.processing)
                self.overlayController.showProcessing()
            }
            await reprocess(record: record, sessionID: sessionID)
            cancelProcessingTimeout()
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
        isRecording = false
        recordingMode = .holdToTalk
        recordingIntent = .dictation
        hotkeyPressedAt = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        _ = try? audioRecorder.stop()
        Task {
            await sttRouter.cancelPreparedRecording()
        }
        selectionTask?.cancel()
        selectionTask = nil
        Task { @MainActor in
            appState.setStatus(.idle)
            overlayController.dismiss(after: 0.3)
        }
        NSLog("[Workflow] Recording cancelled")
    }

    func startProcessingTimeout(sessionID: UUID) {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.processingTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            NSLog("[Workflow] Processing timeout after 120 seconds")
            self?.handleProcessingTimeout(sessionID: sessionID)
        }
    }

    func cancelProcessingTimeout() {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
    }

    func handleProcessingTimeout(sessionID: UUID) {
        guard processingSessionID == sessionID else { return }
        let recordID = activeProcessingRecordID
        cancelCurrentProcessing(resetUI: false, reason: L("workflow.timeout.reason"))
        var timeoutRecord: HistoryRecord? = nil
        if let recordID {
            timeoutRecord = historyStore.record(id: recordID)
        }
        Task { @MainActor in
            self.lastRetryableFailureRecord = timeoutRecord
            self.soundEffectPlayer.play(.error)
            self.appState.setStatus(.failed(message: L("workflow.timeout.status")))
            self.overlayController.showTimeoutFailure()
        }
    }

    func handleActivationTap() {
        handlePressBegan(intent: .dictation, startLocked: true)
    }

    func handlePressBegan(intent: RecordingIntent, startLocked: Bool) {
        if isPersonaPickerPresented {
            dismissPersonaPicker()
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

        // If the agent is waiting for a clarification reply, intercept the hotkey press
        // to start a clarification recording instead of cancelling the agent session.
        if pendingClarificationContinuation != nil {
            guard !isRecording else { return }
            isClarificationRecording = true
            Task { [weak self] in await self?.beginClarificationRecording() }
            return
        }

        hotkeyPressedAt = startLocked ? nil : Date()

        if isRecording {
            guard recordingMode == .locked else {
                NSLog("[Workflow] Already recording, ignoring press")
                return
            }

            confirmLockedRecording()
            return
        }

        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        Task { [weak self] in
            await self?.beginRecording(intent: intent, startLocked: startLocked)
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

        let personaHotkeyAppliesToSelection = settingsStore.personaHotkeyAppliesToSelection
        logger.debug(
            "handlePersonaPickerRequested — personaHotkeyAppliesToSelection=\(personaHotkeyAppliesToSelection)",
        )
        Task { [weak self] in
            guard let self else { return }

            let selectionSnapshot: TextSelectionSnapshot = if settingsStore.personaHotkeyAppliesToSelection {
                await textInjector.getSelectionSnapshot()
            } else {
                TextSelectionSnapshot()
            }

            logger.debug("snapshot: isFocusedTarget=\(selectionSnapshot.isFocusedTarget) isEditable=\(selectionSnapshot.isEditable) hasSelection=\(selectionSnapshot.hasSelection) source=\(selectionSnapshot.source) selectedText=\(selectionSnapshot.selectedText?.prefix(32) ?? "nil")")

            let selectedText = editingSelectedText(from: selectionSnapshot)
            let mode: PersonaPickerMode
            let items: [PersonaPickerEntry]

            if let selectedText, !selectedText.isEmpty, settingsStore.personaHotkeyAppliesToSelection {
                logger.debug("mode=applySelection")
                mode = .applySelection(PersonaSelectionContext(snapshot: selectionSnapshot, selectedText: selectedText))
                items = personaPickerEntries(includeNoneOption: false)
            } else {
                logger.debug("mode=switchDefault  selectedText=\(selectedText ?? "nil")  hotkeyApplies=\(settingsStore.personaHotkeyAppliesToSelection)")
                mode = .switchDefault
                items = personaPickerEntries(includeNoneOption: true)
            }

            guard !items.isEmpty else { return }

            let activeID = settingsStore.personaRewriteEnabled ? UUID(uuidString: settingsStore.activePersonaID) : nil
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
                            subtitle: $0.subtitle,
                        )
                    },
                    selectedIndex: selectedIndex,
                    title: self.personaPickerTitle(for: mode),
                    instructions: self.personaPickerInstructions(for: mode),
                )
            }
        }
    }

    func beginRecording(intent: RecordingIntent, startLocked: Bool) async {
        isRecording = true
        recordingMode = startLocked ? .locked : .holdToTalk
        recordingIntent = intent
        lastRetryableFailureRecord = nil
        NSLog("[Workflow] Recording started")

        Task { @MainActor in
            appState.setStatus(.recording)
            if startLocked {
                if intent == .askSelection {
                    overlayController.showLockedRecording(hintText: L("overlay.ask.guidance"))
                } else {
                    overlayController.showLockedRecording()
                }
            } else {
                overlayController.show()
            }
        }

        await Self.waitForRecordingStartCueIfNeeded(
            leadIn: Self.recordingStartCueLeadIn,
            playCue: { @MainActor in
                self.soundEffectPlayer.play(.start)
            },
            sleep: sleep,
        )

        selectionTask = Task { [weak self] in
            guard let self else { return TextSelectionSnapshot() }
            return await textInjector.getSelectionSnapshot()
        }

        do {
            try audioRecorder.start(
                levelHandler: { [weak self] level in
                    self?.overlayController.updateLevel(level)
                },
                audioBufferHandler: { _ in },
            )

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
            isRecording = false
            recordingMode = .holdToTalk
            var record = HistoryRecord(
                date: Date(),
                recordingStatus: .failed,
                transcriptionStatus: .skipped,
                processingStatus: .skipped,
                applyStatus: .skipped,
            )
            record.errorMessage = "Audio start failed: \(error.localizedDescription)"
            saveHistoryRecord(record)
            Task { @MainActor in
                let msg = "Audio start failed: \(error.localizedDescription)"
                self.soundEffectPlayer.play(.error)
                appState.setStatus(.failed(message: L("workflow.audioStart.failedStatus")))
                overlayController.showFailure(message: msg)
                overlayController.dismiss(after: 3.0)
                ErrorLogStore.shared.log(msg)
            }
        }
    }

    static func waitForRecordingStartCueIfNeeded(
        leadIn: Duration,
        playCue: @escaping @MainActor () -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void,
    ) async {
        let didStartCue = await MainActor.run {
            playCue()
        }
        guard didStartCue else { return }
        await sleep(leadIn)
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

        let pressDuration = Date().timeIntervalSince(hotkeyPressedAt ?? Date.distantPast)
        hotkeyPressedAt = nil

        if pressDuration < Self.tapToLockThreshold {
            recordingMode = .locked
            Task { @MainActor in
                overlayController.showLockedRecording()
            }
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

    func finishRecordingFromCurrentMode() {
        guard isRecording else { return }

        isRecording = false
        recordingMode = .holdToTalk
        hotkeyPressedAt = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        NSLog("[Workflow] Recording stopped")
        let recordingStoppedAt = Date()

        Task { [weak self] in
            guard let self else { return }
            await finishRecordingAndProcess(recordingStoppedAt: recordingStoppedAt)
        }
    }

    // MARK: - Clarification recording

    func beginClarificationRecording() async {
        isRecording = true
        agentClarificationWindowController.updateRecordingState(.recording)
        NSLog("[Workflow] Clarification recording started")

        do {
            try audioRecorder.start(
                levelHandler: { _ in },
                audioBufferHandler: nil,
            )
        } catch {
            isRecording = false
            isClarificationRecording = false
            agentClarificationWindowController.updateRecordingState(.waitingForReply)
            NSLog("[Workflow] Clarification recording failed to start: \(error)")
        }
    }

    func finishClarificationRecording() {
        guard isRecording, isClarificationRecording else { return }
        isRecording = false
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
}

// swiftlint:enable file_length function_body_length line_length type_body_length
