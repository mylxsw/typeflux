import Foundation

final class WorkflowController {
    private static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes
    private static let processingTimeoutNanoseconds: UInt64 = 120_000_000_000 // 2 minutes
    private static let tapToLockThreshold: TimeInterval = 0.22
    private static let minimumRecordingDuration: TimeInterval = 0.35
    private static let selectionRestoreDelayMicroseconds: useconds_t = 120_000
    private static let automaticVocabularyObservationWindow: TimeInterval = 30
    private static let automaticVocabularyPollInterval: Duration = .seconds(1)
    private static let automaticVocabularyStartupDelay: Duration = .milliseconds(350)
    private static let automaticVocabularyBaselineRetryDelay: Duration = .milliseconds(400)
    private static let automaticVocabularyBaselineRetryCount = 3
    private static let automaticVocabularySettleDelay: TimeInterval = 2.5
    private static let automaticVocabularyMaxAnalysesPerSession = 3

    private enum RecordingMode {
        case holdToTalk
        case locked
    }

    private enum RecordingIntent {
        case dictation
        case askSelection
    }

    private enum ApplyOutcome {
        case inserted
        case presentedInDialog

        var message: String {
            switch self {
            case .inserted:
                return L("workflow.apply.inserted")
            case .presentedInDialog:
                return L("workflow.apply.presentedInDialog")
            }
        }
    }

    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let hotkeyService: HotkeyService
    private let audioRecorder: AudioRecorder
    private let sttRouter: STTRouter
    private let llmService: LLMService
    private let llmAgentService: LLMAgentService
    private let textInjector: TextInjector
    private let clipboard: ClipboardService
    private let historyStore: HistoryStore
    private let overlayController: OverlayController
    private let askAnswerWindowController: AskAnswerWindowController
    private let soundEffectPlayer: SoundEffectPlayer

    private var currentSelectedText: String?
    private var isRecording = false
    private var recordingMode: RecordingMode = .holdToTalk
    private var recordingIntent: RecordingIntent = .dictation
    private var hotkeyPressedAt: Date?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var processingTimeoutTask: Task<Void, Never>?
    private var selectionTask: Task<TextSelectionSnapshot, Never>?
    private var processingTask: Task<Void, Never>?
    private var automaticVocabularyObservationTask: Task<Void, Never>?
    private var processingSessionID = UUID()
    private var activeProcessingRecordID: UUID?
    private var lastRetryableFailureRecord: HistoryRecord?
    private var lastDialogResultText: String?
    private var isPersonaPickerPresented = false
    private var personaPickerItems: [PersonaPickerEntry] = []
    private var personaPickerSelectedIndex = 0
    private var personaPickerMode: PersonaPickerMode = .switchDefault

    private struct PersonaPickerEntry {
        let id: UUID?
        let title: String
        let subtitle: String
    }

    private struct PersonaSelectionContext {
        let snapshot: TextSelectionSnapshot
        let selectedText: String
    }

    private enum PersonaPickerMode {
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
        overlayController: OverlayController,
        askAnswerWindowController: AskAnswerWindowController,
        soundEffectPlayer: SoundEffectPlayer
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
        self.overlayController = overlayController
        self.askAnswerWindowController = askAnswerWindowController
        self.soundEffectPlayer = soundEffectPlayer
        self.overlayController.setRecordingActionHandlers(
            onCancel: { [weak self] in
                guard let self else { return }
                if self.isRecording {
                    self.cancelRecording()
                } else {
                    self.cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.userCancelled"))
                }
            },
            onConfirm: { [weak self] in self?.confirmLockedRecording() }
        )
        self.overlayController.setResultDialogHandler(
            onCopy: { [weak self] in self?.copyLastResultFromDialog() }
        )
        self.overlayController.setFailureRetryHandler(
            onRetry: { [weak self] in
                guard let self, let record = self.lastRetryableFailureRecord else { return }
                self.retry(record: record)
            }
        )
        self.overlayController.setPersonaPickerHandlers(
            onMoveUp: { [weak self] in self?.movePersonaSelection(delta: -1) },
            onMoveDown: { [weak self] in self?.movePersonaSelection(delta: 1) },
            onSelect: { [weak self] index in self?.selectPersonaSelection(at: index) },
            onConfirm: { [weak self] in self?.confirmPersonaSelection() },
            onCancel: { [weak self] in self?.dismissPersonaPicker() }
        )
    }

    private func presentAskAnswer(question: String, selectedText: String?, answerMarkdown: String) {
        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Sending content to window
            Question: \(question)
            Selected Text: \(selectedText ?? "<empty>")
            Answer Markdown: \(answerMarkdown)
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
    }

    func stop() {
        hotkeyService.stop()
        dismissPersonaPicker()
        askAnswerWindowController.dismiss()
        cancelRecording()
        cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.stopping"))
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil
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
            await self.reprocess(record: record, sessionID: sessionID)
            self.cancelProcessingTimeout()
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

    private func startProcessingTimeout(sessionID: UUID) {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.processingTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            NSLog("[Workflow] Processing timeout after 120 seconds")
            self?.handleProcessingTimeout(sessionID: sessionID)
        }
    }

    private func cancelProcessingTimeout() {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
    }

    private func handleProcessingTimeout(sessionID: UUID) {
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

    private func handleActivationTap() {
        handlePressBegan(intent: .dictation, startLocked: true)
    }

    private func handlePressBegan(intent: RecordingIntent, startLocked: Bool) {
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

    private func handlePersonaPickerRequested() {
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
            dismissPersonaPicker(closeOverlay: false)
            return
        }

        Task { [weak self] in
            guard let self else { return }

            let selectionSnapshot: TextSelectionSnapshot
            if self.settingsStore.personaHotkeyAppliesToSelection {
                selectionSnapshot = await self.textInjector.getSelectionSnapshot()
            } else {
                selectionSnapshot = TextSelectionSnapshot()
            }

            let selectedText = editingSelectedText(from: selectionSnapshot)
            let mode: PersonaPickerMode
            let items: [PersonaPickerEntry]

            if let selectedText, !selectedText.isEmpty, self.settingsStore.personaHotkeyAppliesToSelection {
                mode = .applySelection(PersonaSelectionContext(snapshot: selectionSnapshot, selectedText: selectedText))
                items = self.personaPickerEntries(includeNoneOption: false)
            } else {
                mode = .switchDefault
                items = self.personaPickerEntries(includeNoneOption: true)
            }

            guard !items.isEmpty else { return }

            let activeID = self.settingsStore.personaRewriteEnabled ? UUID(uuidString: self.settingsStore.activePersonaID) : nil
            let selectedIndex = items.firstIndex(where: { $0.id == activeID }) ?? 0

            await MainActor.run {
                guard !self.isRecording, self.processingTask == nil else { return }
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
                    instructions: self.personaPickerInstructions(for: mode)
                )
            }
        }
    }

