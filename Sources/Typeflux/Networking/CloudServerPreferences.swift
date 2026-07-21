import Foundation

/// Persists the user's preferred Typeflux Cloud endpoints. An empty value
/// means automatic latency-based routing.
final class CloudServerPreferences: @unchecked Sendable {
    static let shared = CloudServerPreferences()
    static let automaticValue = ""

    private enum Key {
        static let apiServer = "cloud.preferredAPIServer"
        static let asrServer = "cloud.preferredASRServer"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preferredAPIServer: String {
        get { normalizedStoredURL(forKey: Key.apiServer) }
        set { store(newValue, forKey: Key.apiServer) }
    }

    var preferredASRServer: String {
        get { normalizedStoredURL(forKey: Key.asrServer) }
        set { store(newValue, forKey: Key.asrServer) }
    }

    var preferredAPIURL: URL? {
        URL(string: preferredAPIServer)
    }

    var preferredASRURL: URL? {
        URL(string: preferredASRServer)
    }

    private func normalizedStoredURL(forKey key: String) -> String {
        guard let rawValue = defaults.string(forKey: key) else { return Self.automaticValue }
        return Self.normalizedURLString(rawValue) ?? Self.automaticValue
    }

    private func store(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let normalized = Self.normalizedURLString(value) {
            defaults.set(normalized, forKey: key)
        }
    }

    private static func normalizedURLString(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }
}
