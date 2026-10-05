import Foundation

/// Pure presentation rules for the model settings page, kept out of SwiftUI so they stay testable.
enum ModelSettingsPresentation {
    /// Case-insensitive match against any search term. An empty query matches everything.
    static func matches(_ query: String, terms: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return terms.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Splits providers into connected and unconfigured groups while preserving their order.
    static func partition<Item>(
        _ items: [Item],
        query: String,
        isAvailable: (Item) -> Bool,
        searchTerms: (Item) -> [String]
    ) -> (connected: [Item], unconfigured: [Item]) {
        let visible = items.filter { matches(query, terms: searchTerms($0)) }
        return (visible.filter(isAvailable), visible.filter { !isAvailable($0) })
    }

    /// Host and path of an endpoint without the scheme, e.g. `api.example.com/v1`.
    static func endpointLabel(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else { return trimmed }
        var rest = String(trimmed[range.upperBound...])
        while rest.hasSuffix("/") {
            rest.removeLast()
        }
        return rest
    }

    /// Secondary line for a configured language-model provider row. Managed providers show who
    /// owns their catalog instead of an endpoint.
    static func languageProviderDetail(
        modelCount: Int,
        baseURL: String,
        countFormat: String,
        managedLabel: String? = nil
    ) -> String {
        let count = String(format: countFormat, modelCount)
        let suffix = managedLabel ?? endpointLabel(baseURL)
        return suffix.isEmpty ? count : count + " · " + suffix
    }

    /// Save is offered only once the draft differs from what was last stored.
    static func connectionChanged(savedBaseURL: String, savedKey: String, baseURL: String, key: String,
                                  savedAPIStyle: LLMRemoteAPIStyle? = nil, apiStyle: LLMRemoteAPIStyle? = nil) -> Bool {
        savedBaseURL != baseURL || savedKey != key || savedAPIStyle != apiStyle
    }

    /// The add-endpoint form needs a name, an http(s) endpoint with a host and a model ID.
    /// `AskModelProfile.validate()` stays the authority when saving; this only gates the button.
    static func canAddEndpoint(name: String, baseURL: String, model: String) -> Bool {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasScheme = trimmedURL.hasPrefix("https://") || trimmedURL.hasPrefix("http://")
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasScheme && !endpointLabel(trimmedURL).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Localization keys for the scenes a model is currently assigned to.
    static func usageKeys(reference: String, rewriteReference: String, defaultReference: String) -> [String] {
        var keys: [String] = []
        if reference == rewriteReference {
            keys.append("ask.models.rewrite")
        }
        if reference == defaultReference {
            keys.append("models.askDefault")
        }
        return keys
    }

    /// The note explaining scene tags only helps when some row shows one.
    static func showsUsageHint(_ models: [RegisteredModel], rewriteReference: String, defaultReference: String) -> Bool {
        models.contains {
            !usageKeys(reference: $0.reference, rewriteReference: rewriteReference, defaultReference: defaultReference).isEmpty
        }
    }

    /// Lines under a model's scene actions saying why they are greyed out. One line
    /// when both scenes share the reason, otherwise one per blocked scene.
    static func sceneBlockedNotes(rewrite: String?, ask: String?) -> [String] {
        switch (rewrite, ask) {
        case (nil, nil): return []
        case let (rewrite?, ask?) where rewrite == ask: return [rewrite]
        default:
            return [rewrite.map { L("models.rewriteBlocked", $0) }, ask.map { L("models.askBlocked", $0) }]
                .compactMap { $0 }
        }
    }
}
