import Foundation
@testable import Typeflux
import XCTest

private struct ReleaseHTTPProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        .init(latencyMs: 0, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

final class AskReleaseHTTPTests: XCTestCase {
    private struct Fixture {
        let api: AskAPIClient
        let selector: CloudEndpointSelector
        let token: String
        let other: String
    }

    func testRealAPIReceiptBindingPurgeAndDuplicateDelivery() async throws {
        let fixture = try client()
        let api = fixture.api, token = fixture.token
        let id = UUID().uuidString, device = UUID().uuidString
        let request = AskSendRequest(
            id: UUID().uuidString, deviceId: device, text: "Read the fixed release fixture", tools: [
                .init(
                    name: "browser",
                    description: "Fixture read",
                    parameters: .init(data: Data(#"{"type":"object"}"#.utf8))
                )
            ], modelRef: "custom:" + UUID().uuidString, memory: .init(global: "release-memory-to-purge")
        )
        _ = try await api.send(conversationId: id, request: request, token: token)
        let waiting = try await wait(api, id: id, token: token, status: "waiting_inference")
        let run = try XCTUnwrap(waiting.run), inference = try XCTUnwrap(run.inference)
        var response = AskInferenceResult(
            runId: run.id, deviceId: UUID().uuidString, inferenceId: inference.id,
            content: "", toolCalls: [.init(
                id: "read-call",
                function: .init(name: "browser", arguments: #"{"action":"read"}"#)
            )]
        )
        do {
            _ = try await api.inferenceResult(conversationId: id, request: response, token: token)
            XCTFail("Another device cannot submit the receipt")
        } catch {}
        response.deviceId = device
        _ = try await api.inferenceResult(conversationId: id, request: response, token: token)
        _ = try await wait(api, id: id, token: token, status: "waiting_tool")
        let receipt = AskToolResultRequest(
            runId: run.id, deviceId: device, toolCallId: "read-call", content: "Observed fixture", isError: false,
            harness: .init(version: 1, outcome: .init(status: "ok", content: [
                AskTypedContent.json(["type": "text", "text": "Observed fixture"])
            ], durationMs: 12, effectVerified: true))
        )
        _ = try await api.result(conversationId: id, request: receipt, token: token)
        let next = try await wait(api, id: id, token: token, status: "waiting_inference")
        _ = try await api.result(conversationId: id, request: receipt, token: token)
        try await api.purgeMemory(token: token)
        let finished = try await api.inferenceResult(conversationId: id, request: .init(
            runId: run.id, deviceId: device, inferenceId: XCTUnwrap(next.run?.inference?.id),
            content: "Observed fixture"
        ), token: token)
        try await verify(finished, fixture: fixture, id: id, run: run.id)
    }

    private func client() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["TYPEFLUX_RELEASE_HTTP_URL"] else {
            throw XCTSkip("Run the R06 Go-to-Swift bridge with an isolated PostgreSQL database")
        }
        let url = try XCTUnwrap(URL(string: address))
        XCTAssertEqual(url.host, "127.0.0.1")
        let token = try XCTUnwrap(env["TYPEFLUX_RELEASE_HTTP_TOKEN"])
        let other = try XCTUnwrap(env["TYPEFLUX_RELEASE_HTTP_OTHER_TOKEN"])
        let selector = CloudEndpointSelector(baseURLs: [url], prober: ReleaseHTTPProber())
        let api = AskAPIClient(
            executor: CloudRequestExecutor(selector: selector),
            trustedPeer: AskTypedContent.advertisement,
            enabledCapabilities: [.typedContent],
            recoveryMetadataEnabled: true
        )
        return Fixture(api: api, selector: selector, token: token, other: other)
    }

    private func verify(_ finished: AskConversation, fixture: Fixture, id: String, run: String) async throws {
        XCTAssertEqual(finished.run?.status, "completed")
        XCTAssertEqual(finished.run?.recovery?.state, "completed")
        XCTAssertNil(finished.memory)
        let message = try XCTUnwrap(finished.messages.first { $0.toolCallId == "read-call" })
        XCTAssertEqual(message.diagnostic?.runId, run)
        XCTAssertEqual(message.diagnostic?.callId, "read-call")
        XCTAssertEqual(message.harness?.outcome?.durationMs, 12)
        XCTAssertEqual(finished.messages.filter { $0.toolCallId == "read-call" }.count, 1)
        do {
            _ = try await fixture.api.conversation(id: id, token: fixture.other)
            XCTFail("Another account cannot read the run")
        } catch {}
        let legacy = AskAPIClient(executor: CloudRequestExecutor(selector: fixture.selector))
        let old = try await legacy.conversation(id: id, token: fixture.token)
        XCTAssertNil(old.run?.recovery)
        XCTAssertEqual(old.messages.count, finished.messages.count)
    }

    private func wait(_ api: AskAPIClient, id: String, token: String, status: String) async throws -> AskConversation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var observed = "none"
        while ContinuousClock.now < deadline {
            let value = try await api.conversation(id: id, token: token)
            if value.run?.status == status {
                return value
            }
            observed = [value.run?.status, value.run?.recovery?.state, value.run?.stopReason]
                .map { $0 ?? "nil" }.joined(separator: " / ")
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "R06 expected \(status), observed \(observed)", code: 1)
    }
}
