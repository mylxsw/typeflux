import AVFoundation
import AppKit
import AudioToolbox
@testable import Typeflux
import XCTest

final class WorkflowControllerProcessingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
    }

    override func tearDown() {
        KeychainTokenStore.clearAll()
        KeychainTokenStore.useInMemoryStoreForTesting = false
        super.tearDown()
    }

    @MainActor
    func testComposerHotkeyRoutingKeepsFnLockAndCancelsOwnedSession() async throws {
        let controller = makeWorkflowController()
        XCTAssertFalse(controller.routeComposerVoice(.release(ProcessInfo.processInfo.systemUptime)))
        let voice = AskVoiceInput(), recorder = AskTestVoiceRecorder()
        voice.recorder = recorder; controller.composerVoiceInput = voice
        XCTAssertFalse(controller.routeComposerVoice(.activationTap(ProcessInfo.processInfo.systemUptime)))
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        editor.voice = voice
        let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor; window.makeFirstResponder(editor)
        defer { window.close() }
        XCTAssertTrue(voice.begin(in: editor))
        for _ in 0..<100 where recorder.starts == 0 { try await Task.sleep(for: .milliseconds(2)) }
        controller.handlePressEnded()
        XCTAssertEqual(voice.phase, .listening)
        controller.handleActivationTap()
        XCTAssertEqual(voice.phase, .listening)
        controller.cancelRecording()
        for _ in 0..<100 where voice.isOccupied { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(voice.isOccupied)
        XCTAssertEqual(recorder.cancels, 1)
        XCTAssertTrue(voice.begin(in: editor))
        controller.finishRecordingFromCurrentMode()
        for _ in 0..<100 where voice.isOccupied { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertTrue(voice.begin(in: editor))
        controller.handlePressBegan(intent: .dictation, startLocked: false)
        for _ in 0..<100 where voice.isOccupied { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(recorder.stops, 2)
    }

    @MainActor
    func testComposerRecordingUsesConfiguredSTTAndNeverInjectsOrShowsOverlay() async throws {
        let recorder = MockProcessingAudioRecorder()
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector, audioRecorder: recorder,
            sttTranscriber: MockProcessingTranscriber(transcript: " hello "), configureSettings: { $0.sttProvider = .appleSpeech }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.appState.status, .recording)
        let text = try await service.transcribe()
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        XCTAssertEqual(controller.appState.status, .idle)
        XCTAssertEqual(recorder.startCallCount, 1)
        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertTrue(injector.insertedTexts.isEmpty)
        await service.cancel()
        XCTAssertEqual(recorder.stopCallCount, 1)
    }

    @MainActor
    func testComposerMouseHoldRunsProductionRecordingAdapterAndFillsEditor() async throws {
        let recorder = MockProcessingAudioRecorder()
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector, audioRecorder: recorder,
            sttTranscriber: MockProcessingTranscriber(transcript: " held speech "),
            configureSettings: { $0.sttProvider = .appleSpeech }, hasPaidCloudSubscription: { true })
        let voice = AskVoiceInput()
        voice.recorder = WorkflowComposerRecording(controller, isAppBundle: { true })
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.voice = voice
        let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFront(nil)
        window.makeFirstResponder(editor)
        defer { window.close() }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.sendEvent(try event(.leftMouseDown))
        for _ in 0..<200 where recorder.startCallCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.startCallCount, 1, "Recording must start before the mouse is released")
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(voice.phase, .listening)
        NSApp.sendEvent(try event(.leftMouseUp))
        for _ in 0..<400 where voice.isOccupied { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(voice.isOccupied)
        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertEqual(editor.string, "held speech")
        XCTAssertEqual(controller.appState.status, .idle)
        XCTAssertTrue(injector.insertedTexts.isEmpty)
    }

    @MainActor
    func testComposerCancelCleansRecorderAndFailureCannotCancelAnotherRecording() async throws {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        await service.cancel()
        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertFalse(controller.isRecording)
        controller.isRecording = true
        do { try await service.start(); XCTFail("An existing recording must keep ownership") } catch {}
        await service.cancel()
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(recorder.stopCallCount, 1)
        controller.isRecording = false
        let blocked = WorkflowComposerRecording(controller, isAppBundle: { false })
        do { try await blocked.start(); XCTFail("Requires app bundle") } catch {}
        await blocked.cancel()
        XCTAssertFalse(controller.isRecording)
        let failingController = makeWorkflowController(audioRecorder: ThrowingStartAudioRecorder(error: NSError(domain: "microphone", code: 1)))
        let failing = WorkflowComposerRecording(failingController, isAppBundle: { true })
        do { try await failing.start(); XCTFail("Startup failure must be reported") } catch {}
        await failing.cancel()
        XCTAssertFalse(failingController.isRecording)
        XCTAssertFalse(failingController.isAudioRecorderStarting)
        XCTAssertEqual(failingController.appState.status, .idle)
    }

    @MainActor
    func testComposerTranscriptionFailureRestoresIdle() async throws {
        let controller = makeWorkflowController(sttTranscriber: MockProcessingTranscriber(transcript: " "),
            configureSettings: { $0.sttProvider = .appleSpeech }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        do { _ = try await service.transcribe(); XCTFail("Empty transcript must be reported") } catch {}
        XCTAssertEqual(controller.appState.status, .idle)
        XCTAssertFalse(controller.isAudioRecorderStarted)
    }

    func testAskShortcutOpensComposerWithoutStartingRecording() async {
        let hotkeys = MockProcessingHotkeyService()
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(hotkeyService: hotkeys, audioRecorder: recorder)
        var opened = 0
        controller.onAskRequested = { opened += 1 }
        controller.start()
        hotkeys.onAskPressBegan?(HotkeyEventContext())
        hotkeys.onAskPressEnded?()
        await waitForMainActorWork()
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
    }

    func testDictationUsesCurrentInputEvenWhenOriginalTargetWasReadOnly() async {
        let injector = MockProcessingTextInjector()
        let history = MockProcessingHistoryStore()
        let controller = makeWorkflowController(textInjector: injector, historyStore: history)
        var record = HistoryRecord(date: Date())
        injector.onDeliver = {
            XCTAssertEqual(history.list().last?.postProcessedText, "new result")
        }
        let result = await controller.applyTranscribedText(
            "new result",
            selectionSnapshot: TextSelectionSnapshot(
                processID: getpid(), source: "typeflux-ask-answer-window", isEditable: false
            ),
            record: &record
        )
        XCTAssertEqual(result.outcome, .inserted)
        XCTAssertEqual(injector.insertedTexts, ["new result"])
        XCTAssertTrue(injector.replacedTexts.isEmpty)
        XCTAssertLessThanOrEqual(result.appliedAt, Date())
    }

    func testLegacyAskEditRecordsApplyTiming() async throws {
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector)
        var record = HistoryRecord(date: Date())
        var timing = HistoryPipelineTiming()
        let startedAt = Date()
        try await controller.applyLegacyAskDecision(
            .init(decision: AskSelectionDecision(answerEdit: .edit, content: "rewritten"), completedAt: startedAt),
            question: "rewrite",
            selectedText: nil,
            selectionSnapshot: TextSelectionSnapshot(),
            record: &record,
            pipelineTiming: &timing,
            sessionID: controller.processingSessionID
        )
        XCTAssertEqual(injector.insertedTexts, ["rewritten"])
        XCTAssertEqual(record.mode, .editSelection)
        let appliedAt = try XCTUnwrap(timing.applyCompletedAt)
        XCTAssertGreaterThanOrEqual(appliedAt, try XCTUnwrap(timing.applyStartedAt))
        XCTAssertLessThanOrEqual(appliedAt, Date())
    }

    func testApplyTranscribedTextRemovesPeriodFromShortDictation() async {
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector)
        var record = HistoryRecord(date: Date())

        let result = await controller.applyTranscribedText(
            "谢谢。",
            selectionSnapshot: TextSelectionSnapshot(),
            record: &record
        )

        XCTAssertEqual(result.finalResult, "谢谢")
        XCTAssertEqual(injector.insertedTexts, ["谢谢"])
        XCTAssertEqual(record.postProcessedText, "谢谢")
    }

    func testApplyTranscribedTextRemovesPeriodFromProcessedShortDictation() async {
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector)
        var record = HistoryRecord(date: Date())

        let result = await controller.applyTranscribedText(
            "算了，还是选择2吧。",
            selectionSnapshot: TextSelectionSnapshot(),
            record: &record
        )

        XCTAssertEqual(result.finalResult, "算了，还是选择2吧")
        XCTAssertEqual(injector.insertedTexts, ["算了，还是选择2吧"])
        XCTAssertEqual(record.postProcessedText, "算了，还是选择2吧")
    }

    func testApplyTranscribedTextDeduplicatesPunctuationAtCurrentInsertionPoint() async {
        let injector = MockProcessingTextInjector(
            inputSnapshot: CurrentInputTextSnapshot(
                text: "前文？后文",
                selectedRange: CFRange(location: 2, length: 0),
                isEditable: true,
                isFocusedTarget: true
            )
        )
        let controller = makeWorkflowController(textInjector: injector)
        var record = HistoryRecord(date: Date())

        let result = await controller.applyTranscribedText(
            "真的吗？",
            selectionSnapshot: TextSelectionSnapshot(),
            record: &record
        )

        XCTAssertEqual(result.finalResult, "真的吗")
        XCTAssertEqual(injector.insertedTexts, ["真的吗"])
        XCTAssertEqual(record.postProcessedText, "真的吗")
    }

    func testCurrentInputFailureKeepsCompleteCopyableResult() async {
        let injector = MockProcessingTextInjector(insertError: TextDeliveryError.noInput)
        let clipboard = MockClipboardService()
        let controller = makeWorkflowController(textInjector: injector, clipboard: clipboard)
        let (outcome, _) = await controller.applyText("  full result\n", replace: false)
        XCTAssertEqual(outcome, .presentedInDialog)
        XCTAssertEqual(outcome.historyStatus, .failed)
        XCTAssertEqual(controller.lastDialogResultText, "  full result\n")
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
        controller.copyLastResultFromDialog()
        XCTAssertEqual(clipboard.storedText, "  full result\n")
    }

    func testUnconfirmedDeliveryDoesNotClaimSuccessOrRetry() async {
        let injector = MockProcessingTextInjector()
        injector.deliveryResult = .unconfirmed(.paste)
        let controller = makeWorkflowController(textInjector: injector)
        let (outcome, _) = await controller.applyText("recoverable", replace: false)
        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertFalse(outcome.wasInserted)
        XCTAssertEqual(outcome.historyStatus, .skipped)
        XCTAssertEqual(injector.deliveryCallCount, 1)
        XCTAssertEqual(controller.lastDialogResultText, "recoverable")
        XCTAssertFalse(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testUnverifiedDispatchAnalyticsIsNeitherFailureNorConfirmedInsertion() {
        let recorder = AnalyticsEventRecorder()
        let controller = makeWorkflowController(analyticsReporter: recorder)
        let record = HistoryRecord(
            date: Date(), postProcessedText: "retained", recordingStatus: .succeeded,
            transcriptionStatus: .succeeded, processingStatus: .skipped, applyStatus: .skipped
        )
        controller.beginDictationAnalytics(intent: .dictation, mode: .locked, targetBundleIdentifier: nil)
        controller.bindPendingDictationAnalytics(to: record.id)
        controller.recordDictationApplyAnalytics(recordID: record.id, outcome: .unconfirmed)
        controller.reportDictationTerminal(record: record)
        XCTAssertEqual(recorder.events.map(\.name), ["dictation_session_started", "dictation_session_completed"])
        XCTAssertEqual(recorder.events.last?.properties["apply_outcome"], "unconfirmed")
    }

    func testObservedUnchangedDeliveryStillPresentsRecovery() async {
        let injector = MockProcessingTextInjector()
        injector.deliveryResult = .notApplied(.paste)
        let controller = makeWorkflowController(textInjector: injector)
        let (outcome, _) = await controller.applyText("retained", replace: false)
        XCTAssertEqual(outcome, .presentedInDialog)
        XCTAssertEqual(outcome.historyStatus, .failed)
        XCTAssertEqual(controller.lastDialogResultText, "retained")
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
        XCTAssertEqual(injector.deliveryCallCount, 1)
    }

    func testConfirmedPasteCompletesWithoutFailureDialog() async {
        let injector = MockProcessingTextInjector()
        injector.deliveryResult = .delivered(.paste)
        let controller = makeWorkflowController(textInjector: injector)
        let (outcome, _) = await controller.applyText("inserted", replace: false)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(outcome.wasInserted)
        XCTAssertEqual(outcome.historyStatus, .succeeded)
        XCTAssertFalse(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testSupersededDeliveryDoesNotOverwriteNewRecoveryResult() async {
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector)
        let oldSession = controller.processingSessionID
        _ = controller.beginProcessingSession()
        controller.lastDialogResultText = "new result"
        let (outcome, _) = await controller.applyText("old result", replace: false, expectedSessionID: oldSession)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(injector.deliveryCallCount, 0)
        XCTAssertEqual(controller.lastDialogResultText, "new result")
    }

    func testCancellationAfterDispatchDoesNotShowStaleFailureDialog() async {
        let injector = MockProcessingTextInjector()
        injector.deliveryResult = .unconfirmed(.paste)
        injector.onDeliver = { withUnsafeCurrentTask { $0?.cancel() } }
        let controller = makeWorkflowController(textInjector: injector)
        let task = Task { await controller.applyText("retained", replace: false) }
        let (outcome, _) = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(controller.lastDialogResultText, "retained")
        XCTAssertFalse(controller.overlayController.isShowingResultDialogForTesting)
        XCTAssertEqual(injector.deliveryCallCount, 1)
    }

    func testApplyPersonaToSelectionPreservesCapturedReplacementTarget() async {
        let contextID = UUID()
        let snapshot = TextSelectionSnapshot(
            processID: 42,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            selectedRange: CFRange(location: 0, length: 5),
            selectedText: "hello",
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "Draft",
            isFocusedTarget: true,
            replacementContextID: contextID
        )
        let textInjector = MockProcessingTextInjector(selectionSnapshot: snapshot)
        let recorder = MockProcessingAudioRecorder()
        let history = MockProcessingHistoryStore()
        let persona = PersonaProfile(name: "Concise", prompt: "Make it concise.")
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: recorder,
            llmService: CountingProcessingLLMService(rewriteText: "updated"),
            historyStore: history,
            configureSettings: configureReadyLLM
        )

        textInjector.onDeliver = {
            XCTAssertEqual(history.list().last?.postProcessedText, "updated")
        }
        controller.applyPersonaToSelection(
            WorkflowController.PersonaSelectionContext(snapshot: snapshot, selectedText: "hello"),
            persona: persona
        )
        await waitUntil { textInjector.replacedTexts == ["updated"] }

        XCTAssertEqual(textInjector.replacementTargets.first.flatMap { $0 }?.replacementContextID, contextID)
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        XCTAssertEqual(recorder.startCallCount, 0)
    }

    func testPersonaRewritesOpaqueCopySelectionWithoutShowingCopyDialog() async {
        let contextID = UUID()
        let safety = AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: true,
            selectedText: "original", intent: .explicitSelectionAction, capability: .opaque
        )
        let snapshot = TextSelectionSnapshot(
            processID: 42, selectedText: "original", source: "clipboard-copy", isEditable: false,
            role: "AXWindow", isFocusedTarget: true,
            replacementContextID: contextID, replacementSafety: safety
        )
        let injector = MockProcessingTextInjector(selectionSnapshot: snapshot)
        injector.deliveryResult = .unconfirmed(.paste)
        let recorder = MockProcessingAudioRecorder()
        let history = MockProcessingHistoryStore()
        let controller = makeWorkflowController(
            textInjector: injector, audioRecorder: recorder,
            llmService: CountingProcessingLLMService(rewriteText: "rewritten"),
            historyStore: history, configureSettings: configureReadyLLM
        )
        controller.applyPersonaToSelection(
            WorkflowController.PersonaSelectionContext(snapshot: snapshot, selectedText: "original"),
            persona: PersonaProfile(name: "Concise", prompt: "Make it concise.")
        )
        await waitUntil { history.list().last?.applyStatus == .skipped }
        XCTAssertEqual(injector.replacedTexts, ["rewritten"])
        XCTAssertEqual(injector.replacementTargets.first.flatMap { $0 }?.replacementContextID, contextID)
        XCTAssertEqual(history.list().last?.postProcessedText, "rewritten")
        XCTAssertEqual(injector.deliveryCallCount, 1)
        XCTAssertEqual(recorder.startCallCount, 0)
        XCTAssertFalse(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testApplyTextPresentsResultWithoutChangingClipboardWhenReplacementThrows() async {
        let textInjector = MockProcessingTextInjector(
            replaceError: NSError(
                domain: "AXTextInjector",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Paste insertion could not be verified"]
            )
        )
        let clipboard = MockClipboardService()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            clipboard: clipboard
        )

        let (outcome, processed) = await controller.applyText("Manual copy fallback", replace: true)

        XCTAssertEqual(outcome, .presentedInDialog)
        XCTAssertEqual(processed, "Manual copy fallback")
        XCTAssertEqual(controller.lastDialogResultText, "Manual copy fallback")
        XCTAssertNil(clipboard.storedText)
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
        XCTAssertFalse(controller.overlayController.isShowingPassiveNotice)
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)

        controller.copyLastResultFromDialog()

        XCTAssertEqual(clipboard.storedText, "Manual copy fallback")
    }

    func testCancelledSelectionApplyDoesNotCommitLateReplacement() async {
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector)
        let task = Task {
            await controller.applyText(
                "replacement",
                replace: true,
                targetSnapshot: TextSelectionSnapshot(
                    processID: 42,
                    selectedText: "original",
                    source: "accessibility",
                    isEditable: true,
                    isFocusedTarget: true,
                    replacementContextID: UUID()
                )
            )
        }

        task.cancel()
        let (outcome, _) = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(controller.clipboard.getString())
        XCTAssertFalse(controller.overlayController.isShowingResultDialogForTesting)
        XCTAssertTrue(injector.replacedTexts.isEmpty)
    }

    func testIsServiceOverloadedErrorReturnsTrueFor529() {
        let error = NSError(domain: "SSE", code: 529, userInfo: [NSLocalizedDescriptionKey: "HTTP 529: overloaded"])
        XCTAssertTrue(WorkflowController.isServiceOverloadedError(error))
    }

    func testIsServiceOverloadedErrorReturnsTrueFor529FromLLMDomain() {
        let error = NSError(
            domain: "LLM",
            code: 529,
            userInfo: [
                NSLocalizedDescriptionKey: "HTTP 529: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"
            ]
        )
        XCTAssertTrue(WorkflowController.isServiceOverloadedError(error))
    }

    func testIsServiceOverloadedErrorReturnsFalseForOtherStatusCodes() {
        let codes = [400, 401, 429, 500, 503]
        for code in codes {
            let error = NSError(domain: "SSE", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): error"])
            XCTAssertFalse(WorkflowController.isServiceOverloadedError(error), "Expected false for HTTP \(code)")
        }
    }

    func testHasRewritePersonaRequiresNonEmptyPrompt() {
        XCTAssertTrue(WorkflowController.hasRewritePersona("Make it concise"))
        XCTAssertFalse(WorkflowController.hasRewritePersona(nil))
        XCTAssertFalse(WorkflowController.hasRewritePersona("   \n"))
    }

    func testShouldRewriteTranscriptWhenInputContextHasContentWithoutPersona() {
        let inputContext = InputContextSnapshot(
            appName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            role: "AXWindow",
            isEditable: false,
            isFocusedTarget: true,
            prefix: "",
            suffix: "",
            selectedText: "Selected markdown paragraph"
        )

        XCTAssertTrue(WorkflowController.shouldRewriteTranscript(personaPrompt: nil, inputContext: inputContext))
    }

    func testShouldNotRewriteTranscriptWithoutPersonaOrInputContext() {
        XCTAssertFalse(WorkflowController.shouldRewriteTranscript(personaPrompt: nil, inputContext: nil))
    }

    func testQuickInputOnlyAppliesToHoldToTalkDictation() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.quickInputEnabled = true
        })

        XCTAssertTrue(controller.shouldUseQuickInput(recordingMode: .holdToTalk, recordingIntent: .dictation))
        XCTAssertFalse(controller.shouldUseQuickInput(recordingMode: .locked, recordingIntent: .dictation))
        XCTAssertFalse(controller.shouldUseQuickInput(recordingMode: .holdToTalk, recordingIntent: .askSelection))

        controller.recordingAllowsQuickInput = false
        XCTAssertFalse(controller.shouldUseQuickInput(recordingMode: .holdToTalk, recordingIntent: .dictation))
    }

    func testQuickInputIsDisabledByDefault() {
        let controller = makeWorkflowController()

        XCTAssertFalse(controller.shouldUseQuickInput(recordingMode: .holdToTalk, recordingIntent: .dictation))
    }

    func testRecordingHintUsesQuickInputModeWhenQuickInputApplies() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.quickInputEnabled = true
        })

        let hint = controller.recordingHintPresentation(
            intent: .dictation,
            recordingMode: .holdToTalk,
            appName: nil,
            bundleIdentifier: nil
        )

        XCTAssertEqual(hint.text, L("overlay.recording.quickInputHint"))
        XCTAssertEqual(hint.autoHideAfter, WorkflowController.recordingHintAutoHideDelay)
    }

    func testRecordingHintUsesPersonaNameWhenQuickInputDoesNotApply() {
        let persona = PersonaProfile(name: "Meeting Notes", prompt: "Clean up dictation.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personaRewriteEnabled = true
            settingsStore.personas = settingsStore.personas + [persona]
            settingsStore.activePersonaID = persona.id.uuidString
        })

        let hint = controller.recordingHintPresentation(
            intent: .dictation,
            recordingMode: .locked,
            appName: nil,
            bundleIdentifier: nil
        )

        XCTAssertEqual(hint.text, L("overlay.recording.personaHint", persona.name))
        XCTAssertEqual(hint.autoHideAfter, WorkflowController.recordingHintAutoHideDelay)
    }

    func testRecordingHintUsesPersonaNameForLockedRecordingWhenQuickInputIsEnabled() {
        let persona = PersonaProfile(name: "Meeting Notes", prompt: "Clean up dictation.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.quickInputEnabled = true
            settingsStore.personaRewriteEnabled = true
            settingsStore.personas = settingsStore.personas + [persona]
            settingsStore.activePersonaID = persona.id.uuidString
        })

        let hint = controller.recordingHintPresentation(
            intent: .dictation,
            recordingMode: .locked,
            appName: nil,
            bundleIdentifier: nil
        )

        XCTAssertEqual(hint.text, L("overlay.recording.personaHint", persona.name))
        XCTAssertEqual(hint.autoHideAfter, WorkflowController.recordingHintAutoHideDelay)
    }

    func testRecordingHintIsEmptyWhenNoPersonaIsActive() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personaRewriteEnabled = false
        })

        let hint = controller.recordingHintPresentation(
            intent: .dictation,
            recordingMode: .locked,
            appName: nil,
            bundleIdentifier: nil
        )

        XCTAssertNil(hint.text)
        XCTAssertNil(hint.autoHideAfter)
    }

    func testRecordingHintKeepsAskAnythingGuidanceBehavior() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.quickInputEnabled = true
        })

        let hint = controller.recordingHintPresentation(
            intent: .askSelection,
            recordingMode: .holdToTalk,
            appName: nil,
            bundleIdentifier: nil
        )

        XCTAssertEqual(hint.text, L("overlay.ask.guidance"))
        XCTAssertNil(hint.autoHideAfter)
    }

    func testActivePersonaPromptUsesFocusedAppBinding() {
        let customPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it warm and casual.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personas = settingsStore.personas + [customPersona]
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.tinyspeck.slackmacgap",
                personaID: customPersona.id
            )
        })
        let selectionSnapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            selectedRange: nil,
            selectedText: nil,
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "DM",
            isFocusedTarget: true
        )

        let personaPrompt = controller.activePersonaPrompt(
            selectionSnapshot: selectionSnapshot,
            inputContext: nil
        )

        XCTAssertEqual(personaPrompt, customPersona.prompt)
    }

    func testActivePersonaUsesFocusedAppBindingPersonaID() {
        let appPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it warm and casual.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            let globalPersona = settingsStore.personas[0]
            settingsStore.personas = settingsStore.personas + [appPersona]
            settingsStore.applyPersonaSelection(globalPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.tinyspeck.slackmacgap",
                personaID: appPersona.id
            )
        })
        let selectionSnapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            selectedRange: nil,
            selectedText: nil,
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "DM",
            isFocusedTarget: true
        )

        let persona = controller.activePersona(
            selectionSnapshot: selectionSnapshot,
            inputContext: nil
        )

        XCTAssertEqual(persona?.id, appPersona.id)
    }

    func testActivePersonaPromptUsesNoPersonaAppBindingOverDefaultPersona() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            let defaultPersona = settingsStore.personas[0]
            settingsStore.applyPersonaSelection(defaultPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.apple.Notes",
                personaID: nil
            )
        })
        let selectionSnapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            selectedRange: nil,
            selectedText: nil,
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "Note",
            isFocusedTarget: true
        )

        let personaPrompt = controller.activePersonaPrompt(
            selectionSnapshot: selectionSnapshot,
            inputContext: nil
        )

        XCTAssertNil(personaPrompt)
    }

    func testApplicationPersonaPickerTitleUsesApplicationScope() {
        let controller = makeWorkflowController()
        let binding = PersonaAppBinding(
            appIdentifier: "com.apple.Notes",
            personaID: controller.settingsStore.personas[0].id
        )

        XCTAssertEqual(
            controller.personaPickerTitle(for: .switchApplication(binding)),
            L("overlay.personaPicker.switchApplicationTitle")
        )
        if case .application = controller.personaPickerIcon(for: .switchApplication(binding)) {
            // Expected application-scoped icon.
        } else {
            XCTFail("Expected application persona picker icon")
        }
    }

    func testDefaultPersonaPickerTitleUsesGlobalScope() {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let controller = makeWorkflowController()

        XCTAssertEqual(
            controller.personaPickerTitle(for: .switchDefault),
            L("overlay.personaPicker.switchTitle")
        )
        XCTAssertEqual(L("overlay.personaPicker.switchTitle"), "Switch Global Persona")
        XCTAssertEqual(controller.personaPickerIcon(for: .switchDefault), .global)
    }

    func testApplicationPersonaSelectionUpdatesAppBindingWithoutChangingGlobalPersona() throws {
        let targetPersona = PersonaProfile(name: "Release Notes", prompt: "Make it crisp.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            let globalPersona = settingsStore.personas[0]
            let appPersona = settingsStore.personas[1]
            settingsStore.personas = settingsStore.personas + [targetPersona]
            settingsStore.applyPersonaSelection(globalPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.apple.Notes",
                personaID: appPersona.id
            )
        })
        let binding = try XCTUnwrap(controller.settingsStore.personaAppBindings.first)
        controller.personaPickerMode = .switchApplication(binding)
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex(where: { $0.id == targetPersona.id })
        )
        controller.isPersonaPickerPresented = true

        controller.confirmPersonaSelection()

        XCTAssertTrue(controller.settingsStore.personaRewriteEnabled)
        XCTAssertEqual(controller.settingsStore.activePersonaID, controller.settingsStore.personas[0].id.uuidString)
        XCTAssertEqual(controller.settingsStore.personaAppBindings.first?.personaID, targetPersona.id)
    }

    func testOpeningPersonaPickerDoesNotPlayCue() async {
        let eventRecorder = ThreadSafeEventRecorder()
        let controller = makeWorkflowController(
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder)
        )

        controller.handlePersonaPickerRequested()
        await waitForMainActorWork()

        XCTAssertTrue(controller.isPersonaPickerPresented)
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play"))
    }

    func testOpeningPersonaPickerDoesNotPlayCueWhenSoundEffectsAreDisabled() async {
        let eventRecorder = ThreadSafeEventRecorder()
        let controller = makeWorkflowController(
            soundEffectPlayer: makeRecordingSoundEffectPlayer(
                eventRecorder: eventRecorder,
                soundEffectsEnabled: false
            )
        )

        controller.handlePersonaPickerRequested()
        await waitForMainActorWork()

        XCTAssertTrue(controller.isPersonaPickerPresented)
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play"))
    }

    func testPersonaPickerUsesExplicitCaptureForOpaqueSelection() async throws {
        let selectedText = "Selected in Zed"
        let snapshot = TextSelectionSnapshot(
            processID: 42,
            processName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            selectedRange: nil,
            selectedText: selectedText,
            source: "clipboard-copy",
            isEditable: false,
            role: "AXWindow",
            windowTitle: "Editor",
            isFocusedTarget: true,
            replacementContextID: UUID(),
            replacementSafety: .resultOnly
        )
        let textInjector = MockProcessingTextInjector(selectionSnapshot: snapshot)
        let controller = makeWorkflowController(
            textInjector: textInjector,
            configureSettings: { $0.personaHotkeyAppliesToSelection = true }
        )

        controller.handlePersonaPickerRequested()
        await waitUntil { controller.isPersonaPickerPresented }

        XCTAssertEqual(textInjector.selectionCaptureIntents, [.explicitSelectionAction])
        guard case let .applySelection(context) = controller.personaPickerMode else {
            return XCTFail("Expected persona picker to apply a persona to the selected text")
        }
        XCTAssertEqual(context.selectedText, selectedText)
        XCTAssertEqual(
            controller.personaPickerTitle(for: controller.personaPickerMode),
            L("overlay.personaPicker.applyTitle")
        )
        XCTAssertTrue(controller.shouldPresentResultDialog(for: context.snapshot))
    }

    func testPersonaPickerSeparatesSelectionContextFromReplacementCapability() async {
        let snapshot = TextSelectionSnapshot(
            processID: 42,
            processName: "Preview",
            bundleIdentifier: "com.apple.Preview",
            selectedRange: CFRange(location: 2, length: 8),
            selectedText: "Read only",
            source: "accessibility",
            isEditable: false,
            role: "AXStaticText",
            windowTitle: "Document",
            isFocusedTarget: true
        )
        let controller = makeWorkflowController(
            textInjector: MockProcessingTextInjector(selectionSnapshot: snapshot),
            configureSettings: { $0.personaHotkeyAppliesToSelection = true }
        )

        controller.handlePersonaPickerRequested()
        await waitUntil { controller.isPersonaPickerPresented }

        guard case let .applySelection(context) = controller.personaPickerMode else {
            return XCTFail("Expected read-only selected text to remain valid persona context")
        }
        XCTAssertEqual(context.selectedText, "Read only")
        XCTAssertFalse(context.snapshot.canReplaceSelection)
        XCTAssertTrue(controller.shouldPresentResultDialog(for: context.snapshot))
    }

    func testHistoryPickerConfirmCopiesAndInsertsSelectedHistory() async {
        let textInjector = MockProcessingTextInjector()
        let clipboard = MockClipboardService()
        let historyStore = MockProcessingHistoryStore()
        let baseDate = Date(timeIntervalSince1970: 1000)
        historyStore.save(record: HistoryRecord(date: baseDate, transcriptText: "old result"))
        historyStore.save(record: HistoryRecord(date: baseDate.addingTimeInterval(10), personaResultText: "new result"))

        let controller = makeWorkflowController(
            textInjector: textInjector,
            historyStore: historyStore,
            clipboard: clipboard
        )

        controller.handleHistoryPickerRequested()
        XCTAssertTrue(controller.isHistoryPickerPresented)
        XCTAssertEqual(controller.historyPickerItems.map(\.title), ["new result", "old result"])

        controller.confirmHistorySelection()

        XCTAssertFalse(controller.isHistoryPickerPresented)
        XCTAssertEqual(clipboard.storedText, "new result")
        await waitUntil {
            textInjector.insertedTexts == ["new result"]
        }
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
    }

    func testHistoryPickerCopyActionDoesNotInsertText() {
        let textInjector = MockProcessingTextInjector()
        let clipboard = MockClipboardService()
        let historyStore = MockProcessingHistoryStore()
        historyStore.save(record: HistoryRecord(date: Date(timeIntervalSince1970: 1000), transcriptText: "copy only"))
        let controller = makeWorkflowController(
            textInjector: textInjector,
            historyStore: historyStore,
            clipboard: clipboard
        )

        controller.handleHistoryPickerRequested()
        controller.historyPanelModel.perform(.copy, at: 0)

        XCTAssertFalse(controller.isHistoryPickerPresented)
        XCTAssertEqual(clipboard.storedText, "copy only")
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
    }

    func testHistoryPickerShowsMostRecentVoiceRecords() {
        let historyStore = MockProcessingHistoryStore()
        let baseDate = Date(timeIntervalSince1970: 1000)
        for index in 0 ..< WorkflowController.historyPanelVoiceLimit + 5 {
            historyStore.save(record: HistoryRecord(
                date: baseDate.addingTimeInterval(TimeInterval(index)),
                transcriptText: "result \(index)"
            ))
        }

        let controller = makeWorkflowController(historyStore: historyStore)

        controller.handleHistoryPickerRequested()

        XCTAssertEqual(controller.historyPickerItems.count, WorkflowController.historyPanelVoiceLimit)
        XCTAssertEqual(controller.historyPickerItems.first?.text, "result \(WorkflowController.historyPanelVoiceLimit + 4)")
        XCTAssertEqual(controller.historyPickerItems.last?.text, "result 5")
    }

    func testHistoryPickerRetryActionStartsRetryFlow() {
        let historyStore = MockProcessingHistoryStore()
        historyStore.save(record: HistoryRecord(
            date: Date(timeIntervalSince1970: 1000),
            transcriptText: "retry me"
        ))
        let controller = makeWorkflowController(historyStore: historyStore)

        controller.handleHistoryPickerRequested()
        controller.historyPanelModel.perform(.retryTranscription, at: 0)

        XCTAssertFalse(controller.isHistoryPickerPresented)
        XCTAssertNotNil(controller.processingTask)
    }

    func testRetrySelectionPersonaRewritesStoredTextWithoutAudio() async {
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "Concise result")
        let record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: "Make it concise.",
            selectionOriginalText: "Original selection",
            errorMessage: "Timed out",
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .failed,
            applyStatus: .skipped
        )
        historyStore.save(record: record)
        let controller = makeWorkflowController(
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )

        controller.retry(record: record)
        await waitUntil { controller.overlayController.isShowingResultDialogForTesting }

        let savedRecord = historyStore.record(id: record.id)
        XCTAssertEqual(llmService.streamRewriteCallCount, 1)
        XCTAssertEqual(savedRecord?.selectionOriginalText, "Original selection")
        XCTAssertEqual(savedRecord?.selectionEditedText, "Concise result")
        XCTAssertEqual(savedRecord?.applyStatus, .succeeded)
        XCTAssertNil(savedRecord?.audioFilePath)
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testRetryPersonaRewriteUsesCompletedTranscriptWhenAudioIsGone() async {
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "Polished transcript")
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            audioFilePath: "/missing/retry-audio.wav",
            transcriptText: "Raw transcript",
            personaPrompt: "Polish this.",
            errorMessage: "Timed out",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .failed,
            applyStatus: .skipped
        )
        historyStore.save(record: record)
        let controller = makeWorkflowController(
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )

        controller.retry(record: record)
        await waitUntil { controller.overlayController.isShowingResultDialogForTesting }

        let savedRecord = historyStore.record(id: record.id)
        XCTAssertEqual(llmService.streamRewriteCallCount, 1)
        XCTAssertEqual(savedRecord?.transcriptText, "Raw transcript")
        XCTAssertEqual(savedRecord?.personaResultText, "Polished transcript")
        XCTAssertEqual(savedRecord?.postProcessedText, "Polished transcript")
        XCTAssertNil(savedRecord?.errorMessage)
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testRetryFailedApplyPresentsExistingResultWithoutRepeatingLLM() async {
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "Unexpected rewrite")
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            transcriptText: "Raw transcript",
            personaPrompt: "Polish this.",
            postProcessedText: "Existing result",
            errorMessage: "Apply failed",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .failed
        )
        historyStore.save(record: record)
        let controller = makeWorkflowController(
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )

        controller.retry(record: record)
        await waitUntil { controller.overlayController.isShowingResultDialogForTesting }

        XCTAssertEqual(llmService.streamRewriteCallCount, 0)
        XCTAssertEqual(controller.lastDialogResultText, "Existing result")
        XCTAssertNil(historyStore.record(id: record.id)?.errorMessage)
        XCTAssertTrue(controller.overlayController.isShowingResultDialogForTesting)
    }

    func testRetryFailedTranscriptionUsesExistingAudio() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-retry-\(UUID().uuidString).wav")
        try Data().write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let historyStore = MockProcessingHistoryStore()
        let record = HistoryRecord(
            date: Date(),
            mode: .dictation,
            audioFilePath: audioURL.path,
            errorMessage: "ASR failed",
            recordingStatus: .succeeded,
            transcriptionStatus: .failed,
            processingStatus: .skipped,
            applyStatus: .skipped
        )
        historyStore.save(record: record)
        let controller = makeWorkflowController(
            sttTranscriber: MockProcessingTranscriber(transcript: "Recovered transcript"),
            historyStore: historyStore
        )

        controller.retry(record: record)
        await waitUntil { controller.overlayController.isShowingResultDialogForTesting }

        let savedRecord = historyStore.record(id: record.id)
        XCTAssertEqual(savedRecord?.transcriptText, "Recovered transcript")
        XCTAssertEqual(savedRecord?.transcriptionStatus, .succeeded)
        XCTAssertNil(savedRecord?.errorMessage)
    }

    func testRetryRewriteFailureRemainsRetryableWithoutAudio() async {
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "")
        let record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: "Make it concise.",
            selectionOriginalText: "Original selection",
            errorMessage: "Timed out",
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .failed,
            applyStatus: .skipped
        )
        historyStore.save(record: record)
        let controller = makeWorkflowController(
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )

        controller.retry(record: record)
        await waitUntil { controller.lastRetryableFailureRecord != nil }

        XCTAssertEqual(llmService.streamRewriteCallCount, 1)
        XCTAssertEqual(historyStore.record(id: record.id)?.processingStatus, .failed)
        XCTAssertNotNil(controller.lastRetryableFailureRecord)
    }

    func testConfirmingPersonaSelectionPlaysTipCue() async throws {
        let eventRecorder = ThreadSafeEventRecorder()
        let controller = makeWorkflowController(
            soundEffectPlayer: makeNamedSoundEffectPlayer(eventRecorder: eventRecorder)
        )
        controller.personaPickerMode = .switchDefault
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex { $0.id != nil }
        )
        controller.isPersonaPickerPresented = true

        controller.confirmPersonaSelection()
        await eventRecorder.waitUntilContains("cue-play-tip")

        XCTAssertFalse(controller.isPersonaPickerPresented)
        XCTAssertTrue(eventRecorder.snapshot().contains("cue-play-tip"))
    }

    func testConfirmingPersonaSelectionDoesNotPlayCueWhenSoundEffectsAreDisabled() async throws {
        let eventRecorder = ThreadSafeEventRecorder()
        let controller = makeWorkflowController(
            soundEffectPlayer: makeNamedSoundEffectPlayer(
                eventRecorder: eventRecorder,
                soundEffectsEnabled: false
            )
        )
        controller.personaPickerMode = .switchDefault
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex { $0.id != nil }
        )
        controller.isPersonaPickerPresented = true

        controller.confirmPersonaSelection()
        await waitForMainActorWork()

        XCTAssertFalse(controller.isPersonaPickerPresented)
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play-tip"))
    }

    func testGenerateRewriteThrowsConfigurationErrorWhenLLMIsNotConfigured() async {
        let controller = makeWorkflowController()

        await XCTAssertThrowsErrorAsync({
            try await controller.generateRewrite(
                request: LLMRewriteRequest(
                    mode: .rewriteTranscript,
                    sourceText: "hello",
                    spokenInstruction: nil,
                    personaPrompt: "Rewrite this"
                ),
                sessionID: UUID()
            )
        }) { error in
            XCTAssertEqual(
                error as? LLMConfigurationError,
                .notConfigured(reason: .missingAPIKey)
            )
        }
    }

    func testPersonaRewriteTimeoutAfterTranscriptionIsThreeSeconds() {
        XCTAssertEqual(WorkflowController.llmTimeoutAfterTranscriptionSeconds, 3)
    }

    func testPersonaRewriteTimeoutUsesCurrentSetting() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.voiceProcessingTimeout = .tenSeconds
        })
        XCTAssertEqual(controller.llmTimeoutAfterTranscription, 10)

        controller.settingsStore.voiceProcessingTimeout = .thirtySeconds

        XCTAssertEqual(controller.llmTimeoutAfterTranscription, 30)
    }

    func testPersonaRewriteTimeoutBudgetScalesWithSourceText() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.voiceProcessingTimeout = .threeSeconds
        })

        let shortBudget = controller.llmRewriteTimeoutBudget(for: String(repeating: "中", count: 100))
        let longBudget = controller.llmRewriteTimeoutBudget(for: String(repeating: "中", count: 1_000))

        XCTAssertEqual(shortBudget.totalSeconds, 3)
        XCTAssertEqual(longBudget.totalSeconds, 30)
        XCTAssertEqual(longBudget.watchdogSeconds, 40)
    }

    func testProcessingWatchdogIsIndependentFromFallbackWaitSetting() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.voiceProcessingTimeout = .oneSecond
        })

        XCTAssertEqual(controller.settingsStore.voiceProcessingTimeout.seconds, 1)
        XCTAssertEqual(WorkflowController.processingWatchdogTimeoutSeconds, 30)
    }

    func testProcessingWatchdogCancelsStuckSession() async throws {
        let historyStore = MockProcessingHistoryStore()
        let controller = makeWorkflowController(historyStore: historyStore)
        let record = HistoryRecord(
            date: Date(),
            recordingStatus: .succeeded,
            transcriptionStatus: .running,
            processingStatus: .pending,
            applyStatus: .pending
        )
        controller.saveHistoryRecord(record)
        controller.activeProcessingRecordID = record.id
        let sessionID = controller.beginProcessingSession()

        controller.startProcessingWatchdog(sessionID: sessionID, timeoutSeconds: 0.01)
        await waitUntil { controller.processingSessionID != sessionID }
        await waitForMainActorWork()

        XCTAssertNotEqual(controller.processingSessionID, sessionID)
        XCTAssertEqual(controller.appState.status, .failed(message: L("workflow.timeout.status")))
        XCTAssertEqual(
            try XCTUnwrap(historyStore.record(id: record.id)).errorMessage,
            L("workflow.timeout.reason", 0)
        )
    }

    func testGenerateRewriteThrowsTimeoutWhenStreamDoesNotFinish() async {
        let controller = makeWorkflowController(
            llmService: SlowProcessingLLMService(delay: .seconds(2)),
            configureSettings: configureReadyLLM
        )

        await XCTAssertThrowsErrorAsync({
            try await controller.generateRewrite(
                request: LLMRewriteRequest(
                    mode: .rewriteTranscript,
                    sourceText: "hello",
                    spokenInstruction: nil,
                    personaPrompt: "Rewrite this"
                ),
                sessionID: controller.processingSessionID,
                timeoutBudget: .fixed(0.01)
            )
        }) { error in
            XCTAssertEqual(
                (error as? WorkflowController.LLMRequestTimeoutError)?.kind,
                .firstOutput
            )
        }
    }

    func testGenerateRewriteContinuesPastFirstOutputDeadlineWhileStreamMakesProgress() async throws {
        let controller = makeWorkflowController(
            llmService: ProgressingProcessingLLMService(
                chunks: ["one", " two", " three", " four"],
                delay: .milliseconds(200)
            ),
            configureSettings: configureReadyLLM
        )
        // The stream outlives the first-output deadline (4 chunks x 200ms > 0.5s) while every gap
        // stays an order of magnitude below the stall limit, so scheduling delays on a loaded
        // machine cannot trip a timeout.
        let budget = LLMRewriteTimeoutBudget(
            estimatedInputUnits: 200,
            baseSeconds: 0.5,
            firstOutputSeconds: 0.5,
            stallSeconds: 2,
            totalSeconds: 5,
            watchdogSeconds: 6
        )

        let result = try await controller.generateRewrite(
            request: LLMRewriteRequest(
                mode: .rewriteTranscript,
                sourceText: "hello",
                spokenInstruction: nil,
                personaPrompt: "Rewrite this"
            ),
            sessionID: controller.processingSessionID,
            timeoutBudget: budget
        )

        XCTAssertEqual(result.text, "one two three four")
    }

    func testGenerateRewriteDetectsStalledStreamAfterFirstOutput() async {
        let controller = makeWorkflowController(
            llmService: ProgressingProcessingLLMService(
                chunks: ["first", "late"],
                delay: .seconds(2)
            ),
            configureSettings: configureReadyLLM
        )
        let budget = LLMRewriteTimeoutBudget(
            estimatedInputUnits: 200,
            baseSeconds: 0.05,
            firstOutputSeconds: 0.05,
            stallSeconds: 0.05,
            totalSeconds: 0.3,
            watchdogSeconds: 0.4
        )

        await XCTAssertThrowsErrorAsync({
            try await controller.generateRewrite(
                request: LLMRewriteRequest(
                    mode: .rewriteTranscript,
                    sourceText: "hello",
                    spokenInstruction: nil,
                    personaPrompt: "Rewrite this"
                ),
                sessionID: controller.processingSessionID,
                timeoutBudget: budget
            )
        }) { error in
            XCTAssertEqual(
                (error as? WorkflowController.LLMRequestTimeoutError)?.kind,
                .stalledOutput
            )
        }
    }

    func testDictationWithPersonaFallsBackToTranscriptWhenRewriteTimesOut() async {
        let transcript = "insert the transcript"
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: transcript),
            llmService: SlowProcessingLLMService(delay: .seconds(2)),
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )
        controller.llmTimeoutAfterTranscription = 0.01
        let sessionID = controller.processingSessionID

        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
            record: HistoryRecord(
                date: Date(),
                personaPrompt: "Clean up the transcript.",
                recordingStatus: .succeeded
            ),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: nil,
            personaPrompt: "Clean up the transcript.",
            recordingIntent: .dictation,
            sessionID: sessionID
        )

        XCTAssertEqual(textInjector.insertedTexts, [transcript])
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
        let savedRecord = historyStore.list().last
        XCTAssertEqual(savedRecord?.mode, .personaRewrite)
        XCTAssertEqual(savedRecord?.transcriptText, transcript)
        XCTAssertEqual(savedRecord?.personaResultText, transcript)
        XCTAssertEqual(savedRecord?.processingStatus, .succeeded)
        XCTAssertEqual(savedRecord?.applyStatus, .succeeded)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.outcome, .timedOutFallback)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.timeoutMilliseconds, 10)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.baseTimeoutMilliseconds, 10)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.timeoutKind, .firstOutput)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.usedTranscriptFallback, true)
    }

    func testLocalTranscriptIsAppliedWhenCloudASRIsCancelledAndRewriteFails() async {
        let transcript = "Keep this complete local transcript"
        let cases: [(Bool, Error)] = [
            (false, URLError(.cannotConnectToHost)),
            (true, NSError(domain: "LLMService", code: 503))
        ]
        for (replaceSelection, rewriteError) in cases {
            let textInjector = MockProcessingTextInjector()
            let historyStore = MockProcessingHistoryStore()
            let controller = makeWorkflowController(
                textInjector: textInjector,
                sttTranscriber: MockProcessingTranscriber(error: URLError(.cannotConnectToHost)),
                localFallbackTranscriber: MockProcessingTranscriber(transcript: transcript),
                llmService: CountingProcessingLLMService(
                    rewriteText: "Incomplete rewrite",
                    error: rewriteError
                ),
                historyStore: historyStore,
                configureSettings: {
                    self.configureReadyLLM(settingsStore: $0)
                    $0.sttProvider = .typefluxOfficial
                },
                hasPaidCloudSubscription: { true }
            )
            let snapshot = TextSelectionSnapshot(
                selectedRange: CFRange(location: 0, length: replaceSelection ? 5 : 0),
                selectedText: replaceSelection ? "draft" : nil,
                source: "accessibility",
                isEditable: true,
                role: "AXTextArea",
                isFocusedTarget: true
            )

            await controller.process(
                audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
                record: HistoryRecord(date: Date(), recordingStatus: .succeeded),
                selectionSnapshot: snapshot,
                selectedText: snapshot.selectedText,
                askContextText: nil,
                inputContext: nil,
                personaPrompt: "Clean up the transcript.",
                recordingIntent: .dictation,
                sessionID: controller.processingSessionID
            )

            XCTAssertEqual(textInjector.insertedTexts, [transcript])
            XCTAssertTrue(textInjector.replacedTexts.isEmpty)
            let savedRecord = historyStore.list().last
            XCTAssertEqual(savedRecord?.pipelineTiming?.asrRace?.selectedSource, .local)
            XCTAssertEqual(savedRecord?.pipelineTiming?.asrRace?.cloudAttempt.outcome, .cancelled)
            XCTAssertEqual(savedRecord?.pipelineTiming?.asrRace?.localAttempt.outcome, .succeeded)
            XCTAssertEqual(savedRecord?.transcriptText, transcript)
            XCTAssertEqual(savedRecord?.postProcessedText, transcript)
            XCTAssertEqual(savedRecord?.transcriptionStatus, .succeeded)
            XCTAssertEqual(savedRecord?.processingStatus, .succeeded)
            XCTAssertEqual(savedRecord?.applyStatus, .succeeded)
            XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.usedTranscriptFallback, true)
            XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.outcome, .requestFailedFallback)
            XCTAssertNil(savedRecord?.errorMessage)
            XCTAssertNil(controller.lastRetryableFailureRecord)
            XCTAssertFalse(controller.overlayController.isShowingPassiveNotice)
        }
    }

    func testCancelledRewriteDoesNotInsertTranscriptFallback() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let textInjector = MockProcessingTextInjector()
            let historyStore = MockProcessingHistoryStore()
            let controller = makeWorkflowController(
                textInjector: textInjector,
                sttTranscriber: MockProcessingTranscriber(transcript: "Do not insert this transcript"),
                llmService: CountingProcessingLLMService(rewriteText: "Partial rewrite", error: error),
                historyStore: historyStore,
                configureSettings: configureReadyLLM
            )
            await controller.process(
                audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
                record: HistoryRecord(date: Date(), recordingStatus: .succeeded),
                selectionSnapshot: TextSelectionSnapshot(),
                selectedText: nil,
                askContextText: nil,
                inputContext: nil,
                personaPrompt: "Clean up the transcript.",
                recordingIntent: .dictation,
                sessionID: controller.processingSessionID
            )

            XCTAssertTrue(textInjector.insertedTexts.isEmpty)
            XCTAssertTrue(textInjector.replacedTexts.isEmpty)
            XCTAssertEqual(historyStore.list().last?.pipelineTiming?.llmOutcome?.outcome, .cancelled)
            XCTAssertEqual(historyStore.list().last?.pipelineTiming?.llmOutcome?.usedTranscriptFallback, false)
        }
    }

    @MainActor
    func testCancelledOrSupersededRewriteDoesNotApplyLateTranscript() async {
        for cancelTask in [true, false] {
            let started = expectation(description: "rewrite started")
            let textInjector = MockProcessingTextInjector()
            let controller = makeWorkflowController(
                textInjector: textInjector,
                sttTranscriber: MockProcessingTranscriber(transcript: "Do not insert this transcript"),
                llmService: SlowProcessingLLMService(delay: .milliseconds(200), onStart: { started.fulfill() }),
                configureSettings: configureReadyLLM
            )
            let sessionID = controller.processingSessionID
            let task = Task {
                await controller.process(
                    audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
                    record: HistoryRecord(date: Date(), recordingStatus: .succeeded),
                    selectionSnapshot: TextSelectionSnapshot(),
                    selectedText: nil,
                    askContextText: nil,
                    inputContext: nil,
                    personaPrompt: "Clean up the transcript.",
                    recordingIntent: .dictation,
                    sessionID: sessionID
                )
            }
            await fulfillment(of: [started], timeout: 2)
            if cancelTask {
                task.cancel()
            } else {
                _ = controller.beginProcessingSession()
            }
            await task.value

            XCTAssertTrue(textInjector.insertedTexts.isEmpty)
            XCTAssertTrue(textInjector.replacedTexts.isEmpty)
        }
    }

    func testAskFailureDoesNotInsertSpokenInstructionAsFallback() async {
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: "Summarize this draft"),
            historyStore: historyStore,
            configureSettings: {
                self.configureReadyLLM(settingsStore: $0)
            }
        )
        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
            record: HistoryRecord(date: Date(), audioFilePath: "/tmp/mock.wav", recordingStatus: .succeeded),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: nil,
            personaPrompt: nil,
            recordingIntent: .askSelection,
            sessionID: controller.processingSessionID
        )

        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
        XCTAssertEqual(historyStore.list().last?.transcriptionStatus, .succeeded)
        XCTAssertEqual(historyStore.list().last?.processingStatus, .failed)
        XCTAssertEqual(historyStore.list().last?.applyStatus, .skipped)
    }

    func testConnectivityFailureKeepsRecordingRetryableAndShowsPassiveNotice() async {
        let historyStore = MockProcessingHistoryStore()
        let audioPath = "/tmp/connectivity-fallback.wav"
        let controller = makeWorkflowController(
            sttTranscriber: MockProcessingTranscriber(error: URLError(.cannotConnectToHost)),
            historyStore: historyStore,
            configureSettings: { $0.sttProvider = .whisperAPI },
            hasPaidCloudSubscription: { true }
        )

        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: audioPath), duration: 1),
            record: HistoryRecord(
                date: Date(),
                audioFilePath: audioPath,
                recordingStatus: .succeeded,
                transcriptionStatus: .running
            ),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: nil,
            personaPrompt: nil,
            recordingIntent: .dictation,
            sessionID: controller.processingSessionID
        )

        XCTAssertEqual(controller.appState.status, .idle)
        XCTAssertEqual(controller.lastRetryableFailureRecord?.audioFilePath, audioPath)
        XCTAssertTrue(controller.overlayController.isShowingPassiveNotice)
        XCTAssertEqual(historyStore.list().last?.transcriptionStatus, .failed)
    }

    func testDecideAskSelectionThrowsConfigurationErrorWhenLLMIsNotConfigured() async {
        let controller = makeWorkflowController()

        await XCTAssertThrowsErrorAsync({
            try await controller.decideAskSelection(
                selectedText: "draft",
                spokenInstruction: "improve this",
                personaPrompt: nil,
                editableTarget: true,
                sessionID: UUID()
            )
        }) { error in
            XCTAssertEqual(
                error as? LLMConfigurationError,
                .notConfigured(reason: .missingAPIKey)
            )
        }
    }

    func testBeginRecordingStartsAudioBeforeAnalytics() async {
        let analytics = AnalyticsEventRecorder()
        let recorder = MockProcessingAudioRecorder {
            XCTAssertTrue(analytics.events.isEmpty, "Analytics must not delay microphone startup")
        }
        let controller = makeWorkflowController(audioRecorder: recorder, analyticsReporter: analytics)
        await controller.beginRecording(intent: .dictation, startLocked: false)
        XCTAssertEqual(analytics.events.first?.name, "dictation_session_started")
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testRecordingReadinessWaitsForNonemptyAudioEvenAfterQuickRelease() async throws {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        await controller.beginRecording(intent: .dictation, startLocked: false)
        controller.hotkeyPressedAt = controller.monotonicNow()
        controller.handlePressEnded()
        await waitForMainActorWork()
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(controller.appState.status, .idle)

        try recorder.emitAudio(frameCount: 0)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .idle)
        try recorder.emitAudio(frameCount: 320)
        await waitForMainActorWork()
        // Silent input shows the existing recording controls without waiting for speech.
        XCTAssertEqual(controller.appState.status, .recording)
        XCTAssertEqual(controller.overlayController.recordingPresentationForTesting, .recordingLocked)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testAskRecordingWaitsForAudioBeforeShowingReady() async throws {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        await controller.beginRecording(intent: .askSelection, startLocked: true)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .idle)
        try recorder.emitAudio(frameCount: 320, value: 0.00001)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .recording)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testCancelledRecordingAudioCannotMakeNextRecordingReady() async throws {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        await controller.beginRecording(intent: .dictation, startLocked: false)
        controller.cancelRecording()
        await waitForMainActorWork()
        await controller.beginRecording(intent: .dictation, startLocked: false)
        try recorder.emitAudio(frameCount: 320, recordingIndex: 0, value: 0.00001)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .idle)
        try recorder.emitAudio(frameCount: 320, recordingIndex: 1, value: 0.00001)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .recording)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testBeginRecordingStartsAudioBeforeCueSelectionOrDelay() async throws {
        let eventRecorder = ThreadSafeEventRecorder()
        let audioStarted = expectation(description: "audio recorder started")
        let audioRecorder = MockProcessingAudioRecorder {
            eventRecorder.append("audio-start")
            audioStarted.fulfill()
        }
        let controller = makeWorkflowController(
            textInjector: SlowSelectionTextInjector(eventRecorder: eventRecorder),
            audioRecorder: audioRecorder,
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder),
            sleep: { duration in
                eventRecorder.append("unexpected-sleep")
                eventRecorder.append(duration: duration)
            }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await fulfillment(of: [audioStarted], timeout: 0.5)

        let events = eventRecorder.snapshot()
        let audioStartIndex = try XCTUnwrap(events.firstIndex(of: "audio-start"))
        let selectionStartIndex = try XCTUnwrap(events.firstIndex(of: "selection-start"))
        XCTAssertLessThan(audioStartIndex, selectionStartIndex)
        XCTAssertTrue(events.contains("selection-intent-automatic"))
        XCTAssertFalse(events.contains("cue-play"))
        XCTAssertFalse(events.contains("unexpected-sleep"))
        XCTAssertEqual(eventRecorder.durationSnapshot(), [])

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testBeginRecordingStartsAudioBeforeRealtimeSessionSetupCompletes() async throws {
        let eventRecorder = ThreadSafeEventRecorder()
        let realtimeTranscriber = DelayedRealtimeSessionFactory(eventRecorder: eventRecorder)
        let audioRecorder = MockProcessingAudioRecorder {
            eventRecorder.append("audio-start")
        }
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sttTranscriber: realtimeTranscriber,
            configureSettings: { $0.sttProvider = .aliCloud },
            hasPaidCloudSubscription: { true }
        )

        let recordingTask = Task {
            await controller.beginRecording(intent: .dictation, startLocked: false)
        }
        await waitUntil {
            eventRecorder.snapshot().contains("realtime-setup")
        }

        let events = eventRecorder.snapshot()
        let audioStartIndex = try XCTUnwrap(events.firstIndex(of: "audio-start"))
        let realtimeSetupIndex = try XCTUnwrap(events.firstIndex(of: "realtime-setup"))
        XCTAssertLessThan(audioStartIndex, realtimeSetupIndex)

        realtimeTranscriber.releaseSetup()
        await recordingTask.value
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testAudioPrefixSurvivesDelayedRealtimeSetupInOrder() async throws {
        let events = ThreadSafeEventRecorder()
        let factory = DelayedRealtimeSessionFactory(eventRecorder: events)
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: recorder,
            sttTranscriber: factory,
            configureSettings: { $0.sttProvider = .aliCloud },
            hasPaidCloudSubscription: { true }
        )
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        await waitUntil { events.snapshot().contains("realtime-setup") }
        try recorder.emitAudio(frameCount: 320, value: 0.1)
        try recorder.emitAudio(frameCount: 320, value: 0.2)
        factory.releaseSetup()
        await startup.value
        try recorder.emitAudio(frameCount: 320, value: 0.3)
        await controller.activeRealtimeAudioBufferPump?.finishInput()
        let samples = await factory.session.receivedFirstSamples
        XCTAssertEqual(samples, [0.1, 0.2, 0.3])
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testBeginRecordingDoesNotPlayCueWhileAudioStartIsPending() async {
        let eventRecorder = ThreadSafeEventRecorder()
        let audioRecorder = BlockingStartAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder),
            sleep: { _ in }
        )

        let recordingTask = Task {
            await controller.beginRecording(intent: .dictation, startLocked: false)
        }
        audioRecorder.waitUntilStartIsPending()

        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play"))
        controller.finishRecordingFromCurrentMode()

        audioRecorder.releasePendingStart()
        await recordingTask.value
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play"))
    }

    func testCancelledDriverStartKeepsOwnershipUntilStopped() async {
        let recorder = BlockingStartAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        recorder.waitUntilStartIsPending()
        controller.cancelRecording()
        controller.handlePressBegan(intent: .dictation, startLocked: false)
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.isAudioRecorderStarting)
        XCTAssertEqual(recorder.startCallCount, 1)
        recorder.releasePendingStart()
        await startup.value
        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        await waitForMainActorWork()
        XCTAssertEqual(controller.appState.status, .idle)
    }

    func testCancellationBeforeQueuedStartupReleasesOwnership() async {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        let startID = UUID()
        controller.pendingRecordingStartID = startID
        controller.isRecording = true
        controller.isAudioRecorderStarting = true
        controller.cancelRecording()
        await controller.beginRecording(intent: .dictation, startLocked: false, startID: startID)
        XCTAssertEqual(recorder.startCallCount, 0)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        await waitForMainActorWork()
    }

    func testBeginRecordingResetsStateWhenAudioStartFails() async {
        let audioRecorder = ThrowingStartAudioRecorder(error: AVFoundationAudioRecorder.RecorderError
            .inputStartupTimedOut)
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertFalse(controller.shouldFinishRecordingAfterAudioStart)
        XCTAssertNil(controller.pendingRecordingStartID)
        XCTAssertEqual(controller.recordingMode, .holdToTalk)
        XCTAssertEqual(audioRecorder.startCallCount, 3)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        await MainActor.run {
            controller.overlayController.dismissImmediately()
        }
    }

    func testLivePreviewReceivesSnapshotBeforeTheRecordingCallbackReturns() async throws {
        let recorder = MockProcessingAudioRecorder()
        let previewer = SnapshotProcessingLivePreviewer()
        let controller = makeWorkflowController(
            audioRecorder: recorder,
            liveTranscriptionPreviewer: previewer,
            configureSettings: { $0.sttProvider = .localModel }
        )
        await controller.beginRecording(intent: .dictation, startLocked: false)
        XCTAssertTrue(controller.isRecording)
        try recorder.emitAudio(frameCount: 512, value: 0.25, valueAfterDelivery: 0.75)
        await previewer.releaseInput()
        for _ in 0..<100 {
            if await !previewer.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let values = await previewer.values
        XCTAssertEqual(values, [0.25], "The preview must own its audio before the producer resumes")
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testAudioStartFailureCopyExplainsMissingMicrophoneAndRecovery() {
        XCTAssertEqual(
            WorkflowController.audioStartFailureLocalizationKey(
                for: AVFoundationAudioRecorder.RecorderError.inputDeviceUnavailable
            ),
            "workflow.audioStart.noMicrophone"
        )
        XCTAssertEqual(
            WorkflowController.audioStartFailureLocalizationKey(
                for: AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
            ),
            "workflow.audioStart.microphoneNotReady"
        )
        XCTAssertEqual(
            WorkflowController.audioStartFailureLocalizationKey(
                for: NSError(domain: "unexpected", code: 1)
            ),
            "workflow.audioStart.genericFailure"
        )
    }

    func testBeginRecordingRetriesUntilAudioStartupSucceeds() async {
        let audioRecorder = TransientAudioStartupFailureRecorder(
            failureCount: 2,
            error: AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
        )
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(audioRecorder.startCallCount, 3)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testBeginRecordingRetriesFormatChangeUntilAudioStartupSucceeds() async {
        let audioRecorder = TransientAudioStartupFailureRecorder(
            failureCount: 5,
            error: NSError(
                domain: "com.apple.coreaudio.avfaudio",
                code: Int(kAudioUnitErr_FormatNotSupported)
            )
        )
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(audioRecorder.startCallCount, 6)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testBeginRecordingBoundsPersistentFormatChangeRetries() async {
        let audioRecorder = ThrowingStartAudioRecorder(
            error: NSError(
                domain: "com.apple.coreaudio.avfaudio",
                code: Int(kAudioUnitErr_FormatNotSupported)
            )
        )
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(audioRecorder.startCallCount, 12)
        await MainActor.run {
            controller.overlayController.dismissImmediately()
        }
    }

    func testReleasingAfterImmediateAudioStartStopsRecorder() async {
        let eventRecorder = ThreadSafeEventRecorder()
        let audioRecorder = MockProcessingAudioRecorder {
            eventRecorder.append("audio-start")
        }
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder),
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        let now = controller.monotonicNow()
        controller.hotkeyPressedAt = now - 1.1
        controller.audioRecorderStartedAt = now - 1.1
        controller.handlePressEnded()
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)

        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertTrue(eventRecorder.snapshot().contains("audio-start"))
    }

    func testTapToLockThresholdExceedsMinimumRecordingDuration() {
        XCTAssertGreaterThan(
            WorkflowController.tapToLockThreshold,
            WorkflowController.minimumRecordingDuration
        )
    }

    func testReleaseAtOneSecondKeepsRecordingLocked() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let releasedAt: TimeInterval = 1.0
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
            monotonicNow: { releasedAt }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        controller.hotkeyPressedAt = 0
        controller.audioRecorderStartedAt = 0
        controller.handlePressEnded()

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testDelayedShortReleaseUsesPhysicalTimestampAndKeepsRecording() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
            monotonicNow: { 12 }
        )
        await controller.beginRecording(intent: .dictation, startLocked: false)
        controller.hotkeyPressedAt = 10
        controller.audioRecorderStartedAt = 9

        // A 100ms physical tap is delivered two seconds after the press.
        controller.handlePressEnded(hotkeyUptime: 10.1)

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testReleaseBeforeAudioStartStaysLockedWhenDeliveryIsDelayed() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
            monotonicNow: { 12 }
        )
        await controller.beginRecording(intent: .dictation, startLocked: false)
        controller.hotkeyPressedAt = 10
        controller.audioRecorderStartedAt = 11.5

        controller.handlePressEnded(hotkeyUptime: 11.1)

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testReleaseJustAfterOneSecondStopsRecording() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let releasedAt: TimeInterval = 1.001
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
            monotonicNow: { releasedAt }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        controller.hotkeyPressedAt = 0
        controller.audioRecorderStartedAt = 0
        controller.handlePressEnded()
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)

        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
    }

    func testReleaseWithInsufficientCapturedAudioKeepsRecordingLocked() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        let now = controller.monotonicNow()
        controller.hotkeyPressedAt = now - 0.5
        controller.audioRecorderStartedAt = now - 0.2
        controller.handlePressEnded()

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testProvisionalRecordingStartsAudioBeforeSelectingAskMode() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let injector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: injector, audioRecorder: audioRecorder)
        let decision = RecordingGestureDecision()
        controller.recordingGestureDecision = decision
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        for _ in 0..<100 {
            if controller.isAudioRecorderStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertTrue(controller.isAudioRecorderStarted)
        XCTAssertNil(controller.selectionTask)
        XCTAssertNil(controller.activeRealtimeTranscriptionSession)
        XCTAssertTrue(injector.selectionCaptureIntents.isEmpty)

        controller.handlePressBegan(intent: .askSelection, startLocked: true)
        await startup.value

        XCTAssertEqual(controller.recordingIntent, .askSelection)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        let selection = await controller.selectionTask?.value
        XCTAssertEqual(selection?.source, "ask-isolated")
        XCTAssertTrue(injector.selectionCaptureIntents.isEmpty)
        XCTAssertNil(controller.activeRealtimeTranscriptionSession)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testProvisionalRecordingContinuesDictationAfterDecision() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: audioRecorder)
        let decision = RecordingGestureDecision()
        controller.recordingGestureDecision = decision
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        for _ in 0..<100 {
            if controller.isAudioRecorderStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.isAudioRecorderStarted)
        controller.handleActivationTap()
        decision.resolve()
        await startup.value
        XCTAssertEqual(controller.recordingIntent, .dictation)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        controller.confirmLockedRecording()
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        await waitForMainActorWork()
    }

    func testCancelProvisionalRecordingReleasesStartupWithoutSelectingMode() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: audioRecorder)
        controller.recordingGestureDecision = RecordingGestureDecision()
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        for _ in 0..<100 {
            if controller.isAudioRecorderStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        controller.cancelRecording()
        await startup.value
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.recordingGestureDecision)
        XCTAssertNil(controller.selectionTask)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        await waitForMainActorWork()
    }

    /// Main-actor isolated, so no processing task can run between the stop callbacks and the
    /// intent check: the check sees the state the callbacks left, not a finished recording.
    @MainActor
    func testRecordingStopCallbackPreservesAskAndDisablesAfterFinish() async {
        let hotkeys = MockProcessingHotkeyService()
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(hotkeyService: hotkeys, audioRecorder: audioRecorder)
        controller.start()
        XCTAssertEqual(hotkeys.recordingStopEnabled?(), false)
        await controller.beginRecording(intent: .askSelection, startLocked: true)
        XCTAssertEqual(hotkeys.recordingStopEnabled?(), true)
        hotkeys.onRecordingStop?()
        hotkeys.onRecordingStop?()
        XCTAssertEqual(controller.recordingIntent, .askSelection)
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertEqual(hotkeys.recordingStopEnabled?(), false)
        await waitForMainActorWork()
    }

    func testCompleteInputShortcutsStopWithoutChangingRecordingIntentOrPersona() async {
        for source in [WorkflowController.RecordingIntent.dictation, .askSelection] {
            for target in [WorkflowController.RecordingIntent.dictation, .askSelection] {
                for auxiliary in [false, true] {
                    let audioRecorder = MockProcessingAudioRecorder()
                    let controller = makeWorkflowController(audioRecorder: audioRecorder, sleep: { _ in })
                    await controller.beginRecording(intent: source, startLocked: source == .askSelection)
                    controller.recordingUsesAuxiliary = auxiliary
                    controller.handlePressBegan(intent: target, startLocked: target == .askSelection, auxiliary: !auxiliary)
                    XCTAssertEqual(controller.recordingIntent, source)
                    XCTAssertEqual(controller.recordingUsesAuxiliary, auxiliary)
                    await audioRecorder.waitUntilStopCount(isAtLeast: 1)
                    XCTAssertEqual(audioRecorder.startCallCount, 1)
                    XCTAssertEqual(audioRecorder.stopCallCount, 1)
                    controller.handlePressEnded()
                    controller.handleAskPressEnded()
                    XCTAssertEqual(audioRecorder.stopCallCount, 1)
                    await waitForMainActorWork()
                }
            }
        }
    }

    func testAskContextTextFallsBackToInputContextSelection() {
        let controller = makeWorkflowController()
        let inputContext = InputContextSnapshot(
            appName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXGroup",
            isEditable: true,
            isFocusedTarget: true,
            prefix: "Before",
            suffix: "After",
            selectedText: "Selected from input context"
        )

        let askContextText = controller.askContextText(
            from: TextSelectionSnapshot(source: "ask-promoted-isolated"),
            inputContext: inputContext
        )

        XCTAssertEqual(askContextText, "Selected from input context")
    }

    func testActivationTapAfterEndingLockedAskRecordingIsSuppressed() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .askSelection, startLocked: true)

        controller.handlePressBegan(intent: .dictation, startLocked: false)
        XCTAssertNotNil(controller.suppressActivationTapUntil)

        controller.handleActivationTap()

        XCTAssertNil(controller.suppressActivationTapUntil)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)
        await waitForMainActorWork()
    }

    func testActivationTapWhileHoldingDictationLocksExistingRecording() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        controller.handleActivationTap()

        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.startCallCount, 1)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testReleasingWhileAudioStartIsPendingKeepsRecordingLocked() async {
        let audioRecorder = BlockingStartAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        let recordingTask = Task {
            await controller.beginRecording(intent: .dictation, startLocked: false)
        }
        audioRecorder.waitUntilStartIsPending()

        controller.hotkeyPressedAt = controller.monotonicNow() - 0.5
        controller.handlePressEnded()

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertFalse(controller.shouldFinishRecordingAfterAudioStart)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)

        audioRecorder.releasePendingStart()
        await recordingTask.value

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testNewPressIsIgnoredWhileAudioRecorderStopIsPending() async {
        let audioRecorder = BlockingStopAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        XCTAssertEqual(audioRecorder.startCallCount, 1)

        controller.finishRecordingFromCurrentMode()
        audioRecorder.waitUntilStopIsPending()

        controller.handlePressBegan(intent: .dictation, startLocked: false)

        XCTAssertEqual(audioRecorder.startCallCount, 1)
        audioRecorder.releasePendingStop()
    }

    func testFinishRecordingContinuesWhenPreviewTextExistsDespiteSilentAudioGate() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let textInjector = MockProcessingTextInjector()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "final transcript"),
            sleep: { _ in }
        )
        controller.latestRecordingPreviewText = "preview transcript"
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil {
            textInjector.insertedTexts == ["final transcript"]
        }

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertEqual(textInjector.insertedTexts, ["final transcript"])
        XCTAssertTrue(controller.latestRecordingPreviewText.isEmpty)
    }

    func testFinishRecordingUsesPreviewTextWhenFinalTranscriptionIsEmpty() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: ""),
            historyStore: historyStore,
            sleep: { _ in }
        )
        controller.latestRecordingPreviewText = "preview transcript"
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil {
            textInjector.insertedTexts == ["preview transcript"]
        }

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertEqual(textInjector.insertedTexts, ["preview transcript"])
        XCTAssertEqual(historyStore.list().last?.transcriptText, "preview transcript")
        XCTAssertTrue(controller.latestRecordingPreviewText.isEmpty)
    }

    func testFinishRecordingUsesPreviewTextWhenFinalTranscriptionReportsNoSpeech() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let noSpeechError = NSError(
            domain: "STT",
            code: 204,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected in audio."]
        )
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(error: noSpeechError),
            historyStore: historyStore,
            sleep: { _ in }
        )
        controller.latestRecordingPreviewText = "preview transcript"
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil {
            textInjector.insertedTexts == ["preview transcript"]
        }

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertEqual(textInjector.insertedTexts, ["preview transcript"])
        XCTAssertEqual(historyStore.list().last?.transcriptText, "preview transcript")
        XCTAssertTrue(controller.latestRecordingPreviewText.isEmpty)
        XCTAssertNil(controller.lastRetryableFailureRecord)
    }

    func testFinishRecordingUsesPreviewTextWhenFinalTranscriptionIsPreviewSuffix() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "后半段内容。"),
            historyStore: historyStore,
            sleep: { _ in }
        )
        controller.latestRecordingPreviewText = "前半段内容，后半段内容。"
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil {
            historyStore.list().last?.applyStatus == .succeeded
        }

        XCTAssertEqual(textInjector.insertedTexts, ["前半段内容，后半段内容"])
        XCTAssertEqual(historyStore.list().last?.transcriptText, "前半段内容，后半段内容。")
    }

    func testPreferredTranscriptKeepsRawWhenPreviewDoesNotContainFinalAsSuffix() {
        let choice = WorkflowController.preferredTranscript(
            rawTranscribedText: "final transcript",
            recordingPreviewText: "preview transcript"
        )

        XCTAssertEqual(choice.text, "final transcript")
        XCTAssertEqual(choice.reason, .raw)
    }

    func testQuickInputHoldToTalkBypassesPersonaRewriteAfterTranscription() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "persona rewrite")
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "raw transcript"),
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: { settingsStore in
                self.configureReadyLLM(settingsStore: settingsStore)
                settingsStore.quickInputEnabled = true
                settingsStore.applyPersonaSelection(settingsStore.personas[0].id)
            }
        )
        controller.latestRecordingPreviewText = "preview transcript"
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(
            recordingStoppedAt: Date(),
            bypassPersonaRewrite: true
        )
        await waitUntil {
            textInjector.insertedTexts == ["raw transcript"]
        }

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertEqual(textInjector.insertedTexts, ["raw transcript"])
        XCTAssertEqual(llmService.streamRewriteCallCount, 0)
        let savedRecord = historyStore.list().last
        XCTAssertEqual(savedRecord?.mode, .dictation)
        XCTAssertNil(savedRecord?.personaPrompt)
        XCTAssertNil(savedRecord?.personaResultText)
    }

    func testQuickInputLockedRecordingStillAppliesPersonaRewrite() async {
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let llmService = CountingProcessingLLMService(rewriteText: "persona rewrite")
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: "raw transcript"),
            llmService: llmService,
            historyStore: historyStore,
            configureSettings: { settingsStore in
                self.configureReadyLLM(settingsStore: settingsStore)
                settingsStore.quickInputEnabled = true
                settingsStore.applyPersonaSelection(settingsStore.personas[0].id)
            }
        )

        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
            record: HistoryRecord(
                date: Date(),
                personaPrompt: "Use the selected persona.",
                recordingStatus: .succeeded
            ),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: nil,
            personaPrompt: "Use the selected persona.",
            recordingIntent: .dictation,
            sessionID: controller.processingSessionID
        )
        await waitUntil {
            textInjector.insertedTexts == ["persona rewrite"]
        }

        XCTAssertEqual(textInjector.insertedTexts, ["persona rewrite"])
        XCTAssertEqual(llmService.streamRewriteCallCount, 1)
        let savedRecord = historyStore.list().last
        XCTAssertEqual(savedRecord?.mode, .personaRewrite)
        XCTAssertEqual(savedRecord?.transcriptText, "raw transcript")
        XCTAssertEqual(savedRecord?.personaResultText, "persona rewrite")
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.outcome, .completed)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.timeoutMilliseconds, 3_000)
        XCTAssertEqual(savedRecord?.pipelineTiming?.llmOutcome?.usedTranscriptFallback, false)
    }

    @MainActor
    func testLockedPersonaRewriteReusesRealtimeSessionWhenOptimizeDiffers() async {
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let realtimeSession = MockOptimizeRealtimeSession(
            optimize: true,
            transcript: "incorrect realtime transcript"
        )
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: "batch transcript"),
            llmService: CountingProcessingLLMService(rewriteText: "persona rewrite"),
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )

        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
            realtimeTranscriptionSession: realtimeSession,
            record: HistoryRecord(date: Date(), recordingStatus: .succeeded),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: nil,
            personaPrompt: "Use the selected persona.",
            recordingIntent: .dictation,
            sessionID: controller.processingSessionID
        )

        let sessionCalls = await realtimeSession.callCounts()
        XCTAssertEqual(sessionCalls.finish, 1)
        XCTAssertEqual(sessionCalls.cancel, 0)
        XCTAssertEqual(historyStore.list().last?.transcriptText, "incorrect realtime transcript")
        XCTAssertEqual(textInjector.insertedTexts, ["persona rewrite"])
    }

    @MainActor
    func testInputContextRewriteReusesRealtimeSessionWhenOptimizeDiffers() async {
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let realtimeSession = MockOptimizeRealtimeSession(
            optimize: true,
            transcript: "incorrect realtime transcript"
        )
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: "batch transcript"),
            llmService: CountingProcessingLLMService(rewriteText: "context rewrite"),
            historyStore: historyStore,
            configureSettings: configureReadyLLM
        )
        let inputContext = InputContextSnapshot(
            appName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            role: "AXTextArea",
            isEditable: true,
            isFocusedTarget: true,
            prefix: "Existing document text",
            suffix: "",
            selectedText: nil
        )

        await controller.process(
            audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1),
            realtimeTranscriptionSession: realtimeSession,
            record: HistoryRecord(date: Date(), recordingStatus: .succeeded),
            selectionSnapshot: TextSelectionSnapshot(),
            selectedText: nil,
            askContextText: nil,
            inputContext: inputContext,
            personaPrompt: nil,
            recordingIntent: .dictation,
            sessionID: controller.processingSessionID
        )

        let sessionCalls = await realtimeSession.callCounts()
        XCTAssertEqual(sessionCalls.finish, 1)
        XCTAssertEqual(sessionCalls.cancel, 0)
        XCTAssertEqual(historyStore.list().last?.transcriptText, "incorrect realtime transcript")
        XCTAssertEqual(textInjector.insertedTexts, ["context rewrite"])
    }

    func testFinishRecordingCancelsSilentAudioWhenPreviewTextIsEmpty() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1.0)

        let textInjector = MockProcessingTextInjector()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let analytics = AnalyticsEventRecorder()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "should not transcribe"),
            analyticsReporter: analytics,
            sleep: { _ in }
        )
        controller.beginDictationAnalytics(intent: .dictation, mode: .holdToTalk, targetBundleIdentifier: nil)
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitForMainActorWork()

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        let failed = try XCTUnwrap(analytics.events.last)
        XCTAssertEqual(failed.name, "dictation_session_failed")
        XCTAssertEqual(failed.properties["error_kind"], "client_hard_silence")
        XCTAssertEqual(failed.properties["audio_signal"], "hard_silence")
    }

    func testFinishRecordingRetriesLowEnergyAudioOnceAndUsesRetryResult() async throws {
        let audioURL = try writeTestAudio(
            samples: sineWaveSamples(amplitude: 0.003, frameCount: 16_000)
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = SequencedProfileAwareTranscriber(transcripts: ["", "OK"])
        let textInjector = MockProcessingTextInjector()
        let analytics = AnalyticsEventRecorder()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: FileReturningAudioRecorder(fileURL: audioURL),
            sttTranscriber: transcriber,
            analyticsReporter: analytics,
            sleep: { _ in },
            configureSettings: { $0.sttProvider = .localModel }
        )
        controller.beginDictationAnalytics(intent: .dictation, mode: .holdToTalk, targetBundleIdentifier: nil)
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil {
            textInjector.insertedTexts == ["OK"] && analytics.events.last?.name == "dictation_session_completed"
        }

        XCTAssertEqual(textInjector.insertedTexts, ["OK"])
        XCTAssertEqual(transcriber.profiles, [.standard, .lowEnergyRetry])
        XCTAssertEqual(transcriber.audioURLs.count, 2)
        XCTAssertEqual(transcriber.audioURLs[0], transcriber.audioURLs[1])
        XCTAssertNotEqual(transcriber.audioURLs[0], audioURL)
        let completed = try XCTUnwrap(analytics.events.last)
        XCTAssertEqual(completed.name, "dictation_session_completed")
        XCTAssertEqual(completed.properties["audio_signal"], "low_energy")
        XCTAssertEqual(completed.properties["low_energy_retry"], "true")
    }

    func testFinishRecordingDoesNotRetryShortAudibleAudioAfterSuccessfulResult() async throws {
        let audioURL = try writeTestAudio(
            samples: sineWaveSamples(amplitude: 0.2, frameCount: 16_000)
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = SequencedProfileAwareTranscriber(transcripts: ["OK"])
        let textInjector = MockProcessingTextInjector()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: FileReturningAudioRecorder(fileURL: audioURL),
            sttTranscriber: transcriber,
            sleep: { _ in },
            configureSettings: { $0.sttProvider = .localModel }
        )
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil { textInjector.insertedTexts == ["OK"] }

        XCTAssertEqual(transcriber.profiles, [.standard])
        XCTAssertEqual(transcriber.audioURLs, [audioURL])
    }

    func testFinishRecordingStopsAfterOneEmptyLowEnergyRetry() async throws {
        let audioURL = try writeTestAudio(
            samples: sineWaveSamples(amplitude: 0.003, frameCount: 16_000)
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = SequencedProfileAwareTranscriber(transcripts: ["", "", "unexpected"])
        let controller = makeWorkflowController(
            audioRecorder: FileReturningAudioRecorder(fileURL: audioURL),
            sttTranscriber: transcriber,
            sleep: { _ in },
            configureSettings: { $0.sttProvider = .localModel }
        )
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitUntil { transcriber.profiles.count == 2 }
        await waitForMainActorWork()

        XCTAssertEqual(transcriber.profiles, [.standard, .lowEnergyRetry])
    }

    func testFinishRecordingCapturesTailBeforeStoppingRecorder() async throws {
        let audioURL = try writeSilentTestAudio(duration: 1)
        let durations = ThreadSafeDurationRecorder()
        let audioRecorder = FileReturningAudioRecorder(fileURL: audioURL)
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { durations.append($0) }
        )
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())

        XCTAssertEqual(durations.values.first, WorkflowController.recordingTailCaptureDuration)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
    }

    @MainActor
    func testPressShowsLocalModelDownloadAlertAndDoesNotRecord() async {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let audioRecorder = MockProcessingAudioRecorder()
        let alertPresenter = MockLocalModelDownloadAlertPresenter()
        let localModelManager = MockWorkflowLocalModelManager()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            localModelManager: localModelManager,
            localModelDownloadAlertPresenter: alertPresenter,
            configureSettings: { settingsStore in
                settingsStore.sttProvider = .localModel
                settingsStore.localSTTModel = .senseVoiceSmall
            }
        )
        LocalModelDownloadProgressCenter.shared.reportDownloading(model: .senseVoiceSmall, progress: 0.42)

        controller.handlePressBegan(intent: .dictation, startLocked: false)
        controller.handlePressBegan(intent: .dictation, startLocked: false)
        await waitForMainActorWork()
        controller.handleActivationTap()
        await waitForMainActorWork()

        XCTAssertEqual(audioRecorder.startCallCount, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(alertPresenter.presentedModels, [.senseVoiceSmall])
        XCTAssertEqual(alertPresenter.presentedProgresses, [0.42])

        controller.handlePressBegan(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertEqual(audioRecorder.startCallCount, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(alertPresenter.presentedModels, [.senseVoiceSmall, .senseVoiceSmall])
        XCTAssertEqual(alertPresenter.presentedProgresses, [0.42, 0.42])
    }

    func testPressStartsLocalModelDownloadWhenSelectedModelIsMissing() async {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let audioRecorder = MockProcessingAudioRecorder()
        let alertPresenter = MockLocalModelDownloadAlertPresenter()
        let localModelManager = MockWorkflowLocalModelManager()
        let prepared = expectation(description: "selected local model preparation started")
        localModelManager.onPrepare = {
            prepared.fulfill()
        }
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            localModelManager: localModelManager,
            localModelDownloadAlertPresenter: alertPresenter,
            configureSettings: { settingsStore in
                settingsStore.sttProvider = .localModel
                settingsStore.localSTTModel = .senseVoiceSmall
            }
        )

        controller.handlePressBegan(intent: .dictation, startLocked: false)
        await fulfillment(of: [prepared], timeout: 1)
        await waitForMainActorWork()

        XCTAssertEqual(audioRecorder.startCallCount, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(localModelManager.preparedConfigurations.first?.model, .senseVoiceSmall)
        XCTAssertEqual(alertPresenter.presentedModels, [.senseVoiceSmall])
        XCTAssertEqual(alertPresenter.presentedProgresses, [0.02])
    }

    func testLocalModelDownloadFailureUpdatesProgressCenter() async {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let localModelManager = MockWorkflowLocalModelManager()
        localModelManager.prepareError = NSError(
            domain: "WorkflowControllerProcessingTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Network unavailable"]
        )
        let prepared = expectation(description: "selected local model preparation attempted")
        localModelManager.onPrepare = {
            prepared.fulfill()
        }
        let controller = makeWorkflowController(
            localModelManager: localModelManager,
            configureSettings: { settingsStore in
                settingsStore.sttProvider = .localModel
                settingsStore.localSTTModel = .senseVoiceSmall
            }
        )

        controller.handlePressBegan(intent: .dictation, startLocked: false)
        await fulfillment(of: [prepared], timeout: 1)

        for _ in 0 ..< 100 {
            if case let .failed(model, message) = LocalModelDownloadProgressCenter.shared.status {
                XCTAssertEqual(model, .senseVoiceSmall)
                XCTAssertEqual(message, "Network unavailable")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Expected local model download failure status")
    }

    @MainActor
    func testPaidCreditExhaustedPromptIsSuppressedForOneHour() {
        let controller = makeWorkflowController()
        let error = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        let firstPresentation = Date(timeIntervalSince1970: 1000)

        XCTAssertTrue(controller.shouldPresentCloudBillingError(
            error,
            hasPaidSubscription: true,
            now: firstPresentation
        ))
        XCTAssertFalse(controller.shouldPresentCloudBillingError(
            error,
            hasPaidSubscription: true,
            now: firstPresentation.addingTimeInterval(30 * 60)
        ))
        XCTAssertTrue(controller.shouldPresentCloudBillingError(
            error,
            hasPaidSubscription: true,
            now: firstPresentation.addingTimeInterval(60 * 60)
        ))
    }

    @MainActor
    func testFreeCreditExhaustedPromptIsNotSuppressed() {
        let controller = makeWorkflowController()
        let error = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        let firstPresentation = Date(timeIntervalSince1970: 1000)

        XCTAssertTrue(controller.shouldPresentCloudBillingError(
            error,
            hasPaidSubscription: false,
            now: firstPresentation
        ))
        XCTAssertTrue(controller.shouldPresentCloudBillingError(
            error,
            hasPaidSubscription: false,
            now: firstPresentation.addingTimeInterval(30 * 60)
        ))
    }

    func testDictationAnalyticsCorrelatesStartedAndCompletedWithoutTextOrAppIdentity() throws {
        let recorder = AnalyticsEventRecorder()
        let controller = makeWorkflowController(analyticsReporter: recorder)
        let record = HistoryRecord(
            date: Date(),
            postProcessedText: "private transcript",
            recordingDurationSeconds: 1.25,
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .skipped,
            applyStatus: .succeeded
        )

        controller.beginDictationAnalytics(
            intent: .dictation,
            mode: .locked,
            targetBundleIdentifier: "com.google.Chrome"
        )
        controller.bindPendingDictationAnalytics(to: record.id)
        controller.recordDictationApplyAnalytics(recordID: record.id, outcome: .inserted)
        controller.reportDictationTerminal(record: record)

        XCTAssertEqual(recorder.events.map(\.name), ["dictation_session_started", "dictation_session_completed"])
        let started = recorder.events[0].properties
        let completed = recorder.events[1].properties
        XCTAssertEqual(started["recording_mode"], "locked")
        XCTAssertEqual(started["intent"], "dictation")
        XCTAssertEqual(completed["flow_id"], started["flow_id"])
        XCTAssertEqual(completed["audio_seconds"], "1.250")
        XCTAssertEqual(completed["output_chars"], "18")
        XCTAssertEqual(completed["apply_outcome"], "inserted")
        XCTAssertEqual(completed["injection_method"], "ax")
        XCTAssertEqual(completed["target_app_category"], "browser")
        XCTAssertFalse(recorder.events.flatMap { $0.properties.values }.contains("private transcript"))
        XCTAssertFalse(recorder.events.flatMap { $0.properties.values }.contains("com.google.Chrome"))
    }

    func testDictationAnalyticsFailureReportsStageAndSanitizedKind() throws {
        let recorder = AnalyticsEventRecorder()
        let controller = makeWorkflowController(analyticsReporter: recorder)
        let record = HistoryRecord(
            date: Date(),
            errorMessage: "secret provider response",
            recordingStatus: .succeeded,
            transcriptionStatus: .failed,
            processingStatus: .skipped,
            applyStatus: .skipped
        )

        controller.beginDictationAnalytics(intent: .dictation, mode: .holdToTalk, targetBundleIdentifier: nil)
        controller.bindPendingDictationAnalytics(to: record.id)
        controller.reportDictationTerminal(record: record)

        let failed = try XCTUnwrap(recorder.events.last)
        XCTAssertEqual(failed.name, "dictation_session_failed")
        XCTAssertEqual(failed.properties["stage"], "transcription")
        XCTAssertEqual(failed.properties["error_kind"], "transcription_failed")
        XCTAssertFalse(failed.properties.values.contains("secret provider response"))
    }

    func testDictationAnalyticsClosesSkippedTerminalPathAsFailure() throws {
        let recorder = AnalyticsEventRecorder()
        let controller = makeWorkflowController(analyticsReporter: recorder)
        let record = HistoryRecord(
            date: Date(),
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .skipped,
            applyStatus: .skipped
        )

        controller.beginDictationAnalytics(intent: .dictation, mode: .holdToTalk, targetBundleIdentifier: nil)
        controller.bindPendingDictationAnalytics(to: record.id)
        controller.reportDictationTerminal(record: record)

        let failed = try XCTUnwrap(recorder.events.last)
        XCTAssertEqual(failed.name, "dictation_session_failed")
        XCTAssertEqual(failed.properties["stage"], "processing")
        XCTAssertEqual(failed.properties["error_kind"], "processing_skipped")
    }

    func testDictationAnalyticsReportsPendingFailureAndClearsContext() throws {
        let recorder = AnalyticsEventRecorder()
        let controller = makeWorkflowController(analyticsReporter: recorder)

        controller.beginDictationAnalytics(intent: .dictation, mode: .holdToTalk, targetBundleIdentifier: nil)
        controller.reportPendingDictationFailure(stage: "recording", kind: "recording_too_short")
        controller.reportPendingDictationFailure(stage: "recording", kind: "recording_too_short")

        XCTAssertEqual(recorder.events.map(\.name), ["dictation_session_started", "dictation_session_failed"])
        let failed = try XCTUnwrap(recorder.events.last)
        XCTAssertEqual(failed.properties["stage"], "recording")
        XCTAssertEqual(failed.properties["error_kind"], "recording_too_short")
    }

    private func makeWorkflowController(
        textInjector: TextInjector = MockProcessingTextInjector(),
        hotkeyService: HotkeyService = MockProcessingHotkeyService(),
        audioRecorder: AudioRecorder = MockProcessingAudioRecorder(),
        sttTranscriber: Transcriber = MockProcessingTranscriber(),
        localFallbackTranscriber: Transcriber? = nil,
        llmService: LLMService = MockProcessingLLMService(),
        historyStore: HistoryStore = MockProcessingHistoryStore(),
        clipboard: ClipboardService = MockClipboardService(),
        soundEffectPlayer: SoundEffectPlayer? = nil,
        liveTranscriptionPreviewer: (any LiveTranscriptionPreviewing)? = nil,
        localModelManager: (any LocalSTTModelManaging)? = nil,
        localModelDownloadAlertPresenter: any LocalModelDownloadAlertPresenting =
            MockLocalModelDownloadAlertPresenter(),
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        configureSettings: ((SettingsStore) -> Void)? = nil,
        hasPaidCloudSubscription: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthState.shared.canUseCloudASR }
        }
    ) -> WorkflowController {
        let suiteName = "WorkflowControllerProcessingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        configureSettings?(settingsStore)
        let appState = AppStateStore()
        let overlayController = OverlayController(appState: appState)

        return WorkflowController(
            appState: appState,
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            audioRecorder: audioRecorder,
            sttRouter: STTRouter(
                settingsStore: settingsStore,
                whisper: sttTranscriber,
                freeSTT: sttTranscriber,
                appleSpeech: sttTranscriber,
                localModel: sttTranscriber,
                multimodal: sttTranscriber,
                aliCloud: sttTranscriber,
                doubaoRealtime: sttTranscriber,
                googleCloud: sttTranscriber,
                groq: sttTranscriber,
                soniox: sttTranscriber,
                typefluxOfficial: sttTranscriber,
                typefluxCloudLoginFallbackLocalModel: localFallbackTranscriber,
                hasPaidTypefluxCloudSubscription: hasPaidCloudSubscription
            ),
            llmService: llmService,
            llmAgentService: MockProcessingLLMAgentService(),
            textInjector: textInjector,
            clipboard: clipboard,
            historyStore: historyStore,
            mcpRegistry: MCPRegistry(),
            overlayController: overlayController,
            askAnswerWindowController: AskAnswerWindowController(
                clipboard: MockClipboardService(),
                settingsStore: settingsStore,
                outputPostProcessor: NoopOutputPostProcessor()
            ),
            soundEffectPlayer: soundEffectPlayer ?? SoundEffectPlayer(settingsStore: settingsStore),
            liveTranscriptionPreviewer: liveTranscriptionPreviewer,
            localModelManager: localModelManager,
            localModelDownloadAlertPresenter: localModelDownloadAlertPresenter,
            outputPostProcessor: NoopOutputPostProcessor(),
            analyticsReporter: analyticsReporter,
            sleep: sleep,
            monotonicNow: monotonicNow
        )
    }

    private func configureReadyLLM(settingsStore: SettingsStore) {
        settingsStore.setLLMBaseURL("https://example.com/v1", for: .custom)
        settingsStore.setLLMModel("test-model", for: .custom)
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .custom
    }

    private func makeRecordingSoundEffectPlayer(
        eventRecorder: ThreadSafeEventRecorder,
        soundEffectsEnabled: Bool = true
    ) -> SoundEffectPlayer {
        let suiteName = "WorkflowControllerProcessingSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.soundEffectsEnabled = soundEffectsEnabled
        return SoundEffectPlayer(
            settingsStore: settingsStore,
            isEnabledOverride: { soundEffectsEnabled }
        ) { _ in
            MockSoundEffectPlayback(eventRecorder: eventRecorder)
        }
    }

    private func makeNamedSoundEffectPlayer(
        eventRecorder: ThreadSafeEventRecorder,
        soundEffectsEnabled: Bool = true
    ) -> SoundEffectPlayer {
        let suiteName = "WorkflowControllerProcessingNamedSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.soundEffectsEnabled = soundEffectsEnabled
        return SoundEffectPlayer(
            settingsStore: settingsStore,
            isEnabledOverride: { soundEffectsEnabled }
        ) { url in
            let effectName = url.deletingPathExtension().lastPathComponent
            return MockSoundEffectPlayback(eventRecorder: eventRecorder, eventName: "cue-play-\(effectName)")
        }
    }

    private func waitForMainActorWork() async {
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func writeSilentTestAudio(duration: TimeInterval, sampleRate: Double = 16000) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "WorkflowControllerProcessingTests", code: 1)
        }

        let frameCount = Int(duration * sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NSError(domain: "WorkflowControllerProcessingTests", code: 2)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        try audioFile.write(from: buffer)
        return url
    }

    private func writeTestAudio(samples: [Float], sampleRate: Double = 16_000) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "WorkflowControllerProcessingTests", code: 3)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(domain: "WorkflowControllerProcessingTests", code: 4)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData?[0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
        return url
    }

    private func sineWaveSamples(amplitude: Float, frameCount: Int) -> [Float] {
        (0 ..< frameCount).map { frame in
            amplitude * Float(sin(2 * .pi * 440 * Double(frame) / 16_000))
        }
    }

    func testTypefluxASROptimizeIsDisabledForPersonaRewrite() {
        let persona = PersonaProfile(name: "Meeting Notes", prompt: "Clean up dictation.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personaRewriteEnabled = true
            settingsStore.personas += [persona]
            settingsStore.activePersonaID = persona.id.uuidString
        })

        XCTAssertFalse(controller.shouldOptimizeTypefluxASR(
            intent: .dictation,
            recordingMode: .locked,
            appName: nil,
            bundleIdentifier: nil
        ))
    }

    func testTypefluxASROptimizeIsEnabledForQuickInput() {
        let persona = PersonaProfile(name: "Meeting Notes", prompt: "Clean up dictation.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.quickInputEnabled = true
            settingsStore.personaRewriteEnabled = true
            settingsStore.personas += [persona]
            settingsStore.activePersonaID = persona.id.uuidString
        })

        XCTAssertTrue(controller.shouldOptimizeTypefluxASR(
            intent: .dictation,
            recordingMode: .holdToTalk,
            appName: nil,
            bundleIdentifier: nil
        ))
    }

    func testTypefluxASROptimizeIsEnabledWhenPersonaIsDisabled() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personaRewriteEnabled = false
        })

        XCTAssertTrue(controller.shouldOptimizeTypefluxASR(
            intent: .dictation,
            recordingMode: .locked,
            appName: nil,
            bundleIdentifier: nil
        ))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private final class MockProcessingTextInjector: TextInjector {
    private(set) var insertedTexts: [String] = []
    private(set) var replacedTexts: [String] = []
    private(set) var replacementTargets: [TextSelectionSnapshot?] = []
    private(set) var selectionCaptureIntents: [SelectionCaptureIntent] = []
    var deliveryResult: TextDeliveryResult = .delivered(.ax)
    var onDeliver: (() -> Void)?
    private(set) var deliveryCallCount = 0
    private let selectionSnapshot: TextSelectionSnapshot
    private let inputSnapshot: CurrentInputTextSnapshot
    private let insertError: Error?
    private let replaceError: Error?

    init(
        selectionSnapshot: TextSelectionSnapshot = TextSelectionSnapshot(),
        inputSnapshot: CurrentInputTextSnapshot = CurrentInputTextSnapshot(),
        insertError: Error? = nil,
        replaceError: Error? = nil
    ) {
        self.selectionSnapshot = selectionSnapshot
        self.inputSnapshot = inputSnapshot
        self.insertError = insertError
        self.replaceError = replaceError
    }

    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        selectionCaptureIntents.append(intent)
        return selectionSnapshot
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        inputSnapshot
    }

    func currentInputText() async -> String? {
        nil
    }

    @MainActor
    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        try Task.checkCancellation()
        deliveryCallCount += 1
        onDeliver?()
        switch destination {
        case .currentInput:
            if let insertError { throw insertError }
            insertedTexts.append(text)
        case let .selection(target):
            if let replaceError { throw replaceError }
            replacedTexts.append(text)
            replacementTargets.append(target)
        }
        return deliveryResult
    }

}

