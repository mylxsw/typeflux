import Foundation

final class WorkflowController {
    private static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes
    private static let processingTimeoutNanoseconds: UInt64 = 120_000_000_000 // 2 minutes
    private static let tapToLockThreshold: TimeInterval = 0.22
    private static let selectionRestoreDelayMicroseconds: useconds_t = 120_000

    private enum RecordingMode {
        case holdToTalk
        case locked
    }

    private enum ApplyOutcome {
        case inserted
        case copiedToClipboard

        var message: String {
            switch self {
            case .inserted:
                return L("workflow.apply.inserted")
            case .copiedToClipboard:
                return L("workflow.apply.copiedToClipboard")
            }
        }
    }

    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let hotkeyService: HotkeyService
    private let audioRecorder: AudioRecorder
    private let sttRouter: STTRouter
    private let llmService: LLMService
    private let textInjector: TextInjector
    private let clipboard: ClipboardService
    private let historyStore: HistoryStore
    private let overlayController: OverlayController
    private let soundEffectPlayer: SoundEffectPlayer

    private var currentSelectedText: String?
    private var isRecording = false
    private var recordingMode: RecordingMode = .holdToTalk
    private var hotkeyPressedAt: Date?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var processingTimeoutTask: Task<Void, Never>?
    private var selectionTask: Task<TextSelectionSnapshot, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingSessionID = UUID()
    private var activeProcessingRecordID: UUID?
    private var lastTimeoutRecord: HistoryRecord?
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
        textInjector: TextInjector,
        clipboard: ClipboardService,
        historyStore: HistoryStore,
        overlayController: OverlayController,
        soundEffectPlayer: SoundEffectPlayer
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.audioRecorder = audioRecorder
        self.sttRouter = sttRouter
        self.llmService = llmService
        self.textInjector = textInjector
        self.clipboard = clipboard
        self.historyStore = historyStore
        self.overlayController = overlayController
        self.soundEffectPlayer = soundEffectPlayer
        self.overlayController.setRecordingActionHandlers(
            onCancel: { [weak self] in self?.cancelRecording() },
            onConfirm: { [weak self] in self?.confirmLockedRecording() }
        )
        self.overlayController.setResultDialogHandler(
            onCopy: { [weak self] in self?.copyLastResultFromDialog() }
        )
        self.overlayController.setFailureRetryHandler(
            onRetry: { [weak self] in
                guard let self, let record = self.lastTimeoutRecord else { return }
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

    func start() {
        hotkeyService.onPressBegan = { [weak self] in
            self?.handlePressBegan()
        }
        hotkeyService.onPressEnded = { [weak self] in
            self?.handlePressEnded()
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
        cancelRecording()
        cancelCurrentProcessing(resetUI: true, reason: L("workflow.cancel.stopping"))
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
        hotkeyPressedAt = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        _ = try? audioRecorder.stop()
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
            self.lastTimeoutRecord = timeoutRecord
            self.soundEffectPlayer.play(.error)
            self.appState.setStatus(.failed(message: L("workflow.timeout.status")))
            self.overlayController.showTimeoutFailure()
        }
    }

    private func handlePressBegan() {
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

        hotkeyPressedAt = Date()

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
            await self?.beginRecording()
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

            let selectedText = selectionSnapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func beginRecording() async {
        isRecording = true
        recordingMode = .holdToTalk
        NSLog("[Workflow] Recording started")
        await MainActor.run {
            self.soundEffectPlayer.play(.start)
        }

        Task { @MainActor in
            appState.setStatus(.recording)
            overlayController.show()
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

        Task { [weak self] in
            guard let self else { return }
            await self.finishRecordingAndProcess()
        }
    }

    private func generateRewrite(
        request: LLMRewriteRequest,
        sessionID: UUID,
        showsStreamingPreview: Bool = true
    ) async throws -> String {
        var buffer = ""
        var lastChunkAt = Date()

        let stream = llmService.streamRewrite(request: request)
        for try await chunk in stream {
            try ensureProcessingIsActive(sessionID)
            buffer += chunk
            let now = Date()
            if now.timeIntervalSince(lastChunkAt) > 0.15 {
                lastChunkAt = now
                let snapshot = buffer
                if showsStreamingPreview {
                    await MainActor.run {
                        if self.processingSessionID == sessionID {
                            overlayController.updateStreamingText(snapshot)
                        }
                    }
                }
            }
        }

        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
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
        clipboard.write(text: text)

        do {
            if replace {
                dismissOverlayForExternalReplacement()
                try textInjector.replaceSelection(text: text)
            } else {
                try textInjector.insert(text: text)
            }
            return .inserted
        } catch {
            Task { @MainActor in
                self.lastDialogResultText = text
                self.overlayController.showResultDialog(title: fallbackTitle, message: text)
            }
            return .copiedToClipboard
        }
    }

    private func finishRecordingAndProcess() async {
        do {
            let audioFile = try audioRecorder.stop()
            await MainActor.run {
                self.soundEffectPlayer.play(.done)
            }
            let selectionSnapshot = await selectionTask?.value ?? TextSelectionSnapshot()
            selectionTask = nil
            let selectedText = selectionSnapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            currentSelectedText = selectedText
            let personaPrompt = settingsStore.activePersona?.prompt

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
                mode: inferredMode(selectedText: selectedText, personaPrompt: personaPrompt),
                audioFilePath: audioFile.fileURL.path,
                transcriptText: nil,
                personaPrompt: personaPrompt,
                selectionOriginalText: selectedText,
                recordingDurationSeconds: audioFile.duration,
                recordingStatus: .succeeded,
                transcriptionStatus: .running,
                processingStatus: .pending,
                applyStatus: .pending
            )
            saveHistoryRecord(record)
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
                    personaPrompt: personaPrompt,
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
        saveHistoryRecord(mutableRecord)
        activeProcessingRecordID = mutableRecord.id

        let audioFile = AudioFile(fileURL: audioURL, duration: 0)
        let selectedText = mutableRecord.selectionOriginalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaPrompt = personaPrompt(for: mutableRecord)
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
            personaPrompt: personaPrompt,
            sessionID: sessionID,
            forceResultDialogOnSuccess: true
        )
    }

    private func process(
        audioFile: AudioFile,
        record: HistoryRecord,
        selectionSnapshot: TextSelectionSnapshot,
        selectedText: String?,
        personaPrompt: String?,
        sessionID: UUID,
        forceResultDialogOnSuccess: Bool = false
    ) async {
        var record = record
        do {
            try ensureProcessingIsActive(sessionID)

            // When using multimodal and there is no selected text to edit, the transcriber applies
            // persona internally in one shot — no separate LLM rewrite is needed afterwards.
            let multimodalHandlesPersona = settingsStore.sttProvider.handlesPersonaInternally
                && (selectedText == nil || selectedText!.isEmpty)

            // Only keep the overlay in "processing" capsule (hiding streaming text) if an LLM
            // rewrite will follow. For multimodal+persona this is not the case, so let streaming
            // through so the user sees text appearing immediately.
            let shouldKeepProcessingCapsule = requiresRewrite(selectedText: selectedText, personaPrompt: personaPrompt)
                && !multimodalHandlesPersona

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
            record.transcriptText = transcribedText
            record.transcriptionStatus = .succeeded
            saveHistoryRecord(record)

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

            if let selectedText, !selectedText.isEmpty {
                record.mode = .editSelection
                record.processingStatus = .running
                saveHistoryRecord(record)
                let shouldShowResultDialog = shouldPresentResultDialog(for: selectionSnapshot)

                let finalText = try await generateRewrite(
                    request: LLMRewriteRequest(
                        mode: .editSelection,
                        sourceText: selectedText,
                        spokenInstruction: transcribedText,
                        personaPrompt: personaPrompt
                    ),
                    sessionID: sessionID,
                    showsStreamingPreview: !shouldShowResultDialog
                )

                try ensureProcessingIsActive(sessionID)
                record.selectionEditedText = finalText
                record.processingStatus = .succeeded
                record.applyStatus = .running
                saveHistoryRecord(record)

                try ensureProcessingIsActive(sessionID)
                let outcome: ApplyOutcome
                NetworkDebugLogger.logMessage(
                    "[Apply Decision] mode=editSelection hasSelection=\(selectionSnapshot.hasSelection) " +
                    "isEditable=\(selectionSnapshot.isEditable) hasRange=\(selectionSnapshot.selectedRange != nil) " +
                    "showResultDialog=\(shouldShowResultDialog)"
                )
                if shouldShowResultDialog {
                    await MainActor.run {
                        self.lastDialogResultText = finalText
                        self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: finalText)
                    }
                    outcome = .copiedToClipboard
                } else {
                    outcome = applyText(finalText, replace: true, fallbackTitle: L("workflow.result.copyTitle"))
                }
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
            } else if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.mode = .personaRewrite

                if multimodalHandlesPersona {
                    // Persona was already applied by the multimodal transcriber — use result directly.
                    record.personaResultText = transcribedText
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    let outcome = applyText(transcribedText, replace: false)
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                } else {
                    record.processingStatus = .running
                    saveHistoryRecord(record)

                    let finalText = try await generateRewrite(
                        request: LLMRewriteRequest(
                            mode: .rewriteTranscript,
                            sourceText: transcribedText,
                            spokenInstruction: nil,
                            personaPrompt: personaPrompt
                        ),
                        sessionID: sessionID
                    )

                    try ensureProcessingIsActive(sessionID)
                    record.personaResultText = finalText
                    record.processingStatus = .succeeded
                    record.applyStatus = .running
                    saveHistoryRecord(record)

                    try ensureProcessingIsActive(sessionID)
                    let outcome = applyText(finalText, replace: false)
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                }
            } else {
                record.mode = .dictation
                record.processingStatus = .skipped
                record.applyStatus = .running
                saveHistoryRecord(record)

                try ensureProcessingIsActive(sessionID)
                let outcome = applyText(transcribedText, replace: false)
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
            }

            try ensureProcessingIsActive(sessionID)
            saveHistoryRecord(record)
            UsageStatsStore.shared.recordSession(record: record)
            enforceHistoryRetentionPolicy()
            let retryResultText = forceResultDialogOnSuccess ? record.finalText : nil

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.appState.setStatus(.idle)
                    if let finalText = retryResultText, !finalText.isEmpty {
                        self.lastDialogResultText = finalText
                        self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: finalText)
                    } else {
                        self.overlayController.dismissSoon()
                    }
                }
            }
        } catch is CancellationError {
            markCancelled(&record)
            saveHistoryRecord(record)
            enforceHistoryRetentionPolicy()
        } catch {
            let msg = "Processing failed: \(error.localizedDescription)"
            ErrorLogStore.shared.log(msg)
            markFailure(&record, message: msg)
            saveHistoryRecord(record)
            UsageStatsStore.shared.recordSession(record: record)
            enforceHistoryRetentionPolicy()

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.soundEffectPlayer.play(.error)
                    self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
                    self.overlayController.showFailure(message: msg)
                    self.overlayController.dismiss(after: 3.0)
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

    private func inferredMode(selectedText: String?, personaPrompt: String?) -> HistoryRecord.Mode {
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
        case .dictation, .editSelection, .personaRewrite:
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
        Has selection: \(snapshot.hasSelection)
        Selected range: \(rangeDescription)
        Selected text: \(contentDescription)
        """
    }

    private func shouldPresentResultDialog(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.hasSelection && !snapshot.isEditable
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
                let finalText = try await self.generateRewrite(
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

                record.selectionEditedText = finalText
                record.processingStatus = .succeeded
                record.applyStatus = .running
                self.saveHistoryRecord(record)

                let outcome: ApplyOutcome
                if shouldShowResultDialog {
                    await MainActor.run {
                        self.lastDialogResultText = finalText
                        self.overlayController.showResultDialog(title: L("workflow.result.copyTitle"), message: finalText)
                    }
                    outcome = .copiedToClipboard
                } else {
                    outcome = self.applyText(finalText, replace: true, fallbackTitle: L("workflow.result.copyTitle"))
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

    private func enforceHistoryRetentionPolicy() {
        guard let days = settingsStore.historyRetentionPolicy.days else { return }
        historyStore.purge(olderThanDays: days)
    }
}
