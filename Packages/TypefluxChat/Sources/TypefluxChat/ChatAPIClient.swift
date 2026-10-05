import Foundation

/// The app owns credentials and lifecycle. No globals, token persistence, detached
/// work or automatic mutation retries live in the shared client.
public protocol ChatAPI: Sendable {
    func login(email: String, password: String) async throws -> ChatSession
    func refresh(refreshToken: String) async throws -> ChatSession
    func logout(refreshToken: String) async throws
    func models(token: String) async throws -> [ChatModel]
    func list(token: String, offset: Int) async throws -> [ChatConversationSummary]
    func conversation(id: String, token: String) async throws -> ChatConversation
    func send(conversationId: String, request: ChatSendRequest, token: String) async throws -> ChatConversation
    func cancel(conversationId: String, runId: String, token: String) async throws -> ChatConversation
    func observe(id: String, token: String, onValue: @Sendable (ChatConversation) async throws -> Void) async throws
    func googleLogin(identityToken: String) async throws -> ChatSession
    func appleLogin(identityToken: String) async throws -> ChatSession
    func forgotPassword(email: String) async throws
    func resetPassword(email: String, code: String, newPassword: String) async throws
    func profile(token: String) async throws -> ChatProfile
    func creditUsage(token: String) async throws -> ChatCreditUsage
    func regenerate(conversationId: String, request: ChatRegenerateRequest, token: String) async throws -> ChatConversation
    func deleteConversation(id: String, token: String) async throws
}

/// Account and history extras are optional for test doubles and older fixtures:
/// an implementation that does not provide them reports the feature unavailable.
public extension ChatAPI {
    func googleLogin(identityToken _: String) async throws -> ChatSession { throw ChatAPIError.unavailable }
    func appleLogin(identityToken _: String) async throws -> ChatSession { throw ChatAPIError.unavailable }
    func forgotPassword(email _: String) async throws { throw ChatAPIError.unavailable }
    func resetPassword(email _: String, code _: String, newPassword _: String) async throws {
        throw ChatAPIError.unavailable
    }
    func profile(token _: String) async throws -> ChatProfile { throw ChatAPIError.unavailable }
    func creditUsage(token _: String) async throws -> ChatCreditUsage { throw ChatAPIError.unavailable }
    func regenerate(conversationId _: String, request _: ChatRegenerateRequest,
                    token _: String) async throws -> ChatConversation { throw ChatAPIError.unavailable }
    func deleteConversation(id _: String, token _: String) async throws { throw ChatAPIError.unavailable }
}

public struct ChatAPIClient: ChatAPI {
    public let baseURL: URL
    private let session: URLSession
    private let clientVersion: String
    private let deviceId: String?

    public init(baseURL: URL, session: URLSession = .shared, clientVersion: String = "1.0", deviceId: String? = nil) {
        self.baseURL = baseURL; self.session = session; self.clientVersion = clientVersion; self.deviceId = deviceId
    }

    public func login(email: String, password: String) async throws -> ChatSession {
        struct Login: Encodable { let email: String; let password: String }
        return try await execute(path: "/api/v1/auth/login", method: "POST",
                                 body: ChatCoding.encoder().encode(Login(email: email, password: password)),
                                 decoder: JSONDecoder())
    }

    public func refresh(refreshToken: String) async throws -> ChatSession {
        try await execute(path: "/api/v1/auth/refresh", method: "POST", body: refreshBody(refreshToken), decoder: JSONDecoder())
    }

    public func logout(refreshToken: String) async throws {
        struct LoggedOut: Decodable { let loggedOut: Bool }
        let _: LoggedOut = try await execute(path: "/api/v1/auth/logout", method: "POST", body: refreshBody(refreshToken))
    }

    public func models(token: String) async throws -> [ChatModel] {
        try await execute(path: ChatRequest.conversationsPath + "/models", token: token)
    }

    public func list(token: String, offset: Int = 0) async throws -> [ChatConversationSummary] {
        try await execute(path: ChatRequest.conversationsPath + "?offset=\(max(0, offset))", token: token)
    }

    public func conversation(id: String, token: String) async throws -> ChatConversation {
        try await execute(path: conversationPath(id), token: token)
    }

    public func send(conversationId: String, request: ChatSendRequest, token: String) async throws -> ChatConversation {
        try await execute(path: conversationPath(conversationId) + "/messages", method: "POST",
                          body: ChatCoding.encoder().encode(request), token: token)
    }

