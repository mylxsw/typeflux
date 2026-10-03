import Foundation
@testable import Typeflux
import XCTest

/// These fixtures replace DNS and connection establishment. They do not change
/// system DNS, open sockets, or claim to reproduce CFNetwork's resolver timing.
final class AskLocalWebBoundaryTests: XCTestCase {
    private let unavailable = "Local web_fetch is unavailable because a safe connection to the destination cannot be guaranteed. No request was sent."

    func testPreflightAndFinalDNSChecksDoNotBindTheConnectionPeer() async throws {
        for peer in ["127.0.0.1", "10.0.0.1", "::1", "::ffff:127.0.0.1"] {
            let fixture = WebConnectionFixture(peer: peer)
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let tools = AskLocalWebTools(session: session, resolve: { fixture.resolve($0) })

            // The old fetch sequence: validate DNS, submit the hostname, then
            // validate the response URL. The transport owns a separate lookup.
            try tools.checkPublic(fixture.url)
            let (data, response) = try await session.data(from: fixture.url)
            try tools.checkPublic(try XCTUnwrap(response.url))

            XCTAssertEqual(String(decoding: data, as: UTF8.self), "private sentinel")
            XCTAssertEqual(fixture.observations.lookups, 2)
            XCTAssertEqual(fixture.observations.peers, [peer])
            XCTAssertFalse(AskLocalWebTools.isPublic(peer))
        }
    }

    func testFetchFailsClosedBeforeDNSOrConnection() async {
        let fixture = WebConnectionFixture(peer: "127.0.0.1")
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let tools = AskLocalWebTools(session: session, resolve: { fixture.resolve($0) })
        do {
            _ = try await tools.fetch(fixture.url.absoluteString)
            XCTFail("An unverified transport must not perform local web_fetch")
        } catch {
            XCTAssertEqual(error.localizedDescription, unavailable)
        }
        XCTAssertEqual(fixture.observations.lookups, 0)
        XCTAssertEqual(fixture.observations.peers, [])
    }

