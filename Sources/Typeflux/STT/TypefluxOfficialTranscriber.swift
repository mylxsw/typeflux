import AVFoundation
import Foundation
import os

// MARK: - LLM Integration Types

/// Configuration for server-side LLM rewrite, sent as part of the ASR start message.
/// When included, the server runs an LLM pass after transcription and streams the
/// result back over the same WebSocket connection.
struct ASRLLMConfig: Encodable {
    /// Fully-assembled system prompt (language policy + persona + environment context).
    let systemPrompt: String
    /// User prompt template containing "{{transcript}}" as a placeholder for the
    /// final transcription text. The server substitutes it before calling the LLM.
    let userPromptTemplate: String
    /// Stable identifier for the persona used to build the prompts. This is sent
    /// as a request header only, not as part of the WebSocket start payload.
    let personaID: UUID?

    init(systemPrompt: String, userPromptTemplate: String, personaID: UUID? = nil) {
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.personaID = personaID
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case userPromptTemplate = "user_prompt_template"
    }
}

/// Transcribers that support a merged ASR + LLM rewrite in a single WebSocket session.
protocol TypefluxCloudLLMIntegratedTranscriber: TypefluxCloudScenarioAwareTranscriber {
    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?)
}

protocol TypefluxOfficialASRTransport: Sendable {
    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocket(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocketWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?)
}

// MARK: - Main Transcriber

