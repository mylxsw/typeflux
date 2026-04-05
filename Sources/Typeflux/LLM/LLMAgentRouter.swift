import Foundation

final class LLMAgentRouter: LLMAgentService {
    private let settingsStore: SettingsStore
    private let remote: LLMAgentService
    private let ollama: LLMAgentService

    init(settingsStore: SettingsStore, remote: LLMAgentService, ollama: LLMAgentService) {
        self.settingsStore = settingsStore
        self.remote = remote
        self.ollama = ollama
    }

    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding type: T.Type) async throws -> T {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            try await remote.runTool(request: request, decoding: type)
        case .ollama:
            try await ollama.runTool(request: request, decoding: type)
        }
    }
}

final class OllamaAgentService: LLMAgentService {
    func runTool<T: Decodable & Sendable>(request _: LLMAgentRequest, decoding _: T.Type) async throws -> T {
        throw LLMAgentError.unsupportedProvider
    }
}
