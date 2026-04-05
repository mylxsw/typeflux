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
            openAICompatible.streamRewrite(request: request)
        case .ollama:
            ollama.streamRewrite(request: request)
        }
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            try await openAICompatible.complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .ollama:
            try await ollama.complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            try await openAICompatible.completeJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        case .ollama:
            try await ollama.completeJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
            )
        }
    }
}
