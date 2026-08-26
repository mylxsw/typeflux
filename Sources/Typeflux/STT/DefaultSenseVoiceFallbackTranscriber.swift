import Foundation

final class DefaultSenseVoiceFallbackTranscriber: Transcriber {
    private let modelManager: LocalSTTModelManaging

    init(modelManager: LocalSTTModelManaging) {
        self.modelManager = modelManager
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let suiteName = "DefaultSenseVoiceFallbackTranscriber.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = LocalSTTModel.senseVoiceSmall.recommendedDownloadSource
        // A connectivity fallback must never turn into a blocking network download.
        // The full app links its bundled SenseVoice model during startup; lightweight
        // installs fail fast here and keep the saved recording available for retry.
        settingsStore.localSTTAutoSetup = false

        return try await LocalModelTranscriber(
            settingsStore: settingsStore,
            modelManager: modelManager
        )
        .transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
    }
}
