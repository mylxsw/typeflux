// swiftlint:disable file_length function_body_length function_parameter_count line_length
// swiftlint:disable multiple_closures_with_trailing_closure
import Foundation

extension WorkflowController {
    private static func formatDurationSince(_ startDate: Date) -> String {
        String(format: "%.1fms", Date().timeIntervalSince(startDate) * 1000)
    }

    enum AskWithoutSelectionAgentDisposition: Equatable {
        case answer(String)
        case insert(String)
    }

    struct RewriteGenerationResult {
        let text: String
        let firstOutputAt: Date?
        let completedAt: Date
        let requestAttempts: [LLMRequestAttemptDiagnostics]
    }

    struct AskSelectionDecisionResult {
        let decision: AskSelectionDecision
        let completedAt: Date
    }

    struct MergedCloudTranscriptionResult {
        let transcript: String
        let rewritten: String?
        let llmStartedAt: Date?
        let llmFirstOutputAt: Date?
        let llmCompletedAt: Date?
    }

    var shouldSuppressPostRecordingStreamingPreviewForCurrentSTTProvider: Bool {
        switch settingsStore.sttProvider {
        case .aliCloud, .doubaoRealtime, .googleCloud, .soniox, .typefluxOfficial:
            true
        default:
            false
        }
    }