    private func beginRecording(intent: RecordingIntent, startLocked: Bool) async {
        isRecording = true
        recordingMode = startLocked ? .locked : .holdToTalk
        recordingIntent = intent
        lastRetryableFailureRecord = nil
        NSLog("[Workflow] Recording started")
        await MainActor.run {
            self.soundEffectPlayer.play(.start)
        }

        Task { @MainActor in
            appState.setStatus(.recording)
            if intent == .askSelection {
                overlayController.showLockedRecording(hintText: L("overlay.ask.guidance"))
            } else {
                overlayController.show()
            }
        }

        selectionTask = Task { [weak self] in
            guard let self else { return TextSelectionSnapshot() }
            return await self.textInjector.getSelectionSnapshot()
        }

        do {
            try audioRecorder.start(
                levelHandler: { [weak self] level in
                    self?.overlayController.updateLevel(level)
                },
                audioBufferHandler: { _ in }
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
                applyStatus: .skipped
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

    private func handlePressEnded() {
        // Prevent double-end or end without start
        guard isRecording else {
            NSLog("[Workflow] Not recording, ignoring release")
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

    private func handleAskPressEnded() {
        guard isRecording, recordingIntent == .askSelection else { return }
        // Ask recordings are toggle-based; release should not end the recording.
    }

    private func confirmLockedRecording() {
        guard isRecording, recordingMode == .locked else { return }
        finishRecordingFromCurrentMode()
    }

    private func finishRecordingFromCurrentMode() {
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
            await self.finishRecordingAndProcess(recordingStoppedAt: recordingStoppedAt)
        }
    }

    private struct RewriteGenerationResult {
        let text: String
        let completedAt: Date
    }

    private struct AskSelectionDecisionResult {
        let decision: AskSelectionDecision
        let completedAt: Date
    }

    private func generateRewrite(
        request: LLMRewriteRequest,
        sessionID: UUID,
        showsStreamingPreview: Bool = true
    ) async throws -> RewriteGenerationResult {
        try await RequestRetry.perform(
            operationName: "LLM rewrite stream",
            onRetry: { [weak self] _, _, _ in
                guard let self else { return }
                guard showsStreamingPreview else { return }
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.overlayController.updateStreamingText("")
                    }
                }
            }
        ) { [self] in
            var buffer = ""
            var lastChunkAt = Date()

            let stream = self.llmService.streamRewrite(request: request)
            for try await chunk in stream {
                try self.ensureProcessingIsActive(sessionID)
                buffer += chunk
                let now = Date()
                if now.timeIntervalSince(lastChunkAt) > 0.15 {
                    lastChunkAt = now
                    let snapshot = buffer
                    if showsStreamingPreview {
                        await MainActor.run {
                            if self.processingSessionID == sessionID {
                                self.overlayController.updateStreamingText(snapshot)
                            }
                        }
                    }
                }
            }

            return RewriteGenerationResult(
                text: buffer.trimmingCharacters(in: .whitespacesAndNewlines),
                completedAt: Date()
            )
        }
    }

    private func decideAskSelection(
        selectedText: String,
        spokenInstruction: String,
        personaPrompt: String?,
        sessionID: UUID
    ) async throws -> AskSelectionDecisionResult {
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            personaPrompt: personaPrompt
        )
        let decision = try await RequestRetry.perform(operationName: "Ask selection decision") { [self] in
            try await self.llmAgentService.runTool(
                request: LLMAgentRequest(
                    systemPrompt: prompts.system,
                    userPrompt: prompts.user,
                    tools: [AskSelectionDecision.tool],
                    forcedToolName: AskSelectionDecision.tool.name
                ),
                decoding: AskSelectionDecision.self
            )
        }

        try ensureProcessingIsActive(sessionID)

        guard decision.isValid else {
            throw NSError(
                domain: "WorkflowController",
                code: 3001,
                userInfo: [NSLocalizedDescriptionKey: "Ask selection decision returned invalid tool arguments."]
            )
        }

        switch decision.action {
        case .answer:
            guard !decision.trimmedResponse.isEmpty else {
                throw NSError(
                    domain: "WorkflowController",
                    code: 3002,
                    userInfo: [NSLocalizedDescriptionKey: "Ask selection answer was empty."]
                )
            }
        case .edit:
            break
        }

        return AskSelectionDecisionResult(decision: decision, completedAt: Date())
    }

    private func answerAskAnything(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        sessionID: UUID
    ) async throws -> RewriteGenerationResult {
        let prompts = PromptCatalog.askAnythingPrompts(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            personaPrompt: personaPrompt
        )

        let response = try await RequestRetry.perform(operationName: "Ask anything answer") { [self] in
            try await self.llmService.complete(
                systemPrompt: prompts.system,
                userPrompt: prompts.user
            )
        }

        try ensureProcessingIsActive(sessionID)

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "WorkflowController",
                code: 3003,
                userInfo: [NSLocalizedDescriptionKey: "Ask anything answer was empty."]
            )
        }

        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Raw LLM answer
            Selected Text: \(selectedText ?? "<empty>")
            Spoken Instruction: \(spokenInstruction)
            Answer Markdown: \(trimmed)
            """
        )

        return RewriteGenerationResult(text: trimmed, completedAt: Date())
    }

    private func requiresRewrite(selectedText: String?, personaPrompt: String?) -> Bool {
        if let selectedText, !selectedText.isEmpty {
            return true
        }

        if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return false
    }

    private func applyText(_ text: String, replace: Bool, fallbackTitle: String = L("workflow.result.copyTitle")) -> ApplyOutcome {
        do {
            if replace {
                dismissOverlayForExternalReplacement()
                try textInjector.replaceSelection(text: text)
            } else {
                try textInjector.insert(text: text)
            }
            scheduleAutomaticVocabularyObservation(for: text)
            return .inserted
        } catch {
            Task { @MainActor in
                self.lastDialogResultText = text
                self.overlayController.showResultDialog(title: fallbackTitle, message: text)
            }
            return .presentedInDialog
        }
    }

    private func applyTranscribedText(
        _ text: String,
        selectionSnapshot: TextSelectionSnapshot
    ) -> ApplyOutcome {
        applyText(text, replace: shouldReplaceActiveSelection(for: selectionSnapshot))
    }

    private func finishRecordingAndProcess(recordingStoppedAt: Date) async {
        do {
            let audioFile = try audioRecorder.stop()
            let audioFileReadyAt = Date()
            let recordingIntent = self.recordingIntent
            self.recordingIntent = .dictation
            let selectionSnapshot = await selectionTask?.value ?? TextSelectionSnapshot()
            selectionTask = nil

            if audioFile.duration < Self.minimumRecordingDuration {
                try? FileManager.default.removeItem(at: audioFile.fileURL)
                await sttRouter.cancelPreparedRecording()
                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.showNotice(message: L("workflow.recording.tooShort"))
                }
                return
            }

            await MainActor.run {
                self.soundEffectPlayer.play(.done)
            }
            let selectedText = recordingIntent == .askSelection
                ? editingSelectedText(from: selectionSnapshot)
                : nil
            let askContextText = recordingIntent == .askSelection
                ? selectionSnapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            currentSelectedText = selectedText
            let personaPrompt = recordingIntent == .askSelection
                ? nil
                : settingsStore.activePersona?.prompt

            NetworkDebugLogger.logMessage(selectionSnapshotLog(selectionSnapshot))
            let shouldShowResultDialog = shouldPresentResultDialog(for: selectionSnapshot)

            if !shouldShowResultDialog {
                await MainActor.run {
                    self.appState.setStatus(.processing)
                    self.overlayController.showProcessing()
                }
            }

            let record = HistoryRecord(
                date: Date(),
                mode: inferredMode(
                    selectedText: selectedText,
                    personaPrompt: personaPrompt,
                    recordingIntent: recordingIntent
                ),
                audioFilePath: audioFile.fileURL.path,
                transcriptText: nil,
                personaPrompt: personaPrompt,
                selectionOriginalText: recordingIntent == .askSelection ? selectedText : nil,
                recordingDurationSeconds: audioFile.duration,
                pipelineTiming: HistoryPipelineTiming(
                    recordingStoppedAt: recordingStoppedAt,
                    audioFileReadyAt: audioFileReadyAt
                ),
                recordingStatus: .succeeded,
                transcriptionStatus: .running,
                processingStatus: .pending,
                applyStatus: .pending
            )
            saveHistoryRecord(record)
            logPipelineEvent("audio-file-ready", for: record)
            activeProcessingRecordID = record.id
            let sessionID = beginProcessingSession()

            startProcessingTimeout(sessionID: sessionID)
            processingTask = Task { [weak self] in
                guard let self else { return }
                await self.process(
                    audioFile: audioFile,
                    record: record,
                    selectionSnapshot: selectionSnapshot,
                    selectedText: selectedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    recordingIntent: recordingIntent,
                    sessionID: sessionID
                )
                self.cancelProcessingTimeout()
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.processingTask = nil
                        self.activeProcessingRecordID = nil
                    }
                }
            }
        } catch {
            let msg = "Processing failed: \(error.localizedDescription)"
            ErrorLogStore.shared.log(msg)

            var record = HistoryRecord(
                date: Date(),
                recordingStatus: .failed,
                transcriptionStatus: .skipped,
                processingStatus: .skipped,
                applyStatus: .skipped
            )
            record.errorMessage = msg
            saveHistoryRecord(record)

            await MainActor.run {
                self.soundEffectPlayer.play(.error)
                self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
                self.overlayController.showFailure(message: msg)
                self.overlayController.dismiss(after: 3.0)
            }
        }
    }

    private func reprocess(record: HistoryRecord, sessionID: UUID) async {
        guard let audioFilePath = record.audioFilePath, !audioFilePath.isEmpty else {
            await failRetry(record: record, message: L("workflow.retry.audioMissing"))
            return
        }

        let audioURL = URL(fileURLWithPath: audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            await failRetry(record: record, message: L("workflow.retry.audioGone"))
            return
        }

        var mutableRecord = record
        mutableRecord.errorMessage = nil
        mutableRecord.applyMessage = nil
        mutableRecord.transcriptText = nil
        mutableRecord.personaResultText = nil
        mutableRecord.selectionEditedText = nil
        mutableRecord.recordingStatus = .succeeded
        mutableRecord.transcriptionStatus = .running
        mutableRecord.processingStatus = .pending
        mutableRecord.applyStatus = .pending
        mutableRecord.pipelineTiming = HistoryPipelineTiming(
            recordingStoppedAt: Date(),
            audioFileReadyAt: Date()
        )
        saveHistoryRecord(mutableRecord)
        logPipelineEvent("retry-restarted", for: mutableRecord)
        activeProcessingRecordID = mutableRecord.id
        await MainActor.run {
            self.lastRetryableFailureRecord = nil
        }

        let audioFile = AudioFile(fileURL: audioURL, duration: 0)
        let selectedText = mutableRecord.selectionOriginalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaPrompt = mutableRecord.mode == .editSelection || mutableRecord.mode == .askAnswer
            ? nil
            : personaPrompt(for: mutableRecord)
        await process(
            audioFile: audioFile,
            record: mutableRecord,
            selectionSnapshot: TextSelectionSnapshot(
                processID: nil,
                processName: nil,
                selectedRange: nil,
                selectedText: selectedText,
                source: "history-retry",
                isEditable: false
            ),
            selectedText: selectedText,
            askContextText: selectedText,
            personaPrompt: personaPrompt,
            recordingIntent: mutableRecord.mode == .editSelection || mutableRecord.mode == .askAnswer ? .askSelection : .dictation,
            sessionID: sessionID,
            forceResultDialogOnSuccess: true
        )
    }

    private func process(
        audioFile: AudioFile,
        record: HistoryRecord,
        selectionSnapshot: TextSelectionSnapshot,
        selectedText: String?,
        askContextText: String?,
        personaPrompt: String?,
        recordingIntent: RecordingIntent,
        sessionID: UUID,
        forceResultDialogOnSuccess: Bool = false
    ) async {
        var record = record
        do {
            try ensureProcessingIsActive(sessionID)
            var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()

            let isAskSelectionFlow = recordingIntent == .askSelection
                && !(askContextText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            // When using multimodal and there is no selected text to edit, the transcriber applies
            // persona internally in one shot — no separate LLM rewrite is needed afterwards.
            let multimodalHandlesPersona = settingsStore.sttProvider.handlesPersonaInternally
                && (selectedText == nil || selectedText!.isEmpty)

            // Only keep the overlay in "processing" capsule (hiding streaming text) if an LLM
            // rewrite will follow. For multimodal+persona this is not the case, so let streaming
            // through so the user sees text appearing immediately.
            let shouldKeepProcessingCapsule = requiresRewrite(selectedText: selectedText, personaPrompt: personaPrompt)
                && !multimodalHandlesPersona

            pipelineTiming.transcriptionStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            saveHistoryRecord(record)
            logPipelineEvent("transcription-started", for: record)

            let transcribedText = try await sttRouter.transcribeStream(audioFile: audioFile) { [weak self] snapshot in
                guard let self, !snapshot.text.isEmpty else { return }
                guard !shouldKeepProcessingCapsule else { return }
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.overlayController.updateStreamingText(snapshot.text)
                    }
                }
            }
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.transcriptionCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.transcriptText = transcribedText
            record.transcriptionStatus = .succeeded
            saveHistoryRecord(record)
            logPipelineEvent("transcription-completed", for: record)

            let normalizedTranscript = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedTranscript.isEmpty {
                record.processingStatus = .skipped
                record.applyStatus = .skipped
                record.applyMessage = L("workflow.transcription.emptySkipped")
                saveHistoryRecord(record)

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.appState.setStatus(.idle)
                        self.overlayController.showNotice(message: L("workflow.transcription.noSpeech"))
                    }
                }
                return
            }

            if isAskSelectionFlow, let askContextText, !askContextText.isEmpty {
                record.processingStatus = .running
                saveHistoryRecord(record)

                pipelineTiming.llmProcessingStartedAt = Date()
                record.pipelineTiming = pipelineTiming
                saveHistoryRecord(record)
                logPipelineEvent("llm-processing-started", for: record)

                let askDecisionResult = try await decideAskSelection(
                    selectedText: askContextText,
                    spokenInstruction: transcribedText,
                    personaPrompt: personaPrompt,
                    sessionID: sessionID
                )

                switch askDecisionResult.decision.action {
                case .answer:
                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.llmProcessingCompletedAt = askDecisionResult.completedAt
                    record.pipelineTiming = pipelineTiming
                    logPipelineEvent("llm-processing-completed", for: record)
                    record.mode = .askAnswer
                    record.personaResultText = askDecisionResult.decision.trimmedResponse
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.applyStartedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    await MainActor.run {
                        self.presentAskAnswer(
                            question: transcribedText,
                            selectedText: askContextText,
                            answerMarkdown: askDecisionResult.decision.trimmedResponse
                        )
                    }
                    pipelineTiming.applyCompletedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    record.applyStatus = .succeeded
                    record.applyMessage = L("workflow.ask.answerPresented")
                case .edit:
                    record.mode = .editSelection
                    record.applyStatus = .pending
                    saveHistoryRecord(record)

                    let shouldShowResultDialog = shouldPresentResultDialog(for: selectionSnapshot)
                    let rewriteResult = try await generateRewrite(
                        request: LLMRewriteRequest(
                            mode: .editSelection,
                            sourceText: askContextText,
                            spokenInstruction: transcribedText,
                            personaPrompt: personaPrompt
                        ),
                        sessionID: sessionID,
                        showsStreamingPreview: !shouldShowResultDialog
                    )

                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.llmProcessingCompletedAt = rewriteResult.completedAt
                    record.pipelineTiming = pipelineTiming
                    logPipelineEvent("llm-processing-completed", for: record)
                    record.selectionEditedText = rewriteResult.text
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.applyStartedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    let outcome: ApplyOutcome
                    NetworkDebugLogger.logMessage(
                        "[Apply Decision] mode=editSelection hasSelection=\(selectionSnapshot.hasSelection) " +
                        "isEditable=\(selectionSnapshot.isEditable) hasRange=\(selectionSnapshot.selectedRange != nil) " +
                        "showResultDialog=\(shouldShowResultDialog)"
                    )
                    if shouldShowResultDialog {
                        await MainActor.run {
                            self.lastDialogResultText = rewriteResult.text
                            self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: rewriteResult.text)
                        }
                        outcome = .presentedInDialog
                    } else {
                        outcome = applyText(rewriteResult.text, replace: true, fallbackTitle: L("workflow.result.copyTitle"))
                    }
                    pipelineTiming.applyCompletedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                }
            } else if recordingIntent == .askSelection {
                record.processingStatus = .running
                saveHistoryRecord(record)

                pipelineTiming.llmProcessingStartedAt = Date()
                record.pipelineTiming = pipelineTiming
                saveHistoryRecord(record)
                logPipelineEvent("llm-processing-started", for: record)

                let answerResult = try await answerAskAnything(
                    selectedText: askContextText,
                    spokenInstruction: transcribedText,
                    personaPrompt: personaPrompt,
                    sessionID: sessionID
                )

                try ensureProcessingIsActive(sessionID)
                pipelineTiming.llmProcessingCompletedAt = answerResult.completedAt
                record.pipelineTiming = pipelineTiming
                logPipelineEvent("llm-processing-completed", for: record)
                record.mode = .askAnswer
                record.personaResultText = answerResult.text
                record.processingStatus = .succeeded
                record.applyStatus = .running
                saveHistoryRecord(record)

                try ensureProcessingIsActive(sessionID)
                pipelineTiming.applyStartedAt = Date()
                record.pipelineTiming = pipelineTiming
                await MainActor.run {
                    self.presentAskAnswer(
                        question: transcribedText,
                        selectedText: askContextText,
                        answerMarkdown: answerResult.text
                    )
                }
                pipelineTiming.applyCompletedAt = Date()
                record.pipelineTiming = pipelineTiming
                record.applyStatus = .succeeded
                record.applyMessage = L("workflow.ask.answerPresented")
            } else if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.mode = .personaRewrite

                if multimodalHandlesPersona {
                    // Persona was already applied by the multimodal transcriber — use result directly.
                    record.personaResultText = transcribedText
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.applyStartedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    let outcome = applyTranscribedText(transcribedText, selectionSnapshot: selectionSnapshot)
                    pipelineTiming.applyCompletedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                } else {
                    record.processingStatus = .running
                    saveHistoryRecord(record)

                    pipelineTiming.llmProcessingStartedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    saveHistoryRecord(record)
                    logPipelineEvent("llm-processing-started", for: record)

                    let rewriteOutput: String
                    do {
                        let rewriteResult = try await generateRewrite(
                            request: LLMRewriteRequest(
                                mode: .rewriteTranscript,
                                sourceText: transcribedText,
                                spokenInstruction: nil,
                                personaPrompt: personaPrompt
                            ),
                            sessionID: sessionID
                        )

                        try ensureProcessingIsActive(sessionID)
                        pipelineTiming.llmProcessingCompletedAt = rewriteResult.completedAt
                        rewriteOutput = rewriteResult.text
                        record.personaResultText = rewriteResult.text
                        logPipelineEvent("llm-processing-completed", for: record)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        NetworkDebugLogger.logError(
                            context: "Persona rewrite failed, using transcript as fallback",
                            error: error
                        )
                        ErrorLogStore.shared.log(
                            "Persona rewrite failed, using transcript as fallback: \(error.localizedDescription)"
                        )
                        pipelineTiming.llmProcessingCompletedAt = Date()
                        rewriteOutput = transcribedText
                        record.personaResultText = transcribedText
                    }

                    record.pipelineTiming = pipelineTiming
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    pipelineTiming.applyStartedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    let outcome = applyTranscribedText(rewriteOutput, selectionSnapshot: selectionSnapshot)
                    pipelineTiming.applyCompletedAt = Date()
                    record.pipelineTiming = pipelineTiming
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                }
            } else {
                record.mode = .dictation
                record.processingStatus = .skipped
                record.applyStatus = .running
                saveHistoryRecord(record)

                try ensureProcessingIsActive(sessionID)
                pipelineTiming.applyStartedAt = Date()
                record.pipelineTiming = pipelineTiming
                let outcome = applyTranscribedText(transcribedText, selectionSnapshot: selectionSnapshot)
                pipelineTiming.applyCompletedAt = Date()
                record.pipelineTiming = pipelineTiming
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
            }

            try ensureProcessingIsActive(sessionID)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-completed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            enforceHistoryRetentionPolicy()
            let retryResultText = forceResultDialogOnSuccess ? record.finalText : nil
            let finalMode = record.mode
            let finalTranscriptText = record.transcriptText
            let finalSelectionOriginalText = record.selectionOriginalText

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.lastRetryableFailureRecord = nil
                    self.appState.setStatus(.idle)
                    if let finalText = retryResultText, !finalText.isEmpty {
                        if finalMode == .askAnswer {
                            self.presentAskAnswer(
                                question: finalTranscriptText ?? "",
                                selectedText: finalSelectionOriginalText,
                                answerMarkdown: finalText
                            )
                        } else {
                            self.lastDialogResultText = finalText
                            self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: finalText)
                        }
                    } else {
                        self.overlayController.dismissSoon()
                    }
                }
            }
        } catch is CancellationError {
            markCancelled(&record)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-cancelled", for: record)
            enforceHistoryRetentionPolicy()
        } catch {
            let msg = "Processing failed: \(error.localizedDescription)"
            ErrorLogStore.shared.log(msg)
            markFailure(&record, message: msg)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-failed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            enforceHistoryRetentionPolicy()
            let retryableFailureRecord = record.audioFilePath == nil ? nil : record

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.lastRetryableFailureRecord = retryableFailureRecord
                    self.soundEffectPlayer.play(.error)
                    self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
                    if retryableFailureRecord == nil {
                        self.overlayController.showFailure(message: msg)
                        self.overlayController.dismiss(after: 3.0)
                    } else {
                        self.overlayController.showRetryableFailure(message: msg)
                    }
                }
            }
        }
    }

    private func failRetry(record: HistoryRecord, message: String) async {
        ErrorLogStore.shared.log(message)
        var mutableRecord = record
        mutableRecord.errorMessage = message
        if mutableRecord.audioFilePath == nil {
            mutableRecord.recordingStatus = .failed
        } else if mutableRecord.transcriptText == nil {
            mutableRecord.transcriptionStatus = .failed
        } else {
            mutableRecord.processingStatus = .failed
        }
        saveHistoryRecord(mutableRecord)

        await MainActor.run {
            self.lastRetryableFailureRecord = nil
            self.soundEffectPlayer.play(.error)
            self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
            self.overlayController.showFailure(message: message)
            self.overlayController.dismiss(after: 3.0)
        }
    }

    private func markFailure(_ record: inout HistoryRecord, message: String) {
        record.errorMessage = message
        if record.transcriptionStatus == .running {
            record.transcriptionStatus = .failed
            record.processingStatus = .skipped
            record.applyStatus = .skipped
            return
        }

        if record.processingStatus == .running {
            record.processingStatus = .failed
            record.applyStatus = .skipped
            return
        }

        if record.applyStatus == .running {
            record.applyStatus = .failed
            return
        }

        record.processingStatus = .failed
    }

    private func markCancelled(_ record: inout HistoryRecord) {
        record.errorMessage = L("workflow.cancel.newRecording")
        if record.transcriptionStatus == .running {
            record.transcriptionStatus = .failed
            record.processingStatus = .skipped
            record.applyStatus = .skipped
            return
        }

        if record.processingStatus == .running {
            record.processingStatus = .failed
            record.applyStatus = .skipped
            return
        }

        if record.applyStatus == .running {
            record.applyStatus = .failed
        }
    }

    private func beginProcessingSession() -> UUID {
        let sessionID = UUID()
        processingSessionID = sessionID
        return sessionID
    }

    private func ensureProcessingIsActive(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard processingSessionID == sessionID else {
            throw CancellationError()
        }
    }

    private func cancelCurrentProcessing(resetUI: Bool, reason: String) {
        processingSessionID = UUID()
        processingTask?.cancel()
        processingTask = nil
        cancelProcessingTimeout()
        lastRetryableFailureRecord = nil

        if let activeProcessingRecordID,
           var record = historyStore.record(id: activeProcessingRecordID) {
            record.errorMessage = reason
            if record.transcriptionStatus == .running {
                record.transcriptionStatus = .failed
                record.processingStatus = .skipped
                record.applyStatus = .skipped
            } else if record.processingStatus == .running {
                record.processingStatus = .failed
                record.applyStatus = .skipped
            } else if record.applyStatus == .running {
                record.applyStatus = .failed
            }
            saveHistoryRecord(record)
        }
        activeProcessingRecordID = nil

        guard resetUI else { return }
        Task { @MainActor in
            self.appState.setStatus(.idle)
            self.overlayController.dismiss(after: 0.1)
        }
    }

    private func inferredMode(
        selectedText: String?,
        personaPrompt: String?,
        recordingIntent: RecordingIntent
    ) -> HistoryRecord.Mode {
        if recordingIntent == .askSelection {
            return .askAnswer
        }

        if let selectedText, !selectedText.isEmpty {
            return .editSelection
        }

        if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .personaRewrite
        }

        return .dictation
    }

    private func personaPrompt(for record: HistoryRecord) -> String? {
        switch record.mode {
        case .dictation, .editSelection, .personaRewrite, .askAnswer:
            return record.personaPrompt ?? settingsStore.activePersona?.prompt
        }
    }

    private func selectionSnapshotLog(_ snapshot: TextSelectionSnapshot) -> String {
        let processDescription: String
        if let name = snapshot.processName, let pid = snapshot.processID {
            processDescription = "\(name) (pid: \(pid))"
        } else if let name = snapshot.processName {
            processDescription = name
        } else if let pid = snapshot.processID {
            processDescription = "pid: \(pid)"
        } else {
            processDescription = "<unknown>"
        }

        let rangeDescription: String
        if let range = snapshot.selectedRange {
            rangeDescription = "{location: \(range.location), length: \(range.length)}"
        } else {
            rangeDescription = "<none>"
        }

        let contentDescription: String
        if let text = snapshot.selectedText, !text.isEmpty {
            contentDescription = text
        } else {
            contentDescription = "<none>"
        }

        return """
        [Selection Context]
        Process: \(processDescription)
        Source: \(snapshot.source)
        Editable target: \(snapshot.isEditable)
        Focus matched: \(snapshot.isFocusedTarget)
        Role: \(snapshot.role ?? "<unknown>")
        Window: \(snapshot.windowTitle ?? "<unknown>")
        Has selection: \(snapshot.hasSelection)
        Selected range: \(rangeDescription)
        Selected text: \(contentDescription)
        """
    }

    private func shouldPresentResultDialog(for snapshot: TextSelectionSnapshot) -> Bool {
        hasAskSelectionContext(snapshot) && !canReplaceActiveSelection(for: snapshot)
    }

    private func editingSelectedText(from snapshot: TextSelectionSnapshot) -> String? {
        guard canReplaceActiveSelection(for: snapshot) else { return nil }
        return snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        canReplaceActiveSelection(for: snapshot)
    }

    private func hasAskSelectionContext(_ snapshot: TextSelectionSnapshot) -> Bool {
        guard snapshot.isFocusedTarget else { return false }
        return snapshot.hasSelection
    }

    private func canReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        guard hasAskSelectionContext(snapshot) else { return false }
        return snapshot.isEditable
    }

    private func dismissOverlayForExternalReplacement() {
        overlayController.dismissImmediately()
        usleep(Self.selectionRestoreDelayMicroseconds)
    }

    private func personaPickerTitle(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            return L("overlay.personaPicker.switchTitle")
        case .applySelection:
            return L("overlay.personaPicker.applyTitle")
        }
    }

    private func personaPickerInstructions(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            return L("overlay.personaPicker.switchInstructions")
        case .applySelection:
            return L("overlay.personaPicker.applyInstructions")
        }
    }

    private func copyLastResultFromDialog() {
        guard let lastDialogResultText, !lastDialogResultText.isEmpty else { return }
        clipboard.write(text: lastDialogResultText)
        overlayController.showNotice(message: L("workflow.result.copied"))
    }

    private func scheduleAutomaticVocabularyObservation(for insertedText: String) {
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil

        guard settingsStore.automaticVocabularyCollectionEnabled else {
            logAutomaticVocabulary("skip scheduling: feature disabled")
            return
        }

        let normalizedInsertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInsertedText.isEmpty else {
            logAutomaticVocabulary("skip scheduling: inserted text empty after normalization")
            return
        }

        logAutomaticVocabulary(
            "session scheduled | insertedText=\(automaticVocabularyPreview(normalizedInsertedText)) " +
            "| observationWindow=\(Int(Self.automaticVocabularyObservationWindow))s " +
            "| settleDelay=\(Self.automaticVocabularySettleDelay)s " +
            "| maxAnalyses=\(Self.automaticVocabularyMaxAnalysesPerSession)"
        )

        automaticVocabularyObservationTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: Self.automaticVocabularyStartupDelay)
            } catch {
                self.logAutomaticVocabulary("session cancelled before startup delay finished")
                return
            }

            guard !Task.isCancelled else { return }
            let baselineSnapshot = await self.readAutomaticVocabularyBaselineWithRetry()
            guard let baselineText = baselineSnapshot.text else {
                self.logAutomaticVocabulary(
                    "session aborted: failed to read baseline input text | " +
                    self.describeCurrentInputTextSnapshot(baselineSnapshot)
                )
                return
            }

            var observationState = AutomaticVocabularyMonitor.makeObservationState(
                baselineText: baselineText,
                startedAt: Date()
            )
            self.logAutomaticVocabulary(
                "session started | baselineText=\(self.automaticVocabularyPreview(baselineText))"
            )
            let deadline = Date().addingTimeInterval(Self.automaticVocabularyObservationWindow)

            while Date() < deadline {
                do {
                    try await Task.sleep(for: Self.automaticVocabularyPollInterval)
                } catch {
                    self.logAutomaticVocabulary("session cancelled during polling")
                    return
                }

                guard !Task.isCancelled else { return }
                let currentSnapshot = await self.textInjector.currentInputTextSnapshot()
                guard let currentText = currentSnapshot.text else {
                    self.logAutomaticVocabulary(
                        "poll skipped: failed to read current input text | " +
                        self.describeCurrentInputTextSnapshot(currentSnapshot)
                    )
                    continue
                }
                let now = Date()
                let didChange = AutomaticVocabularyMonitor.observe(
                    text: currentText,
                    at: now,
                    state: &observationState
                )
                if didChange {
                    self.logAutomaticVocabulary(
                        "change observed | analysisCount=\(observationState.analysisCount) " +
                        "| latestText=\(self.automaticVocabularyPreview(currentText))"
                    )
                }

                guard let pendingAnalysis = AutomaticVocabularyMonitor.pendingAnalysis(
                    state: observationState,
                    now: now,
                    settleDelay: Self.automaticVocabularySettleDelay,
                    maxAnalyses: Self.automaticVocabularyMaxAnalysesPerSession
                ) else {
                    continue
                }

                AutomaticVocabularyMonitor.markAnalysisCompleted(
                    for: pendingAnalysis.updatedText,
                    state: &observationState
                )
                self.logAutomaticVocabulary(
                    "stable change ready for analysis | analysisRound=\(observationState.analysisCount) " +
                    "| previous=\(self.automaticVocabularyPreview(pendingAnalysis.previousStableText)) " +
                    "| updated=\(self.automaticVocabularyPreview(pendingAnalysis.updatedText))"
                )

                guard let change = AutomaticVocabularyMonitor.detectChange(
                    from: pendingAnalysis.previousStableText,
                    to: pendingAnalysis.updatedText
                ) else {
                    self.logAutomaticVocabulary("analysis skipped: no candidate terms found after diff")
                    continue
                }
                let candidateSummary = change.candidateTerms.joined(separator: ", ")
                self.logAutomaticVocabulary(
                    "diff detected | oldFragment=\(self.automaticVocabularyPreview(change.oldFragment)) " +
                    "| newFragment=\(self.automaticVocabularyPreview(change.newFragment)) " +
                    "| candidates=\(candidateSummary)"
                )

                do {
                    let acceptedTerms = try await self.evaluateAutomaticVocabularyCandidates(
                        transcript: normalizedInsertedText,
                        change: change
                    )
                    let approvedSummary = acceptedTerms.joined(separator: ", ")
                    self.logAutomaticVocabulary("llm decision received | approvedTerms=\(approvedSummary)")
                    let addedTerms = self.addAutomaticVocabularyTerms(acceptedTerms)
                    guard !addedTerms.isEmpty else {
                        self.logAutomaticVocabulary("analysis completed: no new terms added")
                        continue
                    }

                    let addedSummary = addedTerms.joined(separator: ", ")
                    self.logAutomaticVocabulary("terms added | addedTerms=\(addedSummary)")

                    await MainActor.run {
                        self.overlayController.showNotice(message: self.automaticVocabularyNotice(for: addedTerms))
                    }
                } catch {
                    self.logAutomaticVocabulary("analysis failed: \(error.localizedDescription)")
                    ErrorLogStore.shared.log("Automatic vocabulary evaluation failed: \(error.localizedDescription)")
                }
            }

            self.logAutomaticVocabulary(
                "session completed | totalAnalyses=\(observationState.analysisCount)"
            )
        }
    }

    private func evaluateAutomaticVocabularyCandidates(
        transcript: String,
        change: AutomaticVocabularyChange
    ) async throws -> [String] {
        let prompts = PromptCatalog.automaticVocabularyDecisionPrompts(
            transcript: transcript,
            oldFragment: change.oldFragment,
            newFragment: change.newFragment,
            candidateTerms: change.candidateTerms,
            existingTerms: VocabularyStore.activeTerms()
        )
        let response = try await llmService.completeJSON(
            systemPrompt: prompts.system,
            userPrompt: prompts.user,
            schema: AutomaticVocabularyMonitor.decisionSchema
        )
        self.logAutomaticVocabulary("llm raw response | response=\(self.automaticVocabularyPreview(response))")
        return AutomaticVocabularyMonitor.parseAcceptedTerms(from: response)
    }

    private func addAutomaticVocabularyTerms(_ terms: [String]) -> [String] {
        let existingTerms = Set(VocabularyStore.activeTerms().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var knownTerms = existingTerms
        var addedTerms: [String] = []

        for rawTerm in terms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = term.lowercased()
            guard !term.isEmpty, !knownTerms.contains(normalized) else { continue }
            _ = VocabularyStore.add(term: term, source: .automatic)
            knownTerms.insert(normalized)
            addedTerms.append(term)
        }

        return addedTerms
    }

    private func automaticVocabularyNotice(for terms: [String]) -> String {
        if terms.count == 1, let term = terms.first {
            return L("workflow.vocabulary.autoAdded.single", term)
        }

        return L("workflow.vocabulary.autoAdded.multiple", terms.count)
    }

    private func readAutomaticVocabularyBaselineWithRetry() async -> CurrentInputTextSnapshot {
        var latestSnapshot = await textInjector.currentInputTextSnapshot()
        guard latestSnapshot.text == nil else { return latestSnapshot }

        for attempt in 1...Self.automaticVocabularyBaselineRetryCount {
            logAutomaticVocabulary(
                "baseline read retry \(attempt)/\(Self.automaticVocabularyBaselineRetryCount) | " +
                describeCurrentInputTextSnapshot(latestSnapshot)
            )

            do {
                try await Task.sleep(for: Self.automaticVocabularyBaselineRetryDelay)
            } catch {
                return latestSnapshot
            }

            latestSnapshot = await textInjector.currentInputTextSnapshot()
            if latestSnapshot.text != nil {
                logAutomaticVocabulary(
                    "baseline read recovered on retry \(attempt) | " +
                    describeCurrentInputTextSnapshot(latestSnapshot)
                )
                return latestSnapshot
            }
        }

        return latestSnapshot
    }

    private func logAutomaticVocabulary(_ message: String) {
        NetworkDebugLogger.logMessage("[Auto Vocabulary] \(message)")
    }

    private func automaticVocabularyPreview(_ text: String, limit: Int = 80) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    private func describeCurrentInputTextSnapshot(_ snapshot: CurrentInputTextSnapshot) -> String {
        let processName = snapshot.processName ?? "<unknown>"
        let processID = snapshot.processID.map(String.init) ?? "<unknown>"
        let role = snapshot.role ?? "<unknown>"
        let textPreview = snapshot.text.map { automaticVocabularyPreview($0) } ?? "<nil>"
        let failureReason = snapshot.failureReason ?? "<none>"

        return "process=\(processName)(pid: \(processID)) | role=\(role) | " +
            "editable=\(snapshot.isEditable) | failureReason=\(failureReason) | text=\(textPreview)"
    }

    private func personaPickerEntries(includeNoneOption: Bool) -> [PersonaPickerEntry] {
        var items: [PersonaPickerEntry] = []
        if includeNoneOption {
            items.append(
                PersonaPickerEntry(
                    id: nil,
                    title: L("persona.none.title"),
                    subtitle: L("persona.none.subtitle")
                )
            )
        }
        items.append(
            contentsOf: settingsStore.personas.map {
                PersonaPickerEntry(id: $0.id, title: $0.name, subtitle: $0.prompt)
            }
        )
        return items
    }

    private func movePersonaSelection(delta: Int) {
        guard isPersonaPickerPresented, !personaPickerItems.isEmpty else { return }
        let maxIndex = personaPickerItems.count - 1
        personaPickerSelectedIndex = max(0, min(maxIndex, personaPickerSelectedIndex + delta))
        Task { @MainActor in
            self.overlayController.updatePersonaPickerSelection(self.personaPickerSelectedIndex)
        }
    }

    private func confirmPersonaSelection() {
        guard isPersonaPickerPresented, personaPickerItems.indices.contains(personaPickerSelectedIndex) else { return }

        let selected = personaPickerItems[personaPickerSelectedIndex]
        let mode = personaPickerMode
        dismissPersonaPicker(closeOverlay: false)

        switch mode {
        case .switchDefault:
            settingsStore.applyPersonaSelection(selected.id)
            if selected.id != nil {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L("workflow.persona.switched", selected.title))
                }
            } else {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L("workflow.persona.switchedOff"))
                }
            }
        case .applySelection(let context):
            guard let personaID = selected.id,
                  let persona = settingsStore.personas.first(where: { $0.id == personaID }) else { return }
            applyPersonaToSelection(context, persona: persona)
        }
    }

    private func selectPersonaSelection(at index: Int) {
        guard isPersonaPickerPresented, personaPickerItems.indices.contains(index) else { return }
        personaPickerSelectedIndex = index
        confirmPersonaSelection()
    }

    private func dismissPersonaPicker(closeOverlay: Bool = true) {
        guard isPersonaPickerPresented else { return }
        isPersonaPickerPresented = false
        personaPickerItems = []
        personaPickerSelectedIndex = 0
        personaPickerMode = .switchDefault
        guard closeOverlay else { return }
        Task { @MainActor in
            self.overlayController.dismiss(after: 0.05)
        }
    }

    private func applyPersonaToSelection(_ context: PersonaSelectionContext, persona: PersonaProfile) {
        let personaPrompt = persona.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personaPrompt.isEmpty else { return }

        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        let sessionID = beginProcessingSession()
        startProcessingTimeout(sessionID: sessionID)

        var record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: personaPrompt,
            selectionOriginalText: context.selectedText,
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .running,
            applyStatus: .pending
        )
        saveHistoryRecord(record)
        activeProcessingRecordID = record.id

        Task { @MainActor in
            self.appState.setStatus(.processing)
            self.overlayController.showProcessing()
        }

        let shouldShowResultDialog = shouldPresentResultDialog(for: context.snapshot)
        processingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let rewriteResult = try await self.generateRewrite(
                    request: LLMRewriteRequest(
                        mode: .rewriteTranscript,
                        sourceText: context.selectedText,
                        spokenInstruction: nil,
                        personaPrompt: personaPrompt
                    ),
                    sessionID: sessionID,
                    showsStreamingPreview: !shouldShowResultDialog
                )
                try self.ensureProcessingIsActive(sessionID)

                record.selectionEditedText = rewriteResult.text
                record.processingStatus = .succeeded
                record.applyStatus = .running
                self.saveHistoryRecord(record)

                let outcome: ApplyOutcome
                if shouldShowResultDialog {
                    await MainActor.run {
                        self.lastDialogResultText = rewriteResult.text
                        self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: rewriteResult.text)
                    }
                    outcome = .presentedInDialog
                } else {
                    outcome = self.applyText(rewriteResult.text, replace: true, fallbackTitle: L("workflow.result.copyTitle"))
                }

                try self.ensureProcessingIsActive(sessionID)
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
                self.saveHistoryRecord(record)
                UsageStatsStore.shared.recordSession(record: record)
                self.enforceHistoryRetentionPolicy()

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.appState.setStatus(.idle)
                        if !shouldShowResultDialog {
                            self.overlayController.dismissSoon()
                        }
                    }
                    self.processingTask = nil
                    self.activeProcessingRecordID = nil
                }
            } catch is CancellationError {
                self.markCancelled(&record)
                self.saveHistoryRecord(record)
                self.enforceHistoryRetentionPolicy()
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.processingTask = nil
                        self.activeProcessingRecordID = nil
                    }
                }
            } catch {
                let msg = "Processing failed: \(error.localizedDescription)"
                ErrorLogStore.shared.log(msg)
                self.markFailure(&record, message: msg)
                self.saveHistoryRecord(record)
                UsageStatsStore.shared.recordSession(record: record)
                self.enforceHistoryRetentionPolicy()

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.soundEffectPlayer.play(.error)
                        self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
                        self.overlayController.showFailure(message: msg)
                        self.overlayController.dismiss(after: 3.0)
                    }
                    self.processingTask = nil
                    self.activeProcessingRecordID = nil
                }
            }

            self.cancelProcessingTimeout()
        }
    }

    private func saveHistoryRecord(_ record: HistoryRecord) {
        historyStore.save(record: record)
    }

    private func logPipelineEvent(_ event: String, for record: HistoryRecord) {
        guard let timing = record.pipelineTiming, timing.hasData else { return }

        let durations: [(String, Int?)] = [
            ("stop_to_audio_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.audioFileReadyAt)),
            ("stt_ms", timing.millisecondsBetween(timing.transcriptionStartedAt, timing.transcriptionCompletedAt)),
            ("stop_to_stt_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.transcriptionCompletedAt)),
            ("transcript_to_llm_ms", timing.millisecondsBetween(timing.transcriptionCompletedAt, timing.llmProcessingStartedAt)),
            ("llm_ms", timing.millisecondsBetween(timing.llmProcessingStartedAt, timing.llmProcessingCompletedAt)),
            ("apply_ms", timing.millisecondsBetween(timing.applyStartedAt, timing.applyCompletedAt)),
            ("end_to_end_ms", timing.millisecondsBetween(
                timing.recordingStoppedAt,
                timing.applyCompletedAt ?? timing.llmProcessingCompletedAt ?? timing.transcriptionCompletedAt
            ))
        ]

        let durationSummary = durations
            .compactMap { label, value in value.map { "\(label)=\($0)" } }
            .joined(separator: " ")

        NetworkDebugLogger.logMessage(
            "[Voice Pipeline] event=\(event) record_id=\(record.id.uuidString) mode=\(record.mode.rawValue) \(durationSummary)"
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private func enforceHistoryRetentionPolicy() {
        guard let days = settingsStore.historyRetentionPolicy.days else { return }
        historyStore.purge(olderThanDays: days)
    }
}
