import Foundation

struct AskSearchConfiguration: Sendable {
    var provider: AskSearchSettings.Provider = .none
    var apiKey = ""
    var cloudflare = AskCloudflareSearchConfiguration()

    var isConfigured: Bool {
        guard provider != .none, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n") else { return false }
        return provider != .cloudflare || cloudflare.isValid
    }
}

struct AskCloudflareSearchConfiguration: Sendable, Equatable {
    static let providers = ["ceramic", "exa", "linkup"]
    var accountID = ""
    var gatewayID = "default"
    var provider = "ceramic"
    var byokAlias = ""

    var normalized: Self {
        let gateway = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return .init(accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
              gatewayID: gateway.isEmpty ? "default" : gateway,
              provider: engine.isEmpty ? "ceramic" : engine,
              byokAlias: byokAlias.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isValid: Bool {
        let value = normalized
        return value.accountID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
            && Self.validIdentifier(value.gatewayID)
            && Self.providers.contains(value.provider)
            && (value.byokAlias.isEmpty || Self.validIdentifier(value.byokAlias))
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}

// The account token must not follow redirects, including same-host redirects.
final class AskCloudflareRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AskCloudflareSearch {
    static let maxResponseBytes = 4 << 20
    static let maxOutputCharacters = 16000

    struct Item: Decodable {
        let title: String?
        let url: String?
        let description: String?
    }

    struct Response: Decodable {
        let items: [Item]
    }

    static func request(query: String, count: Int, configuration: AskSearchConfiguration) throws -> URLRequest {
        guard configuration.provider == .cloudflare, configuration.isConfigured else {
            throw AskLocalError.message(L("ask.settings.search.cloudflare.invalid"))
        }
        let value = configuration.cloudflare.normalized
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(value.accountID)/ai/websearch/")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["query": query, "limit": min(max(count, 1), 10), "provider": value.provider,
                                  "options": ["gateway": ["id": value.gatewayID]]]
        if !value.byokAlias.isEmpty { body["byokAlias"] = value.byokAlias }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func search(_ query: String, count: Int, configuration: AskSearchConfiguration, session: URLSession) async throws -> String {
        let request = try request(query: query, count: count, configuration: configuration)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: AskCloudflareRedirectPolicy())
            try validate(response)
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxResponseBytes else { throw unavailable() }
                data.append(byte)
            }
            let body = try JSONDecoder().decode(Response.self, from: data)
            guard !body.items.isEmpty else { return "No results." }
            let output = body.items.prefix(min(max(count, 1), 10)).enumerated().map { index, item in
                let title = String((item.title ?? "").prefix(500))
                let url = String((item.url ?? "").prefix(2000))
                let snippet = String((item.description ?? "").prefix(4000))
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return "\(index + 1). \(title)\n   \(url)" + (snippet.isEmpty ? "" : "\n   " + snippet)
            }.joined(separator: "\n")
            return String(output.prefix(maxOutputCharacters))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AskLocalError {
            throw error
        } catch {
            throw unavailable()
        }
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw unavailable() }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw AskLocalError.message(L("ask.settings.search.cloudflare.unauthorized"))
        case 429: throw AskLocalError.message(L("ask.settings.search.cloudflare.rateLimited"))
        default: throw unavailable()
        }
        guard response.expectedContentLength <= maxResponseBytes else { throw unavailable() }
    }

    private static func unavailable() -> AskLocalError { .message(L("ask.settings.search.cloudflare.unavailable")) }
}
