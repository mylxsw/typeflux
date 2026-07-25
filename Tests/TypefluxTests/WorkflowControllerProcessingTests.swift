import AVFoundation
@testable import Typeflux
import XCTest

final class WorkflowControllerProcessingTests: XCTestCase {
    func testApplyDetachedAgentEditResultInsertsIntoEditableInputWithoutSelection() async {
        let textInjector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: textInjector)
        let snapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Notes",
            selectedRange: nil,
            selectedText: nil,
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "Draft",
            isFocusedTarget: true
        )

        let (outcome, _) = await controller.applyDetachedAgentEditResult("Draft reply", selectionSnapshot: snapshot)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(textInjector.insertedTexts, ["Draft reply"])
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
    }

    func testApplyDetachedAgentEditResultReplacesSelectionWhenSelectionIsReplaceable() async {
        let textInjector = MockProcessingTextInjector()
        let controller = makeWorkflowController(textInjector: textInjector)
        let snapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Notes",
            selectedRange: CFRange(location: 0, length: 5),
            selectedText: "hello",
            source: "accessibility",
            isEditable: true,
            role: "AXTextArea",
            windowTitle: "Draft",
            isFocusedTarget: true
        )

        let (outcome, _) = await controller.applyDetachedAgentEditResult("updated", selectionSnapshot: snapshot)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(textInjector.replacedTexts, ["updated"])
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
    }

    func testApplyTextPresentsCopyDialogWhenInsertThrows() async {
        let textInjector = MockProcessingTextInjector(
            insertError: NSError(
                domain: "AXTextInjector",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Paste insertion could not be verified"]
            )
        )
        let controller = makeWorkflowController(textInjector: textInjector)

        let (outcome, processed) = await controller.applyText("Manual copy fallback", replace: false)

        XCTAssertEqual(outcome, .presentedInDialog)
        XCTAssertEqual(processed, "Manual copy fallback")
        XCTAssertEqual(controller.lastDialogResultText, "Manual copy fallback")
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
    }

    func testHandleDetachedAgentLaunchKeepsProcessingStatusVisible() {
        let controller = makeWorkflowController()
        controller.activeProcessingRecordID = UUID()
        controller.appState.setStatus(.processing)

        controller.handleDetachedAgentLaunch()

        XCTAssertEqual(controller.appState.status, .processing)
        XCTAssertNil(controller.activeProcessingRecordID)
    }

    func testAskWithoutSelectionAgentDispositionMapsAnswerToAnswer() {
        let result = WorkflowController.askWithoutSelectionAgentDisposition(
            for: .answer("Here is the answer")
        )

        XCTAssertEqual(result, .answer("Here is the answer"))
    }

    func testAskWithoutSelectionAgentDispositionMapsEditToInsert() {
        let result = WorkflowController.askWithoutSelectionAgentDisposition(
            for: .edit("Draft to insert")
        )

        XCTAssertEqual(result, .insert("Draft to insert"))
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
        XCTAssertEqual(controller.historyPickerItems.map(\.text), ["new result", "old result"])

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
        controller.copyHistorySelection(at: 0)

        XCTAssertFalse(controller.isHistoryPickerPresented)
        XCTAssertEqual(clipboard.storedText, "copy only")
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
    }

    func testHistoryPickerShowsMostRecentTwentyRecords() {
        let historyStore = MockProcessingHistoryStore()
        let baseDate = Date(timeIntervalSince1970: 1000)
        for index in 0 ..< 25 {
            historyStore.save(record: HistoryRecord(
                date: baseDate.addingTimeInterval(TimeInterval(index)),
                transcriptText: "result \(index)"
            ))
        }

        let controller = makeWorkflowController(historyStore: historyStore)

        controller.handleHistoryPickerRequested()

        XCTAssertEqual(controller.historyPickerItems.count, 20)
        XCTAssertEqual(controller.historyPickerItems.first?.text, "result 24")
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
        controller.retryHistorySelection(at: 0)

        XCTAssertFalse(controller.isHistoryPickerPresented)
        XCTAssertNotNil(controller.processingTask)
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

    func testProcessingTimeoutUsesMinimumForShortOrMissingRecordings() {
        XCTAssertEqual(
            WorkflowController.processingTimeoutNanoseconds(recordingDurationSeconds: nil),
            120_000_000_000
        )
        XCTAssertEqual(
            WorkflowController.processingTimeoutNanoseconds(recordingDurationSeconds: 30),
            120_000_000_000
        )
    }

    func testProcessingTimeoutScalesWithRecordingDuration() {
        XCTAssertEqual(
            WorkflowController.processingTimeoutNanoseconds(recordingDurationSeconds: 132),
            222_000_000_000
        )
    }

    func testPersonaRewriteTimeoutAfterTranscriptionIsThirtySeconds() {
        XCTAssertEqual(WorkflowController.llmTimeoutAfterTranscriptionSeconds, 30)
    }

    func testGenerateRewriteThrowsTimeoutWhenStreamDoesNotFinish() async {
        let controller = makeWorkflowController(
            llmService: SlowProcessingLLMService(delay: .milliseconds(200)),
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
                timeout: 0.01
            )
        }) { error in
            XCTAssertTrue(error is WorkflowController.LLMRequestTimeoutError)
        }
    }

    func testDictationWithPersonaFallsBackToTranscriptWhenRewriteTimesOut() async {
        let transcript = "insert the transcript"
        let textInjector = MockProcessingTextInjector()
        let historyStore = MockProcessingHistoryStore()
        let controller = makeWorkflowController(
            textInjector: textInjector,
            sttTranscriber: MockProcessingTranscriber(transcript: transcript),
            llmService: SlowProcessingLLMService(delay: .milliseconds(200)),
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
        XCTAssertFalse(events.contains("cue-play"))
        XCTAssertFalse(events.contains("unexpected-sleep"))
        XCTAssertEqual(eventRecorder.durationSnapshot(), [])

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

    func testBeginRecordingRetriesUntilAudioStartupSucceeds() async {
        let audioRecorder = TransientTimeoutAudioRecorder(timeoutCount: 2)
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

        controller.hotkeyPressedAt = Date(timeIntervalSinceNow: -0.5)
        controller.handlePressEnded()
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)

        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertTrue(eventRecorder.snapshot().contains("audio-start"))
    }

    func testAskPressDuringActiveDictationPromotesExistingRecording() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let selectionSnapshot = TextSelectionSnapshot(
            processID: 1,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            selectedRange: nil,
            selectedText: "Selected browser text",
            source: "clipboard-copy",
            isEditable: true,
            role: "AXGroup",
            windowTitle: "Chat",
            isFocusedTarget: true
        )
        let inputSnapshot = CurrentInputTextSnapshot(
            processID: 1,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXGroup",
            text: "Before Selected browser text After",
            selectedRange: CFRange(location: 7, length: 21),
            isEditable: true,
            isFocusedTarget: true,
            textSource: "visible-text"
        )
        let controller = makeWorkflowController(
            textInjector: MockProcessingTextInjector(
                selectionSnapshot: selectionSnapshot,
                inputSnapshot: inputSnapshot
            ),
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        controller.handlePressBegan(intent: .askSelection, startLocked: true)

        XCTAssertEqual(controller.recordingIntent, .askSelection)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        let promotedSelectionSnapshot = await controller.selectionTask?.value
        XCTAssertEqual(promotedSelectionSnapshot?.selectedText, "Selected browser text")
        XCTAssertEqual(promotedSelectionSnapshot?.source, "clipboard-copy")
        let promotedInputContext = await controller.inputContextTask?.value
        XCTAssertEqual(promotedInputContext?.selectedText, "Selected browser text")

        controller.cancelRecording()
        await waitForMainActorWork()
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

    func testReleasingWhileAudioStartIsPendingStopsAfterStartCompletes() async {
        let audioRecorder = BlockingStartAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in }
        )

        let recordingTask = Task {
            await controller.beginRecording(intent: .dictation, startLocked: false)
        }
        audioRecorder.waitUntilStartIsPending()

        controller.hotkeyPressedAt = Date(timeIntervalSinceNow: -0.5)
        controller.handlePressEnded()

        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.shouldFinishRecordingAfterAudioStart)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)

        audioRecorder.releasePendingStart()
        await recordingTask.value
        await audioRecorder.waitUntilStopCount(isAtLeast: 1)

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 1)
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
            historyStore.list().last?.transcriptText == "前半段内容，后半段内容。"
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
        let controller = makeWorkflowController(
            textInjector: textInjector,
            audioRecorder: audioRecorder,
            sttTranscriber: MockProcessingTranscriber(transcript: "should not transcribe"),
            sleep: { _ in }
        )
        controller.isAudioRecorderStarted = true

        await controller.finishRecordingAndProcess(recordingStoppedAt: Date())
        await waitForMainActorWork()

        XCTAssertEqual(audioRecorder.stopCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
    }

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

    private func makeWorkflowController(
        textInjector: TextInjector = MockProcessingTextInjector(),
        audioRecorder: AudioRecorder = MockProcessingAudioRecorder(),
        sttTranscriber: Transcriber = MockProcessingTranscriber(),
        llmService: LLMService = MockProcessingLLMService(),
        historyStore: HistoryStore = MockProcessingHistoryStore(),
        clipboard: ClipboardService = MockClipboardService(),
        soundEffectPlayer: SoundEffectPlayer? = nil,
        localModelManager: (any LocalSTTModelManaging)? = nil,
        localModelDownloadAlertPresenter: any LocalModelDownloadAlertPresenting =
            MockLocalModelDownloadAlertPresenter(),
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        configureSettings: ((SettingsStore) -> Void)? = nil
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
            hotkeyService: MockProcessingHotkeyService(),
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
                typefluxOfficial: sttTranscriber
            ),
            llmService: llmService,
            llmAgentService: MockProcessingLLMAgentService(),
            textInjector: textInjector,
            clipboard: clipboard,
            historyStore: historyStore,
            agentJobStore: MockProcessingAgentJobStore(),
            agentExecutionRegistry: AgentExecutionRegistry(),
            mcpRegistry: MCPRegistry(),
            overlayController: overlayController,
            askAnswerWindowController: AskAnswerWindowController(
                clipboard: MockClipboardService(),
                settingsStore: settingsStore,
                outputPostProcessor: NoopOutputPostProcessor()
            ),
            agentClarificationWindowController: AgentClarificationWindowController(
                settingsStore: settingsStore
            ),
            soundEffectPlayer: soundEffectPlayer ?? SoundEffectPlayer(settingsStore: settingsStore),
            localModelManager: localModelManager,
            localModelDownloadAlertPresenter: localModelDownloadAlertPresenter,
            outputPostProcessor: NoopOutputPostProcessor(),
            sleep: sleep
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
        return SoundEffectPlayer(settingsStore: settingsStore) { _ in
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
        return SoundEffectPlayer(settingsStore: settingsStore) { url in
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

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        selectionSnapshot
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        inputSnapshot
    }

    func currentInputText() async -> String? {
        nil
    }

    func insert(text: String) throws {
        if let insertError {
            throw insertError
        }
        insertedTexts.append(text)
    }

    func replaceSelection(text: String) throws {
        if let replaceError {
            throw replaceError
        }
        replacedTexts.append(text)
    }
}

