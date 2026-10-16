import Foundation

/// Validated local image bytes, distinct from the server-backed AskGeneratedImage record.
struct AskGeneratedImageData: Sendable {
    let data: Data
    let mediaType: String
    let width: Int
    let height: Int
    var fileExtension: String {
        mediaType == "image/jpeg" ? "jpg" : "png"
    }
}

struct AskImageGenerationResult: Sendable {
    var images: [AskGeneratedImageData]
    var requestID: String?
    var usage: JSONValue?
    var responseModel: String?
    var responseProvider: String?
    var incomplete = false
    var unvalidatedImages: [Data] = []
}

protocol AskImageGenerating: Sendable {
    func generate(_ input: AskImageRequest, configuration: AskImageConfiguration, key: String, retention: AskImageGenerationRetention) async throws
        -> AskImageGenerationResult
}

struct AskImageGenerationService: AskImageGenerating {
    var transport: any AskImageTransport = AskImageHTTP()
    var validate: (@Sendable (Data) async throws -> AskGeneratedImageData)? = nil
    var nativeValidator: AskGeneratedImageValidator = .shared
    static let maximumResponseBytes = 46 * 1024 * 1024

    func generate(_ input: AskImageRequest, configuration: AskImageConfiguration,
                  key: String, retention: AskImageGenerationRetention) async throws -> AskImageGenerationResult {
        // Native availability is not permission to POST. Retain the original stamp
        // without gating the request or losing a charged response when it expires.
        let validate = validate ?? nativeValidator.batch()
        let request = try Self.request(input, configuration: configuration, key: key)
        let data = try await transport.send(request, limit: Self.maximumResponseBytes)
        // The HTTP response (including inline originals and usage) is retained
        // before cancellation, parsing, downloads or any native decoder can fail.
        try retention.response(data)
        let body = try Self.object(data)
        let sources = try Self.sources(body, provider: configuration.provider)
        guard !sources.isEmpty else { throw AskImageError.noImage }
        guard sources.count <= 8 else { throw AskImageError.tooLarge }
        var images: [AskGeneratedImageData] = [], total = 0
        var incomplete = false
        var unvalidated: [Data] = []
        for source in sources {
            do {
                try Task.checkCancellation()
                let bytes: Data
                var downloaded = false
                switch source {
                case let .base64(encoded):
                    guard encoded.utf8.count <= 23 * 1024 * 1024,
                          let decoded = Data(base64Encoded: encoded) else { throw AskImageError.invalidResponse }
                    bytes = decoded
                case let .url(raw):
                    let url = try Self.downloadURL(raw, provider: configuration.provider)
                    bytes = try await download(url, input: input)
                    downloaded = true
                }
                guard !bytes.isEmpty, bytes.count <= AskArtifactStore.maximumFileBytes,
                      bytes.count <= AskArtifactStore.maximumBundleBytes - 64 * 1024 - total else { throw AskImageError.tooLarge }
                total += bytes.count
                if downloaded {
                    do { try retention.downloaded(bytes) }
                    catch { unvalidated.append(bytes); incomplete = true; continue }
                }
                do { images.append(try await validate(bytes)) }
                catch { unvalidated.append(bytes); incomplete = true }
            } catch {
                incomplete = true
                // No producer replay. Preserve already validated partial output and
                // the raw journal even if the next download or decoder is unavailable.
                if Task.isCancelled { break }
            }
        }
        return .init(images: images, requestID: (body["request_id"] ?? body["id"]) as? String,
                     usage: (body["usage"] as? [String: Any]).map(AskTypedContent.json),
                     responseModel: body["model"] as? String, responseProvider: body["provider"] as? String,
                     incomplete: incomplete, unvalidatedImages: unvalidated)
    }

    private func download(_ url: URL, input: AskImageRequest) async throws -> Data {
        func read() async throws -> Data {
            try Task.checkCancellation()
            // A signed object URL is sufficient; never forward the provider credential.
            var request = try URLRequest(url: url, timeoutInterval: input.timeout(maximum: 45))
            request.setValue("image/png, image/jpeg", forHTTPHeaderField: "Accept")
            return try await transport.send(request, limit: AskArtifactStore.maximumFileBytes)
        }
        do {
            return try await read()
        } catch {
            let transient: Bool = switch error {
            case let AskImageError.http(status): [500, 502, 503, 504].contains(status)
            case let network as URLError: [.timedOut, .networkConnectionLost].contains(network.code)
            default: false
            }
            guard transient else { throw error }
            // Retry only the same idempotent download, never the paid generation POST.
            return try await read()
        }
    }