private final class SlowSelectionTextInjector: TextInjector {
    private let eventRecorder: ThreadSafeEventRecorder

    init(eventRecorder: ThreadSafeEventRecorder) {
        self.eventRecorder = eventRecorder
    }

    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        switch intent {
        case .automaticInsertion:
            eventRecorder.append("selection-intent-automatic")
        case .explicitSelectionAction:
            eventRecorder.append("selection-intent-explicit")
        case .readOnlyContext:
            eventRecorder.append("selection-intent-read-only")
        }
        eventRecorder.append("selection-start")
        try? await Task.sleep(for: .seconds(30))
        return TextSelectionSnapshot()
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        eventRecorder.append("input-context-start")
        try? await Task.sleep(for: .seconds(30))
        return CurrentInputTextSnapshot()
    }

    func currentInputText() async -> String? {
        nil
    }

    @MainActor
    func deliver(text _: String, to _: TextDeliveryDestination) async throws -> TextDeliveryResult {
        .delivered(.ax)
    }
}

private final class MockProcessingLLMService: LLMService {
    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        ""
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        "{}"
    }
}

private final class CountingProcessingLLMService: LLMService {
    private let rewriteText: String
    private let error: Error?
    private let lock = NSLock()
    private var rewriteCalls = 0
    private var recordedRequests: [LLMRewriteRequest] = []
    var requests: [LLMRewriteRequest] { lock.withLock { recordedRequests } }

