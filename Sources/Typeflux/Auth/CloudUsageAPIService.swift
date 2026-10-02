import Foundation
import os

struct CloudUsageAPIService: Sendable {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudUsageAPIService")

    private let executor: CloudRequestExecutor

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) {
        self.executor = executor
    }

    func fetchCurrentPeriodStats(token: String) async throws -> CloudUsageCurrentPeriodStats {
        try await execute(path: "/api/v1/usage/current-period/stats", token: token)
    }

    static func fetchCurrentPeriodStats(token: String) async throws -> CloudUsageCurrentPeriodStats {
        try await CloudUsageAPIService().fetchCurrentPeriodStats(token: token)
    }

    /// Credits per local day and per feature, bucketed in `timeZone`.
    func fetchCurrentPeriodBreakdown(token: String, timeZone: TimeZone) async throws -> CloudUsageBreakdown {
        try await execute(
            path: "/api/v1/usage/current-period/breakdown",
            token: token,
            query: [URLQueryItem(name: "tz", value: timeZone.identifier)]
        )
    }

    static func fetchCurrentPeriodBreakdown(token: String, timeZone: TimeZone) async throws -> CloudUsageBreakdown {
        try await CloudUsageAPIService().fetchCurrentPeriodBreakdown(token: token, timeZone: timeZone)
    }

    private func execute<Response: Decodable>(
        path: String,
        token: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await executor.execute(apiPath: path) { baseURL in
                var resolvedURL = AuthEndpointResolver.resolve(baseURL: baseURL, path: path)
                if !query.isEmpty,
                   var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) {
                    components.queryItems = query
                    resolvedURL = components.url ?? resolvedURL
                }
                var request = URLRequest(url: resolvedURL)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 30
                return request
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let CloudRequestExecutorError.allEndpointsFailed(lastError) {
            Self.logger.error("All usage endpoints failed: \(lastError.localizedDescription)")
            throw AuthError.networkError(lastError)
        } catch {
            Self.logger.error("Usage network error: \(error.localizedDescription)")
            throw AuthError.networkError(error)
        }

        if httpResponse.statusCode == 401 {
            throw AuthError.unauthorized
        }

        if httpResponse.statusCode >= 200, httpResponse.statusCode < 300 {
            if let envelope = try? JSONDecoder().decode(APIResponse<Response>.self, from: data),
               envelope.code == "OK",
               let responseData = envelope.data {
                return responseData
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                Self.logger.error("Usage decoding error: \(error.localizedDescription)")
                throw AuthError.invalidResponse
            }
        }

        if let envelope = try? JSONDecoder().decode(APIResponse<Response>.self, from: data) {
            throw AuthError.serverError(code: envelope.code, message: envelope.message)
        }
        throw AuthError.invalidResponse
    }
}
