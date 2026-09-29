import Foundation

protocol ProviderModelCatalog {
    func models(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration) async throws
        -> [RegisteredModel]
}

struct HTTPProviderModelCatalog: ProviderModelCatalog {
    var session = URLSession(configuration: .ephemeral, delegate: AskModelRedirectPolicy(), delegateQueue: nil)

    struct Page {
        var models: [RegisteredModel]
        var cursor: String?
    }

    func models(provider: RegisteredProvider,
                connection: SettingsStore.TextLLMConfiguration) async throws -> [RegisteredModel] {
        try AskModelProfile(name: provider.name, baseURL: connection.baseURL, model: "catalog").validate()
        guard let base = URL(string: connection.baseURL) else { throw AskLocalError.message(L("ask.models.invalid")) }
        let path = provider.isOllama ? "api/tags" : "models"
        let endpoint = provider.isOllama ? base.appendingPathComponent(path) : OpenAIEndpointResolver.resolve(
            from: base,
            path: path
        )
        var result: [RegisteredModel] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            if let cursor {
                let name = provider.remote == .gemini ? "pageToken" : "after_id"
                components.queryItems = [URLQueryItem(name: name, value: cursor)]
            }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            Self.authenticate(&request, provider: provider, key: connection.apiKey)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse
            else { throw AskLocalError.message(L("models.invalidResponse")) }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw AskLocalError.message(L("models.httpError", response.statusCode))
            }
            guard data.count <= 8_000_000 else { throw AskLocalError.message(L("models.invalidResponse")) }
            let page = try Self.parse(data, provider: provider)
            for model in page.models where !result.contains(where: { $0.id == model.id }) {
                result.append(model)
            }
            cursor = page.cursor
            if let cursor,
               !seenCursors.insert(cursor).inserted {
                throw AskLocalError.message(L("models.invalidResponse"))
            }
        } while cursor != nil
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func authenticate(_ request: inout URLRequest, provider: RegisteredProvider, key: String) {
        switch provider.remote?.apiStyle {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            if !key.isEmpty {
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
        }
    }

    static func parse(_ data: Data, provider: RegisteredProvider) throws -> Page {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskLocalError.message(L("models.invalidResponse"))
        }
        let key = provider.isOllama || provider.remote == .gemini ? "models" : "data"
        guard let rows = body[key] as? [[String: Any]] else { throw AskLocalError.message(L("models.invalidResponse")) }
        let models = try rows.map { row -> RegisteredModel in
            guard let raw = (row["id"] ?? row["name"]) as? String, !raw.isEmpty else {
                throw AskLocalError.message(L("models.invalidResponse"))
            }
            let id = provider.remote == .gemini && raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            var model = RegisteredModel(id: id, name: (row["display_name"] ?? row["displayName"]) as? String ?? id)
            if let methods = row["supportedGenerationMethods"] as? [String] {
                model.chat = methods.contains("generateContent")
            }
            if let capabilities = row["capabilities"] as? [String] {
                model.vision = capabilities.contains("vision")
            }
            if let architecture = row["architecture"] as? [String: Any],
               let inputs = architecture["input_modalities"] as? [String] {
                model.vision = inputs.contains("image")
            }
            return model
        }
        var cursor = body["nextPageToken"] as? String
        if body["has_more"] as? Bool == true {
            guard let last = body["last_id"] as? String,
                  !last.isEmpty else { throw AskLocalError.message(L("models.invalidResponse")) }
            cursor = last
        }
        return Page(models: models, cursor: cursor?.isEmpty == true ? nil : cursor)
    }
}
