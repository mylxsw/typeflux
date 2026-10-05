import Foundation

@MainActor
final class AskCloudflareConnectionTest: ObservableObject {
    typealias Search = @Sendable (AskSearchConfiguration) async throws -> Void
    @Published private(set) var testing = false
    @Published private(set) var result: String?
    /// Whether the last finished test reached the provider; nil while idle or testing.
    @Published private(set) var succeeded: Bool?
    private var task: Task<Void, Never>?
    private let search: Search

    init(search: @escaping Search = { try await AskCloudflareConnectionTest.search($0) }) { self.search = search }

    func start(_ configuration: AskSearchConfiguration) {
        reset()
        guard configuration.isConfigured else {
            result = L("ask.settings.search.cloudflare.invalid")
            succeeded = false
            return
        }
        testing = true
        task = Task { [weak self, search] in
            let message: String
            let ok: Bool
            do {
                try await search(configuration)
                message = L("ask.settings.search.cloudflare.connected")
                ok = true
            } catch {
                message = error.localizedDescription
                ok = false
            }
            guard !Task.isCancelled else { return }
            self?.result = message
            self?.succeeded = ok
            self?.testing = false
            self?.task = nil
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        testing = false
        result = nil
        succeeded = nil
    }

    /// Runs one real query with the provider being configured; Cloudflare's test is billed.
    nonisolated static func search(_ configuration: AskSearchConfiguration) async throws {
        guard configuration.provider == .cloudflare else {
            _ = try await AskLocalWebTools(searchProvider: { configuration }).search("Typeflux", count: 1)
            return
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await AskCloudflareSearch.search("Cloudflare", count: 1, configuration: configuration, session: session)
    }
}
