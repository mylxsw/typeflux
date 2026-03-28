import Foundation

final class WorkflowController {
    private static let recordingTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes
    private static let tapToLockThreshold: TimeInterval = 0.22

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
                return "Applied to the active app."
            case .copiedToClipboard:
                return "Copied to the clipboard because direct insertion was unavailable."
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

    private var currentSelectedText: String?
    private var isRecording = false
    private var recordingMode: RecordingMode = .holdToTalk
    private var hotkeyPressedAt: Date?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var selectionTask: Task<TextSelectionSnapshot, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingSessionID = UUID()
    private var activeProcessingRecordID: UUID?
    private var lastDialogResultText: String?
    private var isPersonaPickerPresented = false
    private var personaPickerItems: [PersonaPickerEntry] = []
    private var personaPickerSelectedIndex = 0

    private struct PersonaPickerEntry {
        let id: UUID?
        let title: String
        let subtitle: String
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
        overlayController: OverlayController
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
        self.overlayController.setRecordingActionHandlers(
            onCancel: { [weak self] in self?.cancelRecording() },
            onConfirm: { [weak self] in self?.confirmLockedRecording() }
        )
        self.overlayController.setResultDialogHandler(
            onCopy: { [weak self] in self?.copyLastResultFromDialog() }
        )
        self.overlayController.setPersonaPickerHandlers(
            onMoveUp: { [weak self] in self?.movePersonaSelection(delta: -1) },
            onMoveDown: { [weak self] in self?.movePersonaSelection(delta: 1) },
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
        cancelCurrentProcessing(resetUI: true, reason: "Cancelled while stopping.")
    }

    func retry(record: HistoryRecord) {
        guard !isRecording else { return }
        cancelCurrentProcessing(resetUI: false, reason: "Cancelled due to retry.")

        let sessionID = beginProcessingSession()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.appState.setStatus(.processing)
                self.overlayController.showProcessing()
            }
            await self.reprocess(record: record, sessionID: sessionID)
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

    private func handlePressBegan() {
        if isPersonaPickerPresented {
            dismissPersonaPicker()
        }

        if !PrivacyGuard.isRunningInAppBundle {
            Task { @MainActor in
                let msg = "Please run via scripts/run_dev_app.sh (app bundle required for privacy permissions)"
                appState.setStatus(.failed(message: "Run as .app"))
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

        cancelCurrentProcessing(resetUI: false, reason: "Cancelled by new recording.")
        Task { [weak self] in
            await self?.beginRecording()
        }
    }

    private func handlePersonaPickerRequested() {
        guard !isRecording else {
            Task { @MainActor in
                self.overlayController.showNotice(message: "Finish the current recording before switching persona.")
            }
            return
        }

        guard processingTask == nil else {
            Task { @MainActor in
                self.overlayController.showNotice(message: "Please wait until processing finishes before switching persona.")
            }
            return
        }

        if isPersonaPickerPresented {
            dismissPersonaPicker(closeOverlay: false)
            return
        }

        let activeID = settingsStore.personaRewriteEnabled ? UUID(uuidString: settingsStore.activePersonaID) : nil
        let items = personaPickerEntries()
        guard !items.isEmpty else { return }

        personaPickerItems = items
        personaPickerSelectedIndex = items.firstIndex(where: { $0.id == activeID }) ?? 0
        isPersonaPickerPresented = true

        Task { @MainActor in
            self.overlayController.showPersonaPicker(
                items: items.map {
                    OverlayController.PersonaPickerItem(
                        id: $0.id?.uuidString ?? "plain-dictation",
                        title: $0.title,
                        subtitle: $0.subtitle
                    )
                },
                selectedIndex: self.personaPickerSelectedIndex
            )
        }
    }

    private func beginRecording() async {
        isRecording = true
        recordingMode = .holdToTalk
        NSLog("[Workflow] Recording started")

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
            historyStore.save(record: record)
            Task { @MainActor in
                let msg = "Audio start failed: \(error.localizedDescription)"
                appState.setStatus(.failed(message: "Audio start failed"))
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

    private func applyText(_ text: String, replace: Bool, fallbackTitle: String = "Copy Result") -> ApplyOutcome {
        clipboard.write(text: text)

        do {
            if replace {
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
                recordingStatus: .succeeded,
                transcriptionStatus: .running,
                processingStatus: .pending,
                applyStatus: .pending
            )
            historyStore.save(record: record)
            activeProcessingRecordID = record.id
            let sessionID = beginProcessingSession()

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
            historyStore.save(record: record)

            await MainActor.run {
                self.appState.setStatus(.failed(message: "Processing failed"))
                self.overlayController.showFailure(message: msg)
                self.overlayController.dismiss(after: 3.0)
            }
        }
    }

    private func reprocess(record: HistoryRecord, sessionID: UUID) async {
        guard let audioFilePath = record.audioFilePath, !audioFilePath.isEmpty else {
            await failRetry(record: record, message: "Retry failed: audio file is missing.")
            return
        }

        let audioURL = URL(fileURLWithPath: audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            await failRetry(record: record, message: "Retry failed: audio file no longer exists.")
            return
        }

        var mutableRecord = record
        mutableRecord.date = Date()
        mutableRecord.errorMessage = nil
        mutableRecord.applyMessage = nil
        mutableRecord.transcriptText = nil
        mutableRecord.personaResultText = nil
        mutableRecord.selectionEditedText = nil
        mutableRecord.recordingStatus = .succeeded
        mutableRecord.transcriptionStatus = .running
        mutableRecord.processingStatus = .pending
        mutableRecord.applyStatus = .pending
        historyStore.save(record: mutableRecord)
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
            sessionID: sessionID
        )
    }

    private func process(
        audioFile: AudioFile,
        record: HistoryRecord,
        selectionSnapshot: TextSelectionSnapshot,
        selectedText: String?,
        personaPrompt: String?,
        sessionID: UUID
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
            historyStore.save(record: record)

            let normalizedTranscript = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedTranscript.isEmpty {
                record.processingStatus = .skipped
                record.applyStatus = .skipped
                record.applyMessage = "Skipped because transcription was empty."
                historyStore.save(record: record)

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.appState.setStatus(.idle)
                        self.overlayController.showNotice(message: "未识别到有效语音内容")
                    }
                }
                return
            }

            if let selectedText, !selectedText.isEmpty {
                record.mode = .editSelection
                record.processingStatus = .running
                historyStore.save(record: record)
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
                historyStore.save(record: record)

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
                        self.overlayController.showResultDialog(title: "Copy Result", message: finalText)
                    }
                    outcome = .copiedToClipboard
                } else {
                    outcome = applyText(finalText, replace: true, fallbackTitle: "Copy Result")
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
                    historyStore.save(record: record)

                    try ensureProcessingIsActive(sessionID)
                    let outcome = applyText(transcribedText, replace: false)
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                } else {
                    record.processingStatus = .running
                    historyStore.save(record: record)

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
                    historyStore.save(record: record)

                    try ensureProcessingIsActive(sessionID)
                    let outcome = applyText(finalText, replace: false)
                    record.applyStatus = .succeeded
                    record.applyMessage = outcome.message
                }
            } else {
                record.mode = .dictation
                record.processingStatus = .skipped
                record.applyStatus = .running
                historyStore.save(record: record)

                try ensureProcessingIsActive(sessionID)
                let outcome = applyText(transcribedText, replace: false)
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
            }

