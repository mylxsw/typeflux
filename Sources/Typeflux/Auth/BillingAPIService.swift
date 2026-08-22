import Foundation
import os

struct BillingAPIService: Sendable {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "BillingAPIService")

    private let executor: CloudRequestExecutor
    private let retrySleep: RequestRetry.SleepClosure

    init(
        executor: CloudRequestExecutor = CloudRequestExecutor(),
        retrySleep: @escaping RequestRetry.SleepClosure = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.executor = executor
        self.retrySleep = retrySleep
    }

    func fetchSubscription(token: String) async throws -> BillingSubscriptionSnapshot {
        try await RequestRetry.perform(
            operationName: "Billing subscription refresh",
            shouldRetry: { error in Self.isRetryableAvailabilityError(error) },
            sleep: retrySleep
        ) {
            try await execute(path: "/api/v1/billing/subscription", method: "GET", token: token, body: nil)
        }
    }

    func createCheckoutSession(token: String, planCode: String) async throws -> BillingCheckoutSession {
        let body = try encode(BillingCheckoutSessionRequest(planCode: planCode))
        return try await execute(path: "/api/v1/billing/checkout-session", method: "POST", token: token, body: body)
    }

    func createPortalSession(token: String) async throws -> BillingPortalSession {
        try await execute(path: "/api/v1/billing/portal-session", method: "POST", token: token, body: Data("{}".utf8))
    }

    func requestBillingPageToken(token: String) async throws -> BillingPageTokenResponse {
        try await execute(path: "/api/v1/billing/page-token", method: "POST", token: token, body: Data("{}".utf8))
    }

    static func fetchSubscription(token: String) async throws -> BillingSubscriptionSnapshot {
        try await BillingAPIService().fetchSubscription(token: token)
    }

    static func createCheckoutSession(token: String, planCode: String) async throws -> BillingCheckoutSession {
        try await BillingAPIService().createCheckoutSession(token: token, planCode: planCode)
    }

    static func createPortalSession(token: String) async throws -> BillingPortalSession {
        try await BillingAPIService().createPortalSession(token: token)
    }

    static func requestBillingPageToken(token: String) async throws -> BillingPageTokenResponse {
        try await BillingAPIService().requestBillingPageToken(token: token)
    }

    private func encode(_ body: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw AuthError.networkError(error)
        }
    }

    private func execute<Response: Decodable>(
        path: String,
        method: String,
        token: String,
        body: Data?
    ) async throws -> Response {
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await executor.execute(apiPath: path) { baseURL in
                let url = AuthEndpointResolver.resolve(baseURL: baseURL, path: path)
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = 30
                return request
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let CloudRequestExecutorError.allEndpointsFailed(lastError) {
            Self.logger.error("All billing endpoints failed: \(lastError.localizedDescription)")
            throw Self.availabilityError(for: lastError)
        } catch {
            Self.logger.error("Billing network error: \(error.localizedDescription)")
            throw Self.availabilityError(for: error)
        }

        let envelope: APIResponse<Response>
        do {
            envelope = try JSONDecoder().decode(APIResponse<Response>.self, from: data)
        } catch {
            Self.logger.error("Billing decoding error: \(error.localizedDescription)")
            throw AuthError.serverError(code: "BILLING_SERVICE_UNAVAILABLE", message: nil)
        }

        if httpResponse.statusCode == 401 {
            throw AuthError.unauthorized
        }

        guard httpResponse.statusCode >= 200, httpResponse.statusCode < 300,
              envelope.code == "OK",
              let responseData = envelope.data
        else {
            throw AuthError.serverError(code: envelope.code, message: envelope.message)
        }

        return responseData
    }

    private static func availabilityError(for error: Error) -> AuthError {
        let nsError = error as NSError
        let code = nsError.domain == NSURLErrorDomain
            ? "BILLING_CONNECTION_UNAVAILABLE"
            : "BILLING_SERVICE_UNAVAILABLE"
        return AuthError.serverError(code: code, message: nil)
    }

    private static func isRetryableAvailabilityError(_ error: Error) -> Bool {
        guard let authError = error as? AuthError else { return false }
        return authError.authErrorCode == "BILLING_CONNECTION_UNAVAILABLE"
            || authError.authErrorCode == "BILLING_SERVICE_UNAVAILABLE"
    }
}
