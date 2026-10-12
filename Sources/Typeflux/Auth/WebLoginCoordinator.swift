import Combine
import Foundation

@MainActor
protocol WebLoginPendingStore: AnyObject {
    var pending: PendingWebLogin? { get set }
}

/// Deliberately process-local: quitting requires a fresh login, with no verifier on disk.
@MainActor
final class WebLoginMemoryStore: WebLoginPendingStore {
    var pending: PendingWebLogin?
}

@MainActor
protocol WebLoginBrowserSession: AnyObject {
    func start() -> Bool
    func cancel()
}

@MainActor
final class WebLoginCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle, creating, waiting, exchanging, succeeded, cancelled, failed(WebLoginFailure)
    }

    typealias BrowserFactory = (URL, String, @escaping (URL?, Bool) -> Void) -> WebLoginBrowserSession

    @Published private(set) var phase: Phase = .idle
    let configuration: WebLoginConfiguration
    private let api: WebLoginAPI
    private let store: WebLoginPendingStore
    private let browserFactory: BrowserFactory
    private let now: () -> Date
    private let makeProof: () throws -> WebLoginProof
    private let authGeneration: () -> Int
    private let accept: (LoginResponse, Int) async throws -> Void
    private var attempt: UUID?
    private var generation: Int?
    private var browserID: UUID?
    private var browser: WebLoginBrowserSession?
    private var expiryTask: Task<Void, Never>?

    init(configuration: WebLoginConfiguration, api: WebLoginAPI, store: WebLoginPendingStore,
         browserFactory: @escaping BrowserFactory, now: @escaping () -> Date = Date.init,
         makeProof: @escaping () throws -> WebLoginProof = { try WebLoginProof.generate() },
         authGeneration: @escaping () -> Int, accept: @escaping (LoginResponse, Int) async throws -> Void) {
        self.configuration = configuration
        self.api = api
        self.store = store
        self.browserFactory = browserFactory
        self.now = now
        self.makeProof = makeProof
        self.authGeneration = authGeneration
        self.accept = accept
        // This release does not resume abandoned transactions after coordinator recreation.
        store.pending = nil
    }

    var isBusy: Bool {
        phase == .creating || phase == .waiting || phase == .exchanging
    }

    func start() async {
        guard configuration.enabled, !isBusy else { return }
        clear()
        let id = UUID()
        attempt = id
        generation = authGeneration()
        phase = .creating
        do {
            guard WebLoginConfiguration.isWebOrigin(configuration.apiOrigin),
                  WebLoginConfiguration.isWebOrigin(configuration.websiteOrigin) else {
                throw WebLoginFailure.invalidResponse
            }
            let proof = try makeProof()
            let transaction = try await api.create(proof: proof)
            guard isCurrent(id) else { return }
            let url = try configuration.validate(transaction, now: now())
            store.pending = PendingWebLogin(proof: proof, transaction: transaction)
            phase = .waiting
            let delay = transaction.expiresAt - now().timeIntervalSince1970
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
                guard let self, attempt == id, phase == .waiting else { return }
                fail(.expired)
            }
            openBrowser(url, attemptID: id)
        } catch {
            guard isCurrent(id) else { return }
            fail(error as? WebLoginFailure ?? .restartRequired)
        }
    }

    func reopen() {
        guard phase == .waiting, let id = attempt, isCurrent(id), let pending = store.pending else { return }
        do {
            let url = try configuration.validate(pending.transaction, now: now())
            openBrowser(url, attemptID: id)
        } catch { fail(.expired) }
    }

    private func openBrowser(_ url: URL, attemptID: UUID) {
        browserID = nil
        browser?.cancel()
        let sessionID = UUID()
        browserID = sessionID
        let session = browserFactory(url,
                                     URL(string: configuration.redirectURI)!.scheme!) { [weak self] url, cancelled in
            Task { @MainActor [weak self] in
                guard let self, browserID == sessionID, isCurrent(attemptID), phase == .waiting else { return }
                if let url {
                    await receive(url)
                } else if cancelled {
                    cancel()
                } else {
                    fail(.browserUnavailable)
                }
            }
        }
        browser = session
        if !session.start() {
            fail(.browserUnavailable)
        }
    }

    /// Both ASWebAuthenticationSession and the application URL router enter here.
    /// The callback has no transaction ID: state identifies the sole active transaction.
    func receive(_ url: URL) async {
        guard configuration.enabled, configuration.matchesCallback(url) else { return }
        guard phase == .waiting, let id = attempt, let expectedGeneration = generation,
              isCurrent(id), let pending = store.pending else {
            // Ignore duplicates during/after exchange; cold launch must explicitly restart.
            if phase == .idle {
                fail(.restartRequired)
            }
            return
        }
        do {
            let code = try pending.code(from: url, configuration: configuration, now: now())
            phase = .exchanging
            store.pending = nil
            expiryTask?.cancel()
            browserID = nil
            browser?.cancel()
            browser = nil
            let response = try await api.exchange(code: code, verifier: pending.proof.verifier)
            guard isCurrent(id) else { return }
            guard !response.accessToken.isEmpty, response.refreshToken?.isEmpty == false,
                  Double(response.expiresAt) > now().timeIntervalSince1970,
                  response.expiresAt < 10_000_000_000 else { throw WebLoginFailure.invalidResponse }
            // accept validates the AuthState generation again before its first mutation.
            try await accept(response, expectedGeneration)
            guard attempt == id else { return }
            clear()
            phase = .succeeded
        } catch {
            guard isCurrent(id) else { return }
            fail(error as? WebLoginFailure ?? .restartRequired)
        }
    }

    func cancel() {
        clear()
        phase = .cancelled
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard attempt == id else { return false }
        guard generation == authGeneration() else { cancel(); return false }
        return true
    }

    private func fail(_ failure: WebLoginFailure) {
        clear()
        phase = .failed(failure)
    }

    private func clear() {
        attempt = nil
        generation = nil
        browserID = nil
        store.pending = nil
        expiryTask?.cancel()
        expiryTask = nil
        browser?.cancel()
        browser = nil
    }
}