final class TypefluxOfficialTranscriber: ASROptimizeAwareTranscriber, TypefluxCloudLLMIntegratedTranscriber,
    OptimizeAwareRealtimeSessionFactory, RecordingPrewarmingTranscriber {
    private let routingClient: any TypefluxOfficialASRRoutingClient
    private let transport: any TypefluxOfficialASRTransport
    private let serverRegistry: any TypefluxASRServerProviding
    private let credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential?

    init(
        routingClient: any TypefluxOfficialASRRoutingClient = TypefluxOfficialASRRouteCache.shared,
        transport: any TypefluxOfficialASRTransport = DefaultTypefluxOfficialASRTransport(),
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        credentialProvider: @escaping @Sendable () async -> TypefluxCloudSessionCredential? = {
            await AuthState.shared.validSessionCredential()
        }
    ) {
        self.routingClient = routingClient
        self.transport = transport
        self.serverRegistry = serverRegistry
        self.credentialProvider = credentialProvider
    }

    /// Uses `accessTokenProvider` for every credential lookup and treats all
    /// of its tokens as one signed-in session.
    convenience init(
        routingClient: any TypefluxOfficialASRRoutingClient = TypefluxOfficialASRRouteCache.shared,
        transport: any TypefluxOfficialASRTransport = DefaultTypefluxOfficialASRTransport(),
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        accessTokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.init(
            routingClient: routingClient,
            transport: transport,
            serverRegistry: serverRegistry,
            credentialProvider: {
                await accessTokenProvider().map { TypefluxCloudSessionCredential(accessToken: $0, session: 0) }
            }
        )
    }

    func prepareForRecording() async {
        guard let cache = routingClient as? TypefluxOfficialASRRouteCache,
              let credential = await credentialProvider(),
              !credential.accessToken.isEmpty
        else { return }
        await cache.prefetch(accessToken: credential.accessToken)
    }

    func cancelPreparedRecording() async {
        // The prefetched route remains useful for the next recording.
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

    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let credential = try await Self.recordingCredential(from: credentialProvider)
        let pcmData = try CloudASRAudioConverter.convert(url: audioFile.fileURL)
        let route = try await routingClient.fetchRoute(accessToken: credential.accessToken, scenario: scenario)
        let grants = TypefluxOfficialASRGrantSequence(initial: route) { [routingClient, credentialProvider] in
            try await Self.fetchReplacementRoute(
                for: credential,
                credentialProvider: credentialProvider,
                routingClient: routingClient,
                scenario: scenario
            )
        }

        return try await Self.runWithASRServerFailover(
            preferredServers: route.serverBaseURLs,
            serverRegistry: serverRegistry
        ) { apiBaseURL in
            let grant = try await grants.next()
            return try await transport.transcribeViaWebSocket(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: grant.token,
                provider: grant.provider,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        }
    }

    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        let credential = try await Self.recordingCredential(from: credentialProvider)
        let pcmData = try CloudASRAudioConverter.convert(url: audioFile.fileURL)
        let route = try await routingClient.fetchRoute(accessToken: credential.accessToken, scenario: scenario)
        let grants = TypefluxOfficialASRGrantSequence(initial: route) { [routingClient, credentialProvider] in
            try await Self.fetchReplacementRoute(
                for: credential,
                credentialProvider: credentialProvider,
                routingClient: routingClient,
                scenario: scenario
            )
        }

        return try await Self.runWithASRServerFailover(
            preferredServers: route.serverBaseURLs,
            serverRegistry: serverRegistry
        ) { apiBaseURL in
            let grant = try await grants.next()
            return try await transport.transcribeViaWebSocketWithLLM(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: grant.token,
                provider: grant.provider,
                scenario: scenario,
                llmConfig: llmConfig,
                onASRUpdate: onASRUpdate,
                onLLMStart: onLLMStart,
                onLLMChunk: onLLMChunk
            )
        }
    }

    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        try await makeRealtimeTranscriptionSession(
            scenario: scenario,
            optimize: true,
            onUpdate: onUpdate
        )
    }

    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        let transportDiagnostics = NetworkTransportDiagnosticsRecorder(endpoint: nil)
        return BufferedRealtimeTranscriptionSession(
            upstream: DeferredPCM16RealtimeTranscriptionSession {
                [credentialProvider, routingClient, serverRegistry, transportDiagnostics] in
                transportDiagnostics.markCredentialLookupStarted()
                let token = await credentialProvider()?.accessToken
                transportDiagnostics.markCredentialLookupCompleted()
                guard let token, !token.isEmpty else {
                    throw TypefluxOfficialASRError.notLoggedIn
                }

                transportDiagnostics.markRouteLookupStarted()
                let route = try await routingClient.fetchRoute(accessToken: token, scenario: scenario)
                transportDiagnostics.markRouteLookupCompleted()
                let asrToken: String
                let asrProvider: String
                let serverBaseURLs: [URL]
                switch route {
                case let .webSocket(token, _, _, _, servers):
                    asrToken = token
                    asrProvider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
                    serverBaseURLs = servers
                }

                transportDiagnostics.markServerSelectionStarted()
                let baseURLs = await serverRegistry.orderedServers(preferred: serverBaseURLs)
                transportDiagnostics.markServerSelectionCompleted()
                guard let baseURL = baseURLs.first else {
                    throw TypefluxOfficialASRError.connectionFailed("No Typeflux Cloud endpoint configured.")
                }

                return TypefluxOfficialRealtimePCMStream(
                    apiBaseURL: baseURL.absoluteString,
                    token: asrToken,
                    provider: asrProvider,
                    scenario: scenario,
                    optimize: optimize,
                    onUpdate: onUpdate,
                    transportDiagnostics: transportDiagnostics
                )
            }
        )
    }

    static func testConnection() async throws -> String {
        guard await MainActor.run(body: { AuthState.shared.canUseCloudASR }) else {
            throw TypefluxCloudASRDirectiveError()
        }
        let credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential? = {
            await AuthState.shared.validSessionCredential()
        }
        let credential = try await recordingCredential(from: credentialProvider)
        let pcmData = RemoteSTTTestAudio.pcm16MonoSilence()
        let routingClient = TypefluxOfficialASRRoutingHTTPClient()
        let route = try await routingClient.fetchRoute(accessToken: credential.accessToken, scenario: .modelSetup)
        let grants = TypefluxOfficialASRGrantSequence(initial: route) {
            try await fetchReplacementRoute(
                for: credential,
                credentialProvider: credentialProvider,
                routingClient: routingClient,
                scenario: .modelSetup
            )
        }

        return try await runWithASRServerFailover(preferredServers: route.serverBaseURLs) { apiBaseURL in
            let grant = try await grants.next()
            return try await TypefluxOfficialASRSession.run(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: grant.token,
                scenario: .modelSetup,
                provider: grant.provider
            ) { _ in }
        }
    }

    static func recordingCredential(
        from credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential?
    ) async throws -> TypefluxCloudSessionCredential {
        guard let credential = await credentialProvider(), !credential.accessToken.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }
        return credential
    }

    /// Requests a replacement grant with a currently valid access token of the
    /// session that started the recording. A failover attempt can run long
    /// after the recording began, so the original access token may have
    /// expired; a recording whose session was logged out or replaced stops
    /// instead of continuing on (and billing) another account.
    static func fetchReplacementRoute(
        for recording: TypefluxCloudSessionCredential,
        credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential?,
        routingClient: any TypefluxOfficialASRRoutingClient,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        guard let current = await credentialProvider(), !current.accessToken.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }
        guard current.session == recording.session else {
            throw TypefluxOfficialASRError.sessionChanged
        }
        try Task.checkCancellation()
        return try await routingClient.fetchRoute(accessToken: current.accessToken, scenario: scenario)
    }

    /// Runs an ASR session against the highest-priority cloud endpoint and
    /// retries against the next endpoint when an attempt fails before any
    /// audio was sent. Each attempt must take its own one-time grant (see
    /// `TypefluxOfficialASRGrantSequence`). Once audio has been sent
    /// (`TypefluxOfficialASRAdmittedStreamError`) the failure is final:
    /// mid-session migration is not supported because replaying the audio
    /// elsewhere could duplicate the transcript and its billing. A cancelled
    /// recording stops without another grant or attempt.
    static func runWithASRServerFailover<T>(
        preferredServers: [URL],
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        operation: @Sendable (String) async throws -> T
    ) async throws -> T {
        let baseURLs = await serverRegistry.orderedServers(preferred: preferredServers)

        guard !baseURLs.isEmpty else {
            throw TypefluxOfficialASRError.connectionFailed("No Typeflux Cloud endpoint configured.")
        }

        var lastError: Error?
        for baseURL in baseURLs {
            try Task.checkCancellation()
            do {
                return try await operation(baseURL.absoluteString)
            } catch {
                if Task.isCancelled || TypefluxOfficialASRCancellation.isCancellation(error) {
                    throw CancellationError()
                }
                let admitted = error is TypefluxOfficialASRAdmittedStreamError
                let failure = (error as? TypefluxOfficialASRAdmittedStreamError)?.underlying ?? error
                if let refreshError = failure as? TypefluxOfficialASRGrantRefreshError {
                    throw refreshError.underlying
                }
                if TypefluxCloudASRDirectiveError.fromError(failure) != nil {
                    throw TypefluxCloudASRDirectiveError()
                }
                if let billingError = TypefluxCloudBillingError.fromError(failure) {
                    throw billingError
                }
                await serverRegistry.reportFailure(baseURL, error: failure)
                if admitted {
                    throw failure
                }
                lastError = failure
            }
        }
        throw lastError ?? TypefluxOfficialASRError.connectionFailed("All endpoints failed.")
    }
}

