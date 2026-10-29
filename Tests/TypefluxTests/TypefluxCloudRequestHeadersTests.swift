@testable import Typeflux
import XCTest

final class TypefluxCloudRequestHeadersTests: XCTestCase {
    @MainActor
    func testPaidCloudCallsHaveOneRetryIdentityPerInvocation() throws {
        let connection = ResolvedLLMConnection(provider: .typefluxCloud, baseURL: URL(string: "https://api.example.test/api/v1")!, model: "default", apiKey: "fixture", additionalHeaders: [:])
        let first = connection.headers(for: .textRewrite)
        let second = connection.headers(for: .textRewrite)
        XCTAssertEqual(first["X-Typeflux-Credit-Version"], "2")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(first["Idempotency-Key"])))
        XCTAssertNotEqual(first["Idempotency-Key"], second["Idempotency-Key"])
    }

    func testClientIdentityStoreGeneratesAndPersistsClientID() throws {
        let suiteName = "TypefluxCloudRequestHeadersTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TypefluxCloudClientIdentityStore(defaults: defaults, key: "client-id")

        let first = store.clientID()
        let second = store.clientID()

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: "client-id"), first)
    }

    func testApplyClientInfoAddsUserAgentAndClientMetadataHeaders() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://cloud.typeflux.dev/api/v1/me")))

        TypefluxCloudRequestHeaders.applyClientInfo(to: &request, provider: .fixture)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Typeflux/1.2.3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Typeflux-Credit-Version"), "2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "zh-Hans-US, en-US;q=0.9")
        XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientIDField), "client-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientLocaleField), "zh_Hans_US")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientLanguagesField),
            "zh-Hans-US,en-US"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientOSField), "macOS")
        XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientOSVersionField), "14.6.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientArchitectureField), "arm64")
    }

    func testClientPreferredLanguagesUsesAppLanguageBeforeSystemLanguages() {
        let languages = TypefluxCloudClientInfoProvider.clientPreferredLanguages(
            appLanguage: .simplifiedChinese,
            systemPreferredLanguages: ["en-CN", "zh-Hans-CN"]
        )

        XCTAssertEqual(languages, ["zh-Hans", "en-CN", "zh-Hans-CN"])
    }

    func testClientPreferredLanguagesDeduplicatesAppLanguage() {
        let languages = TypefluxCloudClientInfoProvider.clientPreferredLanguages(
            appLanguage: .simplifiedChinese,
            systemPreferredLanguages: ["zh-Hans", "en-CN", "ZH-HANS"]
        )

        XCTAssertEqual(languages, ["zh-Hans", "en-CN"])
    }

    func testClientLocaleIdentifierUsesAppLanguage() {
        XCTAssertEqual(
            TypefluxCloudClientInfoProvider.clientLocaleIdentifier(appLanguage: .simplifiedChinese),
            "zh-Hans"
        )
    }

    func testTypefluxCloudScenarioHeadersIncludeClientInfo() {
        let headers = TypefluxCloudRequestHeaders.applyingScenario(
            .askAnything,
            to: ["x-request-id": "req-1"],
            provider: .typefluxCloud,
            clientInfoProvider: .fixture
        )

        XCTAssertEqual(headers["x-request-id"], "req-1")
        XCTAssertEqual(headers[TypefluxCloudRequestHeaders.scenarioField], "ask-anything")
        XCTAssertEqual(headers["User-Agent"], "Typeflux/1.2.3")
        XCTAssertEqual(headers[TypefluxCloudRequestHeaders.clientIDField], "client-123")
    }

    func testNonTypefluxCloudScenarioHeadersDoNotIncludeClientInfo() {
        let headers = TypefluxCloudRequestHeaders.applyingScenario(
            .askAnything,
            to: ["x-request-id": "req-1"],
            provider: .openAI,
            clientInfoProvider: .fixture
        )

        XCTAssertEqual(headers["x-request-id"], "req-1")
        XCTAssertNil(headers[TypefluxCloudRequestHeaders.scenarioField])
        XCTAssertNil(headers["User-Agent"])
        XCTAssertNil(headers[TypefluxCloudRequestHeaders.clientIDField])
    }

    func testApplyPersonaIDAddsPersonaHeader() throws {
        let personaID = try XCTUnwrap(UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA001"))
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://cloud.typeflux.dev/api/v1/asr/ws/default")))

        TypefluxCloudRequestHeaders.applyPersonaID(personaID, to: &request)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.personaIDField),
            personaID.uuidString
        )
    }

    func testApplyPersonaIDSkipsNilPersonaID() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://cloud.typeflux.dev/api/v1/asr/ws/default")))

        TypefluxCloudRequestHeaders.applyPersonaID(nil, to: &request)

        XCTAssertNil(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.personaIDField))
    }

    func testApplyingPersonaIDMergesOnlyForTypefluxCloud() throws {
        let personaID = try XCTUnwrap(UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA001"))

        let cloudHeaders = TypefluxCloudRequestHeaders.applyingPersonaID(
            personaID,
            to: ["x-request-id": "req-1"],
            provider: .typefluxCloud
        )
        let openAIHeaders = TypefluxCloudRequestHeaders.applyingPersonaID(
            personaID,
            to: ["x-request-id": "req-1"],
            provider: .openAI
        )

        XCTAssertEqual(cloudHeaders["x-request-id"], "req-1")
        XCTAssertEqual(cloudHeaders[TypefluxCloudRequestHeaders.personaIDField], personaID.uuidString)
        XCTAssertEqual(openAIHeaders["x-request-id"], "req-1")
        XCTAssertNil(openAIHeaders[TypefluxCloudRequestHeaders.personaIDField])
    }
}

private extension TypefluxCloudClientInfoProvider {
    static let fixture = TypefluxCloudClientInfoProvider {
        TypefluxCloudClientInfo(
            appName: "Typeflux",
            appVersion: "1.2.3",
            clientID: "client-123",
            localeIdentifier: "zh_Hans_US",
            preferredLanguages: ["zh-Hans-US", "en-US"],
            osName: "macOS",
            osVersion: "14.6.1",
            architecture: "arm64"
        )
    }
}
