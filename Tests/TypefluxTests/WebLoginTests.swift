import Foundation
import Testing
@testable import Typeflux

private let opaque = String(repeating: "a", count: 43)
private let proof = WebLoginProof(state: String(repeating: "s", count: 43), verifier: String(repeating: "v", count: 43))
private let clock = Date(timeIntervalSince1970: 1_800_000_000)
private func config(enabled: Bool = true, development: Bool = false) -> WebLoginConfiguration {
    .resolve(environment: ["TYPEFLUX_WEB_AUTH_ENABLED": enabled ? "true" : "false",
                           "TYPEFLUX_WEB_AUTH_CHANNEL": development ? "development" : "production"], info: [:])
}

private func transaction(url: String? = nil, expiry: TimeInterval = 1_800_000_600) -> WebLoginTransaction {
    .init(transactionID: opaque, loginURL: url ?? "https://typeflux.app/login?transaction=\(opaque)", expiresAt: expiry)
}

private func callback(_ query: String? = nil) -> URL {
    URL(string: "ai.gulu.app.typeflux://auth/callback?\(query ?? "code=\(opaque)&state=\(proof.state)")")!
}

@Suite("Web login protocol")
struct WebLoginProtocolTests {
    @Test func `pkce RFC vector and independent randomness`() throws {
        let vector = WebLoginProof(state: "state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(vector.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try WebLoginProof.generate()
        let second = try WebLoginProof.generate()
        #expect(first.state.count == 43 && first.verifier.count == 43 && first.challenge.count == 43)
        #expect(first.state != first.verifier && first.state != second.state)
        #expect(throws: WebLoginFailure.invalidResponse) { try WebLoginProof.generate { _ in Data() } }
        #expect(throws: WebLoginFailure.storageFailed) {
            try WebLoginProof.generate { _ in throw WebLoginFailure.storageFailed }
        }
    }

    @Test func `configuration is off by default and separates clients`() {
        let production = WebLoginConfiguration.resolve(environment: [:], info: [:])
        #expect(!production.enabled)
        #expect(production.clientID == "typeflux-macos")
        #expect(config(development: true).redirectURI == "ai.gulu.app.typeflux.dev://auth/callback")
        #expect(config(development: true).clientID == "typeflux-macos-dev")
        #expect(!config(development: true).matchesCallback(callback()))
        let override = WebLoginConfiguration.resolve(
            environment: ["TYPEFLUX_WEB_AUTH_ENABLED": "false"],
            info: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"]
        )
        #expect(!override.enabled)
        #expect(WebLoginConfiguration.resolve(environment: [:], info: ["TYPEFLUX_WEB_AUTH_ENABLED": "true"]).enabled)
    }

    @Test(arguments: [
        "ftp://typeflux.app",
        "https://user@typeflux.app",
        "https://typeflux.app/path",
        "https://typeflux.app?q=a",
        "https://typeflux.app#x",
        "file:///tmp/a"
    ])
    func `rejects invalid origin`(raw: String) throws {
        #expect(try !WebLoginConfiguration.isWebOrigin(#require(URL(string: raw))))
    }

