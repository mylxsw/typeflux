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

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
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
                    try await typefluxOfficial.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
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
}
