@testable import Typeflux
import XCTest

final class TypefluxOfficialTranscriberTests: XCTestCase {
    func testStartMessageDisablesOptimizeWhenLLMRewriteIsIncluded() throws {
        let message = TypefluxOfficialASRStartMessageFactory.make(
            optimize: false,
            llmConfig: ASRLLMConfig(
                systemPrompt: "Rewrite with persona",
                userPromptTemplate: "{{transcript}}"
            )
        )
        let config = try XCTUnwrap(message["config"] as? [String: Any])

        XCTAssertEqual(config["optimize"] as? Bool, false)
        XCTAssertNotNil(config["llm"])
    }

    func testStartMessageEnablesOptimizeWithoutLLMRewrite() throws {
        let message = TypefluxOfficialASRStartMessageFactory.make(optimize: true)
        let config = try XCTUnwrap(message["config"] as? [String: Any])

        XCTAssertEqual(config["optimize"] as? Bool, true)
        XCTAssertNil(config["llm"])
    }

    func testWebSocketRequestIncludesScenarioHeader() throws {
        let traceID = "client-trace-123"
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "https://cloud.typeflux.dev",
            token: "token-123",
            scenario: .voiceInput,
            traceID: traceID
        )

        XCTAssertEqual(request.url?.absoluteString, "wss://cloud.typeflux.dev/api/v1/asr/ws/default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.scenarioField),
            TypefluxCloudScenario.voiceInput.rawValue
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientIDField))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxOfficialASRRequestFactory.traceIDHeader),
            traceID
        )
    }

    func testWebSocketRequestConvertsHTTPPrefixToWS() throws {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "http://asr-2.example.com/",
            token: "token-123",
            scenario: .voiceInput
        )

        XCTAssertEqual(request.url?.absoluteString, "ws://asr-2.example.com/api/v1/asr/ws/default")
    }

    func testASRTokenScopeReadsConcreteProvider() throws {
        let token = try makeUnsignedJWT(payload: ["asr_provider": "doubao"])

        XCTAssertEqual(TypefluxOfficialASRTokenScope.provider(from: token), "doubao")
    }

    func testASRTokenScopeIgnoresUnsupportedProvider() throws {
        let token = try makeUnsignedJWT(payload: ["asr_provider": "default"])

        XCTAssertNil(TypefluxOfficialASRTokenScope.provider(from: token))
    }

    func testWebSocketRequestIncludesPersonaIDHeaderWhenProvided() throws {
        let personaID = SettingsStore.defaultPersonaID

        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "https://cloud.typeflux.dev",
            token: "token-123",
            scenario: .voiceInput,
            personaID: personaID
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.personaIDField),
            personaID.uuidString
        )
    }

    func testReceiveFailureIsUnexpectedBeforeCompletionWithoutFinalSegments() {
        XCTAssertTrue(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: []
            )
        )
    }

    func testReceiveFailureIsAcceptedAfterFinalSegmentWithoutCompletedEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: ["hello world"]
            )
        )
    }

    func testReceiveFailureIsAcceptedAfterExplicitCompletionEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: true,
                finalSegments: []
            )
        )
    }

    func testNormalProviderCompletionErrorIsAccepted() {
        XCTAssertTrue(
            TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(
                "websocket: close 1000 (normal): finish last sequence"
            )
        )
    }

    func testNonNormalProviderErrorIsNotAcceptedAsCompletion() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(
                "websocket: close 1008 (policy violation): bad token"
            )
        )
    }
}

private func makeUnsignedJWT(payload: [String: String]) throws -> String {
    let header = base64URLEncoded(Data(#"{"alg":"none"}"#.utf8))
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(header).\(base64URLEncoded(payloadData))."
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