    @Test(arguments: ["http://localhost:5174", "http://127.0.0.1:5174", "http://[::1]:5174", "http://typeflux.test", "http://typeflux.test:80"])
    func `HTTP transaction preserves exact configured origin`(origin: String) throws {
        let configuration = WebLoginConfiguration.resolve(environment: [
            "TYPEFLUX_WEB_AUTH_ENABLED": "true", "TYPEFLUX_WEB_AUTH_ORIGIN": origin,
            "TYPEFLUX_WEB_AUTH_API_ORIGIN": origin
        ], info: [:])
        let login = transaction(url: "\(origin)/login?transaction=\(opaque)")
        #expect(try configuration.validate(login, now: clock).scheme == "http")
        #expect(throws: WebLoginFailure.invalidResponse) {
            try configuration.validate(transaction(url: "https://localhost:5174/login?transaction=\(opaque)"), now: clock)
        }
    }

    @Test func `validates transaction and strict callback`() throws {
        #expect(try config().validate(transaction(), now: clock).host == "typeflux.app")
        let pending = PendingWebLogin(proof: proof, transaction: transaction())
        #expect(try pending.code(from: callback(), configuration: config(), now: clock) == opaque)
        #expect(throws: WebLoginFailure.expired) {
            try pending.code(from: callback(), configuration: config(), now: clock.addingTimeInterval(600))
        }
        for url in ["https://evil.test/login", "http://typeflux.app/login", "https://typeflux.app:444/login",
                    "https://user@typeflux.app/login", "https://typeflux.app/login/", "https://typeflux.app/%6cogin"] {
            #expect(throws: WebLoginFailure.invalidResponse) {
                try config().validate(transaction(url: "\(url)?transaction=\(opaque)"), now: clock)
            }
        }
        for suffix in ["&transaction=\(opaque)", "&extra=x", "#fragment", "x"] {
            #expect(throws: WebLoginFailure.invalidResponse) {
                try config().validate(transaction(url: transaction().loginURL + suffix), now: clock)
            }
        }
        for expiry in [clock.timeIntervalSince1970, clock.timeIntervalSince1970 + 1801] {
            #expect(throws: WebLoginFailure.invalidResponse) { try config().validate(
                transaction(expiry: expiry),
                now: clock
            ) }
        }
    }

    @Test(arguments: [
        "code=x&state=x",
        "code=&state=s",
        "code=x",
        "code=x&code=y&state=s",
        "code=x&state=s&state=s",
        "error=denied&state=s"
    ])
    func `rejects malformed queries`(query: String) {
        #expect(throws: WebLoginFailure.invalidCallback) {
            try PendingWebLogin(proof: proof, transaction: transaction()).code(
                from: callback(query),
                configuration: config(),
                now: clock
            )
        }
    }

    @Test(arguments: [
        "ai.gulu.app.typeflux://oauth/github",
        "ai.gulu.app.typeflux://auth/callback/",
        "ai.gulu.app.typeflux://auth/%63allback",
        "ai.gulu.app.typeflux://user@auth/callback",
        "ai.gulu.app.typeflux://auth:443/callback",
        "ai.gulu.app.typeflux://auth/callback#x",
        "typeflux://billing/return"
    ])
    func `rejects other routes`(raw: String) throws {
        #expect(try !config().matchesCallback(#require(URL(string: raw))))
    }
}

@MainActor
private final class FakeWebAPI: WebLoginAPI {
    var creates = 0
    var exchanges = 0
    var create: () async throws -> WebLoginTransaction = { transaction() }
    var exchange: () async throws -> LoginResponse = { .init(
        accessToken: "access",
        expiresAt: 1_800_003_600,
        refreshToken: "refresh"
    ) }
    var receivedVerifier: String?
    func create(proof _: WebLoginProof) async throws -> WebLoginTransaction {
        creates += 1; return try await create()
    }

    func exchange(code _: String, verifier: String) async throws -> LoginResponse {
        exchanges += 1; receivedVerifier = verifier; return try await exchange()
    }
}

@MainActor
private final class FakeBrowser: WebLoginBrowserSession {
    var canStart = true
    var starts = 0
    var cancels = 0
    var completion: ((URL?, Bool) -> Void)?
    func start() -> Bool {
        starts += 1; return canStart
    }

    func cancel() {
        cancels += 1
    }
}

@MainActor
private final class Harness {
    let api = FakeWebAPI()
    let browser = FakeBrowser()
    let store = WebLoginMemoryStore()
    var generation = 0
    var accepted = 0
    var time = clock
    var failure: WebLoginFailure?
    lazy var coordinator = WebLoginCoordinator(
        configuration: config(), api: api, store: store,
        browserFactory: { [unowned self] _, _, completion in browser.completion = completion; return browser },
        now: { [unowned self] in time }, makeProof: { proof },
        authGeneration: { [unowned self] in generation },
        accept: { [unowned self] _, expected in
            #expect(expected == generation)
            if let failure {
                throw failure
            }
            accepted += 1
        }
    )
}

@Suite("Web login state machine", .exclusiveUIState)
@MainActor
struct WebLoginCoordinatorTests {
    @Test func `success consumes once and clears verifier`() async {
        let h = Harness()
        await h.coordinator.start()
        #expect(h.coordinator.phase == .waiting)
        await h.coordinator.start()
        #expect(h.api.creates == 1)
        await h.coordinator.receive(callback())
        await h.coordinator.receive(callback())
        #expect(h.accepted == 1 && h.api.exchanges == 1)
        #expect(h.api.receivedVerifier == proof.verifier)
        #expect(h.store.pending == nil && h.coordinator.phase == .succeeded)
    }

    @Test func `cancellation during creation rejects late result`() async {
        let h = Harness()
        h.api.create = { h.coordinator.cancel(); return transaction() }
        await h.coordinator.start()
        #expect(h.coordinator.phase == .cancelled && h.browser.starts == 0)
        await h.coordinator.receive(callback())
        #expect(h.api.exchanges == 0)
    }