    func generateRewrite(
        request: LLMRewriteRequest,
        sessionID: UUID,
        showsStreamingPreview: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> RewriteGenerationResult {
        let configStatus = await validateLLMConfiguration()
        guard case .ready = configStatus else {
            await presentLLMNotConfigured(configStatus)
            if case let .notConfigured(reason) = configStatus {
                throw LLMConfigurationError.notConfigured(reason: reason)
            }
            throw CancellationError()
        }

        func performRewrite() async throws -> RewriteGenerationResult {
            let diagnosticsRecorder = request.diagnosticsRecorder ?? LLMRequestDiagnosticsRecorder()
            let instrumentedRequest = request.withDiagnosticsRecorder(diagnosticsRecorder)
            return try await RequestRetry.perform(
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
                var firstOutputAt: Date?
                var lastChunkAt = Date()

                let stream = llmService.streamRewrite(request: instrumentedRequest)
                for try await chunk in stream {
                    try ensureProcessingIsActive(sessionID)
                    if firstOutputAt == nil, !chunk.isEmpty {
                        firstOutputAt = Date()
                    }
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
                    firstOutputAt: firstOutputAt,
                    completedAt: Date(),
                    requestAttempts: await diagnosticsRecorder.settledSnapshot()
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
                throw LLMRequestTimeoutError(timeoutSeconds: timeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    func decideAskSelection(
        selectedText: String?,
        spokenInstruction: String,
        personaPrompt: String?,
        editableTarget: Bool?,
        appSystemContext: AppSystemContext? = nil,
        sessionID: UUID
    ) async throws -> AskSelectionDecisionResult {
        let configStatus = await validateLLMConfiguration()
        guard case .ready = configStatus else {
            await presentLLMNotConfigured(configStatus)
            if case let .notConfigured(reason) = configStatus {
                throw LLMConfigurationError.notConfigured(reason: reason)
            }
            throw CancellationError()
        }

        NetworkDebugLogger.logMessage(
            """
            [Ask Decision] request
            editableTarget: \(editableTarget.map { $0 ? "true" : "false" } ?? "<unknown>")
            selectedTextLength: \(selectedText?.count ?? 0)
            spokenInstruction: \(spokenInstruction)
            """
        )
        let prompts = PromptCatalog.askSelectionDecisionPrompts(
            selectedText: selectedText,
            spokenInstruction: spokenInstruction,
            personaPrompt: personaPrompt,
            editableTarget: editableTarget
        )
        let decision = try await RequestRetry.perform(operationName: "Ask selection decision") { [self] in
            try await llmAgentService.runTool(
                request: LLMAgentRequest(
                    systemPrompt: prompts.system,
                    userPrompt: prompts.user,
                    tools: [AskSelectionDecision.tool],
                    forcedToolName: AskSelectionDecision.tool.name,
                    appSystemContext: appSystemContext
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

        guard !decision.trimmedContent.isEmpty else {
            throw NSError(
                domain: "WorkflowController",
                code: 3002,
                userInfo: [NSLocalizedDescriptionKey: "Ask selection content was empty."]
            )
        }

        let normalizedDecision: AskSelectionDecision = if editableTarget == false, decision.answerEdit == .edit {
            AskSelectionDecision(
                answerEdit: .answer,
                content: decision.content
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
            """
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
        sessionID: UUID
    ) async throws {
        switch askDecisionResult.decision.answerEdit {
        case .answer:
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.llmProcessingCompletedAt = askDecisionResult.completedAt
            record.pipelineTiming = pipelineTiming
            logPipelineEvent("llm-processing-completed", for: record)
            record.mode = .askAnswer

            var openCCResult: String?
            let finalAnswer: String
            if let config = settingsStore.effectiveOutputOpenCCConfig {
                let converted = await outputPostProcessor.process(askDecisionResult.decision.trimmedContent)
                if converted != askDecisionResult.decision.trimmedContent {
                    openCCResult = converted
                }
                finalAnswer = converted
                record.openCCConfig = config
            } else {
                finalAnswer = askDecisionResult.decision.trimmedContent
            }

            record.personaResultText = askDecisionResult.decision.trimmedContent
            record.openCCResultText = openCCResult
            record.postProcessedText = finalAnswer
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
                    answerMarkdown: finalAnswer
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = L("workflow.ask.answerPresented")
            recordDictationApplyAnalytics(recordID: record.id, outcome: .presentedInDialog)

        case .edit:
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.llmProcessingCompletedAt = askDecisionResult.completedAt
            record.pipelineTiming = pipelineTiming
            logPipelineEvent("llm-processing-completed", for: record)
            record.mode = .editSelection

            let replaceSelection = shouldReplaceActiveSelection(for: selectionSnapshot)
            try ensureProcessingIsActive(sessionID)
            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            let (outcome, processedText) = await applyText(
                askDecisionResult.decision.trimmedContent,
                replace: replaceSelection,
                fallbackTitle: L("workflow.result.copyTitle"),
                targetSnapshot: selectionSnapshot
            )
            record.selectionEditedText = askDecisionResult.decision.trimmedContent
            record.postProcessedText = processedText
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.processingStatus = .succeeded
            record.applyStatus = .succeeded
            record.applyMessage = outcome.message
            recordDictationApplyAnalytics(recordID: record.id, outcome: outcome)
            saveHistoryRecord(record)
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
        targetSnapshot: TextSelectionSnapshot? = nil
    ) async -> (ApplyOutcome, String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NetworkDebugLogger.logMessage(
            """
            [Apply Text] start
            replace: \(replace)
            fallbackTitle: \(fallbackTitle)
            textLength: \(text.count)
            normalizedPreview: \(String(normalizedText.prefix(120)))
            """
        )
        if let targetSnapshot, shouldBypassTextInjection(for: targetSnapshot) {
            NetworkDebugLogger.logMessage(
                """
                [Apply Text] bypassing text injection for Typeflux-owned target
                process: \(targetSnapshot.processName ?? "<unknown>")
                bundleIdentifier: \(targetSnapshot.bundleIdentifier ?? "<unknown>")
                source: \(targetSnapshot.source)
                window: \(targetSnapshot.windowTitle ?? "<unknown>")
                """
            )
            presentResultDialog(title: fallbackTitle, text: text)
            return (.presentedInDialog, text)
        }
        do {
            if replace {
                try await dismissOverlayForExternalReplacement()
                try Task.checkCancellation()
                try await textInjector.replaceSelection(text: text, target: targetSnapshot)
            } else {
                try textInjector.insert(text: text)
            }
            let bumpedTerms = VocabularyStore.incrementOccurrences(in: text)
            if !bumpedTerms.isEmpty {
                NetworkDebugLogger.logMessage(
                    "[Apply Text] vocabulary occurrences bumped: \(bumpedTerms.joined(separator: ", "))"
                )
            }
            scheduleAutomaticVocabularyObservation(for: text)
            NetworkDebugLogger.logMessage(
                """
                [Apply Text] success
                replace: \(replace)
                textLength: \(text.count)
                """
            )
            return (.inserted, text)
        } catch {
            NetworkDebugLogger.logError(context: "[Apply Text] fallback to result dialog", error: error)
            presentResultDialog(title: fallbackTitle, text: text)
            return (.presentedInDialog, text)
        }
    }

    func applyTranscribedText(
        _ text: String,
        selectionSnapshot: TextSelectionSnapshot,
        record: inout HistoryRecord
    ) async -> (outcome: ApplyOutcome, openCCResult: String?, finalResult: String) {
        // 1. Final optimization (punctuation, spaces)
        let optimizedText = DictationOutputOptimizer.optimize(text)

        // 2. OpenCC
        var openCCResult: String?
        let afterOpenCC: String
        if let config = settingsStore.effectiveOutputOpenCCConfig {
            afterOpenCC = await outputPostProcessor.process(optimizedText)
            openCCResult = afterOpenCC
            record.openCCConfig = config
        } else {
            afterOpenCC = optimizedText
        }

        // 3. Apply to target
        let (outcome, finalAppliedText) = await applyText(
            afterOpenCC,
            replace: shouldReplaceActiveSelection(for: selectionSnapshot),
            targetSnapshot: selectionSnapshot
        )
        return (outcome, openCCResult, finalAppliedText)
    }

    func finishRecordingAndProcess(
        recordingStoppedAt: Date,
        startupContext: RecordingStartupContext? = nil,
        bypassPersonaRewrite: Bool = false
    ) async {
        do {
            let finishStartedAt = Date()
            NetworkDebugLogger
                .logMessage("[Ask Timing] finishRecordingAndProcess entered intent=\(recordingIntent.traceName)")
            // Keep capturing briefly after the release event so final consonants and
            // short utterances are not clipped at the hotkey boundary.
            await sleep(Self.recordingTailCaptureDuration)
            let audioFile = try audioRecorder.stop()
            NetworkDebugLogger.logMessage(
                "[Ask Timing] audioRecorder.stop completed in \(Self.formatDurationSince(finishStartedAt))"
            )
            _ = await liveTranscriptionPreviewer?.finish()
            let realtimeTranscriptionSession = activeRealtimeTranscriptionSession
            let realtimeAudioBufferPump = activeRealtimeAudioBufferPump
            let recordingPreviewText = latestRecordingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            activeRealtimeTranscriptionSession = nil
            activeRealtimeAudioBufferPump = nil
            latestRecordingPreviewText = ""
            isAudioRecorderStarted = false
            let audioFileReadyAt = Date()
            let recordingIntent = recordingIntent
            self.recordingIntent = .dictation
            let selectionAwaitStartedAt = Date()
            let selectionSnapshot = await selectionTask?.value ?? TextSelectionSnapshot()
            selectionTask = nil
            let capturedInputContext = await inputContextTask?.value
            inputContextTask = nil
            let inputContext = bypassPersonaRewrite ? nil : capturedInputContext
            NetworkDebugLogger.logMessage(
                "[Ask Timing] context tasks completed in \(Self.formatDurationSince(selectionAwaitStartedAt))"
            )

            let audioAnalysisStartedAt = Date()
            let audioFileURL = audioFile.fileURL
            let audioAnalysis = try await Task.detached(priority: .userInitiated) {
                try AudioContentAnalyzer.analyze(fileURL: audioFileURL)
            }.value
            NetworkDebugLogger.logMessage(
                "[Ask Timing] audio analysis completed in \(Self.formatDurationSince(audioAnalysisStartedAt))"
            )
            let validatedAudioFile = AudioFile(
                fileURL: audioFile.fileURL,
                duration: audioAnalysis.duration
            )
            let signalClassification = audioAnalysis.signalClassification
            recordPendingDictationAudioAnalysis(
                classification: signalClassification,
                analysis: audioAnalysis
            )
            NetworkDebugLogger.logMessage(
                """
                [Audio Analysis] classification=\(signalClassification.rawValue)
                duration=\(String(format: "%.3f", audioAnalysis.duration))
                rmsPowerDB=\(audioAnalysis.rmsPowerDB)
                peakPowerDB=\(audioAnalysis.peakPowerDB)
                audibleDuration=\(String(format: "%.3f", audioAnalysis.audibleDuration))
                audibleFrameRatio=\(audioAnalysis.audibleFrameRatio)
                """
            )

            if validatedAudioFile.duration < Self.minimumRecordingDuration {
                try? FileManager.default.removeItem(at: validatedAudioFile.fileURL)
                realtimeAudioBufferPump?.cancel()
                await realtimeTranscriptionSession?.cancel()
                await sttRouter.cancelPreparedRecording()
                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.showNotice(message: L("workflow.recording.tooShort"))
                }
                reportPendingDictationFailure(stage: "recording", kind: "recording_too_short")
                return
            }

            if signalClassification == .hardSilence, recordingPreviewText.isEmpty {
                try? FileManager.default.removeItem(at: validatedAudioFile.fileURL)
                realtimeAudioBufferPump?.cancel()
                await realtimeTranscriptionSession?.cancel()
                await sttRouter.cancelPreparedRecording()
                await MainActor.run {
                    self.appState.setStatus(.idle)
                    self.overlayController.showNotice(message: L("workflow.transcription.noSpeech"))
                }
                reportPendingDictationFailure(stage: "transcription", kind: "client_hard_silence")
                return
            }

            if signalClassification != .audible {
                NetworkDebugLogger.logMessage(
                    """
                    [Audio Analysis] continuing despite low saved-audio signal because recording preview produced text
                    duration: \(String(format: "%.3f", audioAnalysis.duration))
                    rmsPowerDB: \(audioAnalysis.rmsPowerDB)
                    peakPowerDB: \(audioAnalysis.peakPowerDB)
                    audibleDuration: \(String(format: "%.3f", audioAnalysis.audibleDuration))
                    audibleFrameRatio: \(audioAnalysis.audibleFrameRatio)
                    previewLength: \(recordingPreviewText.count)
                    """
                )
            }

            let shouldPrepareRetryAudio = recordingPreviewText.isEmpty
                && (signalClassification == .lowEnergy
                    || validatedAudioFile.duration <= Self.shortAudioRetryDuration)
            var retryAudioFile: AudioFile?
            if shouldPrepareRetryAudio {
                do {
                    retryAudioFile = try await Task.detached(priority: .userInitiated) {
                        try LowEnergyAudioPreparer.prepare(
                            audioFile: validatedAudioFile,
                            analysis: audioAnalysis
                        )
                    }.value
                } catch {
                    NetworkDebugLogger.logError(
                        context: "Low-energy audio preparation failed; using original audio",
                        error: error
                    )
                }
            }
            let transcriptionAudioFile = signalClassification == .lowEnergy
                ? (retryAudioFile ?? validatedAudioFile)
                : validatedAudioFile

            await MainActor.run {
                _ = self.soundEffectPlayer.play(.done)
            }
            let selectedText = recordingIntent == .askSelection
                ? editingSelectedText(from: selectionSnapshot)
                : nil
            let askContextText = recordingIntent == .askSelection
                ? askContextText(from: selectionSnapshot, inputContext: inputContext)
                : nil
            currentSelectedText = selectedText
            if bypassPersonaRewrite {
                NetworkDebugLogger.logMessage("[Workflow] quick input enabled; bypassing persona rewrite")
            }
            let activePersonaProfile = recordingIntent == .askSelection || bypassPersonaRewrite
                ? nil
                : activePersona(selectionSnapshot: selectionSnapshot, inputContext: inputContext)
            let personaPrompt = activePersonaProfile.map {
                settingsStore.resolvedPersonaPrompt(for: $0)
            }
            let fallbackWaitSeconds = settingsStore.voiceProcessingTimeout.seconds

            NetworkDebugLogger.logMessage(selectionSnapshotLog(selectionSnapshot))
            if WorkflowOverlayPresentationPolicy.shouldShowProcessingAfterRecording() {
                await MainActor.run {
                    self.appState.setStatus(.processing)
                    self.overlayController.showProcessing(timeout: fallbackWaitSeconds)
                }
            }

            let record = HistoryRecord(
                date: Date(),
                mode: inferredMode(
                    selectedText: selectedText,
                    personaPrompt: personaPrompt,
                    recordingIntent: recordingIntent
                ),
                audioFilePath: validatedAudioFile.fileURL.path,
                transcriptText: nil,
                personaPrompt: personaPrompt,
                selectionOriginalText: recordingIntent == .askSelection ? selectedText : nil,
                recordingDurationSeconds: validatedAudioFile.duration,
                pipelineTiming: HistoryPipelineTiming(
                    hotkeyDetectedAt: startupContext?.hotkeyDetectedAt,
                    recordingWorkflowStartedAt: startupContext?.recordingWorkflowStartedAt,
                    audioEngineStartedAt: audioFile.startupTiming?.audioEngineStartedAt,
                    firstAudioBufferAt: audioFile.startupTiming?.firstAudioBufferAt,
                    recordingStoppedAt: recordingStoppedAt,
                    audioFileReadyAt: audioFileReadyAt
                ),
                recordingStatus: .succeeded,
                transcriptionStatus: .running,
                processingStatus: .pending,
                applyStatus: .pending
            )
            saveHistoryRecord(record)
            bindPendingDictationAnalytics(to: record.id)
            logPipelineEvent("audio-file-ready", for: record)
            activeProcessingRecordID = record.id
            let sessionID = beginProcessingSession()

            startProcessingWatchdog(sessionID: sessionID)
            processingTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if let retryAudioFile,
                       retryAudioFile.fileURL != validatedAudioFile.fileURL {
                        try? FileManager.default.removeItem(at: retryAudioFile.fileURL)
                    }
                }
                let processingStartedAt = Date()
                NetworkDebugLogger
                    .logMessage("[Ask Timing] processing task entered intent=\(recordingIntent.traceName)")
                await realtimeAudioBufferPump?.finishInput()
                NetworkDebugLogger.logMessage(
                    "[Ask Timing] realtime audio pump finished in \(Self.formatDurationSince(processingStartedAt))"
                )
                await process(
                    audioFile: transcriptionAudioFile,
                    lowEnergyRetryAudioFile: retryAudioFile,
                    realtimeTranscriptionSession: realtimeTranscriptionSession,
                    record: record,
                    selectionSnapshot: selectionSnapshot,
                    selectedText: selectedText,
                    askContextText: askContextText,
                    inputContext: inputContext,
                    personaPrompt: personaPrompt,
                    personaID: activePersonaProfile?.id,
                    recordingIntent: recordingIntent,
                    sessionID: sessionID,
                    recordingPreviewText: recordingPreviewText
                )
                NetworkDebugLogger.logMessage(
                    "[Ask Timing] process completed in \(Self.formatDurationSince(processingStartedAt))"
                )
                cancelProcessingWatchdog()
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.processingTask = nil
                        self.activeProcessingRecordID = nil
                    }
                }
            }
        } catch {
            await liveTranscriptionPreviewer?.cancel()
            activeRealtimeAudioBufferPump?.cancel()
            await activeRealtimeTranscriptionSession?.cancel()
            activeRealtimeTranscriptionSession = nil
            activeRealtimeAudioBufferPump = nil
            latestRecordingPreviewText = ""
            isAudioRecorderStarted = false
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
            bindPendingDictationAnalytics(to: record.id)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)

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
            audioFileReadyAt: Date()
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
                isEditable: false
            ),
            selectedText: selectedText,
            askContextText: selectedText,
            inputContext: nil,
            personaPrompt: personaPrompt,
            recordingIntent: mutableRecord.mode == .editSelection || mutableRecord.mode == .askAnswer
                ? .askSelection
                : .dictation,
            sessionID: sessionID,
            forceResultDialogOnSuccess: true
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    func process(
        audioFile: AudioFile,
        lowEnergyRetryAudioFile: AudioFile? = nil,
        realtimeTranscriptionSession: (any RealtimeTranscriptionSession)? = nil,
        record: HistoryRecord,
        selectionSnapshot: TextSelectionSnapshot,
        selectedText: String?,
        askContextText: String?,
        inputContext: InputContextSnapshot?,
        personaPrompt: String?,
        personaID: UUID? = nil,
        recordingIntent: RecordingIntent,
        sessionID: UUID,
        forceResultDialogOnSuccess: Bool = false,
        recordingPreviewText: String = ""
    ) async {
        var record = record
        let asrRaceDiagnosticsRecorder = sttRouter.usesTypefluxOfficialCloudLocalRace
            ? ASRRaceDiagnosticsRecorder()
            : nil
        do {
            try ensureProcessingIsActive(sessionID)
            var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()

            let isAskSelectionFlow = recordingIntent == .askSelection
                && !(askContextText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let multimodalHandlesPersona = settingsStore.sttProvider.handlesPersonaInternally
                && (selectedText == nil || selectedText!.isEmpty)
            let hasRewritePersona = Self.hasRewritePersona(personaPrompt)
            let hasInputContext = inputContext?.hasContent == true
            let shouldRewriteTranscript = Self.shouldRewriteTranscript(
                personaPrompt: personaPrompt,
                inputContext: inputContext
            )
            let expectedASROptimize = !shouldRewriteTranscript
            let usableRealtimeTranscriptionSession = realtimeTranscriptionSession
            if let actualASROptimize = (realtimeTranscriptionSession as?
                any RealtimeASROptimizeProviding)?.asrOptimize {
                let action = actualASROptimize == expectedASROptimize
                    ? "reuse_realtime"
                    : "reuse_realtime_mismatch"
                NetworkDebugLogger.logMessage(
                    "[ASR Timing][client] phase=optimize_decision action=\(action) " +
                        "requested_optimize=\(actualASROptimize) expected_optimize=\(expectedASROptimize) " +
                        "rewrite_required=\(shouldRewriteTranscript) replay_audio=false"
                )
            }
            pipelineTiming.transcriptionStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            saveHistoryRecord(record)
            logPipelineEvent("transcription-started", for: record)

            let cloudScenario: TypefluxCloudScenario = switch recordingIntent {
            case .dictation:
                .voiceInput
            case .askSelection:
                .askAnything
            }

            // Use merged ASR+LLM path when both providers are Typeflux Cloud and
            // a persona rewrite is needed. The server will run the LLM after
            // transcription and stream results back over the same WebSocket.
            let canMergeWithLLM = settingsStore.sttProvider == .typefluxOfficial
                && !sttRouter.usesTypefluxOfficialCloudLocalRace
                && settingsStore.llmRemoteProvider == .typefluxCloud
                && recordingIntent == .dictation
                && !multimodalHandlesPersona
                && inputContext == nil
                && hasRewritePersona

            var rawTranscribedText: String
            var mergedLLMResult: String?
            var mergedLLMStartedAt: Date?
            var mergedLLMFirstOutputAt: Date?
            var mergedLLMCompletedAt: Date?
            let fallbackPreviewText = recordingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)

            let transcriptionStartedAt = Date()
            NetworkDebugLogger.logMessage("[Ask Timing] transcription entered intent=\(recordingIntent.traceName)")
            if let realtimeTranscriptionSession = usableRealtimeTranscriptionSession {
                do {
                    if settingsStore.sttProvider == .typefluxOfficial,
                       sttRouter.usesTypefluxOfficialCloudLocalRace {
                        rawTranscribedText = try await sttRouter.transcribeWithTypefluxOfficialCloudPriority(
                            audioFile: audioFile,
                            onUpdate: { _ in },
                            diagnosticsRecorder: asrRaceDiagnosticsRecorder
                        ) {
                            try await realtimeTranscriptionSession.finish()
                        }
                    } else {
                        rawTranscribedText = try await realtimeTranscriptionSession.finish()
                    }
                } catch {
                    if Self.shouldUseRecordingPreviewOnTranscriptionFailure(error),
                       !fallbackPreviewText.isEmpty {
                        NetworkDebugLogger.logError(
                            context: "Realtime STT session failed; using recording preview text",
                            error: error
                        )
                        rawTranscribedText = ""
                    } else {
                        NetworkDebugLogger.logError(
                            context: "Realtime STT session failed; falling back to recorded audio",
                            error: error
                        )
                        rawTranscribedText = try await sttRouter.transcribeStream(
                            audioFile: audioFile,
                            scenario: cloudScenario,
                            optimize: !shouldRewriteTranscript,
                            diagnosticsRecorder: asrRaceDiagnosticsRecorder
                        ) { _ in }
                    }
                }
            } else if canMergeWithLLM,
                      let resolvedPersonaPrompt = personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !resolvedPersonaPrompt.isEmpty {
                let mergedResult = try await performMergedCloudTranscription(
                    audioFile: audioFile,
                    personaPrompt: resolvedPersonaPrompt,
                    personaID: personaID,
                    selectionSnapshot: selectionSnapshot,
                    cloudScenario: cloudScenario,
                    sessionID: sessionID
                )
                rawTranscribedText = mergedResult.transcript
                mergedLLMResult = mergedResult.rewritten
                mergedLLMStartedAt = mergedResult.llmStartedAt
                mergedLLMFirstOutputAt = mergedResult.llmFirstOutputAt
                mergedLLMCompletedAt = mergedResult.llmCompletedAt
            } else {
                do {
                    rawTranscribedText = try await sttRouter.transcribeStream(
                        audioFile: audioFile,
                        scenario: cloudScenario,
                        optimize: !shouldRewriteTranscript,
                        diagnosticsRecorder: asrRaceDiagnosticsRecorder
                    ) { _ in }
                } catch {
                    guard Self.shouldUseRecordingPreviewOnTranscriptionFailure(error),
                          !fallbackPreviewText.isEmpty
                    else {
                        throw error
                    }
                    NetworkDebugLogger.logError(
                        context: "Final STT failed; using recording preview text",
                        error: error
                    )
                    rawTranscribedText = ""
                }
            }
            if let asrRaceDiagnostics = asrRaceDiagnosticsRecorder?.snapshot() {
                pipelineTiming.asrRace = asrRaceDiagnostics
                record.pipelineTiming = pipelineTiming
            }
            if let diagnosticsProvider = usableRealtimeTranscriptionSession as?
                any RealtimeDiagnosticsProviding {
                let diagnostics = await diagnosticsProvider.diagnosticsSnapshot()
                pipelineTiming.merge(diagnostics)
                record.pipelineTiming = pipelineTiming
                saveHistoryRecord(record)
                logPipelineEvent("realtime-session-finished", for: record)
            }
            NetworkDebugLogger.logMessage(
                "[Ask Timing] transcription completed in \(Self.formatDurationSince(transcriptionStartedAt))"
            )

            try ensureProcessingIsActive(sessionID)
            var transcriptChoice = Self.preferredTranscript(
                rawTranscribedText: rawTranscribedText,
                recordingPreviewText: fallbackPreviewText
            )
            if transcriptChoice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               fallbackPreviewText.isEmpty,
               let lowEnergyRetryAudioFile {
                markDictationLowEnergyRetry(recordID: record.id)
                NetworkDebugLogger.logMessage(
                    "[Transcription] empty result; retrying low-energy audio once"
                )
                do {
                    let retryText = try await sttRouter.transcribeStream(
                        audioFile: lowEnergyRetryAudioFile,
                        scenario: cloudScenario,
                        optimize: !shouldRewriteTranscript,
                        profile: .lowEnergyRetry,
                        diagnosticsRecorder: asrRaceDiagnosticsRecorder
                    ) { _ in }
                    if !retryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rawTranscribedText = retryText
                        mergedLLMResult = nil
                        transcriptChoice = Self.preferredTranscript(
                            rawTranscribedText: retryText,
                            recordingPreviewText: fallbackPreviewText
                        )
                    }
                } catch {
                    NetworkDebugLogger.logError(
                        context: "Low-energy transcription retry failed",
                        error: error
                    )
                }
            }
            let transcribedText = transcriptChoice.text
            if transcriptChoice.reason == .emptyFinalUsedPreview {
                NetworkDebugLogger.logMessage(
                    "[Transcription] using recording preview text because final transcription was empty"
                )
            } else if transcriptChoice.reason == .finalWasPreviewSuffix {
                NetworkDebugLogger.logMessage(
                    """
                    [Transcription] using recording preview text because realtime final appears truncated
                    finalLength: \(rawTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines).count)
                    previewLength: \(fallbackPreviewText.count)
                    """
                )
            }
            pipelineTiming.transcriptionCompletedAt = mergedLLMStartedAt ?? Date()
            pipelineTiming.llmProcessingStartedAt = mergedLLMStartedAt
            pipelineTiming.llmFirstOutputAt = mergedLLMFirstOutputAt
            pipelineTiming.llmProcessingCompletedAt = mergedLLMCompletedAt
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
                reportDictationTerminal(
                    record: record,
                    forcedFailure: (stage: "transcription", kind: "model_empty_result")
                )

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.appState.setStatus(.idle)
                        self.overlayController.showNotice(message: L("workflow.transcription.noSpeech"))
                    }
                }
                return
            }

            let detachedAgentExecution: Bool
            if isAskSelectionFlow, let askContextText, !askContextText.isEmpty {
                detachedAgentExecution = try await processAskFlowWithSelection(
                    transcribedText: transcribedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming
                )
            } else if recordingIntent == .askSelection {
                detachedAgentExecution = try await processAskFlowWithoutSelection(
                    transcribedText: transcribedText,
                    askContextText: askContextText,
                    personaPrompt: personaPrompt,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming
                )
            } else if shouldRewriteTranscript {
                detachedAgentExecution = false
                try await processPersonaRewriteFlow(
                    transcribedText: transcribedText,
                    personaPrompt: personaPrompt ?? "",
                    personaID: personaID,
                    selectionSnapshot: selectionSnapshot,
                    inputContext: inputContext,
                    multimodalHandlesPersona: multimodalHandlesPersona && !hasInputContext,
                    mergedLLMResult: mergedLLMResult,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming
                )
            } else {
                detachedAgentExecution = false
                try await processDictationFlow(
                    transcribedText: transcribedText,
                    selectionSnapshot: selectionSnapshot,
                    sessionID: sessionID,
                    record: &record,
                    pipelineTiming: &pipelineTiming
                )
            }

            if detachedAgentExecution {
                return
            }

            try ensureProcessingIsActive(sessionID)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-completed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)
            enforceHistoryRetentionPolicy()
            if await shouldShowTypefluxCloudASRLoginFallbackNotice() {
                let isAlreadyPreservingNotice = await MainActor.run {
                    self.shouldPreserveLLMConfigurationNotice
                }
                if !isAlreadyPreservingNotice {
                    await presentLLMNotConfigured(.notConfigured(reason: .cloudNotLoggedIn))
                }
            }
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
                            self.overlayController.showResultDialog(
                                title: L("workflow.result.copyTitle"),
                                message: finalText
                            )
                        }
                    } else {
                        if self.shouldPreserveLLMConfigurationNotice {
                            self.shouldPreserveLLMConfigurationNotice = false
                        } else {
                            self.overlayController.dismissSoon()
                        }
                    }
                }
            }
        } catch let error as LLMConfigurationError {
            mergeASRRaceDiagnostics(from: asrRaceDiagnosticsRecorder, into: &record)
            let message = error.localizedDescription
            ErrorLogStore.shared.log("Processing failed: \(message)")
            markFailure(&record, message: message)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-failed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)
            enforceHistoryRetentionPolicy()
        } catch let error as TypefluxCloudLoginRequiredError {
            mergeASRRaceDiagnostics(from: asrRaceDiagnosticsRecorder, into: &record)
            let message = error.localizedDescription
            ErrorLogStore.shared.log("Processing skipped because Typeflux Cloud login is required: \(message)")
            markFailure(&record, message: message)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-failed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)
            enforceHistoryRetentionPolicy()
            let shouldPresentLogin = await MainActor.run {
                guard self.processingSessionID == sessionID else { return false }
                self.lastRetryableFailureRecord = nil
                self.appState.setStatus(.failed(message: message))
                return true
            }
            if shouldPresentLogin {
                await presentTypefluxCloudLoginRequired()
            }
        } catch is CancellationError {
            mergeASRRaceDiagnostics(from: asrRaceDiagnosticsRecorder, into: &record)
            markCancelled(&record)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-cancelled", for: record)
            discardDictationAnalytics(recordID: record.id)
            enforceHistoryRetentionPolicy()
        } catch {
            mergeASRRaceDiagnostics(from: asrRaceDiagnosticsRecorder, into: &record)
            if shouldTreatAsSkippedSpeechInput(error: error, audioFile: audioFile) {
                record.transcriptionStatus = .skipped
                record.processingStatus = .skipped
                record.applyStatus = .skipped
                record.applyMessage = L("workflow.transcription.emptySkipped")
                record.errorMessage = nil
                saveHistoryRecord(record)
                reportDictationTerminal(
                    record: record,
                    forcedFailure: (stage: "transcription", kind: "no_speech")
                )

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

            if let loginRequiredError = TypefluxCloudLoginRequiredError.fromError(error) {
                let message = loginRequiredError.localizedDescription
                ErrorLogStore.shared.log("Processing skipped because Typeflux Cloud login is required: \(message)")
                markFailure(&record, message: message)
                saveHistoryRecord(record)
                logPipelineEvent("pipeline-failed", for: record)
                UsageStatsStore.shared.recordSession(record: record)
                reportDictationTerminal(record: record)
                enforceHistoryRetentionPolicy()
                let shouldPresentLogin = await MainActor.run {
                    guard self.processingSessionID == sessionID else { return false }
                    self.lastRetryableFailureRecord = nil
                    self.appState.setStatus(.failed(message: message))
                    return true
                }
                if shouldPresentLogin {
                    await presentTypefluxCloudLoginRequired()
                }
                return
            }

            let msg = "Processing failed: \(error.localizedDescription)"
            ErrorLogStore.shared.log(msg)
            markFailure(&record, message: msg)
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-failed", for: record)
            UsageStatsStore.shared.recordSession(record: record)
            reportDictationTerminal(record: record)
            enforceHistoryRetentionPolicy()
            if let billingError = TypefluxCloudBillingError.fromError(error) {
                let shouldPresentBilling = await MainActor.run {
                    guard self.processingSessionID == sessionID else { return false }
                    self.lastRetryableFailureRecord = nil
                    let subscription = AuthState.shared.subscription
                    self.appState.setStatus(.failed(message: billingError.title(
                        hasPaidSubscription: subscription.hasPaidSubscription,
                        billingEnabled: subscription.billingEnabled
                    )))
                    return true
                }
                if shouldPresentBilling {
                    await presentCloudBillingError(billingError)
                }
                return
            }
            let retryableFailureRecord = record.audioFilePath == nil ? nil : record

            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.lastRetryableFailureRecord = retryableFailureRecord
                    if ServerConnectivityFailure.matches(error) {
                        self.soundEffectPlayer.play(.tip)
                        self.appState.setStatus(.idle)
                        self.overlayController.showPassiveNotice(
                            message: L("workflow.transcription.serverUnavailableNotice")
                        )
                    } else {
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
    }

    static func preferredTranscript(
        rawTranscribedText: String,
        recordingPreviewText: String
    ) -> (text: String, reason: TranscriptChoiceReason) {
        let normalizedRawTranscript = rawTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPreviewText = recordingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fallbackPreviewText.isEmpty else {
            return (rawTranscribedText, .raw)
        }
        guard !normalizedRawTranscript.isEmpty else {
            return (fallbackPreviewText, .emptyFinalUsedPreview)
        }
        guard fallbackPreviewText.count > normalizedRawTranscript.count,
              fallbackPreviewText.hasSuffix(normalizedRawTranscript)
        else {
            return (rawTranscribedText, .raw)
        }

        return (fallbackPreviewText, .finalWasPreviewSuffix)
    }

    enum TranscriptChoiceReason: Equatable {
        case raw
        case emptyFinalUsedPreview
        case finalWasPreviewSuffix
    }

    static func shouldUseRecordingPreviewOnTranscriptionFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("no speech")
            || message.contains("no transcription")
            || message.contains("empty transcript")
            || message.contains("empty transcription")
            || message.contains("silent audio")
            || message.contains("silence")
            || message.contains("socket is not connected")
            || message.contains("socket was not connected")
            || message.contains("not connected")
    }

    private func processAskFlowWithSelection(
        transcribedText: String,
        askContextText: String,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming
    ) async throws -> Bool {
        NetworkDebugLogger.logMessage(
            """
            [Ask Flow] selected-text context
            snapshot: \(askSelectionSnapshotSummary(selectionSnapshot))
            selectedTextLength: \(askContextText.count)
            instruction: \(transcribedText)
            """
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
                pipelineTiming: &pipelineTiming
            )
            return true
        }

        let askDecisionResult: AskSelectionDecisionResult
        do {
            askDecisionResult = try await decideAskSelection(
                selectedText: askContextText,
                spokenInstruction: transcribedText,
                personaPrompt: personaPrompt,
                editableTarget: askEditableTargetContext(for: selectionSnapshot),
                appSystemContext: AppSystemContext(snapshot: selectionSnapshot),
                sessionID: sessionID
            )
        } catch let error as LLMConfigurationError {
            completeAskFlowAfterLLMConfigurationFallback(
                error: error,
                record: &record,
                pipelineTiming: &pipelineTiming
            )
            return false
        }
        try await applyLegacyAskDecision(
            askDecisionResult,
            question: transcribedText,
            selectedText: askContextText,
            selectionSnapshot: selectionSnapshot,
            record: &record,
            pipelineTiming: &pipelineTiming,
            sessionID: sessionID
        )
        return false
    }

    private func processAgentAskFlowWithSelection(
        transcribedText: String,
        askContextText: String,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming _: inout HistoryPipelineTiming
    ) async throws {
        try ensureProcessingIsActive(sessionID)
        let jobID = UUID()
        launchDetachedAgentAskTask(
            jobID: jobID,
            recordID: record.id,
            transcribedText: transcribedText,
            selectedText: askContextText,
            personaPrompt: personaPrompt,
            sessionID: sessionID,
            selectionSnapshot: selectionSnapshot,
            selectedTextForAnswerPresentation: askContextText
        )
        handleDetachedAgentLaunch()
    }

    private func processAgentAskFlowWithoutSelection(
        transcribedText: String,
        askContextText: String?,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming _: inout HistoryPipelineTiming
    ) async throws {
        try ensureProcessingIsActive(sessionID)
        let jobID = UUID()
        launchDetachedAgentAskTask(
            jobID: jobID,
            recordID: record.id,
            transcribedText: transcribedText,
            selectedText: nil,
            personaPrompt: personaPrompt,
            sessionID: sessionID,
            selectionSnapshot: selectionSnapshot,
            selectedTextForAnswerPresentation: askContextText
        )
        handleDetachedAgentLaunch()
    }

    private func processAskFlowWithoutSelection(
        transcribedText: String,
        askContextText: String?,
        personaPrompt: String?,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming
    ) async throws -> Bool {
        NetworkDebugLogger.logMessage(
            """
            [Ask Flow] no selected-text context
            snapshot: \(askSelectionSnapshotSummary(selectionSnapshot))
            instruction: \(transcribedText)
            """
        )
        record.processingStatus = .running
        saveHistoryRecord(record)

        await MainActor.run { self.overlayController.transitionToLLMPhase() }
        pipelineTiming.llmProcessingStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        saveHistoryRecord(record)
        logPipelineEvent("llm-processing-started", for: record)

        if settingsStore.agentFrameworkEnabled, settingsStore.agentEnabled {
            let agentLaunchStartedAt = Date()
            try await processAgentAskFlowWithoutSelection(
                transcribedText: transcribedText,
                askContextText: askContextText,
                personaPrompt: personaPrompt,
                selectionSnapshot: selectionSnapshot,
                sessionID: sessionID,
                record: &record,
                pipelineTiming: &pipelineTiming
            )
            NetworkDebugLogger.logMessage(
                "[Ask Timing] detached agent ask launched in \(Self.formatDurationSince(agentLaunchStartedAt))"
            )
            return true
        }

        let askDecisionResult: AskSelectionDecisionResult
        let askDecisionStartedAt = Date()
        do {
            askDecisionResult = try await decideAskSelection(
                selectedText: askContextText,
                spokenInstruction: transcribedText,
                personaPrompt: personaPrompt,
                editableTarget: askEditableTargetContext(for: selectionSnapshot),
                appSystemContext: AppSystemContext(snapshot: selectionSnapshot),
                sessionID: sessionID
            )
        } catch let error as LLMConfigurationError {
            completeAskFlowAfterLLMConfigurationFallback(
                error: error,
                record: &record,
                pipelineTiming: &pipelineTiming
            )
            return false
        }
        NetworkDebugLogger.logMessage(
            "[Ask Timing] ask decision completed in \(Self.formatDurationSince(askDecisionStartedAt))"
        )
        try await applyLegacyAskDecision(
            askDecisionResult,
            question: transcribedText,
            selectedText: askContextText,
            selectionSnapshot: selectionSnapshot,
            record: &record,
            pipelineTiming: &pipelineTiming,
            sessionID: sessionID
        )
        return false
    }

    private func completeAskFlowAfterLLMConfigurationFallback(
        error: LLMConfigurationError,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming
    ) {
        ErrorLogStore.shared.log(
            "Ask flow skipped because LLM configuration is unavailable: \(error.localizedDescription)"
        )
        pipelineTiming.llmProcessingCompletedAt = Date()
        record.pipelineTiming = pipelineTiming
        record.processingStatus = .skipped
        record.applyStatus = .skipped
        record.applyMessage = L("workflow.llmNotConfigured.askSkipped")
    }

    private func launchDetachedAgentAskTask(
        jobID: UUID,
        recordID: UUID,
        transcribedText: String,
        selectedText: String?,
        personaPrompt: String?,
        sessionID: UUID,
        selectionSnapshot: TextSelectionSnapshot,
        selectedTextForAnswerPresentation: String?
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { [weak self] in
                    guard let self else { return }
                    await self.agentExecutionRegistry.finish(jobID: jobID)
                    await MainActor.run {
                        self.finishDetachedAskOverlayIfStillProcessing(sessionID: sessionID)
                    }
                }
            }

            do {
                let execution = try await runAskAgent(
                    selectedText: selectedText,
                    spokenInstruction: transcribedText,
                    personaPrompt: personaPrompt,
                    jobID: jobID,
                    appSystemContext: AppSystemContext(snapshot: selectionSnapshot)
                )
                await completeDetachedAgentAskTask(
                    execution: execution,
                    recordID: recordID,
                    sessionID: sessionID,
                    transcribedText: transcribedText,
                    selectionSnapshot: selectionSnapshot,
                    selectedTextForAnswerPresentation: selectedTextForAnswerPresentation
                )
            } catch let error as LLMConfigurationError {
                guard var record = historyStore.record(id: recordID) else { return }
                var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()
                completeAskFlowAfterLLMConfigurationFallback(
                    error: error,
                    record: &record,
                    pipelineTiming: &pipelineTiming
                )
                saveHistoryRecord(record)
                logPipelineEvent("pipeline-completed", for: record)
                UsageStatsStore.shared.recordSession(record: record)
                reportDictationTerminal(record: record)
                enforceHistoryRetentionPolicy()
                await MainActor.run {
                    guard self.processingSessionID == sessionID else { return }
                    self.finishDetachedAskOverlay(dismiss: true)
                }
            } catch is CancellationError {
                await failDetachedAgentAskTask(
                    recordID: recordID,
                    sessionID: sessionID,
                    errorMessage: L("workflow.cancel.userCancelled"),
                    treatAsCancellation: true
                )
            } catch {
                let message = "Processing failed: \(error.localizedDescription)"
                ErrorLogStore.shared.log(message)
                await failDetachedAgentAskTask(
                    recordID: recordID,
                    sessionID: sessionID,
                    errorMessage: message,
                    treatAsCancellation: false
                )
            }
        }

        Task {
            await agentExecutionRegistry.register(task, for: jobID)
        }
    }

    private func completeDetachedAgentAskTask(
        execution: AskAgentExecutionResult,
        recordID: UUID,
        sessionID: UUID,
        transcribedText: String,
        selectionSnapshot: TextSelectionSnapshot,
        selectedTextForAnswerPresentation: String?
    ) async {
        guard var record = historyStore.record(id: recordID) else { return }

        var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()
        pipelineTiming.llmProcessingCompletedAt = Date()
        record.pipelineTiming = pipelineTiming
        logPipelineEvent("llm-processing-completed", for: record)

        switch Self.askWithoutSelectionAgentDisposition(for: execution.result) {
        case let .answer(text):
            record.mode = .askAnswer

            var openCCResult: String?
            let finalAnswer: String
            if let config = settingsStore.effectiveOutputOpenCCConfig {
                let converted = await outputPostProcessor.process(text)
                if converted != text {
                    openCCResult = converted
                }
                finalAnswer = converted
                record.openCCConfig = config
            } else {
                finalAnswer = text
            }

            record.personaResultText = text
            record.openCCResultText = openCCResult
            record.postProcessedText = finalAnswer
            record.processingStatus = .succeeded
            record.applyStatus = .running
            saveHistoryRecord(record)

            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            await MainActor.run {
                if self.processingSessionID == sessionID {
                    self.finishDetachedAskOverlay(dismiss: false)
                }
                self.presentAskAnswer(
                    question: transcribedText,
                    selectedText: selectedTextForAnswerPresentation,
                    answerMarkdown: finalAnswer
                )
            }
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = L("workflow.ask.answerPresented")
            recordDictationApplyAnalytics(recordID: record.id, outcome: .presentedInDialog)

        case let .insert(text):
            record.mode = .editSelection
            record.processingStatus = .succeeded
            record.applyStatus = .running
            saveHistoryRecord(record)

            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            let (outcome, processedText) = await applyDetachedAgentEditResult(
                text,
                selectionSnapshot: selectionSnapshot
            )
            record.selectionEditedText = text
            record.postProcessedText = processedText
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = outcome.message
            recordDictationApplyAnalytics(recordID: record.id, outcome: outcome)

            await MainActor.run {
                guard self.processingSessionID == sessionID else { return }
                self.finishDetachedAskOverlay(dismiss: outcome == .inserted)
            }
        }

        saveHistoryRecord(record)
        logPipelineEvent("pipeline-completed", for: record)
        UsageStatsStore.shared.recordSession(record: record)
        reportDictationTerminal(record: record)
        enforceHistoryRetentionPolicy()
        _ = execution.jobID
    }

    private func failDetachedAgentAskTask(
        recordID: UUID,
        sessionID: UUID,
        errorMessage: String,
        treatAsCancellation: Bool
    ) async {
        guard var record = historyStore.record(id: recordID) else { return }

        if treatAsCancellation {
            markCancelled(&record)
            record.errorMessage = errorMessage
            saveHistoryRecord(record)
            logPipelineEvent("pipeline-cancelled", for: record)
            enforceHistoryRetentionPolicy()
            await MainActor.run {
                guard self.processingSessionID == sessionID else { return }
                self.finishDetachedAskOverlay(dismiss: true)
            }
            return
        }

        markFailure(&record, message: errorMessage)
        saveHistoryRecord(record)
        logPipelineEvent("pipeline-failed", for: record)
        UsageStatsStore.shared.recordSession(record: record)
        reportDictationTerminal(record: record)
        enforceHistoryRetentionPolicy()

        await MainActor.run {
            guard self.processingSessionID == sessionID else { return }
            self.lastRetryableFailureRecord = nil
            self.soundEffectPlayer.play(.error)
            self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
            self.overlayController.showFailure(message: errorMessage)
            self.overlayController.dismiss(after: 3.0)
        }
    }

    @MainActor
    private func finishDetachedAskOverlay(dismiss: Bool) {
        lastRetryableFailureRecord = nil
        appState.setStatus(.idle)
        if dismiss {
            overlayController.dismissSoon()
        }
    }

    @MainActor
    private func finishDetachedAskOverlayIfStillProcessing(sessionID: UUID) {
        guard processingSessionID == sessionID else { return }
        if appState.status == .processing {
            lastRetryableFailureRecord = nil
            appState.setStatus(.idle)
        }
        overlayController.dismissProcessingIfVisible()
    }

    /// Thread-safe accumulator for LLM streaming chunks captured in @Sendable closures.
    private final class LLMStreamBuffer: @unchecked Sendable {
        private var _text = ""
        private var _startedAt: Date?
        private var _firstOutputAt: Date?
        private let lock = NSLock()

        func append(_ chunk: String) {
            lock.lock()
            if _firstOutputAt == nil, !chunk.isEmpty {
                _firstOutputAt = Date()
            }
            _text += chunk
            lock.unlock()
        }

        func markStarted() {
            lock.lock()
            _startedAt = _startedAt ?? Date()
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return _text
        }

        var timing: (startedAt: Date?, firstOutputAt: Date?) {
            lock.lock()
            defer { lock.unlock() }
            return (_startedAt, _firstOutputAt)
        }
    }

    /// Builds an `ASRLLMConfig` by constructing the same prompts the LLM service would
    /// use for a `rewriteTranscript` request, substituting `{{transcript}}` as a
    /// placeholder for the actual transcript text.
    private func buildASRLLMConfig(
        personaPrompt: String,
        personaID: UUID?,
        selectionSnapshot: TextSelectionSnapshot
    ) -> ASRLLMConfig {
        let placeholderRequest = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "{{transcript}}",
            spokenInstruction: nil,
            personaPrompt: personaPrompt,
            personaID: personaID,
            appSystemContext: AppSystemContext(snapshot: selectionSnapshot),
            vocabularyTerms: VocabularyStore.activeTerms()
        )
        let prompts = PromptCatalog.rewritePrompts(for: placeholderRequest)
        var effectiveSystemPrompt = PromptCatalog.appendLanguageResolutionPolicy(
            to: prompts.system
        )
        let effectiveUserPrompt = PromptCatalog.appendUserEnvironmentContext(
            to: prompts.user,
            appLanguage: settingsStore.appLanguage
        )
        if let appContext = placeholderRequest.appSystemContext {
            let extra = PromptCatalog.appSpecificSystemContext(appContext)
            if !extra.isEmpty {
                effectiveSystemPrompt = PromptCatalog.appendAdditionalSystemContext(
                    extra,
                    to: effectiveSystemPrompt
                )
            }
        }
        return ASRLLMConfig(
            systemPrompt: effectiveSystemPrompt,
            userPromptTemplate: effectiveUserPrompt,
            personaID: personaID
        )
    }

    /// Performs transcription and, when the server supports it, an inline LLM persona
    /// rewrite over the same WebSocket connection.  Overlay updates are managed here so
    /// `processPersonaRewriteFlow` can treat the result identically to a normal rewrite.
    private func performMergedCloudTranscription(
        audioFile: AudioFile,
        personaPrompt: String,
        personaID: UUID?,
        selectionSnapshot: TextSelectionSnapshot,
        cloudScenario: TypefluxCloudScenario,
        sessionID: UUID
    ) async throws -> MergedCloudTranscriptionResult {
        let llmConfig = buildASRLLMConfig(
            personaPrompt: personaPrompt,
            personaID: personaID,
            selectionSnapshot: selectionSnapshot
        )
        let llmBuffer = LLMStreamBuffer()
        let suppressStreamingPreview = shouldSuppressPostRecordingStreamingPreviewForCurrentSTTProvider

        let result = try await sttRouter.transcribeStreamWithLLMRewrite(
            audioFile: audioFile,
            llmConfig: llmConfig,
            scenario: cloudScenario,
            onASRUpdate: { _ in },
            onLLMStart: { [weak self] in
                guard let self else { return }
                llmBuffer.markStarted()
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.overlayController.transitionToLLMPhase()
                    }
                }
            },
            onLLMChunk: { [weak self] chunk in
                guard let self else { return }
                guard !suppressStreamingPreview else { return }
                llmBuffer.append(chunk)
                let current = llmBuffer.text
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.overlayController.updateStreamingText(current)
                    }
                }
            }
        )
        let timing = llmBuffer.timing
        return MergedCloudTranscriptionResult(
            transcript: result.transcript,
            rewritten: result.rewritten,
            llmStartedAt: timing.startedAt,
            llmFirstOutputAt: timing.firstOutputAt,
            llmCompletedAt: result.rewritten == nil ? nil : Date()
        )
    }

    private func processPersonaRewriteFlow(
        transcribedText: String,
        personaPrompt: String,
        personaID: UUID?,
        selectionSnapshot: TextSelectionSnapshot,
        inputContext: InputContextSnapshot?,
        multimodalHandlesPersona: Bool,
        mergedLLMResult: String? = nil,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming
    ) async throws {
        record.mode = Self.hasRewritePersona(personaPrompt) ? .personaRewrite : .dictation

        if multimodalHandlesPersona {
            record.processingStatus = .succeeded
            record.applyStatus = .running

            try ensureProcessingIsActive(sessionID)
            pipelineTiming.applyStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            let result = await applyTranscribedText(
                transcribedText,
                selectionSnapshot: selectionSnapshot,
                record: &record
            )
            record.personaResultText = transcribedText
            record.openCCResultText = result.openCCResult
            record.postProcessedText = result.finalResult
            pipelineTiming.applyCompletedAt = Date()
            record.pipelineTiming = pipelineTiming
            record.applyStatus = .succeeded
            record.applyMessage = result.outcome.message
            recordDictationApplyAnalytics(recordID: record.id, outcome: result.outcome)
            saveHistoryRecord(record)
            return
        }

        record.processingStatus = .running
        saveHistoryRecord(record)

        let rewriteOutput: String
        var billingFallbackError: TypefluxCloudBillingError?
        if let merged = mergedLLMResult {
            // Rewrite already completed as part of the merged ASR+LLM WebSocket session.
            // The overlay was updated with streaming chunks during transcription, so we
            // only need to record the timing and move on.
            pipelineTiming.llmProcessingStartedAt = pipelineTiming.llmProcessingStartedAt
                ?? pipelineTiming.transcriptionCompletedAt
                ?? Date()
            pipelineTiming.llmProcessingCompletedAt = pipelineTiming.llmProcessingCompletedAt ?? Date()
            if let startedAt = pipelineTiming.llmProcessingStartedAt,
               let completedAt = pipelineTiming.llmProcessingCompletedAt {
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: startedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: nil,
                    outcome: .completed,
                    usedTranscriptFallback: false
                )
            }
            record.pipelineTiming = pipelineTiming
            rewriteOutput = merged
            logPipelineEvent("llm-processing-completed", for: record)
        } else {
            await MainActor.run { self.overlayController.transitionToLLMPhase() }
            pipelineTiming.llmProcessingStartedAt = Date()
            record.pipelineTiming = pipelineTiming
            saveHistoryRecord(record)
            logPipelineEvent("llm-processing-started", for: record)
            let llmStartedAt = pipelineTiming.llmProcessingStartedAt ?? Date()
            let llmTimeoutMilliseconds = LLMProcessingOutcomeDiagnostics.clampedMilliseconds(
                for: llmTimeoutAfterTranscription
            )

            do {
                let rewriteResult = try await generateRewrite(
                    request: LLMRewriteRequest(
                        mode: .rewriteTranscript,
                        sourceText: transcribedText,
                        spokenInstruction: nil,
                        personaPrompt: personaPrompt,
                        personaID: personaID,
                        appSystemContext: AppSystemContext(snapshot: selectionSnapshot),
                        inputContext: inputContext,
                        vocabularyTerms: VocabularyStore.activeTerms()
                    ),
                    sessionID: sessionID,
                    showsStreamingPreview: WorkflowOverlayPresentationPolicy
                        .shouldShowLLMStreamingPreviewAfterTranscription(),
                    timeout: llmTimeoutAfterTranscription
                )

                try ensureProcessingIsActive(sessionID)
                pipelineTiming.llmFirstOutputAt = rewriteResult.firstOutputAt
                pipelineTiming.llmProcessingCompletedAt = rewriteResult.completedAt
                pipelineTiming.llmRequestAttempts = rewriteResult.requestAttempts
                if rewriteResult.text.isEmpty {
                    ErrorLogStore.shared.log("Persona rewrite returned an empty response, using transcript as fallback")
                    rewriteOutput = transcribedText
                    pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                        startedAt: llmStartedAt,
                        completedAt: rewriteResult.completedAt,
                        timeoutMilliseconds: llmTimeoutMilliseconds,
                        outcome: .emptyResponseFallback,
                        usedTranscriptFallback: true
                    )
                } else {
                    rewriteOutput = rewriteResult.text
                    pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                        startedAt: llmStartedAt,
                        completedAt: rewriteResult.completedAt,
                        timeoutMilliseconds: llmTimeoutMilliseconds,
                        outcome: .completed,
                        usedTranscriptFallback: false
                    )
                }
                logPipelineEvent("llm-processing-completed", for: record)
            } catch is LLMRequestTimeoutError {
                // Timeout: insert transcript as fallback so the user isn't left empty-handed
                // after waiting the full timeout period. Log for diagnostics.
                ErrorLogStore.shared.log(
                    "Persona rewrite timed out after \(String(format: "%.2f", llmTimeoutAfterTranscription))s, using transcript as fallback"
                )
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .timedOutFallback,
                    usedTranscriptFallback: true
                )
                rewriteOutput = transcribedText
            } catch let error where Self.isServiceOverloadedError(error) {
                // Service overloaded (HTTP 529): all retries exhausted; insert transcript as
                // fallback so the user isn't left with an error dialog.
                ErrorLogStore.shared.log("LLM service overloaded after retries, using transcript as fallback")
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .serviceOverloadedFallback,
                    usedTranscriptFallback: true
                )
                rewriteOutput = transcribedText
            } catch let error as LLMConfigurationError {
                ErrorLogStore.shared.log(
                    "LLM configuration unavailable (\(error.localizedDescription)), using transcript as fallback"
                )
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .configurationUnavailableFallback,
                    usedTranscriptFallback: true
                )
                rewriteOutput = transcribedText
            } catch let error where TypefluxCloudBillingError.fromError(error) != nil {
                let billingError = TypefluxCloudBillingError.fromError(error)
                ErrorLogStore.shared.log(
                    "Typeflux Cloud billing requirement during persona rewrite, using transcript as fallback"
                )
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .billingFallback,
                    usedTranscriptFallback: true
                )
                rewriteOutput = transcribedText
                billingFallbackError = billingError
            } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .cancelled,
                    usedTranscriptFallback: false
                )
                record.pipelineTiming = pipelineTiming
                throw CancellationError()
            } catch {
                // Rewriting is optional for dictation: preserve the complete transcript
                // when the request fails, never a partially streamed rewrite.
                try ensureProcessingIsActive(sessionID)
                ErrorLogStore.shared.log("Persona rewrite request failed, using transcript as fallback")
                let completedAt = Date()
                pipelineTiming.llmProcessingCompletedAt = completedAt
                pipelineTiming.llmOutcome = LLMProcessingOutcomeDiagnostics(
                    startedAt: llmStartedAt,
                    completedAt: completedAt,
                    timeoutMilliseconds: llmTimeoutMilliseconds,
                    outcome: .requestFailedFallback,
                    usedTranscriptFallback: true
                )
                rewriteOutput = transcribedText
            }
        }

        record.pipelineTiming = pipelineTiming
        record.processingStatus = .succeeded
        record.applyStatus = .running
        saveHistoryRecord(record)

        try ensureProcessingIsActive(sessionID)
        pipelineTiming.applyStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        let result = await applyTranscribedText(rewriteOutput, selectionSnapshot: selectionSnapshot, record: &record)
        record.personaResultText = rewriteOutput
        record.openCCResultText = result.openCCResult
        record.postProcessedText = result.finalResult
        pipelineTiming.applyCompletedAt = Date()
        record.pipelineTiming = pipelineTiming
        record.applyStatus = .succeeded
        record.applyMessage = result.outcome.message
        recordDictationApplyAnalytics(recordID: record.id, outcome: result.outcome)
        saveHistoryRecord(record)

        if let billingFallbackError {
            await presentCloudBillingError(billingFallbackError)
        }
    }

    private func processDictationFlow(
        transcribedText: String,
        selectionSnapshot: TextSelectionSnapshot,
        sessionID: UUID,
        record: inout HistoryRecord,
        pipelineTiming: inout HistoryPipelineTiming
    ) async throws {
        record.mode = .dictation
        record.processingStatus = .skipped
        record.applyStatus = .running
        saveHistoryRecord(record)

        try ensureProcessingIsActive(sessionID)
        pipelineTiming.applyStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        let result = await applyTranscribedText(transcribedText, selectionSnapshot: selectionSnapshot, record: &record)
        record.transcriptText = transcribedText
        record.openCCResultText = result.openCCResult
        record.postProcessedText = result.finalResult
        pipelineTiming.applyCompletedAt = Date()
        record.pipelineTiming = pipelineTiming
        record.applyStatus = .succeeded
        record.applyMessage = result.outcome.message
        recordDictationApplyAnalytics(recordID: record.id, outcome: result.outcome)
    }

    static func isServiceOverloadedError(_ error: Error) -> Bool {
        (error as NSError).code == 529
    }

    static func hasRewritePersona(_ personaPrompt: String?) -> Bool {
        personaPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func shouldRewriteTranscript(
        personaPrompt: String?,
        inputContext: InputContextSnapshot?
    ) -> Bool {
        hasRewritePersona(personaPrompt) || inputContext?.hasContent == true
    }

    func shouldShowTypefluxCloudASRLoginFallbackNotice() async -> Bool {
        guard settingsStore.sttProvider == .typefluxOfficial else { return false }
        return await MainActor.run { !AuthState.shared.isLoggedIn }
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
        // If the agent is waiting for a clarification reply, cancel it too.
        dismissClarification()

        processingSessionID = UUID()
        processingTask?.cancel()
        processingTask = nil
        cancelProcessingWatchdog()
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
            discardDictationAnalytics(recordID: activeProcessingRecordID)
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

    func personaPrompt(for record: HistoryRecord) -> String? {
        switch record.mode {
        case .dictation, .editSelection, .personaRewrite, .askAnswer:
            record.personaPrompt ?? settingsStore.activePersonaPrompt
        }
    }

    func activePersonaPrompt(
        selectionSnapshot: TextSelectionSnapshot,
        inputContext: InputContextSnapshot?
    ) -> String? {
        guard let persona = activePersona(selectionSnapshot: selectionSnapshot, inputContext: inputContext) else {
            return nil
        }
        return settingsStore.resolvedPersonaPrompt(for: persona)
    }

    func activePersona(
        selectionSnapshot: TextSelectionSnapshot,
        inputContext: InputContextSnapshot?
    ) -> PersonaProfile? {
        settingsStore.effectivePersona(
            appName: inputContext?.appName ?? selectionSnapshot.processName,
            bundleIdentifier: inputContext?.bundleIdentifier ?? selectionSnapshot.bundleIdentifier
        )
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

    func askContextText(
        from snapshot: TextSelectionSnapshot,
        inputContext: InputContextSnapshot?
    ) -> String? {
        let snapshotText = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !snapshotText.isEmpty {
            return snapshotText
        }

        let inputContextSelectedText = inputContext?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return inputContextSelectedText.isEmpty ? nil : inputContextSelectedText
    }

    func shouldReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.canReplaceSelection
    }

    func shouldBypassTextInjection(for snapshot: TextSelectionSnapshot) -> Bool {
        if snapshot.source == "typeflux-native" {
            return false
        }

        if snapshot.source == "typeflux-ask-answer-window"
            || snapshot.source == "typeflux-non-text-window"
            || snapshot.source == "typeflux-owned-target" {
            return true
        }

        if snapshot.processID == getpid() {
            return !snapshot.isEditable
        }

        if snapshot.bundleIdentifier == Bundle.main.bundleIdentifier {
            return !snapshot.isEditable
        }

        return false
    }

    static func askWithoutSelectionAgentDisposition(for result: AskAgentResult) -> AskWithoutSelectionAgentDisposition {
        switch result {
        case let .answer(text):
            .answer(text)
        case let .edit(text):
            .insert(text)
        }
    }

    func hasAskSelectionContext(_ snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.hasAskSelectionContext
    }

    func canReplaceActiveSelection(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.canReplaceSelection
    }

    func dismissOverlayForExternalReplacement() async throws {
        await MainActor.run {
            overlayController.dismissImmediately()
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    func handleDetachedAgentLaunch() {
        activeProcessingRecordID = nil
        lastRetryableFailureRecord = nil
    }

    func shouldShowDialogForDetachedAgentEdit(using snapshot: TextSelectionSnapshot) -> Bool {
        hasAskSelectionContext(snapshot) && !shouldReplaceActiveSelection(for: snapshot)
    }

    func applyDetachedAgentEditResult(
        _ text: String,
        selectionSnapshot: TextSelectionSnapshot
    ) async -> (ApplyOutcome, String) {
        let replaceSelection = shouldReplaceActiveSelection(for: selectionSnapshot)
        let shouldShowResultDialog = shouldShowDialogForDetachedAgentEdit(using: selectionSnapshot)
        NetworkDebugLogger.logMessage(
            "[Apply Detached Agent Edit] hasSelection=\(selectionSnapshot.hasSelection) " +
                "isEditable=\(selectionSnapshot.isEditable) hasRange=\(selectionSnapshot.selectedRange != nil) " +
                "replaceSelection=\(replaceSelection) showResultDialog=\(shouldShowResultDialog)"
        )

        let processedText = await outputPostProcessor.process(text)
        if shouldShowResultDialog {
            presentResultDialog(title: L("workflow.result.copyTitle"), text: processedText)
            return (.presentedInDialog, processedText)
        }

        return await applyText(
            processedText,
            replace: replaceSelection,
            fallbackTitle: L("workflow.result.copyTitle"),
            targetSnapshot: selectionSnapshot
        )
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
            """
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

    private func mergeASRRaceDiagnostics(
        from recorder: ASRRaceDiagnosticsRecorder?,
        into record: inout HistoryRecord
    ) {
        guard let diagnostics = recorder?.snapshot() else { return }
        var timing = record.pipelineTiming ?? HistoryPipelineTiming()
        timing.asrRace = diagnostics
        record.pipelineTiming = timing
    }

    func saveHistoryRecord(_ record: HistoryRecord) {
        var record = record
        record.pipelineStats = record.pipelineTiming?.generatedStats() ?? record.pipelineStats
        historyStore.save(record: record)
    }

    func logPipelineEvent(_ event: String, for record: HistoryRecord) {
        guard let timing = record.pipelineTiming, timing.hasData else { return }

        let durations: [(String, Int?)] = [
            ("hotkey_to_first_audio_ms", timing.millisecondsBetween(timing.hotkeyDetectedAt, timing.firstAudioBufferAt)),
            ("hotkey_dispatch_ms", timing.millisecondsBetween(timing.hotkeyDetectedAt, timing.recordingWorkflowStartedAt)),
            (
                "recording_preparation_ms",
                timing.millisecondsBetween(timing.recordingWorkflowStartedAt, timing.audioEngineStartedAt)
            ),
            (
                "audio_engine_to_first_buffer_ms",
                timing.millisecondsBetween(timing.audioEngineStartedAt, timing.firstAudioBufferAt)
            ),
            ("stop_to_audio_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.audioFileReadyAt)),
            ("stt_ms", timing.millisecondsBetween(timing.transcriptionStartedAt, timing.transcriptionCompletedAt)),
            ("stop_to_stt_ms", timing.millisecondsBetween(timing.recordingStoppedAt, timing.transcriptionCompletedAt)),
            (
                "realtime_connect_ms",
                timing.millisecondsBetween(timing.realtimeSessionStartedAt, timing.realtimeConnectionReadyAt)
            ),
            (
                "realtime_audio_to_first_result_ms",
                timing.millisecondsBetween(
                    timing.realtimeFirstAudioSubmittedAt,
                    timing.realtimeFirstResultReceivedAt
                )
            ),
            (
                "realtime_ready_to_audio_ms",
                timing.millisecondsBetween(
                    timing.realtimeConnectionReadyAt,
                    timing.realtimeFirstAudioSubmittedAt
                )
            ),
            (
                "realtime_stop_to_final_ms",
                timing.millisecondsBetween(timing.realtimeFinishStartedAt, timing.realtimeFinalResultReceivedAt)
            ),
            (
                "realtime_finish_ms",
                timing.millisecondsBetween(timing.realtimeFinishStartedAt, timing.realtimeFinishCompletedAt)
            ),
            (
                "transcript_to_llm_ms",
                timing.millisecondsBetween(timing.transcriptionCompletedAt, timing.llmProcessingStartedAt)
            ),
            ("llm_ms", timing.millisecondsBetween(timing.llmProcessingStartedAt, timing.llmProcessingCompletedAt)),
            ("llm_ttft_ms", timing.millisecondsBetween(timing.llmProcessingStartedAt, timing.llmFirstOutputAt)),
            ("apply_ms", timing.millisecondsBetween(timing.applyStartedAt, timing.applyCompletedAt)),
            (
                "end_to_end_ms",
                timing.millisecondsBetween(
                    timing.recordingStoppedAt,
                    timing.applyCompletedAt ?? timing.llmProcessingCompletedAt ?? timing.transcriptionCompletedAt
                )
            )
        ]

        let durationSummary = durations
            .compactMap { label, value in value.map { "\(label)=\($0)" } }
            .joined(separator: " ")

        NetworkDebugLogger.logMessage(
            "[Voice Pipeline] event=\(event) record_id=\(record.id.uuidString) mode=\(record.mode.rawValue) \(durationSummary)"
                .trimmingCharacters(in: .whitespaces)
        )
    }

    func enforceHistoryRetentionPolicy() {
        guard let days = settingsStore.historyRetentionPolicy.days else { return }
        historyStore.purge(olderThanDays: days)
    }
}

// swiftlint:enable multiple_closures_with_trailing_closure
// swiftlint:enable file_length function_body_length function_parameter_count line_length
