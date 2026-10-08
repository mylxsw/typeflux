import Foundation

/// The language model translations and word cards go to: the model chosen for
/// translation, sent the prompts as written; or, when none is chosen, the
/// text-processing model exactly as before.
final class AskTranslationLLMService: LLMService, @unchecked Sendable {
    private let reference: () -> String
    /// Whether the chosen model is still in Settings → Models.
    private let exists: (String) -> Bool
    private let textProcessing: LLMService
    private let chosen: LLMService

    init(reference: @escaping () -> String, exists: @escaping (String) -> Bool = { _ in true },
         textProcessing: LLMService, chosen: LLMService) {
        self.reference = reference
        self.exists = exists
        self.textProcessing = textProcessing
        self.chosen = chosen
    }

    convenience init(settings: SettingsStore, textProcessing: LLMService) {
        self.init(
            reference: { [weak settings] in settings?.askTranslationSettings.modelReference ?? "" },
            exists: { [weak settings] reference in
                settings.flatMap { ModelRegistry.read($0.defaults)?.resolve(reference) } != nil
            },
            textProcessing: textProcessing,
            chosen: OpenAICompatibleLLMService(settingsStore: settings, configuration: { [weak settings] in
                settings?.translationLLMConfiguration()
                    ?? SettingsStore.TextLLMConfiguration(provider: .custom, baseURL: "", model: "", apiKey: "")
            }, sendsPromptsAsWritten: true)
        )
    }

    /// A chosen model that was removed is reported, rather than quietly replaced.
    private func service() throws -> LLMService {
        let reference = reference()
        if reference.isEmpty { return textProcessing }
        guard exists(reference) else {
            throw AskPluginFailure(message: L("ask.translation.error.modelMissing"), retry: false)
        }
        return chosen
    }

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        textProcessing.streamRewrite(request: request)
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        try await service().complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        try await service().completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt, schema: schema)
    }

    func streamComplete(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        do {
            return try service().streamComplete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