    @Test func `cancellation and logout during exchange reject late tokens`() async {
        for logout in [false, true] {
            let h = Harness()
            h.api.exchange = {
                if logout {
                    h.generation += 1
                } else {
                    h.coordinator.cancel()
                }
                return .init(accessToken: "late", expiresAt: 1_800_003_600, refreshToken: "refresh")
            }
            await h.coordinator.start()
            await h.coordinator.receive(callback())
            #expect(h.accepted == 0 && h.coordinator.phase == .cancelled)
        }
    }

    @Test func `replay while exchange suspended is ignored`() async {
        let h = Harness()
        h.api.exchange = {
            await h.coordinator.receive(callback())
            return .init(accessToken: "access", expiresAt: 1_800_003_600, refreshToken: "refresh")
        }
        await h.coordinator.start()
        await h.coordinator.receive(callback())
        #expect(h.api.exchanges == 1 && h.accepted == 1)
    }

    @Test func `invalid state expiry and cold launch never exchange`() async {
        let cold = Harness()
        await cold.coordinator.receive(callback())
        #expect(cold.coordinator.phase == .failed(.restartRequired))
        for expired in [false, true] {
            let h = Harness()
            await h.coordinator.start()
            if expired {
                h.time = clock.addingTimeInterval(601)
            }
            await h.coordinator.receive(expired ? callback() : callback("code=\(opaque)&state=wrong"))
            #expect(h.api.exchanges == 0 && h.store.pending == nil)
            #expect(h.coordinator.phase == .failed(expired ? .expired : .invalidCallback))
        }
    }

    @Test func `browser failure reopen and old callback`() async {
        let h = Harness()
        h.browser.canStart = false
        await h.coordinator.start()
        #expect(h.coordinator.phase == .failed(.browserUnavailable))
        h.browser.canStart = true
        await h.coordinator.start()
        let old = h.browser.completion
        h.coordinator.reopen()
        #expect(h.browser.starts == 3)
        old?(nil, true)
        await Task.yield()
        #expect(h.coordinator.phase == .waiting)
        h.time = clock.addingTimeInterval(601)
        h.coordinator.reopen()
        #expect(h.coordinator.phase == .failed(.expired))
    }

