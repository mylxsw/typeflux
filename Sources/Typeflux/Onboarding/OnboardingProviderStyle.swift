import Foundation

enum OnboardingProviderIconPlateStyle: Equatable {
    case neutral
    case light
}

enum OnboardingProviderStyle {
    static let listColumnWidth: CGFloat = 408

    static func iconPlateStyle(for providerID: StudioModelProviderID) -> OnboardingProviderIconPlateStyle {
        switch providerID {
        case .whisperAPI, .multimodalLLM, .openAI, .openRouter, .grok, .groq, .groqSTT, .ollama:
            .light
        default:
            .neutral
        }
    }
}
