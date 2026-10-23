import Foundation
import Testing
@testable import Typeflux

@Suite("Built-in model context limits")
struct ModelContextCatalogTests {
    @Test func documentedIDsAndProviderNamespacesResolve() {
        for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol"] {
            #expect(ModelContextCatalog.limits(forModelID: id) == .init(contextWindow: 1_050_000, maxOutput: 128_000))
        }
        #expect(ModelContextCatalog.limits(forModelID: " OpenAI/GPT-4.1 ") == .init(contextWindow: 1_047_576, maxOutput: 32_768))
        #expect(ModelContextCatalog.limits(forModelID: "gpt-4o-2024-08-06") == .init(contextWindow: 128_000, maxOutput: 16_384))
        #expect(ModelContextCatalog.limits(forModelID: "gpt-4o-mini")?.maxOutput == 16_384)
        #expect(ModelContextCatalog.limits(forModelID: "o3")?.contextWindow == 200_000)
        #expect(ModelContextCatalog.limits(forModelID: "o4-mini")?.maxOutput == 100_000)
        #expect(ModelContextCatalog.limits(forModelID: "gpt-5")?.contextWindow == 400_000)
        for id in ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            #expect(ModelContextCatalog.limits(forModelID: "anthropic/" + id) == .init(contextWindow: 1_000_000, maxOutput: 128_000))
        }
        for id in ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-3.1-pro-preview", "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"] {
            #expect(ModelContextCatalog.limits(forModelID: "models/" + id) == .init(contextWindow: 1_048_576, maxOutput: 65_536))
        }
        for id in ["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            #expect(ModelContextCatalog.limits(forModelID: id) == .init(contextWindow: 1_000_000, maxOutput: 384_000))
        }
    }

    @Test func unknownVersionsRoutingAliasesAndLocalTagsRemainUnknown() {
        for id in ["", "coding/auto", "default", "gpt-6.1-sol-new", "gpt-4o-2024-05-13", "gpt-4o-audio-preview",
                   "gpt-4o:latest", "claude-sonnet-99", "gemini-3.8-flash-tts", "unknown"] {
            #expect(ModelContextCatalog.limits(forModelID: id) == nil)
        }
    }

    @Test func explicitMetadataWinsAndFallbackDoesNotPersistOrGuessCloud() throws {
        var model = RegisteredModel(id: "gpt-4o", name: "Relay")
        #expect(model.effectiveContextWindowTokens == 128_000)
        #expect(model.effectiveMaxOutputTokens == 16_384)
        #expect(model.contextWindowTokens == nil && model.maxOutputTokens == nil)
        model.contextWindowTokens = 32_000
        model.maxOutputTokens = 2_000
        #expect(model.effectiveContextWindowTokens == 32_000 && model.effectiveMaxOutputTokens == 2_000)
        model.contextWindowTokens = 0
        model.maxOutputTokens = -1
        #expect(model.effectiveContextWindowTokens == 128_000 && model.effectiveMaxOutputTokens == 16_384)
        model.reference = "cloud:gpt-4o"
        #expect(model.effectiveContextWindowTokens == nil && model.effectiveMaxOutputTokens == nil)
        model.contextWindowTokens = 64_000
        model.maxOutputTokens = 4_000
        #expect(model.effectiveContextWindowTokens == 64_000 && model.effectiveMaxOutputTokens == 4_000)
        let old = try JSONDecoder().decode(RegisteredModel.self, from: Data(#"{"id":"gpt-4o","name":"Saved","reference":"custom:saved"}"#.utf8))
        #expect(old.effectiveContextWindowTokens == 128_000 && old.effectiveMaxOutputTokens == 16_384)
        let encoded = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(RegisteredModel.self, from: encoded)
        #expect(decoded.contextWindowTokens == nil && decoded.maxOutputTokens == nil)
        let reduced = RegisteredModel(id: "gpt-6.1-sol", name: "Small endpoint", contextWindowTokens: 32_000)
        #expect(reduced.effectiveMaxOutputTokens == 32_000)
        let unknown = RegisteredModel(id: "coding/auto", name: "Unknown")
        #expect(unknown.effectiveContextWindowTokens == nil && unknown.effectiveMaxOutputTokens == nil)
        let outputOnly = RegisteredModel(id: "coding/auto", name: "Output only", maxOutputTokens: 2_000)
        #expect(outputOnly.effectiveMaxOutputTokens == 2_000 && outputOnly.effectiveContextWindowTokens == nil)
    }

    @Test func devicePlanningUsesBuiltInCapacityAndHonorsEndpointOverride() throws {
        let payload = #"{"messages":[{"role":"user","content":"Hello"}]}"#
        for (model, expected) in [
            (RegisteredModel(id: "gpt-4o", name: "Known"), 128_000),
            (RegisteredModel(id: "gpt-4o", name: "Override", contextWindowTokens: 64_000), 64_000),
            (RegisteredModel(id: "coding/auto", name: "Unknown"), 32_768)
        ] {
            let projected = try AskContextPlanner.devicePayload(payload, model: model, budgeted: false)
            let body = try #require(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
            #expect(body["typeflux_context_window"] as? Int == expected)
            #expect(body["max_tokens"] == nil)
        }
    }
}
