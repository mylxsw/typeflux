import Foundation
@testable import Typeflux
import XCTest

/// Captures the JSON body of every request sent through the Ask inference adapter.
final class AskThinkingCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Status for requests that carry reasoning parameters, to simulate a provider rejecting them.
    nonisolated(unsafe) static var reasoningStatus = 200
    nonisolated(unsafe) static var reply = #"{"choices":[{"message":{"content":"OK"}}]}"#

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var status = 200
        if let data = Self.bodyData(request),
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.bodies.append(body)
            var probe = body
            if AskReasoningRequest.strip(&probe) { status = Self.reasoningStatus }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((status == 200 ? Self.reply : #"{"error":"unknown parameter"}"#).utf8))
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
        AskThinkingCaptureProtocol.requests = []
        AskThinkingCaptureProtocol.reasoningStatus = 200
        AskThinkingCaptureProtocol.reply = #"{"choices":[{"message":{"content":"OK"}}]}"#
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

    func testRejectedEffortIsRetriedOnceWithoutIt() async throws {
        AskThinkingCaptureProtocol.reasoningStatus = 400
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        let payload = #"{"messages":[{"role":"user","content":"Why?"}],"reasoning_effort":"high","max_tokens":1500}"#
        let (text, _) = try await adapter.complete(
            profile: AskModelProfile(name: "Custom", baseURL: "https://example.invalid/v1", model: "m"),
            key: "", payload: payload
        )
        XCTAssertEqual(text, "OK")
        XCTAssertEqual(AskThinkingCaptureProtocol.bodies.count, 2)
        XCTAssertEqual(AskThinkingCaptureProtocol.bodies[0]["reasoning_effort"] as? String, "high")
        XCTAssertNil(AskThinkingCaptureProtocol.bodies[1]["reasoning_effort"])
        XCTAssertEqual(AskThinkingCaptureProtocol.bodies.map { $0["max_tokens"] as? Int }, [1500, 1500])
    }

    func testRejectionWithoutReasoningIsNotRetried() async {
        var attempts = 0
        do {
            _ = try await AskReasoningRequest.send(["messages": []]) { _ -> Int in
                attempts += 1
                throw AskStreamError.rejected
            }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("ask.models.requestError"))
        }
        XCTAssertEqual(attempts, 1)
    }

    func testAnthropicEffortBecomesExtendedThinking() throws {
        var native = try AskCustomInference.nativeBody(
            ["messages": [["role": "user", "content": "Why?"]], "max_tokens": 4096], model: "claude", anthropic: true)
        AskReasoningRequest.applyAnthropic(effort: "medium", to: &native)
        XCTAssertEqual((native["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual((native["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 8192)
        XCTAssertEqual(native["max_tokens"] as? Int, 8192 + 4096)

        // A turn answering tool results keeps thinking off: its thinking block cannot be replayed.
        var toolTurn = try AskCustomInference.nativeBody([
            "messages": [
                ["role": "user", "content": "Why?"],
                ["role": "assistant", "content": "", "tool_calls": [["id": "t", "type": "function",
                                                                       "function": ["name": "computer", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "t", "content": "done"]
            ]
        ], model: "claude", anthropic: true)
        AskReasoningRequest.applyAnthropic(effort: "high", to: &toolTurn)
        XCTAssertNil(toolTurn["thinking"])

        var none = native
        none.removeValue(forKey: "thinking")
        AskReasoningRequest.applyAnthropic(effort: nil, to: &none)
        XCTAssertNil(none["thinking"])
    }

    func testGeminiEffortBecomesThinkingBudget() {
        var native: [String: Any] = ["contents": []]
        AskReasoningRequest.applyGemini(effort: "low", to: &native)
        let config = (native["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        XCTAssertEqual(config?["thinkingBudget"] as? Int, 1024)
        XCTAssertEqual(config?["includeThoughts"] as? Bool, true)
        XCTAssertTrue(AskReasoningRequest.strip(&native))
        XCTAssertNil(native["generationConfig"])
        XCTAssertFalse(AskReasoningRequest.strip(&native))
    }

    func testEffortParsingIgnoresUnknownValues() {
        XCTAssertEqual(AskReasoningRequest.effort(in: ["reasoning_effort": "high"]), "high")
        XCTAssertNil(AskReasoningRequest.effort(in: ["reasoning_effort": "max"]))
        XCTAssertNil(AskReasoningRequest.effort(in: [:]))
        XCTAssertTrue(AskReasoningRequest.isRejection(status: 422))
        XCTAssertFalse(AskReasoningRequest.isRejection(status: 429))
    }

    /// The dictation rewrite path is the counterpart: it keeps switching thinking off.
    func testRewriteTuningStillDisablesThinking() {
        var body: [String: Any] = [:]
        OpenAICompatibleResponseSupport.applyAnthropicTuning(body: &body)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }
}
