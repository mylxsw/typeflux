import Foundation

@MainActor
final class AskCloudflareConnectionTest: ObservableObject {
    typealias Search = @Sendable (AskSearchConfiguration) async throws -> Void
    @Published private(set) var testing = false
    @Published private(set) var result: String?
    private var task: Task<Void, Never>?
    private let search: Search

    init(search: @escaping Search = { try await AskCloudflareConnectionTest.search($0) }) { self.search = search }

    func start(_ configuration: AskSearchConfiguration) {
        reset()
        guard configuration.isConfigured else {
            result = L("ask.settings.search.cloudflare.invalid")
            return
        }
        testing = true
        task = Task { [weak self, search] in
            let message: String
            do {
                try await search(configuration)
                message = L("ask.settings.search.cloudflare.connected")
            } catch {
                message = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.result = message
            self?.testing = false
            self?.task = nil
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        testing = false
        result = nil
    }

    nonisolated static func search(_ configuration: AskSearchConfiguration) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await AskCloudflareSearch.search("Cloudflare", count: 1, configuration: configuration, session: session)
    }
}