    init(rewriteText: String, error: Error? = nil) {
        self.rewriteText = rewriteText
        self.error = error
    }

    var streamRewriteCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rewriteCalls
    }

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        rewriteCalls += 1
        recordedRequests.append(request)
        lock.unlock()
        let rewriteText = rewriteText
        return AsyncThrowingStream { continuation in
            continuation.yield(rewriteText)
            continuation.finish(throwing: error)
        }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        ""
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        "{}"
    }
}

private final class SlowProcessingLLMService: LLMService {
    private let delay: Duration
    private let onStart: (() -> Void)?

    init(delay: Duration, onStart: (() -> Void)? = nil) {
        self.delay = delay
        self.onStart = onStart
    }

    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            onStart?()
            Task {
                do {
                    try await Task.sleep(for: delay)
                    continuation.yield("late")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        ""
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        "{}"
    }
}

private final class ProgressingProcessingLLMService: LLMService {
    private let chunks: [String]
    private let delay: Duration

    init(chunks: [String], delay: Duration) {
        self.chunks = chunks
        self.delay = delay
    }

    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        let delay = delay
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for chunk in chunks {
                        continuation.yield(chunk)
                        try await Task.sleep(for: delay)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        ""
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        "{}"
    }
}

private final class MockProcessingLLMAgentService: LLMAgentService {
    func runTool<T: Decodable & Sendable>(request _: LLMAgentRequest, decoding _: T.Type) async throws -> T {
        throw NSError(domain: "MockProcessingLLMAgentService", code: 1)
    }
}

private final class MockProcessingHotkeyService: HotkeyService {
    var recordingStopEnabled: (() -> Bool)?
    var onRecordingStop: (() -> Void)?
    var onAuxiliaryPressBegan: ((HotkeyEventContext) -> Void)?
    var onAuxiliaryPressEnded: ((HotkeyEventContext) -> Void)?
    var onAuxiliaryPromoted: ((HotkeyEventContext) -> Void)?
    var onActivationTap: ((HotkeyEventContext) -> Void)?
    var onActivationPressBegan: ((HotkeyEventContext) -> Void)?
    var onActivationPressEnded: ((HotkeyEventContext) -> Void)?
    var onActivationCancelled: (() -> Void)?
    var onAskPressBegan: ((HotkeyEventContext) -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onHistoryRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    func start() {}
    func stop() {}
}

private final class MockProcessingAudioRecorder: AudioRecorder {
    private let onStart: () -> Void
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var bufferHandlers: [((AVAudioPCMBuffer) -> Void)?] = []