    func testStaleToolCallsFailClosedForRedirectsTLSAndResponseHazards() async throws {
        // No scenario is allowed to reach the transport. This tests refusal,
        // not the security of a TLS handshake or a running response limiter.
        for reply in WebConnectionFixture.Reply.allCases {
            let fixture = WebConnectionFixture(peer: "::ffff:127.0.0.1", reply: reply)
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let tools = AskLocalWebTools(session: session, resolve: { fixture.resolve($0) })
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["url": fixture.url.absoluteString]), as: UTF8.self)
            let (message, failed) = await tools.execute(name: "web_fetch", arguments: arguments)
            XCTAssertTrue(failed, "\(reply)")
            XCTAssertEqual(message, unavailable, "\(reply)")
            XCTAssertEqual(fixture.observations.lookups, 0, "\(reply)")
            XCTAssertEqual(fixture.observations.peers, [], "\(reply)")
        }
    }

    func testProxyConfigurationCannotEnableFetch() async {
        let fixture = WebConnectionFixture(peer: "127.0.0.1")
        let session = fixture.session(proxies: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888,
            "SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080
        ])
        defer { session.invalidateAndCancel(); fixture.remove() }
        let tools = AskLocalWebTools(session: session, resolve: { fixture.resolve($0) })
        let (message, failed) = await tools.execute(name: "web_fetch", arguments: #"{"url":"https://example.com/"}"#)
        XCTAssertTrue(failed)
        XCTAssertEqual(message, unavailable)
        XCTAssertEqual(fixture.observations.lookups, 0)
        XCTAssertEqual(fixture.observations.peers, [])
    }

    func testLiteralAddressesAndMalformedArgumentsCannotEnableFetch() async throws {
        let fixture = WebConnectionFixture(peer: "127.0.0.1")
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let tools = AskLocalWebTools(session: session, resolve: { fixture.resolve($0) })
        for url in ["http://8.8.8.8/", "http://127.0.0.1/", "https://[2606:4700:4700::1111]/", "http://[::ffff:127.0.0.1]/",
                    "http://[::1]/", "http://169.254.169.254/", "file:///etc/hosts", "", String(repeating: "x", count: 4001)] {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["url": url]), as: UTF8.self)
            let (message, failed) = await tools.execute(name: "web_fetch", arguments: arguments)
            XCTAssertTrue(failed, url)
            XCTAssertEqual(message, unavailable, url)
        }
        let (_, failed) = await tools.execute(name: "web_fetch", arguments: "not json")
        XCTAssertTrue(failed)
        XCTAssertEqual(fixture.observations.lookups, 0)
        XCTAssertEqual(fixture.observations.peers, [])
    }

    func testFetchIsNotAdvertisedAndSearchDoesNotRecommendIt() {
        var tools = AskLocalWebTools()
        defer { tools.session.invalidateAndCancel() }
        XCTAssertTrue(tools.definitions().isEmpty)
        tools.searchProvider = { (.tavily, "fixture-key") }
        XCTAssertEqual(tools.definitions().map(\.name), ["web_search"])
        XCTAssertFalse(tools.definitions()[0].description.contains("web_fetch"))
    }

    func testSearchRedirectPreflightStillRejectsNonPublicAddresses() throws {
        let policy = AskPublicRedirectPolicy()
        let session = URLSession(configuration: .ephemeral, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://8.8.8.8/")!
        let task = session.dataTask(with: source)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for raw in ["http://10.0.0.1/", "http://127.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/",
                    "http://[::ffff:7f00:1]/", "http://169.254.169.254/", "http://printer.local/", "file:///etc/hosts"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: raw)))
            var called = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
                called = true
                XCTAssertNil(redirected, raw)
            }
            XCTAssertTrue(called)
        }
        for raw in ["https://8.8.8.8/", "https://[2606:4700:4700::1111]/"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: raw)))
            var called = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
                called = true
                XCTAssertEqual(redirected?.url, request.url)
            }
            XCTAssertTrue(called)
        }
        var missing = URLRequest(url: source)
        missing.url = nil
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: missing) { XCTAssertNil($0) }
    }

    func testSearchSessionLeavesTLSChallengesToThePlatform() throws {
        let tools = AskLocalWebTools()
        defer { tools.session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(tools.session.delegate as? NSObject)
        // Neither task-level nor session-level trust challenges are overridden.
        // This is a configuration check, not a live TLS integration test.
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:")))
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:")))
    }
}

private final class WebConnectionFixture: @unchecked Sendable {
    enum Reply: CaseIterable {
        case page, privateRedirect, oversized, slow, untrustedTLS
    }

    let host = "\(UUID().uuidString.lowercased()).invalid"
    let peer: String
    let reply: Reply
    private let lock = NSLock()
    private var lookups = 0
    private var peers: [String] = []
    var url: URL { URL(string: "https://\(host)/")! }

    init(peer: String, reply: Reply = .page) {
        self.peer = peer
        self.reply = reply
    }

    func resolve(_: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        lookups += 1
        return ["93.184.216.34", "2606:4700:4700::1111"]
    }

    func connected() {
        lock.lock()
        defer { lock.unlock() }
        peers.append(peer)
    }

    var observations: (lookups: Int, peers: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (lookups, peers)
    }

    func session(proxies: [AnyHashable: Any] = [:]) -> URLSession {
        WebBoundaryProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebBoundaryProtocol.self]
        configuration.connectionProxyDictionary = proxies
        return URLSession(configuration: configuration)
    }

    func remove() { WebBoundaryProtocol.remove(host) }
}

private final class WebBoundaryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: WebConnectionFixture] = [:]

    static func register(_ fixture: WebConnectionFixture) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[fixture.host] = fixture
    }

    static func remove(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures.removeValue(forKey: host)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.connected()
        switch fixture.reply {
        case .slow:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .untrustedTLS:
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
        case .page, .privateRedirect, .oversized:
            let redirect = fixture.reply == .privateRedirect
            let response = HTTPURLResponse(url: request.url!, statusCode: redirect ? 302 : 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/plain", "Location": "http://127.0.0.1/secret"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = fixture.reply == .oversized ? Data(repeating: 120, count: (2 << 20) + 1) : Data("private sentinel".utf8)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