    @Test func `callback from browser and browser cancellation`() async {
        for result in [0, 1, 2] {
            let h = Harness()
            await h.coordinator.start()
            h.browser.completion?(result == 0 ? callback() : nil, result == 1)
            for _ in 0 ..< 100 where h.coordinator.phase == .waiting {
                await Task.yield()
            }
            #expect(h.coordinator
                .phase == (result == 0 ? .succeeded : result == 1 ? .cancelled : .failed(.browserUnavailable)))
        }
    }

    @Test func `failures require new transaction never retry code`() async {
        for failure in [WebLoginFailure.restartRequired, .storageFailed] {
            let h = Harness()
            if failure == .storageFailed {
                h.failure = failure
            } else {
                h.api.exchange = { throw URLError(.networkConnectionLost) }
            }
            await h.coordinator.start()
            await h.coordinator.receive(callback())
            await h.coordinator.receive(callback())
            #expect(h.api.exchanges == 1 && h.coordinator.phase == .failed(failure))
            #expect(h.store.pending == nil)
        }
    }

    @Test func `create error and untrusted URL never open browser`() async {
        for network in [false, true] {
            let h = Harness()
            h.api.create = {
                if network {
                    throw URLError(.timedOut)
                }
                return transaction(url: "https://evil.test/login?transaction=\(opaque)")
            }
            await h.coordinator.start()
            #expect(h.browser.starts == 0 && h.store.pending == nil)
            #expect(h.coordinator.phase == .failed(network ? .restartRequired : .invalidResponse))
        }
    }

    @Test func `invalid tokens cannot become sessions`() async {
        let h = Harness()
        h.api.exchange = { .init(accessToken: "a", expiresAt: 60, refreshToken: nil) }
        await h.coordinator.start()
        await h.coordinator.receive(callback())
        #expect(h.accepted == 0 && h.coordinator.phase == .failed(.invalidResponse))
    }

    @Test func `expiry timer clears secrets without callback`() async throws {
        let h = Harness()
        h.api.create = { transaction(expiry: clock.timeIntervalSince1970 + 0.01) }
        await h.coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.coordinator.phase == .failed(.expired) && h.store.pending == nil)
        #expect(h.api.exchanges == 0)
    }

    @Test func `old browser cannot cancel new attempt and generation change abandons creation`() async {
        let h = Harness()
        await h.coordinator.start()
        let old = h.browser.completion
        h.coordinator.cancel()
        await h.coordinator.start()
        old?(callback(), false)
        await Task.yield()
        #expect(h.coordinator.phase == .waiting && h.api.exchanges == 0)
        h.coordinator.cancel()
        h.api.create = { h.generation += 1; throw URLError(.cancelled) }
        await h.coordinator.start()
        #expect(h.coordinator.phase == .cancelled)
    }

    @Test func `invalid configuration and proof fail before networking`() async {
        for invalidOrigin in [true, false] {
            let h = Harness()
            let configuration = WebLoginConfiguration.resolve(environment: [
                "TYPEFLUX_WEB_AUTH_ENABLED": "true",
                "TYPEFLUX_WEB_AUTH_ORIGIN": invalidOrigin ? "file:///tmp" : "https://typeflux.app"
            ], info: [:])
            let coordinator = WebLoginCoordinator(configuration: configuration, api: h.api, store: h.store,
                                                  browserFactory: { _, _, _ in h.browser },
                                                  makeProof: { throw WebLoginFailure.invalidResponse },
                                                  authGeneration: { 0 }, accept: { _, _ in })
            await coordinator.start()
            #expect(h.api.creates == 0 && coordinator.phase == .failed(.invalidResponse))
        }
    }

    @Test func `disabled feature and unrelated callback do nothing`() async throws {
        let h = Harness()
        let disabled = WebLoginCoordinator(configuration: config(enabled: false), api: h.api, store: h.store,
                                           browserFactory: { _, _, _ in h.browser }, authGeneration: { 0 },
                                           accept: { _, _ in })
        await disabled.start()
        await disabled.receive(callback())
        disabled.reopen()
        #expect(h.api.creates == 0 && disabled.phase == .idle)
        await h.coordinator.start()
        try await h.coordinator.receive(#require(URL(string: "typeflux://billing/return")))
        #expect(h.coordinator.phase == .waiting)
        h.coordinator.cancel()
    }

    @Test func `app router preserves billing and rejects legacy or cross client auth`() async throws {
        let h = Harness()
        var shown = 0
        var billing = 0
        try await AppLoginURLRouter.handle([
            #require(URL(string: "typeflux://billing/return")),
            #require(URL(string: "ai.gulu.app.typeflux://oauth/github?code=legacy")),
            #require(URL(string: "ai.gulu.app.typeflux.dev://auth/callback?code=other"))
        ], login: h.coordinator, isLoggedIn: { false }, showLogin: { shown += 1 }, handleBilling: { billing += 1 })
        #expect(billing == 1 && shown == 0 && h.api.exchanges == 0)
        await AppLoginURLRouter.handle([callback()], login: h.coordinator, isLoggedIn: { false },
                                       showLogin: { shown += 1 }, handleBilling: { billing += 1 })
        #expect(shown == 1 && h.coordinator.phase == .failed(.restartRequired))
        await h.coordinator.start()
        await AppLoginURLRouter.handle([callback()], login: h.coordinator, isLoggedIn: { true },
                                       showLogin: { shown += 1 }, handleBilling: { billing += 1 })
        #expect(h.accepted == 1 && shown == 1 && billing == 1)
    }
}

