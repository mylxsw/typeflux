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

    func testStoppingRecordingBlocksNewRecordingUntilStopCompletes() async {
        let audioRecorder = BlockingStopAudioRecorder()
        let controller = makeWorkflowController(audioRecorder: audioRecorder)
        controller.isRecording = true
        controller.recordingMode = .locked

        controller.finishRecordingFromCurrentMode()
        await audioRecorder.waitUntilStopStarted()

        XCTAssertTrue(controller.isStoppingRecording)

        await controller.beginRecording(intent: .dictation, startLocked: true)

        XCTAssertEqual(audioRecorder.startCallCount, 0)

        audioRecorder.finishStop()
        await waitUntil {
            !controller.isStoppingRecording
        }
        XCTAssertFalse(controller.isStoppingRecording)
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
        let controller = makeWorkflowController { settingsStore in
            settingsStore.personas = settingsStore.personas + [customPersona]
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.tinyspeck.slackmacgap",
                personaID: customPersona.id,
            )
        }
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
        let controller = makeWorkflowController { settingsStore in
            let defaultPersona = settingsStore.personas[0]
            settingsStore.applyPersonaSelection(defaultPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.apple.Notes",
                personaID: nil,
            )
        }
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
        let controller = makeWorkflowController { settingsStore in
            let globalPersona = settingsStore.personas[0]
            let appPersona = settingsStore.personas[1]
            settingsStore.personas = settingsStore.personas + [targetPersona]
            settingsStore.applyPersonaSelection(globalPersona.id)
            settingsStore.savePersonaAppBinding(
                appIdentifier: "com.apple.Notes",
                personaID: appPersona.id,
            )
        }
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

    private func makeWorkflowController(
        textInjector: TextInjector = MockProcessingTextInjector(),
        audioRecorder: AudioRecorder = MockProcessingAudioRecorder(),
        llmService: LLMService = MockProcessingLLMService(),
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
            soundEffectPlayer: SoundEffectPlayer(settingsStore: settingsStore),
        )
    }
}

private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: @escaping () -> Bool,
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
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
    var onAskPressBegan: (() -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    func start() {}
    func stop() {}
}

private final class MockProcessingAudioRecorder: AudioRecorder {
    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
    ) throws {}

    func stop() throws -> AudioFile {
        AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
}

private final class BlockingStopAudioRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private let stopStarted = DispatchSemaphore(value: 0)
    private let stopRelease = DispatchSemaphore(value: 0)
    private var starts = 0

    var startCallCount: Int {
        lock.lock()
        let count = starts
        lock.unlock()
        return count
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
        stopStarted.signal()
        _ = stopRelease.wait(timeout: .now() + 2)
        return AudioFile(fileURL: URL(fileURLWithPath: "/tmp/missing.wav"), duration: 1)
    }

    func waitUntilStopStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.stopStarted.wait()
                continuation.resume()
            }
        }
    }

    func finishStop() {
        stopRelease.signal()
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