    static func request(_ input: AskImageRequest, configuration: AskImageConfiguration,
                        key: String) throws -> URLRequest {
        try configuration.validate(key: key)
        let base = try configuration.validatedBaseURL()
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = configuration.size.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        let body: [String: Any]
        switch configuration.provider {
        case .openAI:
            path = "images/generations"
            body = openAIBody(input, configuration: configuration, model: model, size: size)
        case .volcengine:
            path = "images/generations"
            body = volcengineBody(input, configuration: configuration, model: model, size: size)
        case .bailian:
            path = "services/aigc/multimodal-generation/generation"
            body = bailianBody(input, configuration: configuration, model: model, size: size)
        case .google:
            path = "interactions"
            body = googleBody(input, configuration: configuration, model: model, size: size)
        case .openRouter:
            path = "images"
            body = openRouterBody(input, configuration: configuration, model: model, size: size)
        }
        var request = try authorizedRequest(
            base.appendingPathComponent(path),
            provider: configuration.provider,
            key: key,
            timeout: input.timeout(maximum: 180)
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    private static func openAIBody(_ input: AskImageRequest, configuration: AskImageConfiguration,
                                   model: String, size: String) -> [String: Any] {
        var body: [String: Any] = ["model": model, "prompt": input.prompt, "n": 1]
        if !size.isEmpty {
            body["size"] = size
        } else if let dimensions = ["square": "1024x1024", "landscape": "1536x1024",
                                    "portrait": "1024x1536"][input.layout] {
            body["size"] = dimensions
        }
        if !configuration.quality.isEmpty {
            body["quality"] = configuration.quality
        }
        return body
    }

    private static func volcengineBody(_ input: AskImageRequest, configuration _: AskImageConfiguration,
                                       model: String, size: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": input.prompt,
            "response_format": "b64_json",
            "stream": false
        ]
        if !size.isEmpty {
            body["size"] = size
        } else if let dimensions = ["square": "2048x2048", "landscape": "2496x1664",
                                    "portrait": "1664x2496"][input.layout] {
            body["size"] = dimensions
        }
        return body
    }

    private static func bailianBody(_ input: AskImageRequest, configuration _: AskImageConfiguration,
                                    model: String, size: String) -> [String: Any] {
        var parameters: [String: Any] = ["n": 1]
        if !size.isEmpty {
            parameters["size"] = size.replacingOccurrences(of: "x", with: "*")
        } else if let dimensions = ["square": "1328*1328", "landscape": "1472*1104",
                                    "portrait": "1104*1472"][input.layout] {
            parameters["size"] = dimensions
        }
        return ["model": model, "input": ["messages": [["role": "user", "content": [["text": input.prompt]]]]],
                "parameters": parameters]
    }

    private static func googleBody(_ input: AskImageRequest, configuration _: AskImageConfiguration,
                                   model: String, size: String) -> [String: Any] {
        var format: [String: Any] = ["type": "image"]
        if let aspect = input.aspectRatio {
            format["aspect_ratio"] = aspect
        }
        if !size.isEmpty {
            format["image_size"] = size
        }
        return ["model": model, "input": input.prompt, "response_format": format, "store": false]
    }

    private static func openRouterBody(_ input: AskImageRequest, configuration: AskImageConfiguration,
                                       model: String, size: String) -> [String: Any] {
        var body: [String: Any] = ["model": model, "prompt": input.prompt, "n": 1]
        if !size.isEmpty {
            body["size"] = size
        } else if let aspect = input.aspectRatio {
            body["aspect_ratio"] = aspect
        }
        if !configuration.quality.isEmpty {
            body["quality"] = configuration.quality
        }
        var routing: [String: Any] = ["allow_fallbacks": false]
        if !configuration.routingProvider.isEmpty {
            routing["only"] = [configuration.routingProvider]
        }
        body["provider"] = routing
        return body
    }

    static func authorizedRequest(_ url: URL, provider: AskImageProvider, key: String,
                                  timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(provider == .google ? key : "Bearer " + key,
                         forHTTPHeaderField: provider == .google ? "x-goog-api-key" : "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    enum Source { case base64(String), url(String) }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, object["code"] == nil || object["code"] is NSNull else {
            throw AskImageError.invalidResponse
        }
        return object
    }

    static func sources(_ body: [String: Any], provider: AskImageProvider) throws -> [Source] {
        switch provider {
        case .google:
            guard body["status"] as? String == "completed" else { throw AskImageError.noImage }
            // Interactions versions expose model output as steps or outputs. Never extract input or thought images.
            let steps = body["steps"] as? [[String: Any]] ?? []
            let parts = steps.filter { $0["type"] as? String == "model_output" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] } + (body["outputs"] as? [[String: Any]] ?? [])
            return try parts.filter { $0["type"] as? String == "image" }.map {
                guard let data = $0["data"] as? String else { throw AskImageError.invalidResponse }
                return .base64(data)
            }
        case .bailian:
            let output = body["output"] as? [String: Any]
            let choices = output?["choices"] as? [[String: Any]] ?? []
            return choices.flatMap { ($0["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] }
                .compactMap { ($0["image"] as? String).map(Source.url) }
        default:
            return try (body["data"] as? [[String: Any]] ?? []).map {
                // URL-only compatible providers are not an arbitrary download capability.
                guard let encoded = $0["b64_json"] as? String else { throw AskImageError.invalidResponse }
                return .base64(encoded)
            }
        }
    }

    static func downloadURL(_ raw: String, provider: AskImageProvider) throws -> URL {
        guard provider == .bailian, let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443, url.fragment == nil,
              let host = url.host?.lowercased(),
              host
              .range(of: "^dashscope[a-z0-9-]*\\.oss-[a-z0-9-]+\\.aliyuncs\\.com$", options: .regularExpression) != nil
        else {
            throw AskImageError.downloadDenied
        }
        return url
    }
}