struct DefaultTypefluxOfficialASRTransport: TypefluxOfficialASRTransport {
    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocket(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await TypefluxOfficialASRSession.run(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            optimize: optimize,
            onUpdate: onUpdate
        )
    }

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocketWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        try await TypefluxOfficialASRSession.runWithLLM(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            llmConfig: llmConfig,
            onASRUpdate: onASRUpdate,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk
        )
    }
}

// MARK: - Errors

enum TypefluxOfficialASRError: LocalizedError {
    case notLoggedIn
    case connectionFailed(String)
    case serverError(String)
    case unexpectedClose
    /// The account was logged out or replaced while a recording was running.
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            L("cloud.error.asrSignInRequired")
        case let .connectionFailed(reason):
            "Failed to connect to Typeflux ASR service: \(reason)"
        case let .serverError(message):
            "Typeflux ASR error: \(message)"
        case .unexpectedClose:
            "The Typeflux ASR connection closed unexpectedly."
        case .sessionChanged:
            "The Typeflux Cloud account changed during the recording, so transcription stopped."
        }
    }
}

/// Maps a WebSocket receive failure to the error a recording reports.
/// Spelled out step by step: chaining the differently typed optionals with
/// `??` made the compiler wrap the first one, so the fallbacks never ran and
/// an unexpected close could end the recording as an empty success.
enum TypefluxOfficialASRReceiveFailure {
    static func classify(_ error: Error) -> Error {
        if let directive = TypefluxCloudASRDirectiveError.fromError(error) {
            return directive
        }
        if let billing = TypefluxCloudBillingError.fromError(error) {
            return billing
        }
        return TypefluxOfficialASRError.unexpectedClose
    }
}

enum TypefluxOfficialASRClosePolicy {
    static func shouldTreatReceiveFailureAsUnexpectedClose(
        completed: Bool,
        finalSegments: [String]
    ) -> Bool {
        !completed && finalSegments.isEmpty
    }

    static func isNormalProviderCompletion(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("close 1000")
            && lowercased.contains("normal")
            && lowercased.contains("finish last sequence")
    }
}

// MARK: - Audio Converter

enum CloudASRAudioConverter {
    static let targetSampleRate: Double = 16000
    /// 100ms of PCM16 at 16kHz mono = 3200 bytes
    static let chunkSize: Int = 3200

