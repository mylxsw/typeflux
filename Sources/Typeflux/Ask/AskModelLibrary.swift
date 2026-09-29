import Combine
import Foundation

struct AskCloudModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var reference: String { "cloud:" + id }
}

struct AskModelProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var baseURL: String
    var model: String
    var reference: String { "custom:" + id }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw AskLocalError.message(L("ask.models.invalid"))
        }
    }
}

/// Profile metadata is local; credentials are stored separately in Keychain.
@MainActor
final class AskModelLibrary: ObservableObject {
    static let shared = AskModelLibrary()
    @Published private(set) var profiles: [AskModelProfile]
    @Published var cloud: [AskCloudModel] = [.init(id: "default", name: "Typeflux Cloud")]
    @Published var defaultReference: String { didSet { defaults.set(defaultReference, forKey: "ask.model.default") } }
    @Published var rewriteReference: String { didSet { defaults.set(rewriteReference, forKey: "llm.profile.reference") } }
    @Published var catalogError: String?
    let automaticallyLoadsCatalog: Bool
    private let defaults: UserDefaults
    private var loading = false

    init(defaults: UserDefaults = .standard, automaticallyLoadsCatalog: Bool = true) {
        self.automaticallyLoadsCatalog = automaticallyLoadsCatalog
        self.defaults = defaults
        profiles = Self.readProfiles(defaults)
        defaultReference = defaults.string(forKey: "ask.model.default") ?? "cloud:default"
        rewriteReference = defaults.string(forKey: "llm.profile.reference") ?? ""
    }

    nonisolated static func readProfiles(_ defaults: UserDefaults) -> [AskModelProfile] {
        guard let data = defaults.data(forKey: "llm.model.profiles") else { return [] }
        return (try? JSONDecoder().decode([AskModelProfile].self, from: data)) ?? []
    }

    nonisolated static func key(for profile: AskModelProfile) -> String {
        KeychainTokenStore.getKeychainValue(account: "ask-model-" + profile.id) ?? ""
    }

    func save(_ profile: AskModelProfile, key: String) throws {
        try profile.validate()
        guard KeychainTokenStore.setKeychainValue(key, account: "ask-model-" + profile.id) else {
            throw AskLocalError.message(L("ask.models.keychainError"))
        }
        var next = profiles.filter { $0.id != profile.id }
        next.append(profile)
        defaults.set(try JSONEncoder().encode(next), forKey: "llm.model.profiles")
        profiles = next
    }

    var configuredProfile: AskModelProfile? {
        let settings = SettingsStore(defaults: defaults)
        guard settings.llmProvider == .openAICompatible,
              settings.llmRemoteProvider != .typefluxCloud,
              settings.llmRemoteProvider.apiStyle == .openAICompatible else { return nil }
        let profile = AskModelProfile(name: settings.llmRemoteProvider.displayName + " · " + settings.llmModel,
                                      baseURL: settings.llmBaseURL, model: settings.llmModel)
        guard (try? profile.validate()) != nil else { return nil }
        return profile
    }

    func importConfiguredProfile() throws {
        guard let profile = configuredProfile else { throw AskLocalError.message(L("ask.models.invalid")) }
        if profiles.contains(where: { $0.baseURL == profile.baseURL && $0.model == profile.model }) { return }
        try save(profile, key: SettingsStore(defaults: defaults).llmAPIKey)
    }

    func remove(_ profile: AskModelProfile) {
        profiles.removeAll { $0.id == profile.id }
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "llm.model.profiles")
        KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id)
        // Keep references explicit: an unavailable model must never silently fall back.
    }

    func name(for reference: String) -> String {
        if let profile = profiles.first(where: { $0.reference == reference }) { return profile.name }
        if let model = cloud.first(where: { $0.reference == reference }) { return model.name }
        return L("ask.models.unavailable")
    }

    func refresh(api: any AskAPI = AskAPIClient(), token: String?) async {
        guard !loading, let token else { return }
        loading = true
        defer { loading = false }
        do {
            cloud = try await api.models(token: token)
            catalogError = nil
        } catch { catalogError = L("ask.models.catalogError") }
    }
}

struct AskInference: Codable, Equatable, Sendable {
    var id: String
    var payload: String
    var summaryThrough: Int?
}
struct AskInferenceResult: Codable, Equatable, Sendable {
    var runId: String
    var deviceId: String
    var inferenceId: String
    var content: String
    var toolCalls: [AskToolCall] = []
    var failed = false
}

/// Refuse redirects so a configured endpoint cannot forward credentials to another host.
final class AskModelRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AskCustomInference: Sendable {
    var session: URLSession = URLSession(configuration: .ephemeral, delegate: AskModelRedirectPolicy(), delegateQueue: nil)

    func complete(profile: AskModelProfile, key: String, payload: String) async throws -> (String, [AskToolCall]) {
        try profile.validate()
        guard var body = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let base = URL(string: profile.baseURL) else { throw AskLocalError.message(L("ask.models.invalid")) }
        body["model"] = profile.model
        body["stream"] = false
        let url = OpenAIEndpointResolver.resolve(from: base, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 2_000_000 else {
            throw AskLocalError.message(L("ask.models.requestError"))
        }
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String?; var toolCalls: [AskToolCall]? }
                var message: Message
            }
            var choices: [Choice]
        }
        guard let message = try AskCoding.decoder().decode(Reply.self, from: data).choices.first?.message,
              !(message.content ?? "").isEmpty || !(message.toolCalls ?? []).isEmpty else {
            throw AskLocalError.message(L("ask.models.requestError"))
        }
        return (message.content ?? "", message.toolCalls ?? [])
    }

    func test(profile: AskModelProfile, key: String) async throws {
        _ = try await complete(profile: profile, key: key, payload: #"{"messages":[{"role":"user","content":"Reply OK"}],"max_tokens":16}"#)
    }
}