    init(onStart: @escaping () -> Void = {}) {
        self.onStart = onStart
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func waitUntilStopCount(isAtLeast expectedCount: Int) async {
        for _ in 0 ..< 100 {
            if stopCallCount >= expectedCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        bufferHandlers.append(audioBufferHandler)
        lock.unlock()
        onStart()
    }

    func emitAudio(
        frameCount: AVAudioFrameCount, recordingIndex: Int = 0, value: Float = 0, valueAfterDelivery: Float? = nil
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frameCount)))
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].update(repeating: value, count: Int(frameCount))
        let handler = lock.withLock { bufferHandlers[recordingIndex] }
        handler?(buffer)
        if let valueAfterDelivery {
            buffer.floatChannelData?[0].update(repeating: valueAfterDelivery, count: Int(frameCount))
        }
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
}

private actor SnapshotProcessingLivePreviewer: LiveTranscriptionPreviewing {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var values: [Float] = []

    func prepareForStart() async {}
    func start(onTextUpdate _: @escaping @Sendable (String) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) async {
        if !released { await withCheckedContinuation { waiter = $0 } }
        values.append(buffer.floatChannelData![0][0])
    }
    func releaseInput() {
        released = true
        waiter?.resume()
        waiter = nil
    }
    func finish() async -> String { "" }
    func cancel() async { releaseInput() }
}

private final class FileReturningAudioRecorder: AudioRecorder {
    private let fileURL: URL
    private let lock = NSLock()
    private var stops = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {}

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.unlock()
        return AudioFile(fileURL: fileURL, duration: 1)
    }
}

