// swiftlint:disable file_length
import Foundation

extension WorkflowController {
    struct RewriteGenerationResult {
        let text: String
        let completedAt: Date
    }

    struct AskSelectionDecisionResult {
        let decision: AskSelectionDecision
        let completedAt: Date
    }

    func generateRewrite(
        request: LLMRewriteRequest,
        sessionID: UUID,
        showsStreamingPreview: Bool = true,
        timeout: TimeInterval? = nil,
    ) async throws -> RewriteGenerationResult {
        func performRewrite() async throws -> RewriteGenerationResult {
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
                },
            ) { [self] in
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
                                    self.overlayController.updateStreamingText(snapshot)
                                }
                            }
                        }
                    }
                }

                return RewriteGenerationResult(
                    text: buffer.trimmingCharacters(in: .whitespacesAndNewlines),
                    completedAt: Date(),
                )
            }
        }

        guard let timeout else {
            return try await performRewrite()
        }

        return try await withThrowingTaskGroup(of: RewriteGenerationResult.self) { group in
            group.addTask { try await performRewrite() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LLMRequestTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func decideAskSelection(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        editableTarget: Bool?,
        sessionID: UUID,
    ) async throws -> AskSelectionDecisionResult {
        NetworkDebugLogger.logMessage(
            """
            [Ask Decision] request
            editableTarget: \(editableTarget.map { $0 ? "true" : "false" } ?? "<unknown>")
            selectedTextLength: \(selectedText?.count ?? 0)
            spokenInstruction: \(spokenInstruction)
            """,
        )
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            personaPrompt: personaPrompt,
            editableTarget: editableTarget,
        )
        let decision = try await RequestRetry.perform(operationName: "Ask selection decision") { [self] in
            try await llmAgentService.runTool(
                request: LLMAgentRequest(
                    systemPrompt: prompts.system,
                    userPrompt: prompts.user,
                    tools: [AskSelectionDecision.tool],
                    forcedToolName: AskSelectionDecision.tool.name,
                ),
                decoding: AskSelectionDecision.self,
            )
        }

        try ensureProcessingIsActive(sessionID)

        guard decision.isValid else {
            throw NSError(
                domain: "WorkflowController",
                code: 3001,
                userInfo: [NSLocalizedDescriptionKey: "Ask selection decision returned invalid tool arguments."],
            )
        }

        guard !decision.trimmedContent.isEmpty else {
            throw NSError(
                domain: "WorkflowController",
                code: 3002,
                userInfo: [NSLocalizedDescriptionKey: "Ask selection content was empty."],
            )
        }

        let normalizedDecision: AskSelectionDecision = if editableTarget == false, decision.answerEdit == .edit {
            AskSelectionDecision(
                answerEdit: .answer,
                content: decision.content,
            )
        } else {
            decision
        }

        NetworkDebugLogger.logMessage(
            """
            [Ask Decision] response
            requestedEditableTarget: \(editableTarget.map { $0 ? "true" : "false" } ?? "<unknown>")
            modelDecision: \(decision.answerEdit.rawValue)
            normalizedDecision: \(normalizedDecision.answerEdit.rawValue)
            contentPreview: \(String(normalizedDecision.trimmedContent.prefix(120)))
            """,
        )

        return AskSelectionDecisionResult(decision: normalizedDecision, completedAt: Date())
    }

    func applyLegacyAskDecision(
        _ askDecisionResult: AskSelectionDecisionResult,
        question: String,
        selectedText: String?,
        selectionSnapshot: TextSelectionSnapshot,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
        sessionID: UUID,
    ) async throws {
        switch askDecisionResult.decision.answerEdit {
        case .answer:
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.llmProcessingCompletedAt = askDecisionResult.completedAt
            record.pipelineTiming = pipelineTiming
            logPipelineEvent("llm-processing-completed", for: record)
            record.mode = .askAnswer
            record.personaResultText = askDecisionResult.decision.trimmedContent
            record.processingStatus = .succeeded
            record.applyStatus = .running
            saveHistoryRecord(record)

            try ensureProcessingIsActive(sessionID)
            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            await MainActor.run {
                self.presentAskAnswer(
                    question: question,
                    selectedText: selectedText,
                    answerMarkdown: askDecisionResult.decision.trimmedContent,
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = L("workflow.ask.answerPresented")

        case .edit:
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.llmProcessingCompletedAt = askDecisionResult.completedAt
            record.pipelineTiming = pipelineTiming
            logPipelineEvent("llm-processing-completed", for: record)
            record.mode = .editSelection
            record.selectionEditedText = askDecisionResult.decision.trimmedContent
            record.processingStatus = .succeeded
            record.applyStatus = .running
            saveHistoryRecord(record)

            let replaceSelection = shouldReplaceActiveSelection(for: selectionSnapshot)
            let shouldShowResultDialog = hasAskSelectionContext(selectionSnapshot) && !replaceSelection
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            let outcome: ApplyOutcome
            NetworkDebugLogger.logMessage(
                "[Apply Decision] mode=editSelection hasSelection=\(selectionSnapshot.hasSelection) " +
                    "isEditable=\(selectionSnapshot.isEditable) hasRange=\(selectionSnapshot.selectedRange != nil) " +
                    "replaceSelection=\(replaceSelection) showResultDialog=\(shouldShowResultDialog)",
            )
            if shouldShowResultDialog {
                await MainActor.run {
                    self.lastDialogResultText = askDecisionResult.decision.trimmedContent
                    self.overlayController.showResultDialog(
                        title: L("workflow.result.copyTitle"),
                        message: askDecisionResult.decision.trimmedContent,
                    )
                }
                outcome = .presentedInDialog
            } else {
                outcome = applyText(
                    askDecisionResult.decision.trimmedContent,
                    replace: replaceSelection,
                    fallbackTitle: L("workflow.result.copyTitle"),
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = outcome.message
        }
    }

    func requiresRewrite(selectedText: String?, personaPrompt: String?) -> Bool {
        if let selectedText, !selectedText.isEmpty {
            return true
        }

        if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return false
    }

    func applyText(
        _ text: String,
        replace: Bool,
        fallbackTitle: String = L("workflow.result.copyTitle"),
    ) -> ApplyOutcome {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NetworkDebugLogger.logMessage(
            """
            [Apply Text] start
            replace: \(replace)
            fallbackTitle: \(fallbackTitle)
            textLength: \(text.count)
            normalizedPreview: \(String(normalizedText.prefix(120)))
            """,
        )
        do {
            if replace {
                dismissOverlayForExternalReplacement()
                try textInjector.replaceSelection(text: text)
            } else {
                try textInjector.insert(text: text)
            }
            scheduleAutomaticVocabularyObservation(for: text)
            NetworkDebugLogger.logMessage(
                """
                [Apply Text] success
                replace: \(replace)
                textLength: \(text.count)
                """,
            )
            return .inserted
        } catch {
            NetworkDebugLogger.logError(context: "[Apply Text] fallback to result dialog", error: error)
            presentResultDialog(title: fallbackTitle, text: text)
            return .presentedInDialog
        }
    }

    func applyTranscribedText(
        _ text: String,
        selectionSnapshot: TextSelectionSnapshot,
    ) -> ApplyOutcome {
        applyText(text, replace: shouldReplaceActiveSelection(for: selectionSnapshot))
    }

    // swiftlint:disable:next function_body_length
    func finishRecordingAndProcess(recordingStoppedAt: Date) async {
        do {
            let audioFile = try audioRecorder.stop()
            let audioFileReadyAt = Date()
            let recordingIntent = recordingIntent
            self.recordingIntent = .dictation
            let selectionSnapshot = await selectionTask?.value ?? TextSelectionSnapshot()
            selectionTask = nil

            let audioAnalysis = try AudioContentAnalyzer.analyze(fileURL: audioFile.fileURL)
            let validatedAudioFile = AudioFile(
                fileURL: audioFile.fileURL,
                duration: audioAnalysis.duration,
            )

            if validatedAudioFile.duration < Self.minimumRecordingDuration {
                try? FileManager.default.removeItem(at: validatedAudioFile.fileURL)
                await sttRouter.cancelPreparedRecording()
                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.showNotice(message: L("workflow.recording.tooShort"))
                }
                return
            }

            if !audioAnalysis.containsAudibleSignal {
                try? FileManager.default.removeItem(at: validatedAudioFile.fileURL)
                await sttRouter.cancelPreparedRecording()
                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.showNotice(message: L("workflow.transcription.noSpeech"))
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
            if WorkflowOverlayPresentationPolicy.shouldShowProcessingAfterRecording() {
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
                    recordingIntent: recordingIntent,
                ),
                audioFilePath: validatedAudioFile.fileURL.path,
                transcriptText: nil,
                personaPrompt: personaPrompt,
                selectionOriginalText: recordingIntent == .askSelection ? selectedText : nil,
                recordingDurationSeconds: validatedAudioFile.duration,
                pipelineTiming: HistoryPipelineTiming(
                    recordingStoppedAt: recordingStoppedAt,
                    audioFileReadyAt: audioFileReadyAt,
                ),
                recordingStatus: .succeeded,
                transcriptionStatus: .running,
                processingStatus: .pending,
                applyStatus: .pending,
            )
            saveHistoryRecord(record)
            logPipelineEvent("audio-file-ready", for: record)
            activeProcessingRecordID = record.id
            let sessionID = beginProcessingSession()

            startProcessingTimeout(sessionID: sessionID)
            processingTask = Task { [weak self] in
                guard let self else { return }
                await process(
                    audioFile: validatedAudioFile,
                    record: record,
                    selectionSnapshot: selectionSnapshot,
                    selectedText: selectedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    recordingIntent: recordingIntent,
                    sessionID: sessionID,
                )
                cancelProcessingTimeout()
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
                applyStatus: .skipped,
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

    func reprocess(record: HistoryRecord, sessionID: UUID) async {
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
            audioFileReadyAt: Date(),
        )
        saveHistoryRecord(mutableRecord)
        logPipelineEvent("retry-restarted", for: mutableRecord)
        activeProcessingRecordID = mutableRecord.id
        await MainActor.run {
            self.lastRetryableFailureRecord = nil
        }

        let audioFile = AudioFile(fileURL: audioURL, duration: 0)
        let selectedText = mutableRecord.selectionOriginalText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                isEditable: false,
            ),
            selectedText: selectedText,
            askContextText: selectedText,
            personaPrompt: personaPrompt,
            recordingIntent: mutableRecord.mode == .editSelection || mutableRecord.mode == .askAnswer
                ? .askSelection
                : .dictation,
            sessionID: sessionID,
            forceResultDialogOnSuccess: true,
        )
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    func process(
        audioFile: AudioFile,
        record: HistoryRecord,
        selectionSnapshot: TextSelectionSnapshot,
        selectedText: String?,
        askContextText: String?,
        personaPrompt: String?,
        recordingIntent: RecordingIntent,
        sessionID: UUID,
        forceResultDialogOnSuccess: Bool = false,
    ) async {
        var record = record
        do {
            try ensureProcessingIsActive(sessionID)
            var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()

            let isAskSelectionFlow = recordingIntent == .askSelection
                && !(askContextText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let multimodalHandlesPersona = settingsStore.sttProvider.handlesPersonaInternally
                && (selectedText == nil || selectedText!.isEmpty)
            let shouldKeepProcessingCapsule =
                requiresRewrite(selectedText: selectedText, personaPrompt: personaPrompt)
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
                try await processAskFlowWithSelection(
                    transcribedText: transcribedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming,
                )
            } else if recordingIntent == .askSelection {
                try await processAskFlowWithoutSelection(
                    transcribedText: transcribedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming,
                )
            } else if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await processPersonaRewriteFlow(
                    transcribedText: transcribedText,
                    personaPrompt: personaPrompt,
                    selectionSnapshot: selectionSnapshot,
                    multimodalHandlesPersona: multimodalHandlesPersona,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming,
                )
            } else {
                try processDictationFlow(
                    transcribedText: transcribedText,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming,
                )
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
                                answerMarkdown: finalText,
                            )
                        } else {
                            self.lastDialogResultText = finalText
                            self.overlayController.showResultDialog(
                                title: L("workflow.result.copyTitle"),
                                message: finalText,
                            )
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
            if shouldTreatAsSkippedSpeechInput(error: error, audioFile: audioFile) {
                record.transcriptionStatus = .skipped
                record.processingStatus = .skipped
                record.applyStatus = .skipped
                record.applyMessage = L("workflow.transcription.emptySkipped")
                record.errorMessage = nil
                saveHistoryRecord(record)

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.lastRetryableFailureRecord = nil
                        self.soundEffectPlayer.play(.done)
                        self.appState.setStatus(.idle)
                        self.overlayController.showNotice(message: L("workflow.transcription.noSpeech"))
                    }
                }
                return
            }

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

    private func processAskFlowWithSelection(
        transcribedText: String,
        askContextText: String,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
    ) async throws {
        NetworkDebugLogger.logMessage(
            """
            [Ask Flow] selected-text context
            snapshot: \(askSelectionSnapshotSummary(selectionSnapshot))
            selectedTextLength: \(askContextText.count)
            instruction: \(transcribedText)
            """,
        )
        record.processingStatus = .running
        saveHistoryRecord(record)

        await MainActor.run { self.overlayController.transitionToLLMPhase() }
        pipelineTiming.llmProcessingStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        saveHistoryRecord(record)
        logPipelineEvent("llm-processing-started", for: record)

        if settingsStore.agentFrameworkEnabled, settingsStore.agentEnabled {
            try await processAgentAskFlowWithSelection(
                transcribedText: transcribedText,
                askContextText: askContextText,
                personaPrompt: personaPrompt,
                selectionSnapshot: selectionSnapshot,
                sessionID: sessionID,
                record: &record,
                pipelineTiming: &pipelineTiming,
            )
            return
        }

        let askDecisionResult = try await decideAskSelection(
            selectedText: askContextText,
            spokenInstruction: transcribedText,
            personaPrompt: personaPrompt,
            editableTarget: askEditableTargetContext(for: selectionSnapshot),
            sessionID: sessionID,
        )
        try await applyLegacyAskDecision(
            askDecisionResult,
            question: transcribedText,
            selectedText: askContextText,
            selectionSnapshot: selectionSnapshot,
            record: &record,
            pipelineTiming: &pipelineTiming,
            sessionID: sessionID,
        )
    }

    private func processAgentAskFlowWithSelection(
        transcribedText: String,
        askContextText: String,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
    ) async throws {
        let agentResult = try await runAskAgent(
            selectedText: askContextText,
            spokenInstruction: transcribedText,
            personaPrompt: personaPrompt,
        )
        try ensureProcessingIsActive(sessionID)
        pipelineTiming.llmProcessingCompletedAt = Date()
        record.pipelineTiming = pipelineTiming
        logPipelineEvent("llm-processing-completed", for: record)

        switch agentResult {
        case let .answer(text):
            record.mode = .askAnswer
            record.personaResultText = text
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
                    answerMarkdown: text,
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = L("workflow.ask.answerPresented")

        case let .edit(text):
            record.mode = .editSelection
            record.selectionEditedText = text
            record.processingStatus = .succeeded
            record.applyStatus = .running
            saveHistoryRecord(record)

            try ensureProcessingIsActive(sessionID)
            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            let shouldShowResultDialog = shouldPresentResultDialog(for: selectionSnapshot)
            let outcome: ApplyOutcome
            NetworkDebugLogger.logMessage(
                "[Apply Decision] mode=editSelection hasSelection=\(selectionSnapshot.hasSelection) " +
                    "isEditable=\(selectionSnapshot.isEditable) hasRange=\(selectionSnapshot.selectedRange != nil) " +
                    "showResultDialog=\(shouldShowResultDialog)",
            )
            if shouldShowResultDialog {
                await MainActor.run {
                    self.lastDialogResultText = text
                    self.overlayController.showResultDialog(
                        title: L("workflow.result.copyTitle"),
                        message: text,
                    )
                }
                outcome = .presentedInDialog
            } else {
                outcome = applyText(text, replace: true, fallbackTitle: L("workflow.result.copyTitle"))
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = outcome.message
        }
    }

    private func processAskFlowWithoutSelection(
        transcribedText: String,
        askContextText: String?,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
    ) async throws {
        NetworkDebugLogger.logMessage(
            """
            [Ask Flow] no selected-text context
            snapshot: \(askSelectionSnapshotSummary(selectionSnapshot))
            instruction: \(transcribedText)
            """,
        )
        record.processingStatus = .running
        saveHistoryRecord(record)

        await MainActor.run { self.overlayController.transitionToLLMPhase() }
        pipelineTiming.llmProcessingStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        saveHistoryRecord(record)
        logPipelineEvent("llm-processing-started", for: record)

        if settingsStore.agentFrameworkEnabled, settingsStore.agentEnabled {
            let agentResult = try await runAskAgent(
                selectedText: nil,
                spokenInstruction: transcribedText,
                personaPrompt: personaPrompt,
            )
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.llmProcessingCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            logPipelineEvent("llm-processing-completed", for: record)

            let answerText: String = switch agentResult {
            case let .answer(text), let .edit(text):
                text
            }

            record.mode = .askAnswer
            record.personaResultText = answerText
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
                    answerMarkdown: answerText,
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = L("workflow.ask.answerPresented")
            return
        }

        let askDecisionResult = try await decideAskSelection(
            selectedText: askContextText,
            spokenInstruction: transcribedText,
            personaPrompt: personaPrompt,
            editableTarget: askEditableTargetContext(for: selectionSnapshot),
            sessionID: sessionID,
        )
        try await applyLegacyAskDecision(
            askDecisionResult,
            question: transcribedText,
            selectedText: askContextText,
            selectionSnapshot: selectionSnapshot,
            record: &record,
            pipelineTiming: &pipelineTiming,
            sessionID: sessionID,
        )
    }

    private func processPersonaRewriteFlow(
        transcribedText: String,
        personaPrompt: String,
        selectionSnapshot: TextSelectionSnapshot,
        multimodalHandlesPersona: Bool,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
    ) async throws {
        record.mode = .personaRewrite

        if multimodalHandlesPersona {
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
            return
        }

        record.processingStatus = .running
        saveHistoryRecord(record)

        await MainActor.run { self.overlayController.transitionToLLMPhase() }
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
                    personaPrompt: personaPrompt,
                ),
                sessionID: sessionID,
                timeout: Self.llmTimeoutAfterTranscriptionSeconds,
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
                error: error,
            )
            ErrorLogStore.shared.log(
                "Persona rewrite failed, using transcript as fallback: \(error.localizedDescription)",
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

    private func processDictationFlow(
        transcribedText: String,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming,
    ) throws {
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

    func shouldTreatAsSkippedSpeechInput(error: Error, audioFile: AudioFile) -> Bool {
        guard audioFile.duration < 1.0 else { return false }

        let message = error.localizedDescription.lowercased()
        return message.contains("socket is not connected")
            || message.contains("socket was not connected")
            || message.contains("not connected")
    }

    func failRetry(record: HistoryRecord, message: String) async {
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

    func markFailure(_ record: inout HistoryRecord, message: String) {
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

    func markCancelled(_ record: inout HistoryRecord) {
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

    func beginProcessingSession() -> UUID {
        let sessionID = UUID()
        processingSessionID = sessionID
        return sessionID
    }

    func ensureProcessingIsActive(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard processingSessionID == sessionID else {
            throw CancellationError()
        }
    }

    func cancelCurrentProcessing(resetUI: Bool, reason: String) {
        processingSessionID = UUID()
        processingTask?.cancel()
        processingTask = nil
        cancelProcessingTimeout()
        lastRetryableFailureRecord = nil

        if let activeProcessingRecordID,
           var record = historyStore.record(id: activeProcessingRecordID)
        {
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

    func inferredMode(
        selectedText: String?,
        personaPrompt: String?,
        recordingIntent: RecordingIntent,
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

    func personaPrompt(for record: HistoryRecord) -> String? {
        switch record.mode {
        case .dictation, .editSelection, .personaRewrite, .askAnswer:
            record.personaPrompt ?? settingsStore.activePersona?.prompt
        }
    }

    func selectionSnapshotLog(_ snapshot: TextSelectionSnapshot) -> String {
        let processDescription: String = if let name = snapshot.processName, let pid = snapshot.processID {
            "\(name) (pid: \(pid))"
        } else if let name = snapshot.processName {
            name
        } else if let pid = snapshot.processID {
            "pid: \(pid)"
        } else {
            "<unknown>"
        }

        let rangeDescription = if let range = snapshot.selectedRange {
            "{location: \(range.location), length: \(range.length)}"
        } else {
            "<none>"
        }

        let contentDescription: String = if let text = snapshot.selectedText, !text.isEmpty {
            text
        } else {
            "<none>"
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

    func shouldPresentResultDialog(for snapshot: TextSelectionSnapshot) -> Bool {
        WorkflowOverlayPresentationPolicy.shouldPresentResultDialog(for: snapshot)
    }

    func askEditableTargetContext(for snapshot: TextSelectionSnapshot) -> Bool? {
        if snapshot.isEditable {
            return true
        }

        if snapshot.source == "clipboard-copy", snapshot.hasAskSelectionContext {
            return nil
        }

        return false
    }

    func askSelectionSnapshotSummary(_ snapshot: TextSelectionSnapshot) -> String {
        let rangeDescription = snapshot.selectedRange.map { "[\($0.location),\($0.length)]" } ?? "<none>"
        return
            "source=\(snapshot.source) focused=\(snapshot.isFocusedTarget) editable=\(snapshot.isEditable) "
                + "hasSelection=\(snapshot.hasSelection) canReplace=\(snapshot.canReplaceSelection) "
                + "canSafelyRestore=\(snapshot.canSafelyRestoreSelection) range=\(rangeDescription) "
                + "window=\(snapshot.windowTitle ?? "<unknown>")"
    }

    func editingSelectedText(from snapshot: TextSelectionSnapshot) -> String? {
        guard snapshot.canReplaceSelection else { return nil }
        return snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func shouldReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.canReplaceSelection
    }

    func hasAskSelectionContext(_ snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.hasAskSelectionContext
    }

    func canReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.canReplaceSelection
    }

    func dismissOverlayForExternalReplacement() {
        overlayController.dismissImmediately()
        usleep(Self.selectionRestoreDelayMicroseconds)
    }

    func copyLastResultFromDialog() {
        guard let lastDialogResultText, !lastDialogResultText.isEmpty else { return }
        clipboard.write(text: lastDialogResultText)
        overlayController.showNotice(message: L("workflow.result.copied"))
    }

    func presentResultDialog(title: String, text: String) {
        NetworkDebugLogger.logMessage(
            """
            [Result Dialog] presenting
            title: \(title)
            textLength: \(text.count)
            preview: \(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
            """,
        )
        let work = { [weak self] in
            guard let self else { return }
            lastDialogResultText = text
            overlayController.showResultDialog(title: title, message: text)
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func saveHistoryRecord(_ record: HistoryRecord) {
        var record = record
        record.pipelineStats = record.pipelineTiming?.generatedStats() ?? record.pipelineStats
        historyStore.save(record: record)
    }

    func logPipelineEvent(_ event: String, for record: HistoryRecord) {
        guard let timing = record.pipelineTiming, timing.hasData else { return }

        let durations: [(String, Int?)] = [
            ("stop_to_audio_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.audioFileReadyAt)),
            ("stt_ms", timing.millisecondsBetween(timing.transcriptionStartedAt, timing.transcriptionCompletedAt)),
            ("stop_to_stt_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.transcriptionCompletedAt)),
            ("transcript_to_llm_ms", timing.millisecondsBetween(timing.transcriptionCompletedAt, timing.llmProcessingStartedAt)),
            ("llm_ms", timing.millisecondsBetween(timing.llmProcessingStartedAt, timing.llmProcessingCompletedAt)),
            ("apply_ms", timing.millisecondsBetween(timing.applyStartedAt, timing.applyCompletedAt)),
            (
                "end_to_end_ms",
                timing.millisecondsBetween(
                    timing.recordingStoppedAt,
                    timing.applyCompletedAt ?? timing.llmProcessingCompletedAt ?? timing.transcriptionCompletedAt,
                ),
            ),
        ]

        let durationSummary = durations
            .compactMap { label, value in value.map { "\(label)=\($0)" } }
            .joined(separator: " ")

        NetworkDebugLogger.logMessage(
            "[Voice Pipeline] event=\(event) record_id=\(record.id.uuidString) mode=\(record.mode.rawValue) \(durationSummary)"
                .trimmingCharacters(in: .whitespaces),
        )
    }

    func enforceHistoryRetentionPolicy() {
        guard let days = settingsStore.historyRetentionPolicy.days else { return }
        historyStore.purge(olderThanDays: days)
    }
}
