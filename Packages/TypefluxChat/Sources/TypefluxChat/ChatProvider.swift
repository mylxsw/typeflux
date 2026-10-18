import Foundation
import Network

/// The wire protocol a provider speaks.
public enum ChatProviderAPI: String, Codable, Sendable {
    case openAICompatible
    case anthropic
    case gemini
    /// Ollama: `/api/tags` for models, its OpenAI-compatible `/v1` endpoint for chat.
    case ollama
}

/// Providers the user can add with their own key. Presets fix the address.
public enum ChatProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, deepSeek, openRouter, dashScope, moonshot, ollama, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .dashScope: "Qwen (DashScope)"
        case .moonshot: "Moonshot"
        case .ollama: "Ollama"
        case .custom: "OpenAI-compatible"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .dashScope: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: "https://api.moonshot.cn/v1"
        case .ollama, .custom: ""
        }
    }

    public var api: ChatProviderAPI {
        switch self {
        case .anthropic: .anthropic
        case .gemini: .gemini
        case .ollama: .ollama
        default: .openAICompatible
        }
    }

    /// Ollama and custom endpoints are typed by the user; presets keep their address.
    public var hasEditableAddress: Bool { self == .ollama || self == .custom }

    /// Ollama on a home network usually runs without a key; custom gateways may too.
    public var requiresKey: Bool { self != .ollama && self != .custom }

    /// Providers whose chat models all accept images; others are confirmed per model.
    var modelsSupportImages: Bool { self == .anthropic || self == .gemini }
}

public struct ChatProviderModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var vision: Bool
    public var enabled: Bool

    public init(id: String, name: String? = nil, vision: Bool = false, enabled: Bool = true) {
        self.id = id; self.name = name ?? id; self.vision = vision; self.enabled = enabled
    }
}

/// A provider configured by the user. The key is stored separately in the Keychain.
public struct ChatProvider: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ChatProviderKind
    public var name: String
    public var baseURL: String
    public var models: [ChatProviderModel]

    public init(id: String = UUID().uuidString.lowercased(), kind: ChatProviderKind, name: String? = nil,
                baseURL: String? = nil, models: [ChatProviderModel] = []) {
        self.id = id; self.kind = kind; self.name = name ?? kind.displayName
        self.baseURL = baseURL ?? kind.defaultBaseURL; self.models = models
    }

    public static let referencePrefix = "local:"

    public func reference(for modelID: String) -> String {
        Self.referencePrefix + id + "/" + modelID
    }

    /// Splits `local:<provider>/<model>`; model IDs may themselves contain slashes.
    public static func parse(reference: String) -> (provider: String, model: String)? {
        guard reference.hasPrefix(referencePrefix) else { return nil }
        let rest = reference.dropFirst(referencePrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let provider = String(rest[..<slash]), model = String(rest[rest.index(after: slash)...])
        return provider.isEmpty || model.isEmpty ? nil : (provider, model)
    }

    /// The models shown in the picker.
    public var chatModels: [ChatModel] {
        models.filter(\.enabled).map {
            ChatModel.local(reference: reference(for: $0.id), id: $0.id, name: $0.name, providerName: name,
                            vision: $0.vision)
        }
    }

    /// The validated address, or nil when it is not allowed.
    public var endpoint: URL? { ChatEndpointPolicy.validate(baseURL) }
}

/// Requests carry the user's key, so addresses are restricted: HTTPS anywhere, or
/// plain HTTP only to a private network (Ollama or LM Studio at home).
public enum ChatEndpointPolicy {
    public static func validate(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1 ... 65535).contains($0) }) ?? true else { return nil }
        switch scheme {
        case "https": return url
        case "http": return isPrivateHost(host) ? url : nil
        default: return nil
        }
    }

    public static func isPrivateHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || (name.hasSuffix(".local") && name.count > 6) {
            return true
        }
        if let bytes = IPv4Address(name)?.rawValue {
            return bytes[0] == 127 || bytes[0] == 10 ||
                (bytes[0] == 172 && (16 ... 31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let bytes = IPv6Address(name)?.rawValue {
            return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1) ||
                bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        }
        return false
    }
}

public enum ChatProviderError: Error, Equatable, Sendable {
    case invalidEndpoint
    case missingKey
    case invalidKey
    case notFound
    case rateLimited
    case redirected
    case invalidResponse
    case server(status: Int)
}
