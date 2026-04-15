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

    private func makeWorkflowController(
        textInjector: TextInjector = MockProcessingTextInjector(),
        llmService: LLMService = MockProcessingLLMService(),
    ) -> WorkflowController {
        let suiteName = "WorkflowControllerProcessingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        let appState = AppStateStore()
        let overlayController = OverlayController(appState: appState)

        return WorkflowController(
            appState: appState,
            settingsStore: settingsStore,
            hotkeyService: MockProcessingHotkeyService(),
            audioRecorder: MockProcessingAudioRecorder(),
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
