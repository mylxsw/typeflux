import Foundation

/// Business intent is independent of the historical usage scenario and output format.
enum TypefluxCloudFeature: String, CaseIterable, Sendable {
    case voiceInput = "voice-input"
    case textRewrite = "text-rewrite"
    case askSelection = "ask-selection"
    case translation
    case wordCard = "word-card"
    case automaticVocabulary = "automatic-vocabulary"
    case memoryConsolidation = "memory-consolidation"
}

/// A scoped value crosses protocol decorators and retry tasks without shared mutable
/// state. Only the Cloud transport emits it; local and user-owned providers ignore it.
enum LLMFeatureContext {
    @TaskLocal static var feature: TypefluxCloudFeature?
}

extension LLMService {
    func complete(systemPrompt: String, userPrompt: String, feature: TypefluxCloudFeature) async throws -> String {
        try await LLMFeatureContext.$feature.withValue(feature) {
            try await complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema,
                      feature: TypefluxCloudFeature) async throws -> String {
        try await LLMFeatureContext.$feature.withValue(feature) {
            try await completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt, schema: schema)
        }
    }
}
