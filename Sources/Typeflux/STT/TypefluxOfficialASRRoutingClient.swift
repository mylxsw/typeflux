import Foundation

enum TypefluxOfficialASRRouteDecision: Equatable, Sendable {
    case webSocket(token: String, tokenType: String, expiresAt: Int64?, expiresInSeconds: Int?, serverBaseURLs: [URL])
}

protocol TypefluxOfficialASRRoutingClient: Sendable {
    func fetchRoute(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision
}

enum TypefluxOfficialASRRoutingError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case serverError(code: String, message: String?)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Received an invalid Typeflux Cloud ASR token response."
        case .unauthorized:
            "Please sign in to use Typeflux Cloud speech recognition."
        case let .serverError(code, message):
            TypefluxCloudServerErrorMessage.userMessage(
                code: code,
                message: message,
                fallback: "Typeflux Cloud ASR token request failed."
            )
        case .missingToken:
            "Typeflux Cloud did not return a temporary ASR token."
        }
    }
}

struct TypefluxOfficialASRRoutingHTTPClient: TypefluxOfficialASRRoutingClient {
    private let executor: CloudRequestExecutor

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) {
        self.executor = executor
    }

    func fetchRoute(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        let (data, response) = try await executor.execute(apiPath: "/api/v1/asr/token") { baseURL in
            var request = URLRequest(url: AuthEndpointResolver.resolve(
                baseURL: baseURL,
                path: "/api/v1/asr/token"
            ))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: TypefluxOfficialASRRequestFactory.traceIDHeader)
            TypefluxCloudRequestHeaders.applyScenario(scenario, to: &request)
            return request
        }

        let envelope = try decodeEnvelope(ASRTokenResponse.self, from: data)
        if response.statusCode == 401 {
            throw TypefluxOfficialASRRoutingError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode), envelope.code == "OK", let payload = envelope.data else {
            throw TypefluxOfficialASRRoutingError.serverError(code: envelope.code, message: envelope.message)
        }

        let token = payload.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw TypefluxOfficialASRRoutingError.missingToken
        }
        return .webSocket(
            token: token,
            tokenType: payload.tokenType.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: payload.expiresAt,
            expiresInSeconds: payload.expiresInSeconds,
            serverBaseURLs: TypefluxASRServerURLNormalizer.normalizedURLs(from: payload.server)
        )
    }

    private func decodeEnvelope<T: Decodable>(_: T.Type, from data: Data) throws -> APIResponse<T> {
        do {
            return try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            throw TypefluxOfficialASRRoutingError.invalidResponse
        }
    }
}

private struct ASRTokenResponse: Decodable {
    let token: String
    let tokenType: String
    let expiresAt: Int64?
    let expiresInSeconds: Int?
    let server: [String]

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case expiresAt = "expires_at"
        case expiresInSeconds = "expires_in_seconds"
        case server
    }
}