private final class BlockingStartAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSCondition()
    private var starts = 0
    private var stops = 0
    private var startIsPending = false
    private var shouldReleaseStart = false

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        startIsPending = true
        lock.broadcast()
        while !shouldReleaseStart {
            lock.wait()
        }
        lock.unlock()
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.broadcast()
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }

    func waitUntilStartIsPending() {
        lock.lock()
        while !startIsPending {
            lock.wait()
        }
        lock.unlock()
    }

    func waitUntilStopCount(isAtLeast expectedCount: Int) async {
        for _ in 0 ..< 100 {
            if stopCallCount >= expectedCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func releasePendingStart() {
        lock.lock()
        shouldReleaseStart = true
        lock.broadcast()
        lock.unlock()
    }
}

private final class ThrowingStartAudioRecorder: AudioRecorder {
    private let error: Error
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    init(error: Error) {
        self.error = error
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        lock.unlock()
        throw error
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
}

private final class TransientAudioStartupFailureRecorder: AudioRecorder {
    private let failureCount: Int
    private let error: Error
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    init(failureCount: Int, error: Error) {
        self.failureCount = failureCount
        self.error = error
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        let shouldFail = starts <= failureCount
        lock.unlock()

        if shouldFail {
            throw error
        }
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
}

private final class BlockingStopAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSCondition()
    private var starts = 0
    private var stopIsPending = false
    private var shouldReleaseStop = false

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stopIsPending = true
        lock.broadcast()
        while !shouldReleaseStop {
            lock.wait()
        }
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }

    func waitUntilStopIsPending() {
        lock.lock()
        while !stopIsPending {
            lock.wait()
        }
        lock.unlock()
    }

    func releasePendingStop() {
        lock.lock()
        shouldReleaseStop = true
        lock.broadcast()
        lock.unlock()
    }
}

private final class MockSoundEffectPlayback: SoundEffectPlayback {
    var volume: Float = 0
    var currentTime: TimeInterval = 0

    private let eventRecorder: ThreadSafeEventRecorder
    private let eventName: String

    init(eventRecorder: ThreadSafeEventRecorder, eventName: String = "cue-play") {
        self.eventRecorder = eventRecorder
        self.eventName = eventName
    }

    func prepareToPlay() -> Bool {
        true
    }

    func play() -> Bool {
        eventRecorder.append(eventName)
        return true
    }

    func stop() {}
}

private final class ThreadSafeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var durations: [Duration] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func append(duration: Duration) {
        lock.lock()
        durations.append(duration)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func durationSnapshot() -> [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    func waitUntilContains(_ event: String) async {
        for _ in 0 ..< 100 {
            if snapshot().contains(event) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class MockLocalModelDownloadAlertPresenter: LocalModelDownloadAlertPresenting {
    private(set) var presentedModels: [LocalSTTModel] = []
    private(set) var presentedProgresses: [Double] = []

    @MainActor
    func showDownloadingAlert(model: LocalSTTModel, progress: Double) {
        presentedModels.append(model)
        presentedProgresses.append(progress)
    }
}

private final class MockWorkflowLocalModelManager: LocalSTTModelManaging {
    var onPrepare: (() -> Void)?
    var prepareError: Error?

    private let lock = NSLock()
    private var _availableModels: Set<LocalSTTModel> = []
    private var _preparedConfigurations: [LocalSTTConfiguration] = []

    var preparedConfigurations: [LocalSTTConfiguration] {
        lock.withLock { _preparedConfigurations }
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        try await prepareModel(configuration: LocalSTTConfiguration(settingsStore: settingsStore), onUpdate: onUpdate)
    }

    func prepareModel(
        configuration: LocalSTTConfiguration,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        lock.withLock {
            _preparedConfigurations.append(configuration)
        }
        onUpdate?(LocalSTTPreparationUpdate(
            message: "Preparing",
            progress: 0.5,
            storagePath: storagePath(for: configuration),
            source: "Test"
        ))
        onPrepare?()
        if let prepareError {
            throw prepareError
        }
        let _: Void = lock.withLock {
            _availableModels.insert(configuration.model)
        }
    }

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        guard isModelAvailable(configuration.model) else { return nil }
        return LocalSTTPreparedModelInfo(storagePath: storagePath(for: configuration), sourceDisplayName: "Test")
    }

    func isModelAvailable(_ model: LocalSTTModel) -> Bool {
        lock.withLock { _availableModels.contains(model) }
    }

    func deleteModelFiles(_ model: LocalSTTModel) throws {
        _ = lock.withLock {
            _availableModels.remove(model)
        }
    }

    func storagePath(for configuration: LocalSTTConfiguration) -> String {
        "/tmp/\(configuration.model.rawValue)"
    }
}

private final class MockProcessingTranscriber: Transcriber {
    private let transcript: String
    private let error: Error?

    init(transcript: String = "", error: Error? = nil) {
        self.transcript = transcript
        self.error = error
    }

    func transcribe(audioFile _: AudioFile) async throws -> String {
        if let error {
            throw error
        }
        return transcript
    }
}

private final class SequencedProfileAwareTranscriber: TranscriptionProfileAwareTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingTranscripts: [String]
    private var capturedProfiles: [TranscriptionProfile] = []
    private var capturedAudioURLs: [URL] = []

    init(transcripts: [String]) {
        remainingTranscripts = transcripts
    }

    var profiles: [TranscriptionProfile] {
        lock.withLock { capturedProfiles }
    }

    var audioURLs: [URL] {
        lock.withLock { capturedAudioURLs }
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile, profile: .standard) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        profile: TranscriptionProfile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let transcript: String = lock.withLock {
            capturedProfiles.append(profile)
            capturedAudioURLs.append(audioFile.fileURL)
            return remainingTranscripts.isEmpty ? "" : remainingTranscripts.removeFirst()
        }
        await onUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        return transcript
    }
}

private final class ThreadSafeDurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedValues: [Duration] = []

    var values: [Duration] {
        lock.withLock { capturedValues }
    }

    func append(_ duration: Duration) {
        lock.withLock { capturedValues.append(duration) }
    }
}

private actor MockOptimizeRealtimeSession: RealtimeTranscriptionSession, RealtimeASROptimizeProviding {
    nonisolated let asrOptimize: Bool?
    private let transcript: String
    private var finishCallCount = 0
    private var cancelCallCount = 0
    private(set) var receivedFirstSamples: [Float] = []

    init(optimize: Bool, transcript: String) {
        asrOptimize = optimize
        self.transcript = transcript
    }

    func start() async {}

    func append(_ buffer: AVAudioPCMBuffer) async {
        if buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] {
            receivedFirstSamples.append(samples[0])
        }
    }

    func finish() async throws -> String {
        finishCallCount += 1
        return transcript
    }

    func cancel() async {
        cancelCallCount += 1
    }

    func callCounts() -> (finish: Int, cancel: Int) {
        (finishCallCount, cancelCallCount)
    }
}