            try ensureProcessingIsActive(sessionID)
            historyStore.save(record: record)
            historyStore.purge(olderThanDays: 7)

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.appState.setStatus(.idle)
                    self.overlayController.dismissSoon()
                }
            }
        } catch is CancellationError {
            markCancelled(&record)
            historyStore.save(record: record)
        } catch {
            let msg = "Processing failed: \(error.localizedDescription)"
            ErrorLogStore.shared.log(msg)
            markFailure(&record, message: msg)
            historyStore.save(record: record)

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.appState.setStatus(.failed(message: "Processing failed"))
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
        historyStore.save(record: mutableRecord)

        await MainActor.run {
            self.appState.setStatus(.failed(message: "Processing failed"))
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
        record.errorMessage = "Cancelled by a new recording."
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

        if let activeProcessingRecordID,
           var record = historyStore.list().first(where: { $0.id == activeProcessingRecordID }) {
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
            historyStore.save(record: record)
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
        snapshot.hasSelection && (!snapshot.isEditable || snapshot.selectedRange == nil)
    }

    private func copyLastResultFromDialog() {
        guard let lastDialogResultText, !lastDialogResultText.isEmpty else { return }
        clipboard.write(text: lastDialogResultText)
        overlayController.showNotice(message: "已复制到剪贴板")
    }

    private func personaPickerEntries() -> [PersonaPickerEntry] {
        var items = [
            PersonaPickerEntry(
                id: nil,
                title: "Plain Dictation",
                subtitle: "Write directly without persona rewriting."
            )
        ]
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
        if let id = selected.id {
            settingsStore.activePersonaID = id.uuidString
            settingsStore.personaRewriteEnabled = true
            Task { @MainActor in
                self.overlayController.showNotice(message: "Persona switched to \(selected.title).")
            }
        } else {
            settingsStore.personaRewriteEnabled = false
            Task { @MainActor in
                self.overlayController.showNotice(message: "Persona switched off.")
            }
        }

        dismissPersonaPicker(closeOverlay: false)
    }

    private func dismissPersonaPicker(closeOverlay: Bool = true) {
        guard isPersonaPickerPresented else { return }
        isPersonaPickerPresented = false
        personaPickerItems = []
        personaPickerSelectedIndex = 0
        guard closeOverlay else { return }
        Task { @MainActor in
            self.overlayController.dismiss(after: 0.05)
        }
    }
}
