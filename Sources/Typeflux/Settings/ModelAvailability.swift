import Foundation

enum ModelAvailability {
    // The exhaustive provider switch deliberately mirrors STTProvider.
    // swiftlint:disable:next cyclomatic_complexity
    static func speechReason(_ provider: STTProvider, settings: SettingsStore, loggedIn: Bool,
                             localModelAvailable: Bool, googleAuthorized: Bool) -> String? {
        switch provider {
        case .typefluxOfficial: loggedIn ? nil : L("models.login")
        case .localModel: localModelAvailable ? nil : L("models.download")
        case .freeModel: FreeSTTModelRegistry.suggestedModelNames.isEmpty ? L("models.noModels") : nil
        case .whisperAPI: settings.whisperAPIKey.isEmpty || settings.whisperModel.isEmpty || settings.whisperBaseURL
            .isEmpty ? L("models.keyMissing") : nil
        case .multimodalLLM: settings.multimodalLLMAPIKey.isEmpty || settings.multimodalLLMBaseURL.isEmpty || settings
            .multimodalLLMModel.isEmpty ? L("models.keyMissing") : nil
        case .aliCloud: settings.aliCloudAPIKey.isEmpty ? L("models.keyMissing") : nil
        case .doubaoRealtime: settings.doubaoAppID.isEmpty || settings.doubaoAccessToken.isEmpty || settings
            .doubaoResourceID.isEmpty ? L("models.keyMissing") : nil
        case .googleCloud: googleAuthorized && !settings.googleCloudProjectID
            .isEmpty ? nil : L("models.googleCredentials")
        case .groq: settings.groqSTTAPIKey.isEmpty ? L("models.keyMissing") : nil
        case .soniox: settings.sonioxAPIKey.isEmpty ? L("models.keyMissing") : nil
        case .appleSpeech: nil
        }
    }

    static func sorted<T>(_ values: [T], available: (T) -> Bool) -> [T] {
        values.enumerated().sorted {
            let left = available($0.element)
            let right = available($1.element)
            return left == right ? $0.offset < $1.offset : left
        }.map(\.element)
    }
}