private final class DelayedRealtimeSessionFactory: RealtimeTranscriptionSessionFactory, @unchecked Sendable {
    let session = MockOptimizeRealtimeSession(optimize: true, transcript: "")
    private let eventRecorder: ThreadSafeEventRecorder
    private let lock = NSLock()
    private var setupContinuation: CheckedContinuation<Void, Never>?
    private var setupWasReleased = false

    init(eventRecorder: ThreadSafeEventRecorder) {
        self.eventRecorder = eventRecorder
    }

    func transcribe(audioFile _: AudioFile) async throws -> String {
        ""
    }

    func makeRealtimeTranscriptionSession(
        scenario _: TypefluxCloudScenario,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        eventRecorder.append("realtime-setup")
        await withCheckedContinuation { continuation in
            lock.withLock {
                if setupWasReleased {
                    continuation.resume()
                } else {
                    setupContinuation = continuation
                }
            }
        }
        return session
    }

    func releaseSetup() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            setupWasReleased = true
            defer { setupContinuation = nil }
            return setupContinuation
        }
        continuation?.resume()
    }
}

private final class MockProcessingHistoryStore: HistoryStore {
    private var records: [UUID: HistoryRecord] = [:]

    func save(record: HistoryRecord) {
        records[record.id] = record
    }

