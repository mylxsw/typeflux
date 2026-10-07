import Foundation

/// Discovery assists editing; it never replaces or validates the user's model selection.
struct AskImageModelDiscovery {
    var transport: any AskImageTransport = AskImageHTTP()

    func models(configuration: AskImageConfiguration, key: String) async throws -> [String] {
        guard configuration.provider.supportsDiscovery else { return configuration.provider.suggestedModels }
        try configuration.validate(key: key, needsModel: false)
        let base = try configuration.validatedBaseURL()
        var result: [String] = [], token: String?
        var tokens = Set<String>()
        for page in 1 ... 20 {
            let url = Self.pageURL(base: base, provider: configuration.provider, page: page, token: token)
            let request = AskImageGenerationService.authorizedRequest(url, provider: configuration.provider, key: key)
            let data = try await transport.send(request, limit: 4 * 1024 * 1024)
            let body = try AskImageGenerationService.object(data)
            let output = body["output"] as? [String: Any] ?? [:]
            let items: [[String: Any]] = switch configuration.provider {
            case .google: body["models"] as? [[String: Any]] ?? []
            case .bailian: output["models"] as? [[String: Any]] ?? []
            default: body["data"] as? [[String: Any]] ?? []
            }
            result += Self.names(items, provider: configuration.provider)
            if configuration.provider == .google, let next = body["nextPageToken"] as? String, !next.isEmpty {
                guard tokens.insert(next).inserted, page < 20 else { throw AskImageError.discovery }
                token = next
            } else if configuration.provider == .bailian, let total = output["total"] as? Int, page * 100 < total {
                guard !items.isEmpty, page < 20 else { throw AskImageError.discovery }
            } else {
                guard !result.isEmpty else { throw AskImageError.discovery }
                // Put probable image models first, without hiding new or unusually named models.
                return Array(Set(result)).sorted {
                    let lhs = Self.imageLike($0), rhs = Self.imageLike($1)
                    return lhs == rhs ? $0.localizedStandardCompare($1) == .orderedAscending : lhs
                }
            }
        }
        throw AskImageError.discovery
    }

    private static func pageURL(base: URL, provider: AskImageProvider, page: Int, token: String?) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(provider == .openRouter ? "images/models" : "models"),
            resolvingAgainstBaseURL: false
        )!
        if provider == .google {
            components.queryItems = [.init(name: "pageSize", value: "100")]
            if let token {
                components.queryItems?.append(.init(name: "pageToken", value: token))
            }
        } else if provider == .bailian {
            components.queryItems = [
                .init(name: "capabilities", value: "IG"),
                .init(name: "providers", value: "qwen"),
                .init(name: "page_no", value: String(page)),
                .init(name: "page_size", value: "100")
            ]
        }
        return components.url!
    }

    private static func names(_ items: [[String: Any]], provider: AskImageProvider) -> [String] {
        items.compactMap { item in
            let name = (item["id"] ?? item["model"] ?? item["name"]) as? String
            guard var name, !name.isEmpty, name.utf8.count <= 512 else { return nil }
            if provider == .google, name.hasPrefix("models/") {
                name.removeFirst(7)
            }
            return name
        }
    }

    static func imageLike(_ name: String) -> Bool {
        ["image", "seedream", "banana", "dall-e"].contains { name.lowercased().contains($0) }
    }
}