    static func convert(url: URL) throws -> Data {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let totalSourceFrames = AVAudioFrameCount(sourceFile.length)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."]
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."]
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."]
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate target buffer."]
            )
        }

        var hasProvidedInput = false
        var convertError: NSError?
        let status = converter.convert(to: targetBuffer, error: &convertError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let convertError { throw convertError }
        guard status != .error else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
            )
        }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(targetBuffer.frameLength) * bytesPerFrame
        guard let channelData = targetBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }
}

enum TypefluxOfficialASRRequestFactory {
    static let traceIDHeader = "X-Typeflux-ASR-Trace-ID"

    static func makeWebSocketRequest(
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        personaID: UUID? = nil,
        traceID: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(string: apiBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            throw TypefluxOfficialASRError.connectionFailed("Invalid WebSocket server URL: \(apiBaseURL)")
        }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/asr/ws/\(provider)"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw TypefluxOfficialASRError.connectionFailed("Invalid WebSocket server URL: \(apiBaseURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let traceID, !traceID.isEmpty {
            request.setValue(traceID, forHTTPHeaderField: traceIDHeader)
        }
        TypefluxCloudRequestHeaders.applyCloudHeaders(scenario: scenario, to: &request)
        TypefluxCloudRequestHeaders.applyPersonaID(personaID, to: &request)
        return request
    }
}

enum TypefluxOfficialASRTokenScope {
    static func provider(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data)
        else {
            return nil
        }

        let provider = claims.asrProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedProviders.contains(provider) else { return nil }
        return provider
    }

    private static let allowedProviders: Set<String> = ["aliyun", "doubao", "google"]

    private struct Claims: Decodable {
        let asrProvider: String

        enum CodingKeys: String, CodingKey {
            case asrProvider = "asr_provider"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            asrProvider = try container.decodeIfPresent(String.self, forKey: .asrProvider) ?? ""
        }
    }
}

// MARK: - WebSocket ASR Session

enum TypefluxOfficialASRStartMessageFactory {
    static func make(
        optimize: Bool,
        llmConfig: ASRLLMConfig? = nil,
        inputMode: String = "realtime"
    ) -> [String: Any] {
        let audioConfig: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "channel": 1,
            "lang": "auto"
        ]
        var config: [String: Any] = [
            "audio": audioConfig,
            "optimize": optimize,
            "input_mode": inputMode
        ]
        if let llmConfig {
            config["llm"] = [
                "system_prompt": llmConfig.systemPrompt,
                "user_prompt_template": llmConfig.userPromptTemplate
            ]
        }
        return ["type": "start", "config": config]
    }
}

private struct TypefluxASRTiming {
    let traceID = UUID().uuidString.lowercased()
    let mode: String
    let optimize: Bool
    let startedAt = Date()
    var connectionReadyAt: Date?
    var firstAudioAt: Date?
    var firstResultAt: Date?
    var finalResultAt: Date?
    var stopStartedAt: Date?
    var serverCompletedAt: Date?
    var audioBytes = 0
    var summaryLogged = false

    mutating func markConnectionReady() {
        connectionReadyAt = connectionReadyAt ?? Date()
    }

    mutating func addAudioBytes(_ count: Int) -> Bool {
        audioBytes += count
        guard count > 0, firstAudioAt == nil else { return false }
        firstAudioAt = Date()
        return true
    }

    mutating func markResult(isFinal: Bool) -> Bool {
        let isFirst = firstResultAt == nil
        firstResultAt = firstResultAt ?? Date()
        if isFinal {
            finalResultAt = finalResultAt ?? Date()
        }
        return isFirst
    }

    mutating func markStopStarted() {
        stopStartedAt = stopStartedAt ?? Date()
    }

    mutating func markServerCompleted() {
        serverCompletedAt = serverCompletedAt ?? Date()
    }

    func summary(status: String, outputChars: Int, endedAt: Date = Date()) -> String {
        [
            "[ASR Timing][client]",
            "trace_id=\(traceID)",
            "phase=summary",
            "mode=\(mode)",
            "status=\(status)",
            "optimize=\(optimize)",
            "connect_ms=\(Self.milliseconds(from: startedAt, to: connectionReadyAt))",
            "first_audio_ms=\(Self.milliseconds(from: startedAt, to: firstAudioAt))",
            "audio_to_first_result_ms=\(Self.milliseconds(from: firstAudioAt, to: firstResultAt))",
            "stop_to_final_ms=\(Self.milliseconds(from: stopStartedAt, to: finalResultAt))",
            "stop_to_server_completed_ms=\(Self.milliseconds(from: stopStartedAt, to: serverCompletedAt))",
            "stop_to_request_completed_ms=\(Self.milliseconds(from: stopStartedAt, to: endedAt))",
            "total_ms=\(Self.milliseconds(from: startedAt, to: endedAt))",
            "audio_bytes=\(audioBytes)",
            "output_chars=\(outputChars)"
        ].joined(separator: " ")
    }

