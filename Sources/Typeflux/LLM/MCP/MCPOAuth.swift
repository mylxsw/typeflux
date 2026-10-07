import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Tokens and the registered client for one MCP server.
struct MCPOAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientId: String
    var clientSecret: String?

    func isUsable(now: Date) -> Bool { expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? true }
}

protocol MCPOAuthTokenStore: Sendable {
    func load(_ key: String) -> MCPOAuthCredentials?
    func save(_ credentials: MCPOAuthCredentials, key: String)
    func delete(_ key: String)
}

/// Stores credentials in the login keychain, one item per server URL.
struct MCPKeychainTokenStore: MCPOAuthTokenStore {
    var service = "com.typeflux.mcp.oauth"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func load(_ key: String) -> MCPOAuthCredentials? {
        var item: CFTypeRef?
        var request = query(key)
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MCPOAuthCredentials.self, from: data)
    }

    func save(_ credentials: MCPOAuthCredentials, key: String) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(query(key) as CFDictionary)
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

enum MCPOAuthError: LocalizedError, Equatable {
    case signInRequired
    case discoveryFailed(String)
    case authorizationFailed(String)
    case tokenFailed(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "This MCP server needs you to sign in. Use Test Connection in Settings → Agent → MCP servers."
        case let .discoveryFailed(detail): "MCP sign-in is not available: \(detail)"
        case let .authorizationFailed(detail): "MCP sign-in failed: \(detail)"
        case let .tokenFailed(detail): "MCP sign-in token request failed: \(detail)"
        }
    }
}