    func list() -> [HistoryRecord] {
        records.values.sorted { $0.date < $1.date }
    }

    func list(limit: Int, offset: Int, searchQuery _: String?) -> [HistoryRecord] {
        Array(list().dropFirst(offset).prefix(limit))
    }

    func record(id: UUID) -> HistoryRecord? {
        records[id]
    }

    func delete(id: UUID) {
        records[id] = nil
    }

    func purge(olderThanDays _: Int) {}
    func clear() {
        records.removeAll()
    }

    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/history.md")
    }
}


extension WorkflowControllerProcessingTests {
    func testAuxiliaryPromotionKeepsMicrophoneRunningAndSnapshotsPersona() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: audioRecorder)
        controller.settingsStore.quickInputEnabled = true
        controller.settingsStore.applyPersonaSelection(SettingsStore.defaultPersonaID)
        controller.settingsStore.savePersonaAppBinding(appIdentifier: "com.test", personaID: SettingsStore.defaultPersonaID)
        let decision = RecordingGestureDecision()
        controller.recordingGestureDecision = decision
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        for _ in 0..<100 {
            if controller.isAudioRecorderStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.isAudioRecorderStarted, "Microphone must start before shortcut settlement")
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        controller.promoteRecordingToAuxiliary(context: HotkeyEventContext())
        await startup.value
        XCTAssertTrue(controller.recordingUsesAuxiliary)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
        XCTAssertFalse(controller.shouldUseQuickInput(recordingMode: .holdToTalk, recordingIntent: .dictation))
        XCTAssertEqual(controller.recordingPersonaSnapshot?.persona?.id, SettingsStore.englishPersonaID)
        let prompt = controller.recordingPersonaSnapshot?.prompt
        controller.settingsStore.auxiliaryPersonaID = SettingsStore.defaultPersonaID.uuidString
        XCTAssertEqual(controller.recordingPersona(appName: nil, bundleIdentifier: "com.test")?.id, SettingsStore.englishPersonaID)
        XCTAssertEqual(controller.recordingPersonaSnapshot?.prompt, prompt)
        XCTAssertEqual(controller.settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testAuxiliaryDoesNotRequireMainPersonaToBeEnabled() async {
        let controller = makeWorkflowController()
        controller.settingsStore.personaRewriteEnabled = false
        controller.recordingUsesAuxiliary = true
        await controller.beginRecording(intent: .dictation, startLocked: true)
        XCTAssertEqual(controller.recordingPersonaSnapshot?.persona?.id, SettingsStore.englishPersonaID)
        XCTAssertFalse(controller.settingsStore.personaRewriteEnabled)
        controller.cancelRecording()
        await waitForMainActorWork()
    }
}


extension WorkflowControllerProcessingTests {
    func testAuxiliaryPromotionPreservesAudioCapturedBeforeGestureAndRealtimeSetup() async throws {
        let events = ThreadSafeEventRecorder()
        let factory = DelayedRealtimeSessionFactory(eventRecorder: events)
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: recorder,
            sttTranscriber: factory,
            configureSettings: { $0.sttProvider = .aliCloud },
            hasPaidCloudSubscription: { true }
        )
        controller.recordingGestureDecision = RecordingGestureDecision()
        let startup = Task { await controller.beginRecording(intent: .dictation, startLocked: false) }
        await waitUntil { controller.isAudioRecorderStarted }
        XCTAssertFalse(events.snapshot().contains("realtime-setup"))
        try recorder.emitAudio(frameCount: 320, value: 0.1)
        controller.promoteRecordingToAuxiliary(context: HotkeyEventContext())
        await waitUntil { events.snapshot().contains("realtime-setup") }
        try recorder.emitAudio(frameCount: 320, value: 0.2)
        factory.releaseSetup()
        await startup.value
        try recorder.emitAudio(frameCount: 320, value: 0.3)
        await controller.activeRealtimeAudioBufferPump?.finishInput()
        let samples = await factory.session.receivedFirstSamples
        XCTAssertEqual(samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(recorder.startCallCount, 1)
        XCTAssertEqual(recorder.stopCallCount, 0)
        XCTAssertEqual(controller.recordingPersonaSnapshot?.persona?.id, SettingsStore.englishPersonaID)
        controller.cancelRecording()
        await waitForMainActorWork()
    }
}

extension WorkflowControllerProcessingTests {
    @MainActor
    func testComposerCancellationDuringMicrophoneStartupReleasesGestureAndRecorder() async throws {
        let recorder = BlockingStartAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder)
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        service.handleHotkey(.prepare(auxiliary: false, locked: false))
        let startup = Task { try await service.start() }
        for _ in 0..<100 where recorder.startCallCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(controller.recordingGestureDecision)
        service.handleHotkey(.cancel)
        startup.cancel()
        recorder.releasePendingStart()
        do { try await startup.value; XCTFail("Cancelled startup must not continue") } catch is CancellationError {}
        await service.cancel()
        XCTAssertNil(controller.recordingGestureDecision)
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(recorder.stopCallCount, 1)
    }

    @MainActor
    func testComposerMissingLLMConfigurationReturnsInlineErrorAndCleansUp() async throws {
        let recorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "raw speech"), configureSettings: {
                $0.sttProvider = .appleSpeech
                $0.applyPersonaSelection(SettingsStore.defaultPersonaID)
                $0.llmProvider = .openAICompatible
                $0.llmRemoteProvider = .custom
                $0.setLLMBaseURL("", for: .custom)
                $0.setLLMModel("", for: .custom)
            }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        do { _ = try await service.transcribe(); XCTFail("Missing configuration must be reported") }
        catch { XCTAssertFalse(error is CancellationError) }
        await service.cancel()
        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertFalse(controller.shouldPreserveLLMConfigurationNotice)
        XCTAssertEqual(controller.appState.status, .idle)
    }

    @MainActor
    func testComposerRewritesWithFrozenMainOrAuxiliaryPersonaAndQuickInputPolicy() async throws {
        for (auxiliary, locked, quickInput, expectsRewrite) in [
            (false, true, false, true), (true, false, true, true),
            (false, false, true, false), (false, true, true, true)
        ] {
            let llm = CountingProcessingLLMService(rewriteText: "rewritten speech")
            let main = PersonaProfile(name: "Main", prompt: "Main prompt")
            let aux = PersonaProfile(name: "Auxiliary", prompt: "Auxiliary prompt")
            let controller = makeWorkflowController(
                sttTranscriber: MockProcessingTranscriber(transcript: "raw speech"), llmService: llm,
                configureSettings: {
                    $0.sttProvider = .appleSpeech
                    $0.personas += [main, aux]
                    $0.applyPersonaSelection(main.id)
                    $0.auxiliaryPersonaID = aux.id.uuidString
                    $0.quickInputEnabled = quickInput
                    $0.activationHotkey = nil
                    $0.auxiliaryHotkey = nil
                    self.configureReadyLLM(settingsStore: $0)
                }, hasPaidCloudSubscription: { true }
            )
            let service = WorkflowComposerRecording(controller, isAppBundle: { true })
            service.handleHotkey(.prepare(auxiliary: auxiliary, locked: locked))
            try await service.start()
            let expected = auxiliary ? aux : main
            XCTAssertEqual(controller.recordingPersonaSnapshot?.persona?.id, expected.id)
            let frozenPrompt = controller.recordingPersonaSnapshot?.prompt
            controller.settingsStore.personaRewriteEnabled = false
            controller.settingsStore.auxiliaryPersonaID = SettingsStore.defaultPersonaID.uuidString
            let result = try await service.transcribe()
            XCTAssertEqual(result, expectsRewrite ? "rewritten speech" : "raw speech")
            XCTAssertEqual(llm.streamRewriteCallCount, expectsRewrite ? 1 : 0)
            XCTAssertEqual(llm.requests.first?.personaPrompt, expectsRewrite ? frozenPrompt : nil)
            XCTAssertEqual(llm.requests.first?.personaID, expectsRewrite ? expected.id : nil)
            XCTAssertEqual(controller.appState.status, .idle)
        }
    }

    @MainActor
    func testComposerMultimodalUsesFrozenPersonaAndOnlySkipsRewriteWhenApplied() async throws {
        for applied in [true, false] {
            let transcriber = PersonaAwareComposerTranscriber(appliesPersona: applied)
            let llm = CountingProcessingLLMService(rewriteText: "rewritten speech")
            let controller = makeWorkflowController(sttTranscriber: transcriber, llmService: llm,
                configureSettings: {
                    $0.sttProvider = .multimodalLLM
                    $0.applyPersonaSelection(SettingsStore.defaultPersonaID)
                    self.configureReadyLLM(settingsStore: $0)
                }, hasPaidCloudSubscription: { true })
            let service = WorkflowComposerRecording(controller, isAppBundle: { true })
            service.handleHotkey(.prepare(auxiliary: true, locked: true))
            try await service.start()
            let prompt = controller.recordingPersonaSnapshot?.prompt
            controller.settingsStore.auxiliaryPersonaID = SettingsStore.defaultPersonaID.uuidString
            let result = try await service.transcribe()
            XCTAssertEqual(transcriber.prompt, prompt)
            XCTAssertEqual(result, applied ? "integrated rewrite" : "rewritten speech")
            XCTAssertEqual(llm.streamRewriteCallCount, applied ? 0 : 1)
            XCTAssertNil(TranscriptionPersonaContext.current)
        }
    }

    @MainActor
    func testComposerQuickInputExplicitlyDisablesMultimodalPersona() async throws {
        let transcriber = PersonaAwareComposerTranscriber(appliesPersona: true)
        let llm = CountingProcessingLLMService(rewriteText: "unexpected")
        let controller = makeWorkflowController(sttTranscriber: transcriber, llmService: llm,
            configureSettings: {
                $0.sttProvider = .multimodalLLM
                $0.applyPersonaSelection(SettingsStore.defaultPersonaID)
                $0.quickInputEnabled = true
                $0.activationHotkey = nil
            }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        service.handleHotkey(.prepare(auxiliary: false, locked: false))
        try await service.start()
        _ = try await service.transcribe()
        XCTAssertTrue(transcriber.sawContext)
        XCTAssertNil(transcriber.prompt)
        XCTAssertEqual(llm.streamRewriteCallCount, 0)
    }

    @MainActor
    func testComposerAuxiliaryChordBothOrdersAndDoubleTapDoNotStopOnStartup() async throws {
        for keys in [[63, 56], [56, 63], [61, 61]] {
            var now = 100.0
            let doubleTap = keys == [61, 61]
            let activation: HotkeyBinding = doubleTap ? .rightOptionActivation : .defaultActivation
            let auxiliary: HotkeyBinding = doubleTap ? .rightOptionAsk : .defaultAuxiliary
            let hotkeys = MockProcessingHotkeyService()
            let recorder = MockProcessingAudioRecorder()
            let controller = makeWorkflowController(hotkeyService: hotkeys, audioRecorder: recorder,
                monotonicNow: { now }, configureSettings: {
                    $0.activationHotkey = activation; $0.auxiliaryHotkey = auxiliary
                })
            let voice = AskVoiceInput()
            voice.monotonicNow = { now }
            voice.recorder = WorkflowComposerRecording(controller, isAppBundle: { true })
            controller.composerVoiceInput = voice
            controller.start()
            let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            editor.voice = voice
            let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = editor; window.makeFirstResponder(editor)
            defer { window.close() }
            var arbiter = HotkeyGestureArbiter()
            var stop = RecordingStopGesture()
            func event(_ key: Int, _ flags: UInt) async throws {
                XCTAssertFalse(stop.handle(type: .flagsChanged, keyCode: key, flags: flags, isRepeat: false,
                    bindings: [activation, auxiliary], enabled: hotkeys.recordingStopEnabled?() == true, timestamp: now))
                let events = arbiter.handleFlagsChanged(keyCode: key, modifierFlags: flags,
                    activationHotkey: activation, askHotkey: nil, auxiliaryHotkey: auxiliary, timestamp: now)
                for event in events {
                    switch event {
                    case .begin(.activation):
                        XCTAssertTrue(voice.begin(in: editor, hotkeyUptime: now))
                    case .begin(.auxiliary):
                        XCTAssertTrue(voice.begin(in: editor, locked: doubleTap, auxiliary: true, hotkeyUptime: now))
                    case .auxiliaryPromoted: hotkeys.onAuxiliaryPromoted?(HotkeyEventContext(uptime: now))
                    case .activationTapped: hotkeys.onActivationTap?(HotkeyEventContext(uptime: now))
                    case .end(.auxiliary): hotkeys.onAuxiliaryPressEnded?(HotkeyEventContext(uptime: now))
                    default: break
                    }
                }
                for _ in 0..<100 where voice.isOccupied && !controller.isAudioRecorderStarted {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            let firstFlags = HotkeyBinding.modifierFlag(for: keys[0])
            try await event(keys[0], firstFlags)
            if doubleTap {
                now += 0.1; try await event(keys[0], 0)
            }
            now += 0.1
            try await event(keys[1], auxiliary.modifierFlags)
            for _ in 0..<100 where controller.recordingPersonaSnapshot == nil {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertEqual(voice.phase, .listening)
            XCTAssertTrue(controller.recordingUsesAuxiliary)
            XCTAssertEqual(controller.recordingPersonaSnapshot?.persona?.id, SettingsStore.englishPersonaID)
            XCTAssertEqual(recorder.startCallCount, 1)
            XCTAssertEqual(recorder.stopCallCount, 0)
            XCTAssertTrue(hotkeys.recordingStopEnabled?() == true)
            if doubleTap {
                now += 0.1; try await event(keys[1], 0)
                XCTAssertEqual(voice.phase, .listening)
                controller.finishRecordingFromCurrentMode()
            } else {
                now += 2
                try await event(keys[1], HotkeyBinding.modifierFlag(for: keys[0]))
                XCTAssertEqual(voice.phase, .transcribing)
            }
            voice.cancel()
            for _ in 0..<100 where voice.isOccupied { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertFalse(voice.isOccupied)
            XCTAssertEqual(recorder.stopCallCount, 1)
            XCTAssertNil(controller.recordingGestureDecision)
        }
    }
}

private final class PersonaAwareComposerTranscriber: Transcriber {
    let appliesPersona: Bool
    var prompt: String?
    var sawContext = false
    init(appliesPersona: Bool) { self.appliesPersona = appliesPersona }
    func transcribe(audioFile: AudioFile) async throws -> String {
        let context = TranscriptionPersonaContext.current
        sawContext = context != nil
        prompt = context?.prompt
        if appliesPersona { context?.markApplied() }
        return appliesPersona ? "integrated rewrite" : "raw speech"
    }
}

// MARK: - Composer live voice

extension WorkflowControllerProcessingTests {
    @MainActor
    private func composerObservations(_ service: WorkflowComposerRecording) -> ComposerLiveObservations {
        let observations = ComposerLiveObservations()
        service.observe(level: { observations.levels.append($0) },
                        transcript: { observations.texts.append(($0, $1)) })
        return observations
    }

    @MainActor
    private func drainMainQueue() async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    func testComposerRecordingForwardsMicrophoneLevels() async throws {
        let recorder = ComposerLevelAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: recorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "file text"),
            configureSettings: { $0.sttProvider = .appleSpeech }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        let observations = composerObservations(service)
        try await service.start()
        recorder.emit(level: 0.4)
        recorder.emit(level: 0.7)
        await drainMainQueue()
        XCTAssertEqual(observations.levels, [0.4, 0.7])
        XCTAssertTrue(observations.texts.isEmpty, "without a realtime recogniser there is no live text")
        let text = try await service.transcribe()
        XCTAssertEqual(text, "file text")
    }

    @MainActor
    func testComposerRecordingStreamsLiveTextAndUsesTheRealtimeResult() async throws {
        let recorder = ComposerLevelAudioRecorder()
        let factory = ComposerLiveSessionFactory(result: .success(" hello world "))
        let controller = makeWorkflowController(audioRecorder: recorder, sttTranscriber: factory,
            configureSettings: { $0.sttProvider = .aliCloud }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        let observations = composerObservations(service)
        // Audio captured before the recogniser is ready is replayed into it.
        recorder.onStart = { try? recorder.emitAudio() }
        try await service.start()
        let session = try XCTUnwrap(factory.session)
        try recorder.emitAudio()
        for _ in 0..<100 {
            if await session.appendCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let appended = await session.appendCount
        XCTAssertEqual(appended, 2)
        await drainMainQueue()
        XCTAssertEqual(observations.texts.first?.0, "hello wor")
        XCTAssertEqual(observations.texts.first?.1, false)
        let text = try await service.transcribe()
        XCTAssertEqual(text, "hello world", "the realtime result replaces the file transcription")
        let counts = await session.counts
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.appState.status, .idle)
    }

    @MainActor
    func testComposerRealtimeFailureFallsBackToTheRecordedAudio() async throws {
        let recorder = ComposerLevelAudioRecorder()
        let factory = ComposerLiveSessionFactory(result: .failure(NSError(domain: "socket", code: 9)))
        let controller = makeWorkflowController(audioRecorder: recorder, sttTranscriber: factory,
            configureSettings: { $0.sttProvider = .aliCloud }, hasPaidCloudSubscription: { true })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        XCTAssertNotNil(factory.session)
        let text = try await service.transcribe()
        XCTAssertEqual(text, "file text")
    }

    @MainActor
    func testComposerCancelAndShortRecordingCancelTheRealtimeSession() async throws {
        for short in [false, true] {
            let recorder = ComposerLevelAudioRecorder(duration: short ? 0.05 : 1)
            let factory = ComposerLiveSessionFactory(result: .success("unused"))
            let controller = makeWorkflowController(audioRecorder: recorder, sttTranscriber: factory,
                configureSettings: { $0.sttProvider = .aliCloud }, hasPaidCloudSubscription: { true })
            let service = WorkflowComposerRecording(controller, isAppBundle: { true })
            try await service.start()
            let session = try XCTUnwrap(factory.session)
            if short {
                do { _ = try await service.transcribe(); XCTFail("A short recording is rejected") } catch {}
            } else {
                await service.cancel()
            }
            let counts = await session.counts
            XCTAssertEqual(counts.cancel, 1)
            XCTAssertEqual(counts.finish, 0)
            XCTAssertFalse(controller.isRecording)
        }
    }

    @MainActor
    func testComposerWithoutCloudSubscriptionHasNoRealtimeSession() async throws {
        let recorder = ComposerLevelAudioRecorder()
        let factory = ComposerLiveSessionFactory(result: .success("unused"))
        let controller = makeWorkflowController(audioRecorder: recorder, sttTranscriber: factory,
            configureSettings: { $0.sttProvider = .aliCloud }, hasPaidCloudSubscription: { false })
        let service = WorkflowComposerRecording(controller, isAppBundle: { true })
        try await service.start()
        XCTAssertNil(factory.session, "live text needs the realtime service the subscription pays for")
        await service.cancel()
        XCTAssertFalse(controller.isRecording)
    }
}

@MainActor
private final class ComposerLiveObservations {
    var levels: [Float] = []
    var texts: [(String, Bool)] = []
}

/// Reports levels and audio buffers on demand, like the microphone tap.
private final class ComposerLevelAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var levelHandler: ((Float) -> Void)?
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private let duration: TimeInterval
    var onStart: () -> Void = {}

    init(duration: TimeInterval = 1) { self.duration = duration }

    func start(levelHandler: @escaping (Float) -> Void,
               audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?) throws {
        lock.withLock { self.levelHandler = levelHandler; bufferHandler = audioBufferHandler }
        onStart()
    }

    func emit(level: Float) { lock.withLock { levelHandler }?(level) }

    func emitAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        lock.withLock { bufferHandler }?(buffer)
    }

    func stop() throws -> AudioFile {
        AudioFile(fileURL: URL(fileURLWithPath: "/tmp/composer-live-mock.wav"), duration: duration)
    }
}

private actor ComposerLiveSession: RealtimeTranscriptionSession {
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let result: Result<String, Error>
    private(set) var appendCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void, result: Result<String, Error>) {
        self.onUpdate = onUpdate
        self.result = result
    }

    var counts: (finish: Int, cancel: Int) { (finishCount, cancelCount) }

    func start() async {}

    func append(_ buffer: AVAudioPCMBuffer) async {
        appendCount += 1
        await onUpdate(TranscriptionSnapshot(text: "hello wor", isFinal: false))
    }

    func finish() async throws -> String {
        finishCount += 1
        return try result.get()
    }

    func cancel() async { cancelCount += 1 }
}

private final class ComposerLiveSessionFactory: RealtimeTranscriptionSessionFactory, @unchecked Sendable {
    private let result: Result<String, Error>
    private let lock = NSLock()
    private var made: ComposerLiveSession?

    init(result: Result<String, Error>) { self.result = result }

    var session: ComposerLiveSession? { lock.withLock { made } }

    func transcribe(audioFile _: AudioFile) async throws -> String { "file text" }

    func makeRealtimeTranscriptionSession(
        scenario _: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        let session = ComposerLiveSession(onUpdate: onUpdate, result: result)
        lock.withLock { made = session }
        return session
    }
}

// MARK: - Clipboard panel

private final class MockClipboardPanelPresenter: ClipboardPanelPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var quickLookURLs: [[URL]] = []
    private(set) var isPresented = false

    func present(_: ClipboardPanelModel) {
        presentCount += 1
        isPresented = true
    }

    func dismiss() {
        dismissCount += 1
        isPresented = false
    }

    func toggleQuickLook(urls: [URL]) {
        quickLookURLs.append(urls)
    }
}

