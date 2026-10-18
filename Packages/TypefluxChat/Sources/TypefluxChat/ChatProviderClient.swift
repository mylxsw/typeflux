import Foundation

/// One turn sent to the user's own provider.
public struct ChatProviderMessage: Equatable, Sendable {
    public var role: String
    public var text: String
    /// A `data:image/...;base64,` URL.
    public var image: String?

    public init(role: String, text: String, image: String? = nil) {
        self.role = role; self.text = text; self.image = image
    }
}

public struct ChatProviderRequest: Sendable {
    public var provider: ChatProvider
    public var apiKey: String?
    public var model: String
    public var system: String?
    public var messages: [ChatProviderMessage]
    public var maxOutputTokens: Int

    public init(provider: ChatProvider, apiKey: String?, model: String, system: String? = nil,
                messages: [ChatProviderMessage], maxOutputTokens: Int = 8192) {
        self.provider = provider; self.apiKey = apiKey; self.model = model; self.system = system
        self.messages = messages; self.maxOutputTokens = maxOutputTokens
    }
}

public enum ChatProviderEvent: Equatable, Sendable {
    case text(String)
    case reasoning(String)
}

/// Talks directly to the user's provider from this device.
public protocol ChatProviderService: Sendable {
    func models(provider: ChatProvider, apiKey: String?) async throws -> [ChatProviderModel]
    func stream(_ request: ChatProviderRequest) -> AsyncThrowingStream<ChatProviderEvent, Error>
}

public struct ChatProviderClient: ChatProviderService {
    private let session: URLSession