@Suite("Web login HTTP", .exclusiveUIState)
@MainActor
struct WebLoginHTTPTests {
    @Test(arguments: ["https://api.typeflux.app", "http://localhost:5174"])
    func `sends frozen contract without state in exchange`(origin: String) async throws {
        let configuration = WebLoginConfiguration.resolve(
            environment: ["TYPEFLUX_WEB_AUTH_API_ORIGIN": origin], info: [:]
        )
        var requests: [URLRequest] = []
        let api = WebLoginHTTPAPI(configuration: configuration) { request in
            requests.append(request)
            let body = request.url!.path.hasSuffix("transactions")
                ? "{\"transaction_id\":\"\(opaque)\",\"login_url\":\"https://typeflux.app/login?transaction=\(opaque)\",\"expires_at\":1800000600}"
                : "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at\":1800003600}"
            return (
                Data("{\"code\":\"OK\",\"message\":\"\",\"data\":\(body)}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        _ = try await api.create(proof: proof)
        let response = try await api.exchange(code: opaque, verifier: proof.verifier)
        #expect(response.expiresAt == 1_800_003_600)
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url?.host == configuration.apiOrigin.host)
            #expect(request.url?.scheme == configuration.apiOrigin.scheme)
            #expect(request.url?.port == configuration.apiOrigin.port)
            #expect(request.httpMethod == "POST" && !request.httpShouldHandleCookies)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        let create = try JSONDecoder().decode([String: String].self, from: #require(requests[0].httpBody))
        let exchange = try JSONDecoder().decode([String: String].self, from: #require(requests[1].httpBody))
        #expect(create["state"] == proof.state && create["code_challenge_method"] == "S256")
        #expect(create["code_verifier"] == nil && exchange["state"] == nil)
        #expect(exchange["code_verifier"] == proof.verifier && exchange["client_id"] == "typeflux-macos")
    }

    @Test func `uncertain network and invalid grant are not retried`() async {
        for network in [false, true] {
            var calls = 0
            let api = WebLoginHTTPAPI(configuration: config()) { request in
                calls += 1
                if network {
                    throw URLError(.networkConnectionLost)
                }
                return (
                    Data("{\"code\":\"AUTH_GRANT_INVALID\",\"message\":\"private\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                )
            }
            await #expect(throws: (any Error).self) { try await api.exchange(code: opaque, verifier: proof.verifier) }
            #expect(calls == 1)
        }
    }

    @Test func `rejects invalid endpoint and malformed responses`() async {
        let invalid = WebLoginConfiguration.resolve(
            environment: ["TYPEFLUX_WEB_AUTH_API_ORIGIN": "ftp://localhost:8080"],
            info: [:]
        )
        var calls = 0
        let api = WebLoginHTTPAPI(configuration: invalid) { _ in calls += 1; throw URLError(.badURL) }
        await #expect(throws: WebLoginFailure.invalidResponse) { try await api.create(proof: proof) }
        #expect(calls == 0)
        for invalidHTTP in [false, true] {
            let client = WebLoginHTTPAPI(configuration: config()) { request in
                let response: URLResponse = invalidHTTP
                    ? URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                    : HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("invalid JSON".utf8), response)
            }
            await #expect(throws: (any Error).self) { try await client.exchange(code: opaque, verifier: proof.verifier)
            }
        }
    }

    @Test(arguments: [400, 403, 404, 405, 429, 500, 503])
    func `creation classifies HTTP failures before decoding proxy bodies`(status: Int) async {
        let expected: WebLoginFailure = switch status {
        case 404, 405: .endpointUnavailable
        case 429: .rateLimited
        case 500...599: .serviceUnavailable
        default: .requestRejected
        }
        let api = WebLoginHTTPAPI(configuration: config()) { request in
            (Data("<html>proxy error with private content</html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: expected) { try await api.create(proof: proof) }
        #expect(!L(expected.localizationKey).hasPrefix("auth.web."))
    }

    @Test(arguments: [URLError.cannotConnectToHost, URLError.timedOut, URLError.appTransportSecurityRequiresSecureConnection])
    func `creation reports transport failure without claiming code consumption`(code: URLError.Code) async {
        var calls = 0
        let api = WebLoginHTTPAPI(configuration: config()) { _ in calls += 1; throw URLError(code) }
        let expected: WebLoginFailure = code == .appTransportSecurityRequiresSecureConnection ? .transportBlocked : .networkUnavailable
        await #expect(throws: expected) { try await api.create(proof: proof) }
        await #expect(throws: WebLoginFailure.restartRequired) { try await api.exchange(code: opaque, verifier: proof.verifier) }
        #expect(calls == 2)
    }

    @Test func `creation reports invalid successful response and rejected envelope`() async {
        for body in ["invalid json", "{\"code\":\"BAD_REQUEST\",\"message\":\"private\"}"] {
            let api = WebLoginHTTPAPI(configuration: config()) { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let expected: WebLoginFailure = body == "invalid json" ? .invalidResponse : .requestRejected
            await #expect(throws: expected) { try await api.create(proof: proof) }
        }
    }

    @Test func `redirect delegate never forwards grant`() throws {
        let url = try #require(URL(string: "https://evil.test"))
        var followed = true
        try WebLoginNoRedirect().urlSession(.shared, task: URLSession.shared.dataTask(with: url),
                                            willPerformHTTPRedirection: #require(HTTPURLResponse(
                                                url: url,
                                                statusCode: 307,
                                                httpVersion: nil,
                                                headerFields: nil
                                            )),
                                            newRequest: URLRequest(url: url)) { followed = $0 != nil }
        #expect(!followed)
    }
}
