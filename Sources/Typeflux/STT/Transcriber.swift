import Foundation

struct TranscriptionSnapshot: Sendable {
    let text: String
    let isFinal: Bool
}

protocol Transcriber {
    func transcribe(audioFile: AudioFile) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String
}

protocol RecordingPrewarmingTranscriber: Transcriber {
    func prepareForRecording() async
    func cancelPreparedRecording() async
}

extension Transcriber {
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
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

    init(
        settingsStore: SettingsStore,
        whisper: Transcriber,
        freeSTT: Transcriber,
        appleSpeech: Transcriber,
        localModel: Transcriber,
        multimodal: Transcriber,
        aliCloud: Transcriber,
        doubaoRealtime: Transcriber
    ) {
        self.settingsStore = settingsStore
        self.whisper = whisper
        self.freeSTT = freeSTT
        self.appleSpeech = appleSpeech
        self.localModel = localModel
        self.multimodal = multimodal
        self.aliCloud = aliCloud
        self.doubaoRealtime = doubaoRealtime
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
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        switch settingsStore.sttProvider {
        case .freeModel:
            do {
                return try await RequestRetry.perform(operationName: "Free STT request") { [self] in
                    try await self.freeSTT.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
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
            if !settingsStore.whisperBaseURL.isEmpty {
                do {
                    return try await RequestRetry.perform(operationName: "Remote STT request") { [self] in
                        try await self.whisper.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                    }
                } catch {
                    NetworkDebugLogger.logError(context: "Remote STT failed", error: error)
                    if settingsStore.useAppleSpeechFallback {
                        NetworkDebugLogger.logMessage("Falling back to Apple Speech after remote STT failure")
                        return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                    }
                    throw error
                }
            }
            if settingsStore.useAppleSpeechFallback {
                NetworkDebugLogger.logMessage("Remote STT is not configured, using Apple Speech fallback")
                return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            }
            throw NSError(
                domain: "STTRouter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Remote transcription is not configured yet."]
            )

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
                try await self.multimodal.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            }

        case .aliCloud:
            do {
                return try await RequestRetry.perform(operationName: "AliCloud STT request") { [self] in
                    try await self.aliCloud.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
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
                    try await self.doubaoRealtime.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Doubao realtime ASR failed", error: error)
                if settingsStore.useAppleSpeechFallback {
                    NetworkDebugLogger.logMessage("Falling back to Apple Speech after Doubao realtime ASR failure")
                    return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
                }
                throw error
            }
        }
    }
}
