import Foundation

/// Per-image previews for typical desktop screenshots. Never used for billing or admission.
/// The ordered presets mirror typeflux-api/internal/ask/policy/image-token-estimates.json.
enum AskImageTokenEstimate {
    private struct Rule: Decodable {
        let pattern: String
        let tokens: Int
    }

    private static let rules: [Rule] = {
        guard let url = Bundle.appResources.url(forResource: "image-token-estimates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return rules
    }()

    static func tokens(_ identifiers: String?...) -> Int {
        for identifier in identifiers.compactMap({ $0 }) {
            let component = identifier.split(separator: "/").last.map(String.init) ?? identifier
            let name = component.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if let rule = rules.first(where: { name.range(of: $0.pattern, options: .regularExpression) != nil }) {
                return rule.tokens
            }
        }
        return 2_000
    }
}
