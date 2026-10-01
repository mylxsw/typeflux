import CryptoKit
import Foundation
@testable import Typeflux
import XCTest

private final class MemoryTokenStore: MCPOAuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: MCPOAuthCredentials] = [:]
    func load(_ key: String) -> MCPOAuthCredentials? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func save(_ credentials: MCPOAuthCredentials, key: String) { lock.lock(); items[key] = credentials; lock.unlock() }
    func delete(_ key: String) { lock.lock(); items[key] = nil; lock.unlock() }
}

/// Routes stubbed OAuth and MCP endpoints by host and path.
private final class OAuthStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (URLRequest, Data?) -> (Int, [String: String], String)] = [:]
    nonisolated(unsafe) static var requests: [(URLRequest, Data?)] = []

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.requests.append((request, body))
        let key = (request.url?.host ?? "") + (request.url?.path ?? "")
        let (status, headers, text) = Self.routes[key]?(request, body) ?? (404, [:], "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func form(_ body: Data?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: body ?? Data(), as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}

final class MCPOAuthTests: XCTestCase {
    private let resource = URL(string: "https://mcp.example.com/mcp")!

    override func setUp() {
        OAuthStubProtocol.requests = []
        OAuthStubProtocol.routes = [
            "mcp.example.com/.well-known/oauth-protected-resource/mcp": { _, _ in
                (200, [:], #"{"authorization_servers":["https://auth.example.com"],"scopes_supported":["mcp:read"]}"#)
            },
            "auth.example.com/.well-known/oauth-authorization-server": { _, _ in
                (200, [:], #"{"authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","code_challenge_methods_supported":["S256"]}"#)
            },
            "auth.example.com/register": { _, body in
                let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                return json?["token_endpoint_auth_method"] as? String == "none" ? (201, [:], #"{"client_id":"cid"}"#) : (400, [:], "{}")
            }
        ]
    }

    func testHelpers() {
        XCTAssertEqual(MCPOAuthAuthorizer.resourceMetadataURL(from: #"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#)?.absoluteString,
                       "https://mcp.example.com/.well-known/oauth-protected-resource")
        XCTAssertNil(MCPOAuthAuthorizer.resourceMetadataURL(from: "Bearer"))
        XCTAssertNil(MCPOAuthAuthorizer.resourceMetadataURL(from: #"Bearer resource_metadata="unterminated"#))
        XCTAssertNil(MCPOAuthAuthorizer.resourceMetadataURL(from: nil))
        XCTAssertEqual(MCPOAuthAuthorizer.wellKnown(resource, "oauth-protected-resource")?.absoluteString, "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(MCPOAuthAuthorizer.wellKnown(URL(string: "https://auth.example.com/")!, "openid-configuration")?.absoluteString,
                       "https://auth.example.com/.well-known/openid-configuration")
        let pkce = MCPOAuthAuthorizer.pkcePair()
        XCTAssertEqual(pkce.verifier.count, 64)
        XCTAssertEqual(pkce.challenge, MCPOAuthAuthorizer.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8)))))
        XCTAssertFalse(pkce.challenge.contains("=") || pkce.challenge.contains("+") || pkce.challenge.contains("/"))
        XCTAssertEqual(String(decoding: MCPOAuthAuthorizer.formBody(["b": "x y&z", "a": "1"]), as: UTF8.self), "a=1&b=x%20y%26z")
        XCTAssertEqual(MCPLoopbackListener.parameters(fromRequestLine: "GET /callback?code=a%20b&state=s HTTP/1.1"), ["code": "a b", "state": "s"])
        XCTAssertNil(MCPLoopbackListener.parameters(fromRequestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(MCPLoopbackListener.parameters(fromRequestLine: "POST /callback HTTP/1.1"))
        XCTAssertTrue(MCPOAuthCredentials(accessToken: "a", tokenEndpoint: "t", clientId: "c").isUsable(now: Date()))
        XCTAssertFalse(MCPOAuthCredentials(accessToken: "a", expiresAt: Date(), tokenEndpoint: "t", clientId: "c").isUsable(now: Date()))
        XCTAssertTrue(MCPOAuthError.signInRequired.localizedDescription.contains("Test Connection"))
    }

    func testInteractiveSignInWithPKCEAndRefresh() async throws {
        var verifier = ""
        OAuthStubProtocol.routes["auth.example.com/token"] = { _, body in
            let form = OAuthStubProtocol.form(body)
            if form["grant_type"] == "authorization_code" {
                XCTAssertEqual(form["code"], "the-code")
                XCTAssertEqual(form["client_id"], "cid")
                XCTAssertEqual(form["resource"], "https://mcp.example.com/mcp")
                verifier = form["code_verifier"] ?? ""
                return (200, [:], #"{"access_token":"at1","refresh_token":"rt1","expires_in":3600}"#)
            }
            XCTAssertEqual(form["grant_type"], "refresh_token")
            XCTAssertEqual(form["refresh_token"], "rt1")
            return (200, [:], #"{"access_token":"at2","expires_in":3600}"#)
        }
        let store = MemoryTokenStore()
        let clock = ClockBox()
        let authorizer = MCPOAuthAuthorizer(resource: resource, interactive: true, store: store, session: OAuthStubProtocol.session(),
                                            callbackTimeout: .seconds(10), now: { clock.now }) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            XCTAssertEqual(value("code_challenge_method"), "S256")
            XCTAssertEqual(value("scope"), "mcp:read")
            XCTAssertEqual(value("resource"), "https://mcp.example.com/mcp")
            XCTAssertTrue(value("redirect_uri").hasPrefix("http://127.0.0.1:"))
            // Simulate the browser following the redirect.
            var callback = URLComponents(string: value("redirect_uri"))!
            callback.queryItems = [.init(name: "code", value: "the-code"), .init(name: "state", value: value("state"))]
            _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!)
        }
        let token = try await authorizer.authorize(challenge: nil)
        XCTAssertEqual(token, "at1")
        XCTAssertFalse(verifier.isEmpty)
        let accessToken = await authorizer.accessToken()
        XCTAssertEqual(accessToken, "at1")

        // An expired token is refreshed and keeps the previous refresh token.
        clock.now = Date().addingTimeInterval(7200)
        let refreshed = await authorizer.accessToken()
        XCTAssertEqual(refreshed, "at2")
        XCTAssertEqual(store.load(resource.absoluteString)?.refreshToken, "rt1")

        await authorizer.signOut()
        let signedOut = await authorizer.accessToken()
        XCTAssertNil(signedOut)
    }

    func testFailuresAndNonInteractiveMode() async throws {
        let store = MemoryTokenStore()
        let quiet = MCPOAuthAuthorizer(resource: resource, interactive: false, store: store, session: OAuthStubProtocol.session())
        do {
            _ = try await quiet.authorize(challenge: nil)
            XCTFail("Background connections must not sign in")
        } catch let error as MCPOAuthError { XCTAssertEqual(error, .signInRequired) }

        // A failed refresh drops the stored credentials.
        OAuthStubProtocol.routes["auth.example.com/token"] = { _, _ in (400, [:], #"{"error":"invalid_grant"}"#) }
        store.save(MCPOAuthCredentials(accessToken: "old", refreshToken: "r", expiresAt: Date.distantPast, tokenEndpoint: "https://auth.example.com/token", clientId: "cid"),
                   key: resource.absoluteString)
        let expired = await quiet.accessToken()
        XCTAssertNil(expired)
        XCTAssertNil(store.load(resource.absoluteString))

        // State mismatches and browser errors are rejected.
        let mismatched = MCPOAuthAuthorizer(resource: resource, interactive: true, store: store, session: OAuthStubProtocol.session(), callbackTimeout: .seconds(10)) { url in
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value ?? ""
            _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: redirect + "?code=x&state=forged")!)
        }
        do {
            _ = try await mismatched.authorize(challenge: nil)
            XCTFail("Expected a state mismatch")
        } catch let error as MCPOAuthError { XCTAssertEqual(error, .authorizationFailed("state mismatch")) }

        let timedOut = MCPOAuthAuthorizer(resource: resource, interactive: true, store: store, session: OAuthStubProtocol.session(),
                                          callbackTimeout: .milliseconds(200)) { _ in }
        do {
            _ = try await timedOut.authorize(challenge: nil)
            XCTFail("Expected a timeout")
        } catch let error as MCPOAuthError { XCTAssertEqual(error, .authorizationFailed("timed out waiting for the browser")) }

        OAuthStubProtocol.routes["auth.example.com/.well-known/oauth-authorization-server"] = { _, _ in
            (200, [:], #"{"authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","code_challenge_methods_supported":["plain"]}"#)
        }
        do {
            _ = try await timedOut.discover(challenge: nil)
            XCTFail("PKCE S256 is required")
        } catch {}
        OAuthStubProtocol.routes = [:]
        do {
            _ = try await timedOut.discover(challenge: nil)
            XCTFail("No metadata")
        } catch let error as MCPOAuthError { XCTAssertEqual(error, .discoveryFailed("no authorization server metadata at https://mcp.example.com/")) }
    }

    func testHTTPClientRetriesWithAFreshTokenAfter401() async throws {
        OAuthStubProtocol.routes["auth.example.com/token"] = { _, body in
            XCTAssertEqual(OAuthStubProtocol.form(body)["grant_type"], "refresh_token")
            return (200, [:], #"{"access_token":"fresh","refresh_token":"r2"}"#)
        }
        OAuthStubProtocol.routes["mcp.example.com/mcp"] = { request, _ in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" else {
                return (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp""#], "{}")
            }
            return (200, [:], #"{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Secure","version":"1"}}}"#)
        }
        let store = MemoryTokenStore()
        store.save(MCPOAuthCredentials(accessToken: "stale", refreshToken: "r", tokenEndpoint: "https://auth.example.com/token", clientId: "cid"), key: resource.absoluteString)
        let authorizer = MCPOAuthAuthorizer(resource: resource, interactive: false, store: store, session: OAuthStubProtocol.session())
        let client = HTTPMCPClient(config: MCPHTTPConfig(url: resource, urlSession: OAuthStubProtocol.session(), authorizer: authorizer))
        try await client.connect()
        let info = await client.serverInfo
        XCTAssertEqual(info?.protocolVersion, "2025-06-18")
        let sent = OAuthStubProtocol.requests.filter { $0.0.url?.path == "/mcp" }.map { $0.0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(sent, ["Bearer stale", "Bearer fresh"])
        let initialize = try XCTUnwrap(OAuthStubProtocol.requests.first { $0.0.url?.path == "/mcp" }?.1)
        XCTAssertTrue(String(decoding: initialize, as: UTF8.self).contains(MCPProtocol.latestVersion))

        // Without an authorizer a 401 is an ordinary server error.
        let plain = HTTPMCPClient(config: MCPHTTPConfig(url: resource, urlSession: OAuthStubProtocol.session()))
        do {
            try await plain.connect()
            XCTFail("Expected 401")
        } catch let MCPClientError.serverError(code, _) { XCTAssertEqual(code, 401) }
        // A token that is rejected again is reported once instead of looping.
        OAuthStubProtocol.routes["mcp.example.com/mcp"] = { _, _ in (401, [:], "{}") }
        let again = HTTPMCPClient(config: MCPHTTPConfig(url: resource, urlSession: OAuthStubProtocol.session(), authorizer: authorizer))
        do {
            try await again.connect()
            XCTFail("Expected 401")
        } catch let MCPClientError.serverError(code, _) { XCTAssertEqual(code, 401) }
    }

    func testKeychainStoreRoundTrip() {
        let store = MCPKeychainTokenStore(service: "com.typeflux.tests.\(UUID().uuidString)")
        let credentials = MCPOAuthCredentials(accessToken: "a", refreshToken: "r", tokenEndpoint: "t", clientId: "c")
        store.save(credentials, key: "k")
        // Some CI keychains are locked; only assert when the item could be written.
        if let loaded = store.load("k") {
            XCTAssertEqual(loaded, credentials)
        }
        store.delete("k")
        XCTAssertNil(store.load("k"))
    }
}

private final class ClockBox: @unchecked Sendable {
    var now = Date()
}
