@testable import Typeflux
import XCTest

// MARK: - Mock Types

private final class MockTranscriber: Transcriber {
    var resultToReturn: String = "transcribed"
    var errorToThrow: Error?
    var transcribeCallCount = 0

    func transcribe(audioFile _: AudioFile) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow {
            throw error
        }
        return resultToReturn
    }

    func transcribeStream(
        audioFile _: AudioFile,
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

private final class DelayedMockTranscriber: Transcriber {
    let delayNanoseconds: UInt64
    let result: Result<String, Error>

    init(delay: TimeInterval, result: Result<String, Error>) {
        delayNanoseconds = UInt64(delay * 1_000_000_000)
        self.result = result
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile _: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let text = try result.get()
        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
        return text
    }
}

private final class MockRecordingPrewarmingTranscriber: RecordingPrewarmingTranscriber {
    var resultToReturn: String = "transcribed"
    var errorToThrow: Error?
    var transcribeCallCount = 0
    var prepareCallCount = 0
    var cancelCallCount = 0

    func transcribe(audioFile _: AudioFile) async throws -> String {
        transcribeCallCount += 1
        if let error = errorToThrow { throw error }
        return resultToReturn
    }

    func transcribeStream(
        audioFile _: AudioFile,
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

private final class MockScenarioAwareTranscriber: TypefluxCloudScenarioAwareTranscriber {
    var resultToReturn: String = "transcribed"
    var transcribeCallCount = 0
    var lastScenario: TypefluxCloudScenario?

    func transcribe(audioFile _: AudioFile, scenario: TypefluxCloudScenario) async throws -> String {
        transcribeCallCount += 1
        lastScenario = scenario
        return resultToReturn
    }

    func transcribeStream(
        audioFile _: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        transcribeCallCount += 1
        lastScenario = scenario
        await onUpdate(TranscriptionSnapshot(text: resultToReturn, isFinal: true))
        return resultToReturn
    }
}

private final class MockOptimizeAwareTranscriber: ASROptimizeAwareTranscriber {
    var resultToReturn = "transcribed"
    var transcribeCallCount = 0
    var lastOptimize: Bool?

    func transcribeStream(
        audioFile _: AudioFile,
        scenario _: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        transcribeCallCount += 1
        lastOptimize = optimize
        await onUpdate(TranscriptionSnapshot(text: resultToReturn, isFinal: true))
        return resultToReturn
    }

    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await transcribeStream(
            audioFile: audioFile,
            scenario: scenario,
            optimize: true,
            onUpdate: onUpdate
        )
    }
}

private final class MockIntegratedTypefluxTranscriber: TypefluxCloudLLMIntegratedTranscriber {
    var resultToReturn: (transcript: String, rewritten: String?) = ("transcribed", "rewritten")
    var errorToThrow: Error?
    var integratedCallCount = 0

    func transcribe(audioFile _: AudioFile, scenario _: TypefluxCloudScenario) async throws -> String {
        resultToReturn.transcript
    }

    func transcribeStream(
        audioFile _: AudioFile,
        scenario _: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        await onUpdate(TranscriptionSnapshot(text: resultToReturn.transcript, isFinal: true))
        return resultToReturn.transcript
    }

    func transcribeStreamWithLLMRewrite(
        audioFile _: AudioFile,
        llmConfig _: ASRLLMConfig,
        scenario _: TypefluxCloudScenario,
        onASRUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart _: @escaping @Sendable () async -> Void,
        onLLMChunk _: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        integratedCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        return resultToReturn
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
    private var googleCloud: MockTranscriber!
    private var groq: MockTranscriber!
    private var typefluxOfficial: MockTranscriber!

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
        googleCloud = MockTranscriber()
        groq = MockTranscriber()
        typefluxOfficial = MockTranscriber()
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
        googleCloud = nil
        groq = nil
        typefluxOfficial = nil
        super.tearDown()
    }

    private func makeRouter(
        localModelOverride: Transcriber? = nil,
        doubaoRealtimeOverride: Transcriber? = nil,
        typefluxOfficialOverride: Transcriber? = nil,
        typefluxCloudLoginFallbackLocalModel: Transcriber? = nil,
        typefluxOfficialCloudPriorityWindow: TimeInterval = STTRouter
            .typefluxOfficialCloudPriorityWindowSeconds,
        isTypefluxCloudLoggedIn: @escaping @Sendable () async -> Bool = { false },
        hasPaidTypefluxCloudSubscription: @escaping @Sendable () async -> Bool = { false }
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
            googleCloud: googleCloud,
            groq: groq,
            soniox: MockTranscriber(),
            typefluxOfficial: typefluxOfficialOverride ?? typefluxOfficial,
            typefluxCloudLoginFallbackLocalModel: typefluxCloudLoginFallbackLocalModel,
            typefluxOfficialCloudPriorityWindow: typefluxOfficialCloudPriorityWindow,
            isTypefluxCloudLoggedIn: isTypefluxCloudLoggedIn,
            hasPaidTypefluxCloudSubscription: hasPaidTypefluxCloudSubscription
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

    func testRoutesToGoogleCloud() async throws {
        settings.sttProvider = .googleCloud
        googleCloud.resultToReturn = "google result"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "google result")
        XCTAssertGreaterThan(googleCloud.transcribeCallCount, 0)
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

    func testFallsBackToTypefluxCloudWhenSelectedLocalModelIsNotPreparedAndLoggedIn() async throws {
        settings.sttProvider = .localModel
        settings.useAppleSpeechFallback = false
        localModel.errorToThrow = NSError(
            domain: LocalModelTranscriber.notPreparedErrorDomain,
            code: LocalModelTranscriber.notPreparedErrorCode
        )
        typefluxOfficial.resultToReturn = "cloud fallback"
        let router = makeRouter(isTypefluxCloudLoggedIn: { true })

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "cloud fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testLocalModelCloudFallbackPreservesOptimize() async throws {
        settings.sttProvider = .localModel
        settings.useAppleSpeechFallback = false
        localModel.errorToThrow = NSError(
            domain: LocalModelTranscriber.notPreparedErrorDomain,
            code: LocalModelTranscriber.notPreparedErrorCode
        )
        let optimizeAwareCloud = MockOptimizeAwareTranscriber()
        optimizeAwareCloud.resultToReturn = "cloud fallback"
        let router = makeRouter(
            typefluxOfficialOverride: optimizeAwareCloud,
            isTypefluxCloudLoggedIn: { true }
        )

        let result = try await router.transcribeStream(
            audioFile: dummyAudioFile(),
            optimize: false
        ) { _ in }

        XCTAssertEqual(result, "cloud fallback")
        XCTAssertEqual(optimizeAwareCloud.transcribeCallCount, 1)
        XCTAssertEqual(optimizeAwareCloud.lastOptimize, false)
    }

    func testTypefluxOfficialPrefersCloudInsidePriorityWindow() async throws {
        settings.sttProvider = .typefluxOfficial
        let cloud = MockTranscriber()
        cloud.resultToReturn = "cloud result"
        let local = MockTranscriber()
        local.resultToReturn = "local result"
        let router = makeRouter(
            typefluxOfficialOverride: cloud,
            typefluxCloudLoginFallbackLocalModel: local,
            typefluxOfficialCloudPriorityWindow: 60
        )
        let diagnosticsRecorder = ASRRaceDiagnosticsRecorder()

        let result = try await router.transcribeStream(
            audioFile: dummyAudioFile(),
            diagnosticsRecorder: diagnosticsRecorder
        ) { _ in }

        XCTAssertEqual(result, "cloud result")
        XCTAssertEqual(diagnosticsRecorder.snapshot()?.selectedSource, .cloud)
        XCTAssertEqual(diagnosticsRecorder.snapshot()?.selectionReason, .cloudWithinPriorityWindow)
    }

    func testTypefluxOfficialCloudPriorityWindowIsThreeSeconds() {
        XCTAssertEqual(STTRouter.typefluxOfficialCloudPriorityWindowSeconds, 3)
    }

    func testTypefluxOfficialUsesReadyLocalResultWhenPriorityWindowExpires() async throws {
        settings.sttProvider = .typefluxOfficial
        let cloud = DelayedMockTranscriber(delay: 60, result: .success("cloud result"))
        let local = MockTranscriber()
        local.resultToReturn = "local result"
        let router = makeRouter(
            typefluxOfficialOverride: cloud,
            typefluxCloudLoginFallbackLocalModel: local,
            typefluxOfficialCloudPriorityWindow: 0
        )
        let diagnosticsRecorder = ASRRaceDiagnosticsRecorder()

        let result = try await router.transcribeStream(
            audioFile: dummyAudioFile(),
            diagnosticsRecorder: diagnosticsRecorder
        ) { _ in }

        XCTAssertEqual(result, "local result")
        XCTAssertEqual(diagnosticsRecorder.snapshot()?.selectedSource, .local)
        XCTAssertEqual(diagnosticsRecorder.snapshot()?.cloudAttempt.outcome, .cancelled)
    }

    func testTypefluxOfficialUsesCloudWhenLocalFailsAfterPriorityWindow() async throws {
        settings.sttProvider = .typefluxOfficial
        let cloud = MockTranscriber()
        cloud.resultToReturn = "cloud result"
        let local = MockTranscriber()
        local.errorToThrow = NSError(domain: "local", code: 1)
        let router = makeRouter(
            typefluxOfficialOverride: cloud,
            typefluxCloudLoginFallbackLocalModel: local,
            typefluxOfficialCloudPriorityWindow: 0
        )

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "cloud result")
    }

    func testTypefluxOfficialBillingFailureDoesNotFallBackToAppleSpeech() async throws {
        let billingError = TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nil)
        settings.sttProvider = .typefluxOfficial
        settings.useAppleSpeechFallback = true
        typefluxOfficial.errorToThrow = billingError
        let router = makeRouter()

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected billing error")
        } catch let error as TypefluxCloudBillingError {
            XCTAssertEqual(error, billingError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testTypefluxOfficialQuotaFailureUsesDefaultSenseVoiceFallbackForPaidSubscription() async throws {
        let billingError = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        settings.sttProvider = .typefluxOfficial
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        typefluxOfficial.errorToThrow = billingError
        let defaultSenseVoiceFallback = MockTranscriber()
        defaultSenseVoiceFallback.resultToReturn = "sensevoice fallback"
        let router = makeRouter(
            typefluxCloudLoginFallbackLocalModel: defaultSenseVoiceFallback,
            hasPaidTypefluxCloudSubscription: { true }
        )

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "sensevoice fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(defaultSenseVoiceFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testTypefluxOfficialQuotaFailureUsesConcurrentLocalResultForFreePlan() async throws {
        let billingError = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        settings.sttProvider = .typefluxOfficial
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        typefluxOfficial.errorToThrow = billingError
        let defaultSenseVoiceFallback = MockTranscriber()
        defaultSenseVoiceFallback.resultToReturn = "sensevoice fallback"
        let router = makeRouter(
            typefluxCloudLoginFallbackLocalModel: defaultSenseVoiceFallback,
            hasPaidTypefluxCloudSubscription: { false }
        )

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "sensevoice fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(defaultSenseVoiceFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testTypefluxOfficialLoginRequiredFallsBackToAppleSpeech() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.useAppleSpeechFallback = true
        typefluxOfficial.errorToThrow = TypefluxOfficialASRError.notLoggedIn
        appleSpeech.resultToReturn = "apple fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "apple fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 1)
    }

    func testTypefluxOfficialRoutingUnauthorizedFallsBackToAppleSpeech() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.useAppleSpeechFallback = true
        typefluxOfficial.errorToThrow = TypefluxOfficialASRRoutingError.unauthorized
        appleSpeech.resultToReturn = "apple fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "apple fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 1)
    }

    func testTypefluxOfficialLoginRequiredUsesDefaultSenseVoiceFallbackWhenLocalOptimizationIsDisabled() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        typefluxOfficial.errorToThrow = TypefluxOfficialASRError.notLoggedIn
        let defaultSenseVoiceFallback = MockTranscriber()
        defaultSenseVoiceFallback.resultToReturn = "sensevoice fallback"
        let router = makeRouter(typefluxCloudLoginFallbackLocalModel: defaultSenseVoiceFallback)

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "sensevoice fallback")
        XCTAssertEqual(typefluxOfficial.transcribeCallCount, 1)
        XCTAssertEqual(defaultSenseVoiceFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testIntegratedTypefluxLoginRequiredUsesDefaultSenseVoiceFallbackWhenLocalOptimizationIsDisabled() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        let integrated = MockIntegratedTypefluxTranscriber()
        integrated.errorToThrow = TypefluxOfficialASRError.notLoggedIn
        let defaultSenseVoiceFallback = MockTranscriber()
        defaultSenseVoiceFallback.resultToReturn = "sensevoice fallback"
        let router = makeRouter(
            typefluxOfficialOverride: integrated,
            typefluxCloudLoginFallbackLocalModel: defaultSenseVoiceFallback
        )

        let result = try await router.transcribeStreamWithLLMRewrite(
            audioFile: dummyAudioFile(),
            llmConfig: ASRLLMConfig(systemPrompt: "sys", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )

        XCTAssertEqual(result.transcript, "sensevoice fallback")
        XCTAssertNil(result.rewritten)
        XCTAssertEqual(integrated.integratedCallCount, 1)
        XCTAssertEqual(defaultSenseVoiceFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testIntegratedTypefluxQuotaFailureUsesDefaultSenseVoiceFallbackForPaidSubscription() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        let integrated = MockIntegratedTypefluxTranscriber()
        integrated.errorToThrow = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        let defaultSenseVoiceFallback = MockTranscriber()
        defaultSenseVoiceFallback.resultToReturn = "sensevoice fallback"
        let router = makeRouter(
            typefluxOfficialOverride: integrated,
            typefluxCloudLoginFallbackLocalModel: defaultSenseVoiceFallback,
            hasPaidTypefluxCloudSubscription: { true }
        )

        let result = try await router.transcribeStreamWithLLMRewrite(
            audioFile: dummyAudioFile(),
            llmConfig: ASRLLMConfig(systemPrompt: "sys", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )

        XCTAssertEqual(result.transcript, "sensevoice fallback")
        XCTAssertNil(result.rewritten)
        XCTAssertEqual(integrated.integratedCallCount, 1)
        XCTAssertEqual(defaultSenseVoiceFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testDoesNotUseTypefluxCloudForUnpreparedLocalModelWhenLoggedOut() async {
        settings.sttProvider = .localModel
        settings.useAppleSpeechFallback = false
        localModel.errorToThrow = NSError(
            domain: LocalModelTranscriber.notPreparedErrorDomain,
            code: LocalModelTranscriber.notPreparedErrorCode
        )
        let router = makeRouter(isTypefluxCloudLoggedIn: { false })

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected local model not prepared error")
        } catch {
            XCTAssertEqual((error as NSError).domain, LocalModelTranscriber.notPreparedErrorDomain)
            XCTAssertEqual(typefluxOfficial.transcribeCallCount, 0)
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

    func testConnectivityFailureUsesBundledLocalFallbackWhenOptimizationIsDisabled() async throws {
        settings.sttProvider = .whisperAPI
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        whisper.errorToThrow = URLError(.cannotConnectToHost)
        let bundledLocalFallback = MockTranscriber()
        bundledLocalFallback.resultToReturn = "offline transcript"
        let router = makeRouter(typefluxCloudLoginFallbackLocalModel: bundledLocalFallback)

        let result = try await router.transcribe(audioFile: dummyAudioFile())

        XCTAssertEqual(result, "offline transcript")
        XCTAssertEqual(whisper.transcribeCallCount, 1)
        XCTAssertEqual(bundledLocalFallback.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testNonConnectivityFailureDoesNotUseBundledLocalFallback() async {
        settings.sttProvider = .whisperAPI
        settings.localOptimizationEnabled = false
        settings.useAppleSpeechFallback = false
        whisper.errorToThrow = NSError(domain: "RemoteSTT", code: 401)
        let bundledLocalFallback = MockTranscriber()
        bundledLocalFallback.resultToReturn = "must not be used"
        let router = makeRouter(typefluxCloudLoginFallbackLocalModel: bundledLocalFallback)

        do {
            _ = try await router.transcribe(audioFile: dummyAudioFile())
            XCTFail("Expected remote provider error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "RemoteSTT")
        }

        XCTAssertEqual(bundledLocalFallback.transcribeCallCount, 0)
    }

    // MARK: - WhisperAPI default OpenAI endpoint

    func testWhisperAPIWithEmptyBaseURLStillRoutesToWhisperTranscriber() async throws {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = ""
        whisper.resultToReturn = "openai default endpoint"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "openai default endpoint")
        XCTAssertEqual(whisper.transcribeCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }

    func testWhisperAPIWithEmptyBaseURLStillFallsBackAfterWhisperFailure() async throws {
        settings.sttProvider = .whisperAPI
        settings.whisperBaseURL = ""
        settings.useAppleSpeechFallback = true
        whisper.errorToThrow = NSError(domain: "test", code: 1)
        appleSpeech.resultToReturn = "apple fallback"
        let router = makeRouter()

        let result = try await router.transcribe(audioFile: dummyAudioFile())
        XCTAssertEqual(result, "apple fallback")
        XCTAssertEqual(whisper.transcribeCallCount, 4)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 1)
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

    func testRoutesTypefluxOfficialWithProvidedBusinessScenario() async throws {
        settings.sttProvider = .typefluxOfficial
        let scenarioAware = MockScenarioAwareTranscriber()
        let router = STTRouter(
            settingsStore: settings,
            whisper: whisper,
            freeSTT: freeSTT,
            appleSpeech: appleSpeech,
            localModel: localModel,
            multimodal: multimodal,
            aliCloud: aliCloud,
            doubaoRealtime: doubaoRealtime,
            googleCloud: googleCloud,
            groq: groq,
            soniox: MockTranscriber(),
            typefluxOfficial: scenarioAware
        )

        let result = try await router.transcribe(
            audioFile: dummyAudioFile(),
            scenario: .askAnything
        )

        XCTAssertEqual(result, "transcribed")
        XCTAssertEqual(scenarioAware.lastScenario, .askAnything)
        XCTAssertEqual(scenarioAware.transcribeCallCount, 1)
    }

    func testIntegratedBillingFailureAfterASRReturnsTranscriptFallback() async throws {
        settings.sttProvider = .typefluxOfficial
        settings.useAppleSpeechFallback = true
        let integrated = MockIntegratedTypefluxTranscriber()
        integrated.errorToThrow = TypefluxCloudIntegratedRewriteError(
            transcript: "already transcribed",
            underlyingError: TypefluxCloudBillingError(reason: .subscriptionRequired, serverMessage: nil)
        )
        let router = makeRouter(typefluxOfficialOverride: integrated)

        let result = try await router.transcribeStreamWithLLMRewrite(
            audioFile: dummyAudioFile(),
            llmConfig: ASRLLMConfig(systemPrompt: "sys", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )

        XCTAssertEqual(result.transcript, "already transcribed")
        XCTAssertNil(result.rewritten)
        XCTAssertEqual(integrated.integratedCallCount, 1)
        XCTAssertEqual(appleSpeech.transcribeCallCount, 0)
    }
}
