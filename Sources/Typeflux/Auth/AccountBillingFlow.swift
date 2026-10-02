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
}
