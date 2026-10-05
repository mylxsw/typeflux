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
        switch settingsStore.effectiveLLMProvider {
        case .openAICompatible:
            openAICompatible.streamRewrite(request: request)
        case .ollama:
            ollama.streamRewrite(request: request)
        }
    }

    func streamComplete(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        switch settingsStore.effectiveLLMProvider {
        case .openAICompatible:
            openAICompatible.streamComplete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .ollama:
            ollama.streamComplete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        switch settingsStore.effectiveLLMProvider {
        case .openAICompatible:
            try await openAICompatible.complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .ollama:
            try await ollama.complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        switch settingsStore.effectiveLLMProvider {
        case .openAICompatible:
            try await openAICompatible.completeJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema
            )
        case .ollama:
            try await ollama.completeJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema
            )
        }
    }
}
