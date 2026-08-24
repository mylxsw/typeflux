import Foundation

struct TranscriptionSnapshot {
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

protocol RealtimeTranscriptionSessionFactory: Transcriber {
    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession
}

/// Realtime factories that can choose between lower ASR latency and the
/// provider's higher-quality recognition pass for each request.
protocol OptimizeAwareRealtimeSessionFactory: RealtimeTranscriptionSessionFactory {
    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession
}

protocol TypefluxCloudScenarioAwareTranscriber: Transcriber {
    func transcribe(audioFile: AudioFile, scenario: TypefluxCloudScenario) async throws -> String
    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String
}

protocol ASROptimizeAwareTranscriber: TypefluxCloudScenarioAwareTranscriber {
    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String
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

extension TypefluxCloudScenarioAwareTranscriber {
    func transcribe(audioFile: AudioFile, scenario: TypefluxCloudScenario) async throws -> String {
        try await transcribeStream(audioFile: audioFile, scenario: scenario) { _ in }
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribe(audioFile: audioFile, scenario: .voiceInput)
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await transcribeStream(
            audioFile: audioFile,
            scenario: .voiceInput,
            onUpdate: onUpdate
        )
    }
}

final class STTRouter {
    static let typefluxOfficialCloudPriorityWindowSeconds: TimeInterval = 3

    let settingsStore: SettingsStore
    let whisper: Transcriber
    let freeSTT: Transcriber
    let appleSpeech: Transcriber
    let localModel: Transcriber
    let multimodal: Transcriber
    let aliCloud: Transcriber
    let doubaoRealtime: Transcriber
    let googleCloud: Transcriber
    let groq: Transcriber
    let soniox: Transcriber
    let typefluxOfficial: Transcriber
    let typefluxCloudLoginFallbackLocalModel: Transcriber?
    let autoModelDownloadService: AutoModelDownloadService?
    let isTypefluxCloudLoggedIn: @Sendable () async -> Bool
    let hasPaidTypefluxCloudSubscription: @Sendable () async -> Bool
    let typefluxOfficialCloudPriorityWindow: TimeInterval

    var usesTypefluxOfficialCloudLocalRace: Bool {
        typefluxCloudLoginFallbackLocalModel != nil
    }

    init(
        settingsStore: SettingsStore,
        whisper: Transcriber,
        freeSTT: Transcriber,
        appleSpeech: Transcriber,
        localModel: Transcriber,
        multimodal: Transcriber,
        aliCloud: Transcriber,
        doubaoRealtime: Transcriber,
        googleCloud: Transcriber,
        groq: Transcriber,
        soniox: Transcriber,
        typefluxOfficial: Transcriber,
        typefluxCloudLoginFallbackLocalModel: Transcriber? = nil,
        autoModelDownloadService: AutoModelDownloadService? = nil,
        typefluxOfficialCloudPriorityWindow: TimeInterval = STTRouter
            .typefluxOfficialCloudPriorityWindowSeconds,
        isTypefluxCloudLoggedIn: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthState.shared.isLoggedIn }
        },
        hasPaidTypefluxCloudSubscription: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthState.shared.subscription.hasPaidSubscription }
        }
    ) {
        self.settingsStore = settingsStore
        self.whisper = whisper
        self.freeSTT = freeSTT
        self.appleSpeech = appleSpeech
        self.localModel = localModel
        self.multimodal = multimodal
        self.aliCloud = aliCloud
        self.doubaoRealtime = doubaoRealtime
        self.googleCloud = googleCloud
        self.groq = groq
        self.soniox = soniox
        self.typefluxOfficial = typefluxOfficial
        self.typefluxCloudLoginFallbackLocalModel = typefluxCloudLoginFallbackLocalModel
        self.autoModelDownloadService = autoModelDownloadService
        self.typefluxOfficialCloudPriorityWindow = typefluxOfficialCloudPriorityWindow
        self.isTypefluxCloudLoggedIn = isTypefluxCloudLoggedIn
        self.hasPaidTypefluxCloudSubscription = hasPaidTypefluxCloudSubscription
    }

    func transcribe(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario = .voiceInput
    ) async throws -> String {
        try await transcribeStream(audioFile: audioFile, scenario: scenario) { _ in }
    }
}
