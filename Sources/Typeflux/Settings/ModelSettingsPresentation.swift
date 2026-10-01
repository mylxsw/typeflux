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
    static func connectionChanged(savedBaseURL: String, savedKey: String, baseURL: String, key: String) -> Bool {
        savedBaseURL != baseURL || savedKey != key
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
}
