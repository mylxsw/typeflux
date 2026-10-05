import Foundation

enum OpenAIEndpointResolver {
    static func resolve(from configuredURL: URL, path expectedPath: String) -> URL {
        if matchesEndpoint(configuredURL, expectedPath: expectedPath) {
            return configuredURL
        }

        let sanitizedPath = expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var base = configuredURL
        let normalized = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        for suffix in ["chat/completions", "messages", "responses", "models"] {
            if normalized == suffix || normalized.hasSuffix("/" + suffix) {
                for _ in suffix.split(separator: "/") { base.deleteLastPathComponent() }
                break
            }
        }
        return base.appendingPathComponent(sanitizedPath)
    }

    private static func matchesEndpoint(_ url: URL, expectedPath: String) -> Bool {
        let normalizedURLPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let normalizedExpectedPath = expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return normalizedURLPath == normalizedExpectedPath || normalizedURLPath.hasSuffix("/" + normalizedExpectedPath)
    }
}
