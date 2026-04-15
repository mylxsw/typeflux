import Foundation

struct TranscriptionSnapshot {
    let text: String
    let isFinal: Bool
}

protocol Transcriber {
    func transcribe(audioFile: AudioFile) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String
}

protocol RecordingPrewarmingTranscriber: Transcriber {
    func prepareForRecording() async
    func cancelPreparedRecording() async
}

protocol TypefluxCloudScenarioAwareTranscriber: Transcriber {
    func transcribe(audioFile: AudioFile, scenario: TypefluxCloudScenario) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String
}

extension Transcriber {
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let text = try await transcribe(audioFile: audioFile)
        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
        return text
    }
}

extension TypefluxCloudScenarioAwareTranscriber {
    func transcribe(audioFile: AudioFile, scenario: TypefluxCloudScenario) async throws -> String {
        try await transcribeStream(audioFile: audioFile, scenario: scenario) { _ in }
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribe(audioFile: audioFile, scenario: .voiceInput)
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        try await transcribeStream(
            audioFile: audioFile,
            scenario: .voiceInput,
            onUpdate: onUpdate,
        )
    }
}

final class STTRouter {
    private let settingsStore: SettingsStore
    private let whisper: Transcriber
    private let freeSTT: Transcriber
    private let appleSpeech: Transcriber
    private let localModel: Transcriber
    private let multimodal: Transcriber
    private let aliCloud: Transcriber
    private let doubaoRealtime: Transcriber
    private let groq: Transcriber
    private let typefluxOfficial: Transcriber

    init(
        settingsStore: SettingsStore,
        whisper: Transcriber,
        freeSTT: Transcriber,
        appleSpeech: Transcriber,
        localModel: Transcriber,
        multimodal: Transcriber,
        aliCloud: Transcriber,
        doubaoRealtime: Transcriber,
        groq: Transcriber,
        typefluxOfficial: Transcriber,
    ) {
        self.settingsStore = settingsStore
        self.whisper = whisper
        self.freeSTT = freeSTT
        self.appleSpeech = appleSpeech
        self.localModel = localModel
        self.multimodal = multimodal
        self.aliCloud = aliCloud
        self.doubaoRealtime = doubaoRealtime
        self.groq = groq
        self.typefluxOfficial = typefluxOfficial
    }

    func transcribe(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario = .voiceInput,
    ) async throws -> String {
        try await transcribeStream(audioFile: audioFile, scenario: scenario) { _ in }
    }

    func prepareForRecording() async {
        switch settingsStore.sttProvider {
        case .doubaoRealtime:
            await (doubaoRealtime as? RecordingPrewarmingTranscriber)?.prepareForRecording()
        case .localModel:
            await (localModel as? RecordingPrewarmingTranscriber)?.prepareForRecording()
        default:
            break
        }
    }

    func cancelPreparedRecording() async {
        switch settingsStore.sttProvider {
        case .doubaoRealtime:
            await (doubaoRealtime as? RecordingPrewarmingTranscriber)?.cancelPreparedRecording()
        case .localModel:
            await (localModel as? RecordingPrewarmingTranscriber)?.cancelPreparedRecording()
        default:
            break
        }
    }

    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario = .voiceInput,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        switch settingsStore.sttProvider {
        case .freeModel:
            do {
                return try await RequestRetry.perform(operationName: "Free STT request") { [self] in
                    try await freeSTT.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Free STT failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after free STT failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }

        case .whisperAPI:
            do {
                return try await RequestRetry.perform(operationName: "Remote STT request") { [self] in
                    try await whisper.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Remote STT failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after remote STT failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }

        case .appleSpeech:
            return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .localModel:
            do {
                return try await localModel.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            } catch {
                NetworkDebugLogger.logError(context: "Local STT failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after local STT failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }

        case .multimodalLLM:
            return try await RequestRetry.perform(operationName: "Multimodal STT request") { [self] in
                try await multimodal.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            }

        case .aliCloud:
            do {
                return try await RequestRetry.perform(operationName: "AliCloud STT request") { [self] in
                    try await aliCloud.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Alibaba Cloud ASR failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after Alibaba Cloud ASR failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }

        case .doubaoRealtime:
            do {
                return try await RequestRetry.perform(operationName: "Doubao realtime STT request") { [self] in
                    try await doubaoRealtime.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Doubao realtime ASR failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after Doubao realtime ASR failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }

        case .groq:
            if !settingsStore.groqSTTAPIKey.isEmpty {
                do {
                    return try await RequestRetry.perform(operationName: "Groq STT request") { [self] in
                        try await groq.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                    }
                } catch {
                    NetworkDebugLogger.logError(context: "Groq STT failed", error: error)
                    if settingsStore.useAppleSpeechFallback {
                        NetworkDebugLogger.logMessage("Falling back to Apple Speech after Groq STT failure")
                        return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                    }
                    throw error
                }
            }
            if settingsStore.useAppleSpeechFallback {
                NetworkDebugLogger.logMessage("Groq STT is not configured, using Apple Speech fallback")
                return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            }
            throw NSError(
                domain: "STTRouter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Groq transcription is not configured yet."],
            )

        case .typefluxOfficial:
            do {
                return try await RequestRetry.perform(operationName: "Typeflux Official STT request") { [self] in
                    if let scenarioAware = typefluxOfficial as? TypefluxCloudScenarioAwareTranscriber {
                        return try await scenarioAware.transcribeStream(
                            audioFile: audioFile,
                            scenario: scenario,
                            onUpdate: onUpdate,
                        )
                    }
                    return try await typefluxOfficial.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Typeflux Official STT failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after Typeflux Official STT failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }
        }
    }

    /// Runs transcription and, if the provider supports it, an LLM persona rewrite in
    /// the same WebSocket session. Only `typefluxOfficial` implements this optimisation;
    /// for all other providers the method falls back to a plain `transcribeStream` call
    /// and returns `rewritten: nil` so the caller can run a separate LLM request.
    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void,
    ) async throws -> (transcript: String, rewritten: String?) {
        guard let integrated = typefluxOfficial as? TypefluxCloudLLMIntegratedTranscriber else {
            let transcript = try await transcribeStream(audioFile: audioFile, scenario: scenario, onUpdate: onASRUpdate)
            return (transcript: transcript, rewritten: nil)
        }
        return try await integrated.transcribeStreamWithLLMRewrite(
            audioFile: audioFile,
            llmConfig: llmConfig,
            scenario: scenario,
            onASRUpdate: onASRUpdate,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk,
        )
    }
}
