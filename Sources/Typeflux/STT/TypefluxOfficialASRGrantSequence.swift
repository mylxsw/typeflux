import Foundation

/// Hands out one-time ASR grants for a single recording.
///
/// The gateway claims a grant before it upgrades the WebSocket, and an
/// ambiguous failure may already have consumed it. The first connection
/// attempt therefore uses the route that selected the servers, and every
/// failover attempt fetches a fresh grant instead of replaying the old one.
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

    init(
        initial route: TypefluxOfficialASRRouteDecision,
        fetch: @escaping @Sendable () async throws -> TypefluxOfficialASRRouteDecision
    ) {
        initial = Grant(route: route)
        self.fetch = fetch
    }

    func next() async throws -> Grant {
        try Task.checkCancellation()
        if let initial {
            self.initial = nil
            return initial
        }
        let route: TypefluxOfficialASRRouteDecision
        do {
            route = try await fetch()
        } catch let error where TypefluxOfficialASRCancellation.isCancellation(error) {
            throw CancellationError()
        } catch {
            throw TypefluxOfficialASRGrantRefreshError(underlying: error)
        }
        // A recording cancelled while the grant was being issued must not
        // use it; an unclaimed grant costs nothing.
        try Task.checkCancellation()
        return Grant(route: route)
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