private final class SlowSelectionTextInjector: TextInjector {
    private let eventRecorder: ThreadSafeEventRecorder

    init(eventRecorder: ThreadSafeEventRecorder) {
        self.eventRecorder = eventRecorder
    }

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
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

    func insert(text _: String) throws {}

    func replaceSelection(text _: String) throws {}
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
    private let lock = NSLock()
    private var rewriteCalls = 0

    init(rewriteText: String) {
        self.rewriteText = rewriteText
    }

    var streamRewriteCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rewriteCalls
    }

    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        rewriteCalls += 1
        lock.unlock()
        let rewriteText = rewriteText
        return AsyncThrowingStream { continuation in
            continuation.yield(rewriteText)
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

private final class SlowProcessingLLMService: LLMService {
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
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

private final class MockProcessingLLMAgentService: LLMAgentService {
    func runTool<T: Decodable & Sendable>(request _: LLMAgentRequest, decoding _: T.Type) async throws -> T {
        throw NSError(domain: "MockProcessingLLMAgentService", code: 1)
    }
}

private final class MockProcessingHotkeyService: HotkeyService {
    var onActivationTap: (() -> Void)?
    var onActivationPressBegan: (() -> Void)?
    var onActivationPressEnded: (() -> Void)?
    var onActivationCancelled: (() -> Void)?
    var onAskPressBegan: (() -> Void)?
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
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        lock.lock()
        starts += 1
        lock.unlock()
        onStart()
    }

    func stop() throws -> AudioFile {
        lock.lock()
        stops += 1
        lock.unlock()
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
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

private final class TransientTimeoutAudioRecorder: AudioRecorder {
    private let timeoutCount: Int
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    init(timeoutCount: Int) {
        self.timeoutCount = timeoutCount
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
        let shouldTimeout = starts <= timeoutCount
        lock.unlock()

        if shouldTimeout {
            throw AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut
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

private actor MockOptimizeRealtimeSession: RealtimeTranscriptionSession, RealtimeASROptimizeProviding {
    nonisolated let asrOptimize: Bool?
    private let transcript: String
    private var finishCallCount = 0
    private var cancelCallCount = 0

    init(optimize: Bool, transcript: String) {
        asrOptimize = optimize
        self.transcript = transcript
    }

    func start() async {}

    func append(_: AVAudioPCMBuffer) async {}

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

private final class MockProcessingAgentJobStore: AgentJobStore, @unchecked Sendable {
    func save(_: AgentJob) async throws {}
    func list(limit _: Int, offset _: Int) async throws -> [AgentJob] {
        []
    }

    func job(id _: UUID) async throws -> AgentJob? {
        nil
    }

    func delete(id _: UUID) async throws {}
    func clear() async throws {}
    func count() async throws -> Int {
        0
    }
}
