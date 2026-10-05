import Foundation
import Security
@testable import Typeflux
import XCTest

private final class CloudflareStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
}

final class AskCloudflareSearchTests: XCTestCase {
    private let account = "0123456789abcdef0123456789abcdef"
    private var configured: AskSearchConfiguration {
        .init(provider: .cloudflare, apiKey: " fixture-token ", cloudflare: .init(accountID: account))
    }
    override func tearDown() { CloudflareStubProtocol.handler = nil }

    func testRequestsForEachProviderAndBYOK() throws {
        for provider in AskCloudflareSearchConfiguration.providers {
            var config = configured
            config.cloudflare.provider = provider
            config.cloudflare.gatewayID = "search"
            config.cloudflare.byokAlias = provider == "exa" ? "my-key" : ""
            let request = try AskCloudflareSearch.request(query: "Go release", count: 3, configuration: config)
            XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/websearch/")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["query"] as? String, "Go release")
            XCTAssertEqual(body["provider"] as? String, provider)
            XCTAssertEqual(body["limit"] as? Int, 3)
            XCTAssertEqual((body["options"] as? [String: [String: String]])?["gateway"]?["id"], "search")
            XCTAssertEqual(body["byokAlias"] as? String, provider == "exa" ? "my-key" : nil)
        }
        for (count, expected) in [(-1, 1), (100, 10)] {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AskCloudflareSearch.request(query: "q", count: count, configuration: configured).httpBody)) as? [String: Any]
            XCTAssertEqual(body?["limit"] as? Int, expected)
        }
    }

    func testValidationAndToolAvailability() throws {
        var config = configured
        XCTAssertTrue(config.isConfigured)
        config.cloudflare = .init(accountID: " \(account) ", gatewayID: " ", provider: " ")
        XCTAssertTrue(config.isConfigured)
        XCTAssertEqual(config.cloudflare.normalized.gatewayID, "default")
        XCTAssertEqual(config.cloudflare.normalized.provider, "ceramic")
        let invalid: [AskCloudflareSearchConfiguration] = [
            .init(), .init(accountID: "../bad"), .init(accountID: account, gatewayID: "../bad"),
            .init(accountID: account, provider: "bad"), .init(accountID: account, byokAlias: "bad alias"),
            .init(accountID: account, byokAlias: String(repeating: "x", count: 65))
        ]
        for options in invalid {
            config.cloudflare = options
            XCTAssertFalse(config.isConfigured)
            XCTAssertThrowsError(try AskCloudflareSearch.request(query: "q", count: 1, configuration: config))
        }
        for token in ["", " ", "bad\rkey", "bad\nkey"] {
            config = configured; config.apiKey = token
            XCTAssertFalse(config.isConfigured)
        }
        XCTAssertFalse(AskSearchConfiguration().isConfigured)
        XCTAssertTrue(AskSearchConfiguration(provider: .tavily, apiKey: "legacy").isConfigured)
        var tools = AskLocalWebTools()
        let valid = configured
        tools.searchProvider = { valid }
        XCTAssertEqual(tools.definitions().map(\.name), ["web_search"])
        tools.searchProvider = { .init(provider: .cloudflare, apiKey: "key") }
        XCTAssertTrue(tools.definitions().isEmpty)
    }

    func testResultsEmptyAndOutputBounds() async throws {
        let session = CloudflareStubProtocol.session
        defer { session.invalidateAndCancel() }
        let config = configured
        let tools = AskLocalWebTools(session: session, searchProvider: { config })
        CloudflareStubProtocol.handler = { _ in (200, #"{"items":[{"title":"Go","url":"https://go.dev","description":"Release\nnotes"}]}"#) }
        let result = try await tools.search("  Go  ", count: 5)
        XCTAssertEqual(result, "1. Go\n   https://go.dev\n   Release notes")
        CloudflareStubProtocol.handler = { _ in (200, #"{"items":[]}"#) }
        let empty = try await tools.search("q", count: 5)
        XCTAssertEqual(empty, "No results.")
        CloudflareStubProtocol.handler = { _ in (200, #"{"items":[{}]}"#) }
        let optional = try await tools.search("q", count: 5)
        XCTAssertEqual(optional, "1. \n   ")
        let item = ["title": "Title", "url": "https://example.com", "description": String(repeating: "x", count: 8000)]
        let data = try JSONSerialization.data(withJSONObject: ["items": Array(repeating: item, count: 10)])
        CloudflareStubProtocol.handler = { _ in (200, String(decoding: data, as: UTF8.self)) }
        let bounded = try await tools.search("q", count: 10)
        XCTAssertEqual(bounded.count, AskCloudflareSearch.maxOutputCharacters)
        let limited = try await tools.search("q", count: 1)
        XCTAssertFalse(limited.contains("2. Title"))
    }

    func testFailuresAreRedactedAndNeverEmptyResults() async throws {
        let session = CloudflareStubProtocol.session
        defer { session.invalidateAndCancel() }
        let config = configured
        let tools = AskLocalWebTools(session: session, searchProvider: { config })
        for (status, body) in [(401, "fixture-secret"), (403, "fixture-secret"), (429, "fixture-secret"),
                               (503, "fixture-secret"), (400, "fixture-secret"), (307, "fixture-secret"),
                               (200, "{}"), (200, "{bad"), (200, #"{"items":null}"#),
                               (200, #"{"items":[{"description":3}]}"#),
                               (200, #"{"items":[],"padding":""# + String(repeating: "x", count: AskCloudflareSearch.maxResponseBytes) + #""}"#)] {
            CloudflareStubProtocol.handler = { _ in (status, body) }
            let (message, failed) = await tools.execute(name: "web_search", arguments: #"{"query":"q"}"#)
            XCTAssertTrue(failed, "\(status)")
            XCTAssertFalse(message.contains("fixture-secret"))
            XCTAssertNotEqual(message, "No results.")
        }
        for code in [URLError.timedOut, .cannotConnectToHost, .cancelled] {
            CloudflareStubProtocol.handler = { _ in throw URLError(code) }
            do {
                _ = try await tools.search("q", count: 1)
                XCTFail("Expected transport error")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error.localizedDescription, L("ask.settings.search.cloudflare.unavailable")) }
            }
        }
        let (_, blank) = await tools.execute(name: "web_search", arguments: #"{"query":" "}"#)
        XCTAssertTrue(blank)
        let (_, long) = await tools.execute(name: "web_search", arguments: "{\"query\":\"\(String(repeating: "a", count: 401))\"}")
        XCTAssertTrue(long)
    }

    func testRejectsOversizedAndNonHTTPResponses() throws {
        let url = try XCTUnwrap(URL(string: "https://api.cloudflare.com/"))
        XCTAssertThrowsError(try AskCloudflareSearch.validate(URLResponse(
            url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
        let oversized = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": String(AskCloudflareSearch.maxResponseBytes + 1)]))
        XCTAssertThrowsError(try AskCloudflareSearch.validate(oversized))
    }

    func testRedirectPolicyRejectsAllDestinations() {
        let policy = AskCloudflareRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://api.cloudflare.com/")!
        let task = session.dataTask(with: original)
        for host in ["api.cloudflare.com", "example.com"] {
            policy.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                              newRequest: URLRequest(url: URL(string: "https://\(host)/other")!)) { request in XCTAssertNil(request) }
        }
    }

    func testSettingsKeepLegacyAndCloudflareTokensSeparate() throws {
        let suite = "cloudflare-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AskSearchSettings(defaults: defaults, keychainService: suite)
        defer {
            settings.provider = .tavily; settings.setAPIKey("")
            settings.provider = .cloudflare; settings.setAPIKey("")
        }
        settings.provider = .tavily
        settings.setAPIKey("legacy-token")
        guard settings.apiKey == "legacy-token" else { throw XCTSkip("Test keychain is unavailable") }
        settings.provider = .cloudflare
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertFalse(settings.isConfigured)
        settings.cloudflare = .init(accountID: account, gatewayID: "search", provider: "exa", byokAlias: "my-key")
        settings.setAPIKey(" cf-token ")
        XCTAssertEqual(settings.apiKey, "cf-token")
        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(settings.configuration.cloudflare, settings.cloudflare)
        XCTAssertEqual(settings.cloudflare.byokAlias, "my-key")
        settings.provider = .none
        XCTAssertFalse(settings.isConfigured)
        settings.provider = .brave
        XCTAssertEqual(settings.apiKey, "legacy-token")
        settings.provider = .cloudflare
        XCTAssertEqual(settings.apiKey, "cf-token")
        settings.setAPIKey("")
        XCTAssertFalse(settings.isConfigured)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("cf-token") })
    }
}
