import XCTest
@testable import Typeflux

// MARK: - Mock Types

private final class MockTranscriber: Transcriber {
    var resultToReturn: String = "transcribed"
    var errorToThrow: Error?
    var transcribeCallCount = 0

    func transcribe(audioFile: AudioFile) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow {
            throw error
        }
        return resultToReturn
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow {
            throw error
        }
        await onUpdate(TranscriptionSnapshot(text: resultToReturn, isFinal: true))
        return resultToReturn
    }
}

private final class MockRecordingPrewarmingTranscriber: RecordingPrewarmingTranscriber {
    var resultToReturn: String = "transcribed"
    var errorToThrow: Error?
    var transcribeCallCount = 0
    var prepareCallCount = 0
    var cancelCallCount = 0

    func transcribe(audioFile: AudioFile) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow { throw error }
        return resultToReturn
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow { throw error }
        await onUpdate(TranscriptionSnapshot(text: resultToReturn, isFinal: true))
        return resultToReturn
    }

    func prepareForRecording() async {
        prepareCallCount += 1
    }

    func cancelPreparedRecording() async {
        cancelCallCount += 1
    }
}

final class STTRouterTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var suiteName: String!

    private var freeSTT: MockTranscriber!
    private var whisper: MockTranscriber!
    private var appleSpeech: MockTranscriber!
    private var localModel: MockTranscriber!
    private var multimodal: MockTranscriber!
    private var aliCloud: MockTranscriber!
    private var doubaoRealtime: MockTranscriber!
    private var groq: MockTranscriber!

    override func setUp() {
        super.setUp()
        suiteName = "STTRouterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)

        freeSTT = MockTranscriber()
        whisper = MockTranscriber()
        appleSpeech = MockTranscriber()
        localModel = MockTranscriber()
        multimodal = MockTranscriber()
        aliCloud = MockTranscriber()
        doubaoRealtime = MockTranscriber()
        groq = MockTranscriber()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = nil
        freeSTT = nil
        whisper = nil
        appleSpeech = nil
        localModel = nil
        multimodal = nil
        aliCloud = nil
        doubaoRealtime = nil
        groq = nil
        super.tearDown()
    }

    private func makeRouter(
        localModelOverride: Transcriber? = nil,
        doubaoRealtimeOverride: Transcriber? = nil
    ) -> STTRouter {
        STTRouter(
            settingsStore: settings,
            whisper: whisper,
            freeSTT: freeSTT,
            appleSpeech: appleSpeech,
            localModel: localModelOverride ?? localModel,
            multimodal: multimodal,
            aliCloud: aliCloud,
            doubaoRealtime: doubaoRealtimeOverride ?? doubaoRealtime,
            groq: groq
        )
    }

    private func dummyAudioFile() -> AudioFile {
        AudioFile(fileURL: URL(fileURLWithPath: "/dev/null"), duration: 1.0)
    }

    // MARK: - Routing

    func testRoutesToFreeModelTranscriber() async throws {
        settings.sttProvider = .freeModel
        freeSTT.resultToReturn = "free result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "free result")
        XCTAssertGreaterThan(freeSTT.transcribeCallCount, 0)
    }

    func testRoutesToWhisperTranscriber() async throws {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = "https://api.example.com"
        whisper.resultToReturn = "whisper result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "whisper result")
        XCTAssertGreaterThan(whisper.transcribeCallCount, 0)
    }

    func testRoutesToAppleSpeech() async throws {
        settings.sttProvider = .appleSpeech
        appleSpeech.resultToReturn = "apple result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple result")
        XCTAssertGreaterThan(appleSpeech.transcribeCallCount, 0)
    }

    func testRoutesToLocalModel() async throws {
        settings.sttProvider = .localModel
        localModel.resultToReturn = "local result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "local result")
        XCTAssertGreaterThan(localModel.transcribeCallCount, 0)
    }

    func testRoutesToMultimodal() async throws {
        settings.sttProvider = .multimodalLLM
        multimodal.resultToReturn = "multimodal result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "multimodal result")
        XCTAssertGreaterThan(multimodal.transcribeCallCount, 0)
    }

    func testRoutesToAliCloud() async throws {
        settings.sttProvider = .aliCloud
        aliCloud.resultToReturn = "alicloud result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "alicloud result")
        XCTAssertGreaterThan(aliCloud.transcribeCallCount, 0)
    }

    func testRoutesToDoubaoRealtime() async throws {
        settings.sttProvider = .doubaoRealtime
        doubaoRealtime.resultToReturn = "doubao result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "doubao result")
        XCTAssertGreaterThan(doubaoRealtime.transcribeCallCount, 0)
    }

    func testRoutesToGroqWhenAPIKeyIsConfigured() async throws {
        settings.sttProvider = .groq
        settings.groqSTTAPIKey = "gsk_test"
        groq.resultToReturn = "groq result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "groq result")
        XCTAssertGreaterThan(groq.transcribeCallCount, 0)
    }

    // MARK: - Fallback (localModel is not wrapped in RequestRetry so these are fast)

    func testFallsBackToAppleSpeechWhenLocalModelFailsAndFallbackEnabled() async throws {
        settings.sttProvider = .localModel
        settings.useAppleSpeechFallback = true
        localModel.errorToThrow = NSError(domain: "test", code: 1)
        appleSpeech.resultToReturn = "apple fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple fallback")
    }

    func testThrowsWhenLocalModelFailsAndFallbackDisabled() async {
        settings.sttProvider = .localModel
        settings.useAppleSpeechFallback = false
        localModel.errorToThrow = NSError(domain: "test", code: 1)
        let router = makeRouter()

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test")
        }
    }

    // MARK: - Fallback with RequestRetry providers (these include retry delays)

    func testFallsBackToAppleSpeechWhenFreeModelFailsAndFallbackEnabled() async throws {
        settings.sttProvider = .freeModel
        settings.useAppleSpeechFallback = true
        freeSTT.errorToThrow = NSError(domain: "test", code: 1)
        appleSpeech.resultToReturn = "apple from free fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple from free fallback")
    }

    func testFallsBackToAppleSpeechWhenWhisperAPIFailsAndFallbackEnabled() async throws {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = "https://api.example.com"
        settings.useAppleSpeechFallback = true
        whisper.errorToThrow = NSError(domain: "test", code: 1)
        appleSpeech.resultToReturn = "apple from whisper fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple from whisper fallback")
    }

    func testThrowsWhenWhisperAPIFailsAndFallbackDisabled() async {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = "https://api.example.com"
        settings.useAppleSpeechFallback = false
        whisper.errorToThrow = NSError(domain: "test", code: 1)
        let router = makeRouter()

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test")
        }
    }

    // MARK: - WhisperAPI empty baseURL

    func testWhisperAPIWithEmptyBaseURLAndFallbackEnabledUsesAppleSpeech() async throws {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = ""
        settings.useAppleSpeechFallback = true
        appleSpeech.resultToReturn = "apple via empty url"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple via empty url")
    }

    func testWhisperAPIWithEmptyBaseURLAndNoFallbackThrows() async {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = ""
        settings.useAppleSpeechFallback = false
        let router = makeRouter()

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "STTRouter")
        }
    }

    // MARK: - prepareForRecording

    func testPrepareForRecordingDelegatesToDoubaoRealtime() async {
        settings.sttProvider = .doubaoRealtime
        let mock = MockRecordingPrewarmingTranscriber()
        let router = makeRouter(doubaoRealtimeOverride: mock)

        await router.prepareForRecording()
        XCTAssertEqual(mock.prepareCallCount, 1)
    }

    func testPrepareForRecordingDelegatesToLocalModel() async {
        settings.sttProvider = .localModel
        let mock = MockRecordingPrewarmingTranscriber()
        let router = makeRouter(localModelOverride: mock)

        await router.prepareForRecording()
        XCTAssertEqual(mock.prepareCallCount, 1)
    }

    func testPrepareForRecordingDoesNothingForOtherProviders() async {
        settings.sttProvider = .appleSpeech
        let router = makeRouter()

        // Should not crash or have side effects.
        await router.prepareForRecording()
    }
}
