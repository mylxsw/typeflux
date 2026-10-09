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
        if let initial {
            self.initial = nil
            return initial
        }
        do {
            return try await Grant(route: fetch())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TypefluxOfficialASRGrantRefreshError(underlying: error)
        }
    }
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