    /// The default session is ephemeral and refuses redirects, so a configured
    /// address can never forward the key to another host.
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: ChatProviderRedirectPolicy(),
                                             delegateQueue: nil)
    }

    public func models(provider: ChatProvider, apiKey: String?) async throws -> [ChatProviderModel] {
        var found: [ChatProviderModel] = []
        var cursor: String?
        // Catalogs are paginated for Anthropic and Gemini; ten pages is far more than any provider lists.
        for _ in 0 ..< 10 {
            let request = try ChatProviderWire.modelsRequest(provider: provider, apiKey: apiKey, cursor: cursor)
            let (data, response) = try await session.data(for: request)
            try ChatProviderWire.check(response, data: data)
            let page = try ChatProviderWire.parseModels(data, provider: provider)
            found += page.models
            guard let next = page.cursor, next != cursor else { break }
            cursor = next
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    public func stream(_ request: ChatProviderRequest) -> AsyncThrowingStream<ChatProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try ChatProviderWire.chatRequest(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes where body.count < 65536 {
                            body.append(byte)
                        }
                        try ChatProviderWire.check(response, data: body)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try ChatProviderWire.parseStreamLine(line, api: request.provider.kind.api) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class ChatProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Request building and response parsing for each provider protocol.
enum ChatProviderWire {
    static let anthropicVersion = "2023-06-01"

    static func base(_ provider: ChatProvider) throws -> URL {
        guard let url = provider.endpoint else { throw ChatProviderError.invalidEndpoint }
        return url
    }

    static func url(_ base: URL, _ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (prefix.isEmpty ? path : prefix + "/" + path)
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? base
    }

    static func authorize(_ request: inout URLRequest, provider: ChatProvider, apiKey: String?) throws {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            if provider.kind.requiresKey { throw ChatProviderError.missingKey }
            return
        }
        switch provider.kind.api {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openAICompatible, .ollama:
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    static func modelsRequest(provider: ChatProvider, apiKey: String?, cursor: String?) throws -> URLRequest {
        let base = try base(provider)
        let target: URL = switch provider.kind.api {
        case .openAICompatible: url(base, "models")
        case .ollama: url(base, "api/tags")
        case .anthropic: url(base, "v1/models", query: [URLQueryItem(name: "limit", value: "100")] +
            (cursor.map { [URLQueryItem(name: "after_id", value: $0)] } ?? []))
        case .gemini: url(base, "v1beta/models", query: [URLQueryItem(name: "pageSize", value: "200")] +
            (cursor.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? []))
        }
        var request = URLRequest(url: target, timeoutInterval: 20)
        try authorize(&request, provider: provider, apiKey: apiKey)
        if provider.kind.api == .anthropic {
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func parseModels(_ data: Data, provider: ChatProvider) throws
        -> (models: [ChatProviderModel], cursor: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatProviderError.invalidResponse
        }
        let vision = provider.kind.modelsSupportImages
        switch provider.kind.api {
        case .openAICompatible:
            let items = object["data"] as? [[String: Any]] ?? []
            return (items.compactMap { ($0["id"] as? String).map { ChatProviderModel(id: $0, enabled: false) } }, nil)
        case .ollama:
            let items = object["models"] as? [[String: Any]] ?? []
            return (items.compactMap {
                (($0["model"] ?? $0["name"]) as? String).map { ChatProviderModel(id: $0, enabled: false) }
            }, nil)
        case .anthropic:
            let items = object["data"] as? [[String: Any]] ?? []
            let models = items.compactMap { item -> ChatProviderModel? in
                guard let id = item["id"] as? String else { return nil }
                return ChatProviderModel(id: id, name: item["display_name"] as? String, vision: vision, enabled: false)
            }
            let more = object["has_more"] as? Bool == true
            return (models, more ? object["last_id"] as? String : nil)
        case .gemini:
            let items = object["models"] as? [[String: Any]] ?? []
            let models = items.compactMap { item -> ChatProviderModel? in
                guard let name = item["name"] as? String,
                      (item["supportedGenerationMethods"] as? [String])?.contains("generateContent") != false
                else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return ChatProviderModel(id: id, name: item["displayName"] as? String, vision: vision, enabled: false)
            }
            return (models, object["nextPageToken"] as? String)
        }
    }

    static func chatRequest(_ request: ChatProviderRequest) throws -> URLRequest {
        let base = try base(request.provider)
        let body: [String: Any]
        let target: URL
        switch request.provider.kind.api {
        case .openAICompatible, .ollama:
            target = url(base, request.provider.kind.api == .ollama ? "v1/chat/completions" : "chat/completions")
            body = openAIBody(request)
        case .anthropic:
            target = url(base, "v1/messages")
            body = anthropicBody(request)
        case .gemini:
            target = url(base, "v1beta/models/\(request.model):streamGenerateContent",
                         query: [URLQueryItem(name: "alt", value: "sse")])
            body = geminiBody(request)
        }
        var urlRequest = URLRequest(url: target, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if request.provider.kind.api == .anthropic {
            urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        try authorize(&urlRequest, provider: request.provider, apiKey: request.apiKey)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Splits `data:image/png;base64,AAAA` into its media type and payload.
    static func imageParts(_ dataURL: String) -> (mediaType: String, data: String)? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5) ..< comma]
        guard header.hasSuffix(";base64") else { return nil }
        return (String(header.dropLast(7)), String(dataURL[dataURL.index(after: comma)...]))
    }

    static func openAIBody(_ request: ChatProviderRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in request.messages {
            if let image = message.image, message.role == "user" {
                messages.append(["role": message.role, "content": [
                    ["type": "text", "text": message.text],
                    ["type": "image_url", "image_url": ["url": image]],
                ]])
            } else {
                messages.append(["role": message.role, "content": message.text])
            }
        }
        return ["model": request.model, "messages": messages, "stream": true]
    }

    static func anthropicBody(_ request: ChatProviderRequest) -> [String: Any] {
        let messages: [[String: Any]] = request.messages.map { message in
            var content: [[String: Any]] = []
            if let image = message.image, message.role == "user", let parts = imageParts(image) {
                content.append(["type": "image", "source": ["type": "base64", "media_type": parts.mediaType,
                                                            "data": parts.data]])
            }
            content.append(["type": "text", "text": message.text])
            return ["role": message.role == "assistant" ? "assistant" : "user", "content": content]
        }
        var body: [String: Any] = ["model": request.model, "max_tokens": request.maxOutputTokens,
                                   "messages": messages, "stream": true]
        if let system = request.system, !system.isEmpty {
            body["system"] = system
        }
        return body
    }

    static func geminiBody(_ request: ChatProviderRequest) -> [String: Any] {
        let contents: [[String: Any]] = request.messages.map { message in
            var parts: [[String: Any]] = []
            if let image = message.image, message.role == "user", let image = imageParts(image) {
                parts.append(["inline_data": ["mime_type": image.mediaType, "data": image.data]])
            }
            parts.append(["text": message.text])
            return ["role": message.role == "assistant" ? "model" : "user", "parts": parts]
        }
        var body: [String: Any] = ["contents": contents]
        if let system = request.system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        return body
    }

    /// Parses one line of a server-sent event stream. Only `data:` lines carry content.
    static func parseStreamLine(_ line: String, api: ChatProviderAPI) throws -> [ChatProviderEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return []
        }
        if object["error"] != nil || object["type"] as? String == "error" {
            throw ChatProviderError.invalidResponse
        }
        switch api {
        case .openAICompatible, .ollama:
            guard let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else {
                return []
            }
            var events: [ChatProviderEvent] = []
            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.text(text))
            }
            return events
        case .anthropic:
            guard object["type"] as? String == "content_block_delta",
                  let delta = object["delta"] as? [String: Any] else { return [] }
            if let text = delta["text"] as? String, !text.isEmpty { return [.text(text)] }
            if let thinking = delta["thinking"] as? String, !thinking.isEmpty { return [.reasoning(thinking)] }
            return []
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { part in
                guard let text = part["text"] as? String, !text.isEmpty else { return nil }
                return part["thought"] as? Bool == true ? .reasoning(text) : .text(text)
            }
        }
    }

    static func check(_ response: URLResponse, data _: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatProviderError.invalidResponse }
        switch http.statusCode {
        case 200 ..< 300: return
        case 300 ..< 400: throw ChatProviderError.redirected
        case 401, 403: throw ChatProviderError.invalidKey
        case 404: throw ChatProviderError.notFound
        case 429: throw ChatProviderError.rateLimited
        default: throw ChatProviderError.server(status: http.statusCode)
        }
    }
}
