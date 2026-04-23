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

    func testScheduleNewObservationFinalizesPreviousSessionWhenEditsWereObserved() async {
        let llmService = MockWorkflowLLMService(stubbedJSON: #"{"terms":["SeedASR"]}"#)
        let controller = makeWorkflowController(llmService: llmService)

        // Simulate a previous session that observed a real user edit but never
        // reached the end of its observation window.
        controller.automaticVocabularyActiveSession = AutomaticVocabularyActiveSession(
            sessionID: UUID(),
            insertedText: "please check the seedsr config",
            baselineText: "please check the seedsr config",
            latestObservedText: "please check the SeedASR config",
            hasObservedChange: true,
        )

        controller.finalizePreviousAutomaticVocabularySessionIfNeeded()

        // The analysis runs on a detached Task — wait a bit for completion.
        for _ in 0 ..< 40 {
            if llmService.completeJSONCallCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(llmService.completeJSONCallCount, 1)
        if let entry = VocabularyStore.load().first(where: { $0.term == "SeedASR" }) {
            _ = VocabularyStore.remove(id: entry.id)
        }
    }

    func testScheduleNewObservationSkipsFinalizationWhenNoChangeWasObserved() {
        let llmService = MockWorkflowLLMService()
        let controller = makeWorkflowController(llmService: llmService)

        // Baseline captured but no user edit ever happened — nothing to analyze.
        controller.automaticVocabularyActiveSession = AutomaticVocabularyActiveSession(
            sessionID: UUID(),
            insertedText: "hello",
            baselineText: "hello",
            latestObservedText: "hello",
            hasObservedChange: false,
        )

        controller.finalizePreviousAutomaticVocabularySessionIfNeeded()

        XCTAssertEqual(llmService.completeJSONCallCount, 0)
    }

    // MARK: - runAutomaticVocabularyAnalysis orchestration paths

    func testRunAnalysisSmallRewriteReachesLLM() async {
        let llmService = MockWorkflowLLMService(stubbedJSON: #"{"terms":["PRDPlus"]}"#)
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "please review the prddraft text",
            baselineText: "please review the prddraft text",
            finalText: "please review the PRDPlus text",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 1)
        XCTAssertTrue(VocabularyStore.activeTerms().contains("PRDPlus"))
        if let entry = VocabularyStore.load().first(where: { $0.term == "PRDPlus" }) {
            _ = VocabularyStore.remove(id: entry.id)
        }
    }

    func testRunAnalysisCaseOnlyAcronymCorrectionReachesLLM() async {
        let llmService = MockWorkflowLLMService(stubbedJSON: #"{"terms":["GPT","API"]}"#)
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "please check the gpt api response",
            baselineText: "please check the gpt api response",
            finalText: "please check the GPT API response",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 1)
        XCTAssertTrue(VocabularyStore.activeTerms().contains("GPT"))
        XCTAssertTrue(VocabularyStore.activeTerms().contains("API"))
        for term in ["GPT", "API"] {
            if let entry = VocabularyStore.load().first(where: { $0.term == term }) {
                _ = VocabularyStore.remove(id: entry.id)
            }
        }
    }

    func testRunAnalysisLargeRewriteIsAbandoned() async {
        let llmService = MockWorkflowLLMService()
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "hello world",
            baselineText: "hello world",
            finalText: "this is a completely different sentence written by the user instead",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 0)
    }

    func testRunAnalysisSkipsWhenFinalEqualsBaseline() async {
        let llmService = MockWorkflowLLMService()
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "hello world",
            baselineText: "hello world",
            finalText: "hello world",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 0)
    }

    func testRunAnalysisSkipsInitialInsertionEvenIfBaselineWasStale() async {
        // Stale baseline scenario: baseline was captured before AX reflected the
        // insertion, so the observed "change" is literally our dictation output.
        // Must NOT reach the LLM.
        let llmService = MockWorkflowLLMService()
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "SeedASR Doubao",
            baselineText: "",
            finalText: "SeedASR Doubao",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 0)
    }

    func testRunAnalysisSkipsWhenLLMReturnsEmpty() async {
        let llmService = MockWorkflowLLMService(stubbedJSON: #"{"terms":[]}"#)
        let controller = makeWorkflowController(llmService: llmService)

        await controller.runAutomaticVocabularyAnalysis(
            insertedText: "please check the apidoc",
            baselineText: "please check the apidoc",
            finalText: "please check the OpenAPI",
        )

        XCTAssertEqual(llmService.completeJSONCallCount, 1)
    }

    // MARK: - Baseline retry with expected substring

    func testBaselineRetryReturnsImmediatelyWhenExpectedSubstringPresent() async {
        let textInjector = MockWorkflowTextInjector(snapshots: [
            CurrentInputTextSnapshot(
                processID: 1,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "please check the prddraft text",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
        ])
        let controller = makeWorkflowController(textInjector: textInjector)

        let start = Date()
        let snapshot = await controller.readAutomaticVocabularyBaselineWithRetry(
            expectedSubstring: "prddraft",
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(snapshot.text, "please check the prddraft text")
        XCTAssertLessThan(elapsed, 0.2, "should not sleep when the first snapshot already contains the inserted text")
    }

    func testBaselineRetryWaitsUntilInsertedSubstringAppears() async {
        let textInjector = MockWorkflowTextInjector(snapshots: [
            // First two reads return the pre-insertion state (AX hasn't caught up).
            CurrentInputTextSnapshot(
                processID: 1,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "please check the ",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            CurrentInputTextSnapshot(
                processID: 1,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "please check the ",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
            // Third read finally shows the inserted text.
            CurrentInputTextSnapshot(
                processID: 1,
                processName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: "AXTextArea",
                text: "please check the prddraft text",
                isEditable: true,
                isFocusedTarget: true,
                failureReason: nil,
            ),
        ])
        let controller = makeWorkflowController(textInjector: textInjector)

        let snapshot = await controller.readAutomaticVocabularyBaselineWithRetry(
            expectedSubstring: "prddraft",
        )

        XCTAssertEqual(snapshot.text, "please check the prddraft text")
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
        settingsStore.llmRemoteProvider = .freeModel
        settingsStore.llmModel = "test-model"

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
                googleCloud: MockWorkflowTranscriber(),
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
            agentClarificationWindowController: AgentClarificationWindowController(
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
    private var stubbedJSON: String

    init(stubbedJSON: String = #"{"terms":[]}"#) {
        self.stubbedJSON = stubbedJSON
    }

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
        return stubbedJSON
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
