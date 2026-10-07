import Foundation

enum AskImageProvider: String, Codable, CaseIterable, Sendable {
    case volcengine, bailian, google, openRouter, openAI

    var title: String {
        switch self {
        case .volcengine: L("imagegen.provider.volcengine")
        case .bailian: L("imagegen.provider.bailian")
        case .google: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI / Compatible"
        }
    }

    var baseURL: String {
        switch self {
        case .volcengine: "https://ark.cn-beijing.volces.com/api/v3"
        case .bailian: "https://dashscope.aliyuncs.com/api/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        }
    }

    /// Suggestions only. Neither this list nor discovery authorizes or restricts a model ID.
    var suggestedModels: [String] {
        switch self {
        case .volcengine: ["doubao-seedream-5-0-lite-260128", "doubao-seedream-4-5-251128"]
        case .bailian: ["qwen-image-2.0", "qwen-image-2.0-pro", "qwen-image-plus"]
        case .google: [
                "gemini-nano-banana-2.1",
                "gemini-3.1-flash-image",
                "gemini-3-pro-image",
                "gemini-2.5-flash-image"
            ]
        case .openRouter: ["google/gemini-3.1-flash-image", "google/gemini-3-pro-image", "openai/gpt-image-2"]
        case .openAI: ["gpt-image-2.5-flare", "gpt-image-2", "gpt-image-1.5"]
        }
    }

    var supportsDiscovery: Bool {
        self != .volcengine
    }
}

struct AskImageConfiguration: Codable, Equatable, Sendable {
    var provider: AskImageProvider = .volcengine
    var baseURL = AskImageProvider.volcengine.baseURL
    var model = AskImageProvider.volcengine.suggestedModels[0]
    /// Empty values intentionally leave new models' defaults to the provider.
    var size = ""
    var quality = ""
    var routingProvider = ""

    static func preset(_ provider: AskImageProvider) -> Self {
        .init(provider: provider, baseURL: provider.baseURL, model: provider.suggestedModels[0])
    }

    func validatedBaseURL() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AskImageError.configuration
        }
        return url
    }

    func validate(key: String, needsModel: Bool = true) throws {
        _ = try validatedBaseURL()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains(where: \.isNewline),
              !needsModel ||
              (!model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.utf8.count <= 512),
              [model, size, quality, routingProvider]
              .allSatisfy({ !$0.contains(where: \.isNewline) && $0.utf8.count <= 512 }) else {
            throw AskImageError.configuration
        }
    }
}

struct AskImageRequest: Equatable, Sendable {
    let prompt: String
    var layout: String = "auto"
    /// Supplied by the execution controller, never by model arguments.
    var deadline: Date?

    func timeout(maximum: TimeInterval) throws -> TimeInterval {
        guard let deadline else { return maximum }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw AskBudgetError.reached("duration") }
        return min(maximum, remaining)
    }

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["prompt", "layout"]),
              let prompt = arguments["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 16000,
              arguments["layout"] == nil || arguments["layout"] is String else { throw AskImageError.arguments }
        let layout = arguments["layout"] as? String ?? "auto"
        guard ["auto", "square", "landscape", "portrait"].contains(layout) else { throw AskImageError.arguments }
        self.prompt = prompt
        self.layout = layout
    }

    var aspectRatio: String? {
        ["square": "1:1", "landscape": "3:2", "portrait": "2:3"][layout]
    }
}

enum AskImageError: Error, LocalizedError, Equatable {
    case configuration, arguments, invalidResponse, noImage, tooLarge, downloadDenied, keychain, discovery
    case http(Int)

    var errorDescription: String? {
        switch self {
        case let .http(status): L("imagegen.error.http", status)
        default: L("imagegen.error." + String(describing: self))
        }
    }
}
