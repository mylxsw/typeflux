import Foundation
@testable import Typeflux
import XCTest

/// Captures the JSON body of every request sent through the Ask inference adapter.
private final class AskThinkingCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let data = Self.bodyData(request),
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.bodies.append(body)
        }
        let reply = #"{"choices":[{"message":{"content":"OK"}}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskThinkingCaptureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Ask is a reasoning conversation: unlike dictation rewrite and transcription, its
/// requests must never carry the "thinking off" parameters, and must forward the
/// reasoning effort the user picked.
final class AskThinkingModeTests: XCTestCase {
    /// Every key the rewrite/transcription paths use to switch thinking off.
    private static let thinkingOffKeys = ["thinking", "enable_thinking", "reasoning", "include_reasoning"]

    override func tearDown() {
        AskThinkingCaptureProtocol.bodies = []
        super.tearDown()
    }

    private func conversation(effort: String?) -> AskConversation {
        AskConversation(
            id: UUID().uuidString, title: "T", revision: 1, updatedAt: Date(),
            messages: [AskMessage(id: "m", role: "user", text: "Why?", createdAt: Date())],
            run: AskRun(id: "run", deviceId: "device", status: "running", steps: 0, updatedAt: Date(),
                        tools: [], pending: [], modelRef: "custom:model", reasoningEffort: effort)
        )
    }

    func testLocalPayloadForwardsReasoningEffortWithoutDisablingThinking() {
        let c = conversation(effort: "high")
        let payload = AskLocalPrompt.payload(conversation: c, record: AskLocalRecord(conversation: c), tools: [])
        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
        for key in Self.thinkingOffKeys {
            XCTAssertNil(payload[key], key)
        }
    }

    func testLocalPayloadLeavesProviderDefaultThinkingWhenNoEffortIsChosen() {
        for effort in [nil, ""] {
            let c = conversation(effort: effort)
            let payload = AskLocalPrompt.payload(conversation: c, record: AskLocalRecord(conversation: c), tools: [])
            XCTAssertNil(payload["reasoning_effort"])
            for key in Self.thinkingOffKeys {
                XCTAssertNil(payload[key], key)
            }
        }
    }

    func testSummaryPayloadDoesNotDisableThinking() {
        let c = conversation(effort: "low")
        let payload = AskLocalPrompt.summaryPayload(conversation: c, through: 1)
        for key in Self.thinkingOffKeys {
            XCTAssertNil(payload[key], key)
        }
    }

    func testCustomInferenceSendsEffortAndNoThinkingOffParameters() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        let payload = #"{"messages":[{"role":"user","content":"Why?"}],"reasoning_effort":"medium"}"#
        _ = try await adapter.complete(
            profile: AskModelProfile(name: "Custom", baseURL: "https://example.invalid/v1", model: "m"),
            key: "", payload: payload
        )
        let body = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.last)
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        for key in Self.thinkingOffKeys {
            XCTAssertNil(body[key], key)
        }
    }

    func testCloudReasoningEffortIsSentOnlyForReasoningModels() {
        let reasoning = RegisteredModel(id: "default", name: "Default", reference: "cloud:default", reasoning: true)
        let plain = RegisteredModel(id: "plain", name: "Plain", reference: "cloud:plain", reasoning: false)
        XCTAssertEqual(AskReasoningEffort.high.requestValue(for: reasoning), "high")
        XCTAssertNil(AskReasoningEffort.providerDefault.requestValue(for: reasoning))
        XCTAssertNil(AskReasoningEffort.high.requestValue(for: plain))
    }

    /// The dictation rewrite path is the counterpart: it keeps switching thinking off.
    func testRewriteTuningStillDisablesThinking() {
        var body: [String: Any] = [:]
        OpenAICompatibleResponseSupport.applyAnthropicTuning(body: &body)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }
}