    static func milliseconds(from start: Date?, to end: Date?) -> Int {
        guard let start, let end, end >= start else { return -1 }
        return Int(end.timeIntervalSince(start) * 1000)
    }
}

private actor TypefluxOfficialASRSession {
    static func run(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        optimize: Bool = true,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: nil,
            optimize: optimize,
            onASRUpdate: onUpdate,
            llmConfig: nil,
            onLLMStart: nil,
            onLLMChunk: nil
        )
        let (transcript, _) = try await session.execute()
        return transcript
    }

    static func runWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: llmConfig.personaID,
            optimize: false,
            onASRUpdate: onASRUpdate,
            llmConfig: llmConfig,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk
        )
        return try await session.execute()
    }

    private let pcmData: Data
    private let apiBaseURL: String
    private let token: String
    private let scenario: TypefluxCloudScenario
    private let provider: String
    private let personaID: UUID?
    private let optimize: Bool
    private let onASRUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let llmConfig: ASRLLMConfig?
    private let onLLMStart: (@Sendable () async -> Void)?
    private let onLLMChunk: (@Sendable (String) async -> Void)?
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxOfficialASRSession")
    private var timing: TypefluxASRTiming

    private var finalSegments: [String] = []
    private var currentPartialText: String = ""
    private var completed = false
    private var sessionError: Error?
    private var rewrittenText: String?
    /// Set once audio or the stop message was sent, or the server returned
    /// output. From then on the endpoint may have admitted and billed the
    /// recording, so a failure must not fail over (see
    /// `TypefluxOfficialASRAdmittedStreamError`).
    private var streamAdmitted = false

    private init(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String,
        personaID: UUID?,
        optimize: Bool,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        llmConfig: ASRLLMConfig?,
        onLLMStart: (@Sendable () async -> Void)?,
        onLLMChunk: (@Sendable (String) async -> Void)?
    ) {
        self.pcmData = pcmData
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.scenario = scenario
        self.provider = provider
        self.personaID = personaID
        self.optimize = optimize
        self.onASRUpdate = onASRUpdate
        self.llmConfig = llmConfig
        self.onLLMStart = onLLMStart
        self.onLLMChunk = onLLMChunk
        timing = TypefluxASRTiming(mode: llmConfig == nil ? "batch" : "batch_llm", optimize: optimize)
    }

    private func execute() async throws -> (transcript: String, rewritten: String?) {
        do {
            return try await executeStream()
        } catch {
            if TypefluxOfficialASRCancellation.isCancellation(error) || Task.isCancelled {
                throw CancellationError()
            }
            if streamAdmitted {
                throw TypefluxOfficialASRAdmittedStreamError(underlying: error)
            }
            throw error
        }
    }

    private func executeStream() async throws -> (transcript: String, rewritten: String?) {
        defer {
            logTimingSummary(status: "interrupted", outputChars: assembleTranscript().count)
        }
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=request_start " +
                "mode=\(timing.mode) provider=\(provider) optimize=\(optimize) " +
                "audio_bytes=\(pcmData.count) endpoint=\(apiBaseURL)"
        )
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: personaID,
            traceID: timing.traceID
        )
        let session = URLSession(configuration: .default)
        let socketTask = session.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .goingAway, reason: nil)
            session.finishTasksAndInvalidate()
        }

        // Cancelling the recording closes the socket, which ends a pending
        // handshake, send or receive instead of waiting for the server.
        return try await withTaskCancellationHandler {
            try await stream(over: socketTask)
        } onCancel: {
            socketTask.cancel(with: .goingAway, reason: nil)
        }
    }

    private func stream(
        over socketTask: URLSessionWebSocketTask
    ) async throws -> (transcript: String, rewritten: String?) {
        // Begin receiving before sending the start message. Entitlement failures
        // can arrive immediately after the WebSocket upgrade, so waiting until
        // after the first send can lose the server's fallback directive.
        let receiveTask = Task { [self] in
            await receiveLoop(socketTask: socketTask)
        }

        do {
            try await sendRecording(over: socketTask)
        } catch {
            // Close the socket so the receive loop ends, and join it before
            // leaving. An error message from the server explains the failed
            // send better than the closed socket does.
            socketTask.cancel(with: .goingAway, reason: nil)
            await receiveTask.value
            if let reported = sessionError, !Self.isUnexpectedClose(reported) {
                throw reported
            }
            throw error
        }

        // Wait for receive loop to complete
        await receiveTask.value
        try Task.checkCancellation()

        if let error = sessionError {
            let transcript = assembleTranscript()
            logTimingSummary(status: "error", outputChars: transcript.count)
            if llmConfig != nil,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               TypefluxCloudBillingError.fromError(error) != nil {
                throw TypefluxCloudIntegratedRewriteError(
                    transcript: transcript,
                    underlyingError: error
                )
            }
            throw error
        }

        let transcript = assembleTranscript()
        if !transcript.isEmpty {
            await onASRUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        logTimingSummary(status: "completed", outputChars: transcript.count)
        return (transcript: transcript, rewritten: rewrittenText)
    }

    private static func isUnexpectedClose(_ error: Error) -> Bool {
        if case .unexpectedClose? = error as? TypefluxOfficialASRError { return true }
        return false
    }

    private func sendRecording(over socketTask: URLSessionWebSocketTask) async throws {
        let startMessage = TypefluxOfficialASRStartMessageFactory.make(
            optimize: optimize,
            llmConfig: llmConfig,
            inputMode: "batch"
        )
        let startData = try JSONSerialization.data(withJSONObject: startMessage)
        try await socketTask.send(.string(String(data: startData, encoding: .utf8)!))
        timing.markConnectionReady()
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=start_sent " +
                "mode=\(timing.mode) optimize=\(optimize) " +
                "connect_ms=\(TypefluxASRTiming.milliseconds(from: timing.startedAt, to: timing.connectionReadyAt))"
        )

        // Stream audio chunks
        let chunkSize = CloudASRAudioConverter.chunkSize
        var offset = pcmData.startIndex
        while offset < pcmData.endIndex {
            let end = pcmData.index(offset, offsetBy: chunkSize, limitedBy: pcmData.endIndex) ?? pcmData.endIndex
            let chunk = Data(pcmData[offset ..< end])
            streamAdmitted = true
            if timing.addAudioBytes(chunk.count) {
                NetworkDebugLogger.logMessage(
                    "[ASR Timing][client] trace_id=\(timing.traceID) phase=first_audio " +
                        "mode=\(timing.mode) optimize=\(optimize) " +
                        "since_start_ms=\(TypefluxASRTiming.milliseconds(from: timing.startedAt, to: timing.firstAudioAt))"
                )
            }
            try await socketTask.send(.data(chunk))
            offset = end
        }

        // Send stop message
        timing.markStopStarted()
        streamAdmitted = true
        let stopMessage = try JSONSerialization.data(withJSONObject: ["type": "stop"])
        try await socketTask.send(.string(String(data: stopMessage, encoding: .utf8)!))
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=stop_sent " +
                "mode=\(timing.mode) optimize=\(optimize) audio_bytes=\(timing.audioBytes)"
        )
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !completed {
            do {
                let message = try await socketTask.receive()
                switch message {
                case let .string(text):
                    await handleTextMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                    completed: completed,
                    finalSegments: finalSegments
                ) {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    sessionError = sessionError
                        ?? TypefluxOfficialASRReceiveFailure.classify(error)
                }
                completed = true
            }
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "partial":
            let partialText = json["text"] as? String ?? ""
            currentPartialText = partialText
            let display = assembleTranscript()
            logFirstResultIfNeeded(isFinal: false, text: display)
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: false))

        case "final":
            let finalText = json["text"] as? String ?? ""
            if !finalText.isEmpty {
                finalSegments.append(finalText)
            }
            currentPartialText = ""
            let display = assembleTranscript()
            logFirstResultIfNeeded(isFinal: true, text: display)
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: true))

        case "event":
            let eventText = json["text"] as? String ?? ""
            if eventText == "completed" {
                timing.markServerCompleted()
                // If LLM is pending, keep the receive loop alive to handle llm_* messages.
                if llmConfig == nil {
                    completed = true
                }
            }

        case "llm_start":
            await onLLMStart?()

        case "llm_chunk":
            let chunkText = json["text"] as? String ?? ""
            if !chunkText.isEmpty {
                await onLLMChunk?(chunkText)
            }

        case "llm_final":
            let finalRewrite = json["text"] as? String ?? ""
            rewrittenText = finalRewrite.isEmpty ? nil : finalRewrite
            completed = true

        case "error":
            let errorCode = json["code"] as? String
            let errorText = errorCode ?? (json["error"] as? String) ?? "Unknown error"
            if TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(errorText) {
                completed = true
                return
            }
            logger.error("ASR server error: \(errorText)")
            sessionError = errorCode.flatMap(TypefluxCloudASRDirectiveError.fromServerCode)
                ?? TypefluxCloudASRDirectiveError.fromMessage(errorText)
                ?? TypefluxCloudBillingError.fromMessage(errorText)
                ?? TypefluxOfficialASRError.serverError(errorText)
            completed = true

        default:
            break
        }
    }

    private func logFirstResultIfNeeded(isFinal: Bool, text: String) {
        guard !text.isEmpty else { return }
        let isFirst = timing.markResult(isFinal: isFinal)
        guard isFirst || isFinal else { return }
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) " +
                "phase=\(isFinal ? "final_result" : "first_result") mode=\(timing.mode) " +
                "optimize=\(optimize) audio_to_result_ms=" +
                "\(TypefluxASRTiming.milliseconds(from: timing.firstAudioAt, to: isFinal ? timing.finalResultAt : timing.firstResultAt)) " +
                "stop_to_result_ms=" +
                "\(TypefluxASRTiming.milliseconds(from: timing.stopStartedAt, to: isFinal ? timing.finalResultAt : timing.firstResultAt)) " +
                "chars=\(text.count)"
        )
    }

    private func logTimingSummary(status: String, outputChars: Int) {
        guard !timing.summaryLogged else { return }
        timing.summaryLogged = true
        NetworkDebugLogger.logMessage(timing.summary(status: status, outputChars: outputChars))
    }

    private func assembleTranscript() -> String {
        var parts = finalSegments
        if !currentPartialText.isEmpty {
            parts.append(currentPartialText)
        }
        return parts.joined()
    }
}