    public func cancel(conversationId: String, runId: String, token: String) async throws -> ChatConversation {
        struct Cancel: Encodable { let runId: String }
        return try await execute(path: conversationPath(conversationId) + "/cancel", method: "POST",
                                 body: ChatCoding.encoder().encode(Cancel(runId: runId)), token: token)
    }

    public func googleLogin(identityToken: String) async throws -> ChatSession {
        struct OAuth: Encodable { let idToken: String }
        return try await execute(path: "/api/v1/auth/oauth/google", method: "POST",
                                 body: ChatCoding.encoder().encode(OAuth(idToken: identityToken)), decoder: JSONDecoder())
    }

    public func appleLogin(identityToken: String) async throws -> ChatSession {
        struct OAuth: Encodable { let idToken: String }
        return try await execute(path: "/api/v1/auth/oauth/apple", method: "POST",
                                 body: ChatCoding.encoder().encode(OAuth(idToken: identityToken)),
                                 decoder: JSONDecoder())
    }

    public func forgotPassword(email: String) async throws {
        struct Forgot: Encodable { let email: String }
        struct Sent: Decodable { let sent: Bool }
        let _: Sent = try await execute(path: "/api/v1/auth/forgot-password", method: "POST",
                                        body: ChatCoding.encoder().encode(Forgot(email: email)))
    }

    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        struct Reset: Encodable { let email: String; let code: String; let newPassword: String }
        struct Done: Decodable { let reset: Bool }
        let _: Done = try await execute(path: "/api/v1/auth/reset-password", method: "POST",
                                        body: ChatCoding.encoder().encode(Reset(email: email, code: code,
                                                                                newPassword: newPassword)))
    }

    public func profile(token: String) async throws -> ChatProfile {
        try await execute(path: "/api/v1/me", token: token)
    }

    public func creditUsage(token: String) async throws -> ChatCreditUsage {
        try await execute(path: "/api/v1/usage/current-period/stats", token: token)
    }

    public func regenerate(conversationId: String, request: ChatRegenerateRequest,
                           token: String) async throws -> ChatConversation {
        try await execute(path: conversationPath(conversationId) + "/regenerate", method: "POST",
                          body: ChatCoding.encoder().encode(request), token: token)
    }

    public func deleteConversation(id: String, token: String) async throws {
        struct Deleted: Decodable { let deleted: Bool }
        let _: Deleted = try await execute(path: conversationPath(id), method: "DELETE", token: token)
    }

    public func observe(id: String, token: String, onValue: @Sendable (ChatConversation) async throws -> Void) async throws {
        try Task.checkCancellation()
        var headers = clientHeaders
        headers["Accept"] = "text/event-stream"
        let request = ChatRequest.make(baseURL: baseURL, path: conversationPath(id) + "/events", token: token,
                                           timeout: 40, headers: headers)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        if http.statusCode == 401 { throw ChatAPIError.unauthorized }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw ChatAPIError.unavailable
        }
        var frame = SSEFrame(limit: 32_000_000)
        var state = ChatConversationStreamState()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let (event, data) = try frame.push(byte), let value = try state.consume(event: event, data: data) {
                try await onValue(value)
            }
        }
        try Task.checkCancellation()
    }

    private func execute<Value: Decodable>(path: String, method: String = "GET", body: Data? = nil,
                                           token: String? = nil, decoder: JSONDecoder = ChatCoding.decoder()) async throws -> Value {
        try Task.checkCancellation()
        let request = ChatRequest.make(baseURL: baseURL, path: path, method: method, body: body,
                                           token: token, headers: clientHeaders)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        return try ChatRequest.decode(data: data, statusCode: http.statusCode, decoder: decoder)
    }

    private var clientHeaders: [String: String] {
        var headers = ["X-Typeflux-Model-Catalog": "1", "X-Scenario": "ask-anything",
                       "X-Client-OS": "iOS", "User-Agent": "Typeflux/\(clientVersion)"]
        if let deviceId { headers["X-Client-ID"] = deviceId }
        return headers
    }

    private func conversationPath(_ id: String) -> String {
        ChatRequest.conversationsPath + "/" + ChatRequest.pathComponent(id)
    }

    private func refreshBody(_ token: String) throws -> Data {
        struct Refresh: Encodable { let refreshToken: String }
        return try ChatCoding.encoder().encode(Refresh(refreshToken: token))
    }
}
