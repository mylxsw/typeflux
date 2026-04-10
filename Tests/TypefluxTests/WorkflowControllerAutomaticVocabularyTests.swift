import AVFoundation
@testable import Typeflux
import XCTest

final class WorkflowControllerAutomaticVocabularyTests: XCTestCase {
    func testAutomaticVocabularyMatchingPrefersBundleIdentifier() {
        let controller = makeWorkflowController()
        let expected = controller.automaticVocabularyExpectedApp(
            from: CurrentInputTextSnapshot(
                processID: 101,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "hello",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
        )

        let matches = controller.automaticVocabularyMatchesExpectedApp(
            CurrentInputTextSnapshot(
                processID: 202,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "hello world",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            expectedApp: expected,
        )

        XCTAssertTrue(matches)
    }

    func testAutomaticVocabularyMatchingFallsBackToProcessID() {
        let controller = makeWorkflowController()
        let expected = controller.automaticVocabularyExpectedApp(
            from: CurrentInputTextSnapshot(
                processID: 101,
                processName: "Terminal",
                bundleIdentifier: nil,
                role: "AXTextArea",
                text: "hello",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
        )

        let matches = controller.automaticVocabularyMatchesExpectedApp(
            CurrentInputTextSnapshot(
                processID: 101,
                processName: "Other Name",
                bundleIdentifier: nil,
                role: "AXTextArea",
                text: "hello world",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            expectedApp: expected,
        )

        XCTAssertTrue(matches)
    }

    func testScheduleAutomaticVocabularyObservationCancelsWhenFocusedAppChanges() async throws {
        let llmService = MockWorkflowLLMService()
        let textInjector = MockWorkflowTextInjector(snapshots: [
            CurrentInputTextSnapshot(
                processID: 101,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "hello",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            CurrentInputTextSnapshot(
                processID: 101,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "hello",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            CurrentInputTextSnapshot(
                processID: 202,
                processName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                role: "AXTextField",
                text: "hello fix",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
        ])
        let controller = makeWorkflowController(textInjector: textInjector, llmService: llmService)

        controller.scheduleAutomaticVocabularyObservation(for: "hello")

        try await Task.sleep(for: .milliseconds(1700))
        await controller.automaticVocabularyObservationTask?.value

        XCTAssertEqual(llmService.completeJSONCallCount, 0)
    }

    private func makeWorkflowController(
        textInjector: TextInjector = MockWorkflowTextInjector(),
        llmService: LLMService = MockWorkflowLLMService(),
    ) -> WorkflowController {
        let suiteName = "WorkflowControllerAutomaticVocabularyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.automaticVocabularyCollectionEnabled = true

        let appState = AppStateStore()
        let overlayController = OverlayController(appState: appState)

        return WorkflowController(
            appState: appState,
            settingsStore: settingsStore,
            hotkeyService: MockWorkflowHotkeyService(),
            audioRecorder: MockWorkflowAudioRecorder(),
            sttRouter: STTRouter(
                settingsStore: settingsStore,
                whisper: MockWorkflowTranscriber(),
                freeSTT: MockWorkflowTranscriber(),
                appleSpeech: MockWorkflowTranscriber(),
                localModel: MockWorkflowTranscriber(),
                multimodal: MockWorkflowTranscriber(),
                aliCloud: MockWorkflowTranscriber(),
                doubaoRealtime: MockWorkflowTranscriber(),
                groq: MockWorkflowTranscriber(),
                typefluxOfficial: MockWorkflowTranscriber(),
            ),
            llmService: llmService,
            llmAgentService: MockWorkflowLLMAgentService(),
            textInjector: textInjector,
            clipboard: MockClipboardService(),
            historyStore: MockWorkflowHistoryStore(),
            agentJobStore: MockWorkflowAgentJobStore(),
            agentExecutionRegistry: AgentExecutionRegistry(),
            mcpRegistry: MCPRegistry(),
            overlayController: overlayController,
            askAnswerWindowController: AskAnswerWindowController(
                clipboard: MockClipboardService(),
                settingsStore: settingsStore,
            ),
            soundEffectPlayer: SoundEffectPlayer(settingsStore: settingsStore),
        )
    }
}

private final class MockWorkflowTextInjector: TextInjector {
    private let snapshots: [CurrentInputTextSnapshot]
    private var currentIndex = 0

    init(snapshots: [CurrentInputTextSnapshot] = [
        CurrentInputTextSnapshot(
            processID: 1,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            text: "",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
        ),
    ]) {
        self.snapshots = snapshots
    }

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        TextSelectionSnapshot()
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        let snapshot = snapshots[min(currentIndex, snapshots.count - 1)]
        if currentIndex < snapshots.count - 1 {
            currentIndex += 1
        }
        return snapshot
    }

    func currentInputText() async -> String? {
        await currentInputTextSnapshot().text
    }

    func insert(text _: String) throws {}

    func replaceSelection(text _: String) throws {}
}

private final class MockWorkflowLLMService: LLMService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockWorkflowLLMService")
    private var callCount = 0

    var completeJSONCallCount: Int {
        queue.sync { callCount }
    }

    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        ""
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        queue.sync {
            callCount += 1
        }
        return #"{"terms":[]}"#
    }
}

private final class MockWorkflowLLMAgentService: LLMAgentService {
    func runTool<T: Decodable & Sendable>(request _: LLMAgentRequest, decoding _: T.Type) async throws -> T {
        throw NSError(domain: "MockWorkflowLLMAgentService", code: 1)
    }
}

private final class MockWorkflowHotkeyService: HotkeyService {
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

private final class MockWorkflowAudioRecorder: AudioRecorder {
    func start(
        levelHandler _: @escaping (Float) -> Void,
        audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?,
    ) throws {}

    func stop() throws -> AudioFile {
        AudioFile(fileURL: URL(fileURLWithPath: "/tmp/mock.wav"), duration: 1)
    }
}

private final class MockWorkflowTranscriber: Transcriber {
    func transcribe(audioFile _: AudioFile) async throws -> String {
        ""
    }
}

private final class MockWorkflowHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/history.md")
    }
}

private final class MockWorkflowAgentJobStore: AgentJobStore, @unchecked Sendable {
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