private actor TypefluxOfficialRealtimePCMStream: PCM16RealtimeTranscriptionSession,
    RealtimeTransportDiagnosticsProviding {
    private let apiBaseURL: String
    private let token: String
    private let provider: String
    private let scenario: TypefluxCloudScenario
    private let optimize: Bool
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxOfficialRealtimePCMStream")
    private var timing: TypefluxASRTiming

    private var urlSession: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var finalSegments: [String] = []
    private var currentPartialText = ""
    private var completed = false
    private var sessionError: Error?
    private var transportDiagnostics: NetworkTransportDiagnosticsRecorder?

    init(
        apiBaseURL: String,
        token: String,
        provider: String = "default",
        scenario: TypefluxCloudScenario,
        optimize: Bool = true,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        transportDiagnostics: NetworkTransportDiagnosticsRecorder? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.provider = provider
        self.scenario = scenario
        self.optimize = optimize
        self.onUpdate = onUpdate
        self.transportDiagnostics = transportDiagnostics
        timing = TypefluxASRTiming(mode: "realtime", optimize: optimize)
    }

    func start() async throws {
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=request_start " +
                "mode=realtime provider=\(provider) optimize=\(optimize) endpoint=\(apiBaseURL)"
        )
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            traceID: timing.traceID
        )
        let transportDiagnostics = transportDiagnostics ?? NetworkTransportDiagnosticsRecorder(endpoint: request.url)
        transportDiagnostics.updateEndpoint(request.url)
        let session = URLSession(
            configuration: .default,
            delegate: transportDiagnostics,
            delegateQueue: nil
        )
        self.transportDiagnostics = transportDiagnostics
        let socketTask = session.webSocketTask(with: request)
        urlSession = session
        self.socketTask = socketTask
        transportDiagnostics.markWebSocketTaskResumed()
        socketTask.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        let startMessage = TypefluxOfficialASRStartMessageFactory.make(optimize: optimize)
        try await sendJSON(startMessage)
        transportDiagnostics.markStartMessageSent()
        timing.markConnectionReady()
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=start_sent " +
                "mode=realtime optimize=\(optimize) " +
                "connect_ms=\(TypefluxASRTiming.milliseconds(from: timing.startedAt, to: timing.connectionReadyAt))"
        )

    }

    func appendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard let socketTask else {
            throw TypefluxOfficialASRError.connectionFailed("Realtime WebSocket is not connected.")
        }
        if timing.addAudioBytes(data.count) {
            NetworkDebugLogger.logMessage(
                "[ASR Timing][client] trace_id=\(timing.traceID) phase=first_audio " +
                    "mode=realtime optimize=\(optimize) " +
                    "since_start_ms=\(TypefluxASRTiming.milliseconds(from: timing.startedAt, to: timing.firstAudioAt))"
            )
        }
        try await socketTask.send(.data(Data(data)))
    }

    func finish() async throws -> String {
        timing.markStopStarted()
        try await sendJSON(["type": "stop"])
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) phase=stop_sent " +
                "mode=realtime optimize=\(optimize) audio_bytes=\(timing.audioBytes)"
        )
        await receiveTask?.value

        if let sessionError {
            logTimingSummary(status: "error", outputChars: assembleTranscript().count)
            throw sessionError
        }

        let transcript = assembleTranscript()
        if !transcript.isEmpty {
            logFirstResultIfNeeded(isFinal: true, text: transcript)
            await onUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        logTimingSummary(status: "completed", outputChars: transcript.count)
        await close()
        return transcript
    }

    func cancel() async {
        logTimingSummary(status: "cancelled", outputChars: assembleTranscript().count)
        await close()
    }

    func transportDiagnosticsSnapshot() async -> NetworkTransportDiagnosticsSnapshot? {
        await transportDiagnostics?.settledSnapshot()
    }

    private func close() async {
        completed = true
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
    }

    private func receiveLoop() async {
        while !completed, !Task.isCancelled {
            do {
                guard let socketTask else { break }
                let message = try await socketTask.receive()
                switch message {
                case let .string(text):
                    await handleTextMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled,
                   TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                       completed: completed,
                       finalSegments: finalSegments
                   ) {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    sessionError = sessionError
                        ?? TypefluxOfficialASRReceiveFailure.classify(error)
                }
                completed = true
            }
        }
    }

    private func handleTextMessage(_ text: String) async {
        let parsingStartedAt = Date()
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            transportDiagnostics?.recordMessageParsing(duration: Date().timeIntervalSince(parsingStartedAt))
            return
        }
        transportDiagnostics?.recordMessageParsing(duration: Date().timeIntervalSince(parsingStartedAt))

        switch type {
        case "partial":
            currentPartialText = json["text"] as? String ?? ""
            let display = assembleTranscript()
            logFirstResultIfNeeded(isFinal: false, text: display)
            await onUpdate(TranscriptionSnapshot(text: display, isFinal: false))
        case "final":
            let finalText = json["text"] as? String ?? ""
            if !finalText.isEmpty {
                finalSegments.append(finalText)
            }
            currentPartialText = ""
            let display = assembleTranscript()
            logFirstResultIfNeeded(isFinal: true, text: display)
            await onUpdate(TranscriptionSnapshot(text: display, isFinal: true))
        case "event":
            if (json["text"] as? String) == "completed" {
                timing.markServerCompleted()
                completed = true
            }
        case "error":
            let errorCode = json["code"] as? String
            let errorText = errorCode ?? (json["error"] as? String) ?? "Unknown error"
            if TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(errorText) {
                completed = true
                return
            }
            logger.error("ASR server error: \(errorText)")
            sessionError = errorCode.flatMap(TypefluxCloudASRDirectiveError.fromServerCode)
                ?? TypefluxCloudASRDirectiveError.fromMessage(errorText)
                ?? TypefluxCloudBillingError.fromMessage(errorText)
                ?? TypefluxOfficialASRError.serverError(errorText)
            completed = true
        default:
            break
        }
    }

    private func logFirstResultIfNeeded(isFinal: Bool, text: String) {
        guard !text.isEmpty else { return }
        let isFirst = timing.markResult(isFinal: isFinal)
        guard isFirst || isFinal else { return }
        NetworkDebugLogger.logMessage(
            "[ASR Timing][client] trace_id=\(timing.traceID) " +
                "phase=\(isFinal ? "final_result" : "first_result") mode=realtime " +
                "optimize=\(optimize) audio_to_result_ms=" +
                "\(TypefluxASRTiming.milliseconds(from: timing.firstAudioAt, to: isFinal ? timing.finalResultAt : timing.firstResultAt)) " +
                "stop_to_result_ms=" +
                "\(TypefluxASRTiming.milliseconds(from: timing.stopStartedAt, to: isFinal ? timing.finalResultAt : timing.firstResultAt)) " +
                "chars=\(text.count)"
        )
    }

    private func logTimingSummary(status: String, outputChars: Int) {
        guard !timing.summaryLogged else { return }
        timing.summaryLogged = true
        NetworkDebugLogger.logMessage(timing.summary(status: status, outputChars: outputChars))
    }

    private func sendJSON(_ json: [String: Any]) async throws {
        guard let socketTask else {
            throw TypefluxOfficialASRError.connectionFailed("Realtime WebSocket is not connected.")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TypefluxOfficialASRError.connectionFailed("Failed to encode realtime message.")
        }
        try await socketTask.send(.string(text))
    }

    private func assembleTranscript() -> String {
        var parts = finalSegments
        if !currentPartialText.isEmpty {
            parts.append(currentPartialText)
        }
        return parts.joined()
    }
}