/// OAuth 2.1 for remote MCP servers (MCP authorization, 2025-06-18): protected
/// resource and authorization server discovery, dynamic client registration,
/// PKCE with a loopback redirect, and refresh. Without `interactive`, it only
/// reuses or refreshes stored tokens and never opens a browser.
actor MCPOAuthAuthorizer {
    let resource: URL
    let interactive: Bool
    private let store: MCPOAuthTokenStore
    private let session: URLSession
    private let openBrowser: @Sendable (URL) async -> Void
    private let callbackTimeout: Duration
    private let now: @Sendable () -> Date

    init(resource: URL, interactive: Bool, store: MCPOAuthTokenStore = MCPKeychainTokenStore(), session: URLSession = .shared,
         callbackTimeout: Duration = .seconds(300), now: @escaping @Sendable () -> Date = { Date() },
         openBrowser: @escaping @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }) {
        self.resource = resource
        self.interactive = interactive
        self.store = store
        self.session = session
        self.callbackTimeout = callbackTimeout
        self.now = now
        self.openBrowser = openBrowser
    }

    private var key: String { resource.absoluteString }

    /// A stored token that is still valid, refreshed when possible.
    func accessToken() async -> String? {
        guard let stored = store.load(key) else { return nil }
        if stored.isUsable(now: now()) { return stored.accessToken }
        return try? await refresh(stored).accessToken
    }

    /// Called after a 401: refresh, or sign in when interactive.
    func authorize(challenge: String?) async throws -> String {
        if let stored = store.load(key), stored.refreshToken != nil, let refreshed = try? await refresh(stored) {
            return refreshed.accessToken
        }
        guard interactive else { throw MCPOAuthError.signInRequired }
        return try await signIn(challenge: challenge).accessToken
    }

    func signOut() { store.delete(key) }

    // MARK: - Discovery

    struct ServerMetadata: Decodable, Equatable {
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint", codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    /// Reads `resource_metadata="..."` from a WWW-Authenticate Bearer challenge.
    static func resourceMetadataURL(from challenge: String?) -> URL? {
        guard let challenge, let range = challenge.range(of: "resource_metadata=\"") else { return nil }
        let rest = challenge[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    static func wellKnown(_ base: URL, _ suffix: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path == "/" ? "" : components.path
        components.path = "/.well-known/" + suffix + path
        components.query = nil
        return components.url
    }

    private func getJSON(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) == true else {
            throw MCPOAuthError.discoveryFailed(url.absoluteString)
        }
        return data
    }

    func discover(challenge: String?) async throws -> (issuer: URL, metadata: ServerMetadata, scopes: [String]) {
        struct ResourceMetadata: Decodable {
            var authorizationServers: [String]?
            var scopesSupported: [String]?
            enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers", scopesSupported = "scopes_supported" }
        }
        var issuer = URL(string: "/", relativeTo: resource)!.absoluteURL
        var scopes: [String] = []
        let candidates = [Self.resourceMetadataURL(from: challenge), Self.wellKnown(resource, "oauth-protected-resource"),
                          Self.wellKnown(issuer, "oauth-protected-resource")].compactMap { $0 }
        for url in candidates {
            if let data = try? await getJSON(url), let meta = try? JSONDecoder().decode(ResourceMetadata.self, from: data) {
                if let server = meta.authorizationServers?.first.flatMap(URL.init(string:)) { issuer = server }
                scopes = meta.scopesSupported ?? []
                break
            }
        }
        for suffix in ["oauth-authorization-server", "openid-configuration"] {
            if let url = Self.wellKnown(issuer, suffix), let data = try? await getJSON(url),
               let metadata = try? JSONDecoder().decode(ServerMetadata.self, from: data) {
                if let methods = metadata.codeChallengeMethodsSupported, !methods.contains("S256") {
                    throw MCPOAuthError.discoveryFailed("the authorization server does not support PKCE S256")
                }
                return (issuer, metadata, scopes)
            }
        }
        throw MCPOAuthError.discoveryFailed("no authorization server metadata at \(issuer.absoluteString)")
    }

    // MARK: - Sign in

    static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        return (verifier, base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func register(_ metadata: ServerMetadata, redirect: String) async throws -> (id: String, secret: String?) {
        guard let endpoint = metadata.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw MCPOAuthError.discoveryFailed("the server does not support dynamic client registration")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Typeflux", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none"
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) == true,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = body["client_id"] as? String else {
            throw MCPOAuthError.authorizationFailed("client registration was rejected")
        }
        return (id, body["client_secret"] as? String)
    }

    func signIn(challenge: String?) async throws -> MCPOAuthCredentials {
        let (_, metadata, scopes) = try await discover(challenge: challenge)
        guard let authorizeURL = URL(string: metadata.authorizationEndpoint) else { throw MCPOAuthError.discoveryFailed("invalid authorization endpoint") }
        let listener = try MCPLoopbackListener()
        defer { listener.cancel() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        let client = try await register(metadata, redirect: redirect)
        let pkce = Self.pkcePair()
        let state = Self.base64URL(Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
            .init(name: "resource", value: resource.absoluteString)
        ] + (scopes.isEmpty ? [] : [.init(name: "scope", value: scopes.joined(separator: " "))])
        guard let url = components.url else { throw MCPOAuthError.authorizationFailed("invalid authorization URL") }
        await openBrowser(url)
        let callback = try await listener.waitForCallback(timeout: callbackTimeout)
        guard callback["state"] == state else { throw MCPOAuthError.authorizationFailed("state mismatch") }
        if let error = callback["error"] { throw MCPOAuthError.authorizationFailed(error) }
        guard let code = callback["code"] else { throw MCPOAuthError.authorizationFailed("no authorization code") }
        let credentials = try await requestToken(endpoint: metadata.tokenEndpoint, clientId: client.id, clientSecret: client.secret, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "code_verifier": pkce.verifier, "resource": resource.absoluteString
        ], previousRefresh: nil)
        store.save(credentials, key: key)
        return credentials
    }

    func refresh(_ stored: MCPOAuthCredentials) async throws -> MCPOAuthCredentials {
        guard let refreshToken = stored.refreshToken else { throw MCPOAuthError.signInRequired }
        do {
            let credentials = try await requestToken(endpoint: stored.tokenEndpoint, clientId: stored.clientId, clientSecret: stored.clientSecret, form: [
                "grant_type": "refresh_token", "refresh_token": refreshToken, "resource": resource.absoluteString
            ], previousRefresh: refreshToken)
            store.save(credentials, key: key)
            return credentials
        } catch {
            store.delete(key)
            throw error
        }
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    private func requestToken(endpoint: String, clientId: String, clientSecret: String?, form: [String: String],
                              previousRefresh: String?) async throws -> MCPOAuthCredentials {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError.tokenFailed("invalid token endpoint") }
        var form = form
        form["client_id"] = clientId
        if let clientSecret { form["client_secret"] = clientSecret }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody(form)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status), let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String else {
            throw MCPOAuthError.tokenFailed("HTTP \(status)")
        }
        let expires = (body["expires_in"] as? Double ?? (body["expires_in"] as? Int).map(Double.init)).map { now().addingTimeInterval($0) }
        return MCPOAuthCredentials(accessToken: access, refreshToken: body["refresh_token"] as? String ?? previousRefresh,
                                   expiresAt: expires, tokenEndpoint: endpoint, clientId: clientId, clientSecret: clientSecret)
    }
}

/// Accepts one OAuth redirect on 127.0.0.1 and answers with a short page.
final class MCPLoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "typeflux.mcp.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<UInt16, Error>) in
            let once = MCPOnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if once.claim() { started.resume(returning: self.listener.port?.rawValue ?? 0) }
                case let .failed(error):
                    if once.claim() { started.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    static func parameters(fromRequestLine line: String) -> [String: String]? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == "/callback" else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let params = Self.parameters(fromRequestLine: line)
            let page = params == nil ? "Not found" : "Typeflux is signed in. You can close this window."
            let response = "HTTP/1.1 \(params == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let params { self?.finish(.success(params)) }
        }
    }

    private func finish(_ value: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(MCPOAuthError.authorizationFailed("timed out waiting for the browser")))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    func cancel() { listener.cancel() }
}

/// Thread-safe one-shot flag.
final class MCPOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
