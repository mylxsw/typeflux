import Foundation

struct CloudDataSyncAPIService: Sendable {
    private let executor: CloudRequestExecutor

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) {
        self.executor = executor
    }

    static func sync(token: String, request: CloudSyncRequest) async throws -> CloudSyncResponse {
        try await CloudDataSyncAPIService().sync(token: token, request: request)
    }

    static func reset(token: String) async throws -> CloudSyncResetResponse {
        try await CloudDataSyncAPIService().reset(token: token)
    }

    func sync(token: String, request: CloudSyncRequest) async throws -> CloudSyncResponse {
        let payload = try JSONEncoder.cloudSync.encode(request)
        let path = "/api/v1/sync"
        let (data, response) = try await executor.execute(apiPath: path) { baseURL in
            var urlRequest = URLRequest(
                url: AuthEndpointResolver.resolve(baseURL: baseURL, path: path)
            )
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.httpBody = payload
            urlRequest.timeoutInterval = 30
            return urlRequest
        }
        guard response.statusCode >= 200, response.statusCode < 300 else {
            throw AuthError.invalidResponse
        }
        let envelope = try JSONDecoder.cloudSync.decode(APIResponse<CloudSyncResponse>.self, from: data)
        guard envelope.code == "OK", let result = envelope.data else { throw AuthError.invalidResponse }
        return result
    }

    func reset(token: String) async throws -> CloudSyncResetResponse {
        let path = "/api/v1/sync"
        let (data, response) = try await executor.execute(apiPath: path) { baseURL in
            var request = URLRequest(url: AuthEndpointResolver.resolve(baseURL: baseURL, path: path))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            return request
        }
        guard response.statusCode >= 200, response.statusCode < 300 else {
            throw AuthError.invalidResponse
        }
        let envelope = try JSONDecoder.cloudSync.decode(APIResponse<CloudSyncResetResponse>.self, from: data)
        guard envelope.code == "OK", let result = envelope.data else { throw AuthError.invalidResponse }
        return result
    }
}

private extension JSONEncoder {
    static var cloudSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cloudSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
