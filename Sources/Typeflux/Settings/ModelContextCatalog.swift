import Foundation

/// Documented defaults for specific model IDs, verified on 2026-10-23.
/// Endpoint metadata wins. Unknown versions, routing aliases and local tags stay unknown.
enum ModelContextCatalog {
    struct Limits: Equatable, Sendable {
        let contextWindow: Int
        let maxOutput: Int
    }

    static func limits(forModelID id: String) -> Limits? {
        entries[ModelVisionCatalog.normalized(id)]
    }

    private static let entries: [String: Limits] = {
        var values: [String: Limits] = [:]
        func add(_ ids: [String], window: Int, output: Int) {
            for id in ids { values[id] = Limits(contextWindow: window, maxOutput: output) }
        }
        // https://developers.openai.com/api/docs/models/<model-id>
        add(["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol"],
            window: 1_050_000, output: 128_000)
        add(["gpt-5", "gpt-5-2025-08-07"], window: 400_000, output: 128_000)
        add(["gpt-4.1", "gpt-4.1-2025-04-14"], window: 1_047_576, output: 32_768)
        add(["gpt-4o", "gpt-4o-2024-08-06", "gpt-4o-mini", "gpt-4o-mini-2024-07-18"],
            window: 128_000, output: 16_384)
        add(["o3", "o3-2025-04-16", "o4-mini", "o4-mini-2025-04-16"], window: 200_000, output: 100_000)
        // https://platform.claude.com/docs/en/models/overview
        add(["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
            window: 1_000_000, output: 128_000)
        // https://ai.google.dev/gemini-api/docs/models/<model-id>
        // Gemini 2.5/3.x publish an input limit; use it conservatively as the planning window.
        // Argon uses a unified window; its default synchronous output is 65,536.
        add(["gemini-2.5-pro", "gemini-2.5-flash", "gemini-3.1-pro-preview", "gemini-3.5-flash-lite",
             "gemini-3.8-flash", "gemini-4-argon"], window: 1_048_576, output: 65_536)
        // https://api-docs.deepseek.com/quick_start/pricing/
        add(["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
            window: 1_000_000, output: 384_000)
        return values
    }()
}

extension RegisteredModel {
    /// Keep inferred defaults out of persisted metadata so future catalog updates apply immediately.
    var effectiveContextWindowTokens: Int? {
        if let contextWindowTokens, contextWindowTokens > 0 { return contextWindowTokens }
        return reference.hasPrefix("cloud:") ? nil : ModelContextCatalog.limits(forModelID: id)?.contextWindow
    }

    var effectiveMaxOutputTokens: Int? {
        let output: Int?
        if let maxOutputTokens, maxOutputTokens > 0 {
            output = maxOutputTokens
        } else {
            output = reference.hasPrefix("cloud:") ? nil : ModelContextCatalog.limits(forModelID: id)?.maxOutput
        }
        guard let output else { return nil }
        return min(output, effectiveContextWindowTokens ?? output)
    }
}
