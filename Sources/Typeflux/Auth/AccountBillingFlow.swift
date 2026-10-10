import Foundation

enum AccountBillingFlow {
    static func destination(
        for action: AccountSubscriptionPresentation.BillingAction,
        requestBillingPageToken: () async throws -> URL,
        createPortalSession: () async throws -> URL
    ) async throws -> URL {
        switch action {
        case .subscribe:
            return try await requestBillingPageToken()
        case .manageBilling:
            return try await createPortalSession()
        }
    }

    static func destination(
        for target: AccountStatusPresentation.Destination,
        requestBillingPageToken: () async throws -> URL,
        createPortalSession: () async throws -> URL
    ) async throws -> URL {
        try await destination(
            for: target == .plans ? .subscribe : .manageBilling,
            requestBillingPageToken: requestBillingPageToken,
            createPortalSession: createPortalSession
        )
    }

    /// Resolves a billing link with `request` and hands it to `onLink`, or its
    /// failure to `onFailure`. A request whose session was logged out or
    /// replaced meanwhile ends with neither: its link and its error belong to
    /// the old account, not to whoever is signed in now.
    @MainActor
    static func open(
        _ request: () async throws -> URL,
        onLink: (URL) -> Void,
        onFailure: (Error) -> Void
    ) async {
        let url: URL
        do {
            url = try await request()
        } catch is BillingSessionReplacedError {
            return
        } catch {
            onFailure(error)
            return
        }
        onLink(url)
    }

    /// Opens `target` for `auth`'s current session, as `open(_:onLink:onFailure:)`.
    @MainActor
    static func open(
        _ target: AccountStatusPresentation.Destination,
        for auth: AuthState,
        onLink: (URL) -> Void,
        onFailure: (Error) -> Void
    ) async {
        await open(
            {
                try await destination(
                    for: target,
                    requestBillingPageToken: { try await auth.requestBillingPageToken() },
                    createPortalSession: { try await auth.createBillingPortalSession() }
                )
            },
            onLink: onLink,
            onFailure: onFailure
        )
    }
}
