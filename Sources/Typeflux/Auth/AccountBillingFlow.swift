import Foundation

enum AccountBillingFlow {
    static let billingPlansBaseURL = URL(string: "https://typeflux.app/billing/plans")!

    static func destination(
        for action: AccountSubscriptionPresentation.BillingAction,
        requestBillingPageToken: () async throws -> String,
        createPortalSession: () async throws -> URL,
        billingPlansBaseURL: URL = billingPlansBaseURL
    ) async throws -> URL {
        switch action {
        case .subscribe:
            let token = try await requestBillingPageToken()
            return try billingPlansURL(token: token, baseURL: billingPlansBaseURL)
        case .manageBilling:
            return try await createPortalSession()
        }
    }

    static func billingPlansURL(token: String, baseURL: URL = billingPlansBaseURL) throws -> URL {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw AuthError.serverError(code: "BILLING_PAGE_UNAVAILABLE", message: nil)
        }

        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "t", value: token)]
        guard let encodedFragment = fragment.percentEncodedQuery else {
            throw AuthError.serverError(code: "BILLING_PAGE_UNAVAILABLE", message: nil)
        }
        components.percentEncodedFragment = encodedFragment

        guard let url = components.url else {
            throw AuthError.serverError(code: "BILLING_PAGE_UNAVAILABLE", message: nil)
        }
        return url
    }
}
