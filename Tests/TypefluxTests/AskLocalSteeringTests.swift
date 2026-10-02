@testable import Typeflux
import XCTest

final class AskLocalSteeringTests: XCTestCase {
    private var directory: URL!
    private let device = "device-1"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-local-steer-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine() -> AskLocalEngine {
        AskLocalEngine(directory: directory, webTools: AskLocalWebTools(resolve: { _ in [] }))
    }

    private func send(_ engine: AskLocalEngine, _ id: String, _ text: String = "Hello") async throws -> AskConversation {
        try await engine.send(conversationId: id, request: AskSendRequest(id: UUID().uuidString, deviceId: device, text: text,
                                                                         tools: AskLocalTools.builtins, modelRef: "custom:m"), token: "")
    }

    private func answer(_ engine: AskLocalEngine, _ c: AskConversation, content: String = "", calls: [AskToolCall] = []) async throws -> AskConversation {
        let run = try XCTUnwrap(c.run)
        let inference = try XCTUnwrap(run.inference)
        return try await engine.inferenceResult(conversationId: c.id, request: AskInferenceResult(
            runId: run.id, deviceId: device, inferenceId: inference.id, content: content, toolCalls: calls), token: "")
    }

    private func steer(_ c: AskConversation, _ text: String, id: String = UUID().uuidString) -> AskSteerRequest {
        AskSteerRequest(runId: c.run?.id ?? "", message: AskSendRequest(id: id, deviceId: device, text: text, tools: []))
    }

    func testSteeringIsDeliveredAfterTheToolResult() async throws {
        let engine = engine()
        let id = UUID().uuidString.lowercased()
        var c = try await send(engine, id)
        let browse = AskToolCall(id: "b1", type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        c = try await answer(engine, c, calls: [browse])
        XCTAssertEqual(c.run?.status, "waiting_tool")
        let request = steer(c, "Also in English")
        c = try await engine.steer(conversationId: id, request: request, token: "")
        _ = try await engine.steer(conversationId: id, request: request, token: "")
        XCTAssertFalse(c.messages.contains { $0.id == request.id }, "it waits for the next step")

        c = try await engine.result(conversationId: id, request: AskToolResultRequest(runId: c.run!.id, deviceId: device, toolCallId: "b1", content: "page", isError: false), token: "")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.messages.map(\.role), ["user", "assistant", "tool", "user"])
        XCTAssertEqual(c.messages.last?.id, request.id)
        XCTAssertEqual(c.messages.last?.steered, true)
        XCTAssertEqual(c.run?.extraSteps, AskLocalEngine.steeringStepBonus)
        let payload = try XCTUnwrap(c.run?.inference?.payload)
        XCTAssertTrue(payload.contains("Also in English"))
        // Replaying a delivered message changes nothing.
        let replay = try await engine.steer(conversationId: id, request: request, token: "")
        XCTAssertEqual(replay.revision, c.revision)
    }

    func testSteeringDuringTheAnswerContinuesTheRun() async throws {
        let engine = engine()
        let id = UUID().uuidString.lowercased()
        var c = try await send(engine, id)
        _ = try await engine.steer(conversationId: id, request: steer(c, "One more thing"), token: "")
        // The device is still computing the answer; the steering waits for it.
        c = try await engine.conversation(id: id, token: "")
        c = try await answer(engine, c, content: "First answer")
        XCTAssertEqual(c.run?.status, "waiting_inference", "the run continues instead of completing")
        XCTAssertEqual(c.messages.map(\.text), ["Hello", "First answer", "One more thing"])
        c = try await answer(engine, c, content: "Second answer")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertEqual(c.run?.steps, 2)
    }

    func testSteeringRejectsFinishedRunsEmptyTextAndOverflow() async throws {
        let engine = engine()
        let id = UUID().uuidString.lowercased()
        var c = try await send(engine, id)
        do {
            _ = try await engine.steer(conversationId: id, request: steer(c, "  "), token: "")
            XCTFail("an empty message is rejected")
        } catch {}
        var wrong = steer(c, "Hi")
        wrong.runId = "other"
        do {
            _ = try await engine.steer(conversationId: id, request: wrong, token: "")
            XCTFail("another run is rejected")
        } catch {}
        for _ in 0 ..< AskLocalEngine.maxSteering {
            c = try await engine.steer(conversationId: id, request: steer(c, "More"), token: "")
        }
        do {
            _ = try await engine.steer(conversationId: id, request: steer(c, "Too many"), token: "")
            XCTFail("the waiting list is bounded")
        } catch {}
        c = try await engine.cancel(conversationId: id, runId: c.run!.id, token: "")
        do {
            _ = try await engine.steer(conversationId: id, request: steer(c, "Late"), token: "")
            XCTFail("a stopped run takes no more messages")
        } catch {}
        // The next run starts without the leftovers; the device sends them itself.
        c = try await send(engine, id, "Next")
        c = try await answer(engine, c, content: "Done")
        XCTAssertFalse(c.messages.contains { $0.text == "More" })
    }

    func testRoutedAPIForwardsSteeringAndOtherServicesReject() async throws {
        let local = engine()
        let routed = AskRoutedAPI(cloud: AskAPIClient(), local: local)
        let id = UUID().uuidString.lowercased()
        let c = try await send(local, id)
        let value = try await routed.steer(conversationId: id, request: steer(c, "Via router"), token: "")
        XCTAssertEqual(value.id, id)
        struct Bare: AskAPI {
            func list(token: String, offset: Int) async throws -> [AskConversationSummary] { [] }
            func conversation(id: String, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
            func delete(conversationId: String, token: String) async throws {}
            func purgeMemory(token: String) async throws {}
            func models(token: String) async throws -> [AskCloudModel] { [] }
            func models(token: String, scenario: String) async throws -> [AskCloudModel] { [] }
            func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { throw AskLocalError.message("x") }
        }
        do {
            _ = try await Bare().steer(conversationId: id, request: steer(c, "x"), token: "")
            XCTFail("services without steering reject it")
        } catch {}
        let encoded = try XCTUnwrap(String(data: AskCoding.encoder().encode(steer(c, "Wire", id: "m1")), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""run_id""#) && encoded.contains(#""device_id""#) && encoded.contains(#""id":"m1""#))
    }
}
