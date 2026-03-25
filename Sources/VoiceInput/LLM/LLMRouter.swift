import Foundation

final class LLMRouter: LLMService {
    private let settingsStore: SettingsStore
    private let openAICompatible: LLMService
    private let ollama: LLMService

    init(settingsStore: SettingsStore, openAICompatible: LLMService, ollama: LLMService) {
        self.settingsStore = settingsStore
        self.openAICompatible = openAICompatible
        self.ollama = ollama
    }

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            return openAICompatible.streamRewrite(request: request)
        case .ollama:
            return ollama.streamRewrite(request: request)
        }
    }
}