private final class MockClipboardContentActions: ClipboardContentActing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites: [(title: String, plainText: Bool)] = []
    private var storedPasteShortcutCount = 0
    var writeSucceeds = true
    var revealed: [[URL]] = []
    var savedURL: URL?
    var recognizedText: String?

    var writes: [(title: String, plainText: Bool)] { lock.withLock { storedWrites } }
    var pasteShortcutCount: Int { lock.withLock { storedPasteShortcutCount } }

    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool) -> Bool {
        lock.withLock { storedWrites.append((entry.title, asPlainText)) }
        return writeSucceeds
    }

    func sendPasteShortcut() {
        lock.withLock { storedPasteShortcutCount += 1 }
    }

    func revealInFinder(_ urls: [URL]) {
        revealed.append(urls)
    }

    func saveToDownloads(_: URL) -> URL? {
        savedURL
    }

    func recognizeText(in _: URL) async -> String? {
        recognizedText
    }
}

extension WorkflowControllerProcessingTests {
    private struct ClipboardPanelHarness {
        let controller: WorkflowController
        let store: InMemoryClipboardHistoryStore
        let presenter: MockClipboardPanelPresenter
        let actions: MockClipboardContentActions
        let historyStore: MockProcessingHistoryStore
        let clipboard: MockClipboardService
        let textInjector: MockProcessingTextInjector

        var model: ClipboardPanelModel { controller.historyPanelModel }

        func index(of title: String) -> Int {
            model.visibleEntries.firstIndex { $0.title == title } ?? -1
        }
    }

    private func makeClipboardPanelHarness(
        voiceTexts: [String] = [],
        configure: (InMemoryClipboardHistoryStore) -> Void = { _ in }
    ) -> ClipboardPanelHarness {
        let historyStore = MockProcessingHistoryStore()
        for (offset, text) in voiceTexts.enumerated() {
            historyStore.save(record: HistoryRecord(date: Date(timeIntervalSince1970: 1000 + Double(offset)), transcriptText: text))
        }
        let clipboard = MockClipboardService()
        let textInjector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: textInjector, historyStore: historyStore, clipboard: clipboard)
        let store = InMemoryClipboardHistoryStore()
        configure(store)
        let presenter = MockClipboardPanelPresenter()
        let actions = MockClipboardContentActions()
        controller.clipboardHistoryStore = store
        controller.clipboardPanelPresenter = presenter
        controller.clipboardContentActions = actions
        controller.historyPanelModel.fileExists = { _ in true }
        return ClipboardPanelHarness(
            controller: controller, store: store, presenter: presenter, actions: actions,
            historyStore: historyStore, clipboard: clipboard, textInjector: textInjector
        )
    }

    /// Clipboard items copied in the last minute, so retention never purges them.
    private func seed(_ store: InMemoryClipboardHistoryStore) {
        let now = Date()
        store.record(.text("copied text"), source: nil, at: now.addingTimeInterval(-30))
        store.record(.image(png: Data([1]), pixelWidth: 2, pixelHeight: 2), source: nil, at: now.addingTimeInterval(-20))
        store.record(.files([URL(fileURLWithPath: "/tmp/report.pdf")]), source: nil, at: now.addingTimeInterval(-10))
        if let index = store.storedItems.firstIndex(where: { $0.payload == .image }) {
            store.storedItems[index].imagePath = "/tmp/shot.png"
        }
    }

    func testHistoryPanelPresentsClipboardAndVoiceEntriesAndTogglesClosed() {
        let harness = makeClipboardPanelHarness(voiceTexts: ["spoken"], configure: seed)

        harness.controller.handleHistoryPickerRequested()

        XCTAssertTrue(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.presenter.presentCount, 1)
        XCTAssertEqual(
            harness.controller.historyPickerItems.map(\.kind),
            [.pdf, .image, .text, .voice]
        )

        harness.controller.handleHistoryPickerRequested()
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.presenter.dismissCount, 1)

        harness.controller.dismissHistoryPicker()
        XCTAssertEqual(harness.presenter.dismissCount, 1)
    }

    func testHistoryPanelDoesNotOpenWhenEmpty() {
        let harness = makeClipboardPanelHarness()
        harness.controller.handleHistoryPickerRequested()
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.presenter.presentCount, 0)
    }

    func testPanelEscapeDismissesThroughTheController() {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.model.cancel()
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.presenter.dismissCount, 1)
    }

    func testPastingFilesWritesThePasteboardThenSendsPaste() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()

        harness.model.perform(.paste, at: harness.index(of: "report.pdf"))

        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.actions.writes.map(\.plainText), [false])
        await waitUntil { harness.actions.pasteShortcutCount == 1 }
        XCTAssertEqual(harness.actions.pasteShortcutCount, 1)
        XCTAssertTrue(harness.textInjector.insertedTexts.isEmpty)
    }

    func testPastingFilePathsAsPlainText() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.model.perform(.pastePlainText, at: harness.index(of: "report.pdf"))
        XCTAssertEqual(harness.actions.writes.map(\.plainText), [true])
        await waitUntil { harness.actions.pasteShortcutCount == 1 }
    }

    func testFailedPasteboardWriteDoesNotSendPaste() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.actions.writeSucceeds = false
        harness.controller.handleHistoryPickerRequested()
        harness.model.perform(.paste, at: harness.index(of: "report.pdf"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.actions.pasteShortcutCount, 0)
    }

    func testPastingCopiedTextInsertsIt() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.model.perform(.paste, at: harness.index(of: "copied text"))
        XCTAssertEqual(harness.clipboard.storedText, "copied text")
        await waitUntil { harness.textInjector.insertedTexts == ["copied text"] }
        XCTAssertEqual(harness.textInjector.insertedTexts, ["copied text"])
    }

    func testCopyingAnImageWritesThePasteboardWithoutPasting() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.model.perform(.copy, at: harness.index(of: L("clipboard.entry.image")))
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
        XCTAssertEqual(harness.actions.writes.count, 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.actions.pasteShortcutCount, 0)
    }

    func testFailedImageCopyKeepsThePanelOpen() {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.actions.writeSucceeds = false
        harness.controller.handleHistoryPickerRequested()
        harness.model.perform(.copy, at: harness.index(of: L("clipboard.entry.image")))
        XCTAssertTrue(harness.controller.isHistoryPickerPresented)
    }

    func testPinningMovesEntriesToTheTopForClipboardAndVoice() {
        let harness = makeClipboardPanelHarness(voiceTexts: ["spoken"], configure: seed)
        harness.controller.handleHistoryPickerRequested()

        harness.model.perform(.togglePin, at: harness.index(of: "spoken"))
        XCTAssertEqual(harness.model.visibleEntries.first?.title, "spoken")
        XCTAssertEqual(harness.store.pinnedVoiceIDs.count, 1)
        XCTAssertEqual(harness.model.selectedEntry?.title, "spoken")

        harness.model.perform(.togglePin, at: harness.index(of: "copied text"))
        XCTAssertTrue(harness.store.storedItems.first { $0.text == "copied text" }?.isPinned ?? false)

        harness.model.perform(.togglePin, at: harness.index(of: "spoken"))
        XCTAssertTrue(harness.store.pinnedVoiceIDs.isEmpty)
    }

    func testDeletingEntriesRemovesThemAndClosesWhenEmpty() {
        let harness = makeClipboardPanelHarness(voiceTexts: ["spoken"]) { store in
            store.record(.text("copied"), source: nil, at: Date())
        }
        harness.controller.handleHistoryPickerRequested()

        harness.model.perform(.delete, at: harness.index(of: "copied"))
        XCTAssertTrue(harness.store.storedItems.isEmpty)
        XCTAssertEqual(harness.model.visibleEntries.map(\.title), ["spoken"])

        harness.model.perform(.delete, at: 0)
        XCTAssertTrue(harness.historyStore.list().isEmpty)
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
    }

    func testRevealQuickLookAndSaveActions() {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()

        harness.model.perform(.quickLook, at: harness.index(of: "report.pdf"))
        XCTAssertEqual(harness.presenter.quickLookURLs, [[URL(fileURLWithPath: "/tmp/report.pdf")]])

        harness.model.perform(.saveToDownloads, at: harness.index(of: L("clipboard.entry.image")))
        XCTAssertEqual(harness.model.notice, L("clipboard.notice.saveFailed"))
        harness.actions.savedURL = URL(fileURLWithPath: "/Downloads/Typeflux.png")
        harness.model.perform(.saveToDownloads)
        XCTAssertEqual(harness.model.notice, L("clipboard.notice.savedToDownloads", "Typeflux.png"))

        harness.model.perform(.revealInFinder, at: harness.index(of: "report.pdf"))
        XCTAssertEqual(harness.actions.revealed, [[URL(fileURLWithPath: "/tmp/report.pdf")]])
        XCTAssertFalse(harness.controller.isHistoryPickerPresented)
    }

    func testCopyImageTextCopiesRecognizedText() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        let image = harness.index(of: L("clipboard.entry.image"))

        harness.model.perform(.copyImageText, at: image)
        await waitUntil { harness.model.notice != nil }
        XCTAssertEqual(harness.model.notice, L("clipboard.notice.noImageText"))
        XCTAssertNil(harness.clipboard.storedText)

        harness.actions.recognizedText = "Hello"
        harness.model.perform(.copyImageText, at: image)
        await waitUntil { harness.clipboard.storedText == "Hello" }
        XCTAssertEqual(harness.model.notice, L("clipboard.notice.imageTextCopied"))
    }

    func testRetryIgnoresClipboardEntries() {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.controller.performHistoryAction(.retryTranscription, on: harness.model.visibleEntries[0])
        XCTAssertTrue(harness.controller.isHistoryPickerPresented)
        XCTAssertNil(harness.controller.processingTask)
    }

    func testClipboardChangesReloadTheOpenPanel() async {
        let harness = makeClipboardPanelHarness(configure: seed)
        harness.controller.handleHistoryPickerRequested()
        harness.store.record(.text("fresh copy"), source: nil, at: Date().addingTimeInterval(60))

        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
        await waitUntil { harness.model.visibleEntries.first?.title == "fresh copy" }
        XCTAssertEqual(harness.model.visibleEntries.first?.title, "fresh copy")
    }

    func testClipboardRetentionFollowsHistorySettings() {
        let harness = makeClipboardPanelHarness()
        let now = Date(timeIntervalSince1970: 10 * 86400)

        harness.controller.settingsStore.historyRetentionPolicy = .oneWeek
        harness.controller.enforceClipboardRetentionPolicy(now: now)
        XCTAssertEqual(harness.store.purgeCutoffs.last, Date(timeIntervalSince1970: 3 * 86400))

        harness.controller.settingsStore.historyRetentionPolicy = .never
        harness.controller.enforceClipboardRetentionPolicy(now: now)
        XCTAssertEqual(harness.store.purgeCutoffs.last, Date(timeIntervalSince1970: 9 * 86400))

        harness.controller.settingsStore.historyRetentionPolicy = .forever
        harness.controller.enforceClipboardRetentionPolicy(now: now)
        XCTAssertEqual(harness.store.purgeCutoffs.count, 2)
        XCTAssertEqual(harness.store.trimCounts, Array(repeating: ClipboardMonitor.maximumItemCount, count: 3))

        harness.controller.clipboardHistoryStore = nil
        harness.controller.enforceClipboardRetentionPolicy(now: now)
        XCTAssertEqual(harness.store.trimCounts.count, 3)
    }
}
