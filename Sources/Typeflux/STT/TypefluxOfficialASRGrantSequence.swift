import Foundation

/// Hands out one-time ASR grants for a single recording.
///
/// The gateway claims a grant before it upgrades the WebSocket, and an
/// ambiguous failure may already have consumed it. The first connection
/// attempt therefore uses the route that selected the servers, and every
/// failover attempt fetches a fresh grant instead of replaying the old one.
///
/// Every grant is checked with `verifySession` right before it is handed
/// out, after all route and server-selection suspensions, so a recording
/// whose account was logged out or replaced meanwhile never opens a
/// connection with it.
actor TypefluxOfficialASRGrantSequence {
    struct Grant: Equatable, Sendable {
        let token: String
        let provider: String

        init(route: TypefluxOfficialASRRouteDecision) {
            switch route {
            case let .webSocket(token, _, _, _, _):
                self.token = token
                provider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
            }
        }
    }

    private var initial: Grant?
    private let fetch: @Sendable () async throws -> TypefluxOfficialASRRouteDecision
    private let verifySession: @Sendable () async throws -> Void

    init(
        initial route: TypefluxOfficialASRRouteDecision,
        verifySession: @escaping @Sendable () async throws -> Void = {},
        fetch: @escaping @Sendable () async throws -> TypefluxOfficialASRRouteDecision
    ) {
        initial = Grant(route: route)
        self.verifySession = verifySession
        self.fetch = fetch
    }

    func next() async throws -> Grant {
        try Task.checkCancellation()
        let grant: Grant
        if let initial {
            self.initial = nil
            grant = initial
        } else {
            grant = try await Grant(route: refreshing(fetch))
        }
        // A recording cancelled or moved to another session while the grant
        // was issued or the servers were selected must not use it; an
        // unclaimed grant costs nothing.
        try Task.checkCancellation()
        try await refreshing(verifySession)
        try Task.checkCancellation()
        return grant
    }

    /// Runs a grant step. Cancellation stays cancellation; any other failure
    /// becomes a `TypefluxOfficialASRGrantRefreshError` so failover stops
    /// without blaming the endpoint.
    private func refreshing<T>(_ step: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await step()
        } catch let error where TypefluxOfficialASRCancellation.isCancellation(error) {
            throw CancellationError()
        } catch {
            throw TypefluxOfficialASRGrantRefreshError(underlying: error)
        }
    }
}

/// Recognizes the ways a cancelled recording surfaces from Swift
/// concurrency and URL loading, so cancellation is never mistaken for an
/// endpoint failure.
enum TypefluxOfficialASRCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let refreshError = error as? TypefluxOfficialASRGrantRefreshError {
            return isCancellation(refreshError.underlying)
        }
        if let admittedError = error as? TypefluxOfficialASRAdmittedStreamError {
            return isCancellation(admittedError.underlying)
        }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

/// An ASR attempt failed after audio was sent to its endpoint. The endpoint
/// may already have admitted, processed and billed the recording, so the
/// failure is final for this recording: replaying the audio on another
/// endpoint with a new grant could transcribe and bill it twice.
struct TypefluxOfficialASRAdmittedStreamError: Error {
    let underlying: Error
}

/// The credential used to start a recording. `session` identifies the
/// signed-in session (it changes on logout and login, not on token refresh),
/// so a recording can renew its access token without switching accounts.
struct TypefluxCloudSessionCredential: Equatable, Sendable {
    let accessToken: String
    let session: Int
}

/// A replacement grant could not be issued. Server failover stops and
/// surfaces the underlying error because another endpoint cannot help and
/// the failure is not the endpoint's fault.
struct TypefluxOfficialASRGrantRefreshError: Error {
    let underlying: Error
}

extension TypefluxOfficialASRRouteDecision {
    var serverBaseURLs: [URL] {
        switch self {
        case let .webSocket(_, _, _, _, servers):
            servers
        }
    }
}
