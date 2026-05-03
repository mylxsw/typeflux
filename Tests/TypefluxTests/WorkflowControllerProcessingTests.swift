import AVFoundation
@testable import Typeflux
import XCTest

final class WorkflowControllerProcessingTests: XCTestCase {
    func testApplyDetachedAgentEditResultInsertsIntoEditableInputWithoutSelection() {
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
            isFocusedTarget: true,
        )

        let outcome = controller.applyDetachedAgentEditResult("Draft reply", selectionSnapshot: snapshot)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(textInjector.insertedTexts, ["Draft reply"])
        XCTAssertTrue(textInjector.replacedTexts.isEmpty)
    }

    func testApplyDetachedAgentEditResultReplacesSelectionWhenSelectionIsReplaceable() {
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
            isFocusedTarget: true,
        )

        let outcome = controller.applyDetachedAgentEditResult("updated", selectionSnapshot: snapshot)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(textInjector.replacedTexts, ["updated"])
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
            for: .answer("Here is the answer"),
        )

        XCTAssertEqual(result, .answer("Here is the answer"))
    }

    func testAskWithoutSelectionAgentDispositionMapsEditToInsert() {
        let result = WorkflowController.askWithoutSelectionAgentDisposition(
            for: .edit("Draft to insert"),
        )

        XCTAssertEqual(result, .insert("Draft to insert"))
    }

    func testIsServiceOverloadedErrorReturnsTrueFor529() {
        let error = NSError(domain: "SSE", code: 529, userInfo: [NSLocalizedDescriptionKey: "HTTP 529: overloaded"])
        XCTAssertTrue(WorkflowController.isServiceOverloadedError(error))
    }

    func testIsServiceOverloadedErrorReturnsTrueFor529FromLLMDomain() {
        let error = NSError(domain: "LLM", code: 529, userInfo: [NSLocalizedDescriptionKey: "HTTP 529: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"])
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
            selectedText: "Selected markdown paragraph",
        )

        XCTAssertTrue(WorkflowController.shouldRewriteTranscript(personaPrompt: nil, inputContext: inputContext))
    }

    func testShouldNotRewriteTranscriptWithoutPersonaOrInputContext() {
        XCTAssertFalse(WorkflowController.shouldRewriteTranscript(personaPrompt: nil, inputContext: nil))
    }

    func testActivePersonaPromptUsesFocusedAppBinding() {
        let customPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it warm and casual.")
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            settingsStore.personas = settingsStore.personas + [customPersona]
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.tinyspeck.slackmacgap",
                personaID: customPersona.id,
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
            isFocusedTarget: true,
        )

        let personaPrompt = controller.activePersonaPrompt(
            selectionSnapshot: selectionSnapshot,
            inputContext: nil,
        )

        XCTAssertEqual(personaPrompt, customPersona.prompt)
    }

    func testActivePersonaPromptUsesNoPersonaAppBindingOverDefaultPersona() {
        let controller = makeWorkflowController(configureSettings: { settingsStore in
            let defaultPersona = settingsStore.personas[0]
            settingsStore.applyPersonaSelection(defaultPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.apple.Notes",
                personaID: nil,
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
            isFocusedTarget: true,
        )

        let personaPrompt = controller.activePersonaPrompt(
            selectionSnapshot: selectionSnapshot,
            inputContext: nil,
        )

        XCTAssertNil(personaPrompt)
    }

    func testApplicationPersonaPickerTitleUsesApplicationScope() throws {
        let controller = makeWorkflowController()
        let binding = PersonaAppBinding(appIdentifier: "com.apple.Notes", personaID: controller.settingsStore.personas[0].id)

        XCTAssertEqual(
            controller.personaPickerTitle(for: .switchApplication(binding)),
            L("overlay.personaPicker.switchApplicationTitle"),
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
            L("overlay.personaPicker.switchTitle"),
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
                personaID: appPersona.id,
            )
        })
        let binding = try XCTUnwrap(controller.settingsStore.personaAppBindings.first)
        controller.personaPickerMode = .switchApplication(binding)
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex(where: { $0.id == targetPersona.id }),
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
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder),
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
                soundEffectsEnabled: false,
            ),
        )

        controller.handlePersonaPickerRequested()
        await waitForMainActorWork()

        XCTAssertTrue(controller.isPersonaPickerPresented)
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play"))
    }

    func testConfirmingPersonaSelectionPlaysTipCue() async throws {
        let eventRecorder = ThreadSafeEventRecorder()
        let controller = makeWorkflowController(
            soundEffectPlayer: makeNamedSoundEffectPlayer(eventRecorder: eventRecorder),
        )
        controller.personaPickerMode = .switchDefault
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex { $0.id != nil },
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
                soundEffectsEnabled: false,
            ),
        )
        controller.personaPickerMode = .switchDefault
        controller.personaPickerItems = controller.personaPickerEntries(includeNoneOption: true)
        controller.personaPickerSelectedIndex = try XCTUnwrap(
            controller.personaPickerItems.firstIndex { $0.id != nil },
        )
        controller.isPersonaPickerPresented = true

        controller.confirmPersonaSelection()
        await waitForMainActorWork()

        XCTAssertFalse(controller.isPersonaPickerPresented)
        XCTAssertFalse(eventRecorder.snapshot().contains("cue-play-tip"))
    }

    func testGenerateRewriteThrowsConfigurationErrorWhenLLMIsNotConfigured() async {
        let controller = makeWorkflowController()

        await XCTAssertThrowsErrorAsync(
            try await controller.generateRewrite(
                request: LLMRewriteRequest(
                    mode: .rewriteTranscript,
                    sourceText: "hello",
                    spokenInstruction: nil,
                    personaPrompt: "Rewrite this",
                ),
                sessionID: UUID(),
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMConfigurationError,
                .notConfigured(reason: .missingAPIKey),
            )
        }
    }

    func testDecideAskSelectionThrowsConfigurationErrorWhenLLMIsNotConfigured() async {
        let controller = makeWorkflowController()

        await XCTAssertThrowsErrorAsync(
            try await controller.decideAskSelection(
                selectedText: "draft",
                spokenInstruction: "improve this",
                personaPrompt: nil,
                editableTarget: true,
                sessionID: UUID(),
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMConfigurationError,
                .notConfigured(reason: .missingAPIKey),
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
            },
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
            sleep: { _ in },
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
        let audioRecorder = ThrowingStartAudioRecorder(error: AVFoundationAudioRecorder.RecorderError.inputStartupTimedOut)
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        await waitForMainActorWork()

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isAudioRecorderStarted)
        XCTAssertFalse(controller.isAudioRecorderStarting)
        XCTAssertFalse(controller.shouldFinishRecordingAfterAudioStart)
        XCTAssertNil(controller.pendingRecordingStartID)
        XCTAssertEqual(controller.recordingMode, .holdToTalk)
        XCTAssertEqual(audioRecorder.startCallCount, 1)
        XCTAssertEqual(audioRecorder.stopCallCount, 0)
    }

    func testReleasingAfterImmediateAudioStartStopsRecorder() async {
        let eventRecorder = ThreadSafeEventRecorder()
        let audioRecorder = MockProcessingAudioRecorder {
            eventRecorder.append("audio-start")
        }
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            soundEffectPlayer: makeRecordingSoundEffectPlayer(eventRecorder: eventRecorder),
            sleep: { _ in },
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
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)

        controller.handlePressBegan(intent: .askSelection, startLocked: true)

        XCTAssertEqual(controller.recordingIntent, .askSelection)
        XCTAssertEqual(controller.recordingMode, .locked)
        XCTAssertEqual(audioRecorder.startCallCount, 1)

        controller.cancelRecording()
        await waitForMainActorWork()
    }

    func testActivationTapAfterEndingLockedAskRecordingIsSuppressed() async {
        let audioRecorder = MockProcessingAudioRecorder()
        let controller = makeWorkflowController(
            audioRecorder: audioRecorder,
            sleep: { _ in },
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
            sleep: { _ in },
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
            sleep: { _ in },
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
            sleep: { _ in },
        )

        await controller.beginRecording(intent: .dictation, startLocked: false)
        XCTAssertEqual(audioRecorder.startCallCount, 1)

        controller.finishRecordingFromCurrentMode()
        audioRecorder.waitUntilStopIsPending()

        controller.handlePressBegan(intent: .dictation, startLocked: false)

        XCTAssertEqual(audioRecorder.startCallCount, 1)
        audioRecorder.releasePendingStop()
    }

    private func makeWorkflowController(
        textInjector: TextInjector = MockProcessingTextInjector(),
        audioRecorder: AudioRecorder = MockProcessingAudioRecorder(),
        llmService: LLMService = MockProcessingLLMService(),
        soundEffectPlayer: SoundEffectPlayer? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        configureSettings: ((SettingsStore) -> Void)? = nil,
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
                whisper: MockProcessingTranscriber(),
                freeSTT: MockProcessingTranscriber(),
                appleSpeech: MockProcessingTranscriber(),
                localModel: MockProcessingTranscriber(),
                multimodal: MockProcessingTranscriber(),
                aliCloud: MockProcessingTranscriber(),
                doubaoRealtime: MockProcessingTranscriber(),
                googleCloud: MockProcessingTranscriber(),
                groq: MockProcessingTranscriber(),
                typefluxOfficial: MockProcessingTranscriber(),
            ),
            llmService: llmService,
            llmAgentService: MockProcessingLLMAgentService(),
            textInjector: textInjector,
            clipboard: MockClipboardService(),
            historyStore: MockProcessingHistoryStore(),
            agentJobStore: MockProcessingAgentJobStore(),
            agentExecutionRegistry: AgentExecutionRegistry(),
            mcpRegistry: MCPRegistry(),
            overlayController: overlayController,
            askAnswerWindowController: AskAnswerWindowController(
                clipboard: MockClipboardService(),
                settingsStore: settingsStore,
            ),
            agentClarificationWindowController: AgentClarificationWindowController(
                settingsStore: settingsStore,
            ),
            soundEffectPlayer: soundEffectPlayer ?? SoundEffectPlayer(settingsStore: settingsStore),
            sleep: sleep,
        )
    }

    private func makeRecordingSoundEffectPlayer(
        eventRecorder: ThreadSafeEventRecorder,
        soundEffectsEnabled: Bool = true,
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
        soundEffectsEnabled: Bool = true,
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
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
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

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        TextSelectionSnapshot()
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        CurrentInputTextSnapshot()
    }

    func currentInputText() async -> String? {
        nil
    }

    func insert(text: String) throws {
        insertedTexts.append(text)
    }

    func replaceSelection(text: String) throws {
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
        for _ in 0..<100 {
            if stopCallCount >= expectedCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
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
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
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
        for _ in 0..<100 {
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
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
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
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
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

    func prepareToPlay() -> Bool { true }

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
        for _ in 0..<100 {
            if snapshot().contains(event) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class MockProcessingTranscriber: Transcriber {
    func transcribe(audioFile _: AudioFile) async throws -> String {
        ""
    }
}

private final class MockProcessingHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: "/tmp/history.md") }
}

private final class MockProcessingAgentJobStore: AgentJobStore, @unchecked Sendable {
    func save(_: AgentJob) async throws {}
    func list(limit _: Int, offset _: Int) async throws -> [AgentJob] { [] }
    func job(id _: UUID) async throws -> AgentJob? { nil }
    func delete(id _: UUID) async throws {}
    func clear() async throws {}
    func count() async throws -> Int { 0 }
}
