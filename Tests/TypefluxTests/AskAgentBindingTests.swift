import Foundation
import XCTest
@testable import Typeflux

final class AskAgentBindingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-binding-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSharedFixturesRemainReadableAndFailClosed() throws {
        struct Case: Decodable {
            var id: String
            var run: BindingRun
            var supported: Bool
        }
        struct BindingRun: Codable { var agentBinding: AskAgentBinding? }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/harness/fixtures/agent-binding.json"))
        let cases = try AskCoding.decoder().decode([Case].self, from: data)
        for value in cases {
            XCTAssertEqual((try? AskAgentBinding.resolve(value.run.agentBinding)) != nil, value.supported, value.id)
            let raw = try AskCoding.encoder().encode(value.run)
            let copy = try AskCoding.decoder().decode(BindingRun.self, from: raw)
            XCTAssertEqual(copy.agentBinding, value.run.agentBinding, value.id)
            XCTAssertEqual((try? AskAgentBinding.resolve(copy.agentBinding)) != nil, value.supported, value.id)
            if ["missing", "null"].contains(value.id) { XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("agent_binding")) }
        }
        XCTAssertEqual(try AskAgentBinding.resolve(nil), .default)
    }

    private func input() -> AskSendRequest {
        .init(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:model")
    }

    private func write(_ record: AskLocalRecord) throws -> Data {
        let data = try AskCoding.encoder().encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(record.conversation.id + ".json"))
        return data
    }

    private func read(_ id: String) throws -> AskLocalRecord {
        try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: directory.appendingPathComponent(id + ".json")))
    }

    func testNewRunIdentityLegacyReadAndReplacementRuns() async throws {
        let engine = AskLocalEngine(directory: directory)
        var c = try await engine.send(conversationId: "identity", request: input(), token: "")
        XCTAssertEqual(c.run?.agentBinding, .default)
        XCTAssertEqual(try read(c.id).conversation.run?.agentBinding, .default)
        c = try await engine.inferenceResult(conversationId: c.id, request: .init(runId: c.run!.id, deviceId: "device",
            inferenceId: c.run!.inference!.id, content: "Answer"), token: "")
        XCTAssertEqual(c.run?.agentBinding, .default)
        var record = try read(c.id)
        record.conversation.run?.agentBinding = nil
        let legacy = try write(record)
        let reopened = AskLocalEngine(directory: directory)
        let loaded = try await reopened.conversation(id: c.id, token: "")
        XCTAssertNil(loaded.run?.agentBinding)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(c.id + ".json")), legacy)
        c = try await reopened.regenerate(conversationId: c.id,
            request: .init(messageId: c.messages.last!.id, deviceId: "device", modelRef: nil), token: "")
        XCTAssertEqual(c.run?.agentBinding, .default)
        c = try await reopened.cancel(conversationId: c.id, runId: c.run!.id, token: "")
        c = try await reopened.retry(conversationId: c.id, runId: c.run!.id, deviceId: "device", modelRef: nil, token: "")
        XCTAssertEqual(c.run?.agentBinding, .default)
        XCTAssertEqual(try read(c.id).conversation.run?.agentBinding, .default)
    }

    func testUnsupportedCommandsLeaveSnapshotAndUsageIntact() async throws {
        for status in ["running", "waiting_tool", "waiting_inference", "paused_credits", "completed", "failed", "cancelled"] {
            let id = "blocked-" + status
            let original = AskLocalEngine(directory: directory)
            let request = input()
            let initial = try await original.send(conversationId: id, request: request, token: "")
            var record = try read(id)
            let run = try XCTUnwrap(initial.run)
            record.conversation.run?.agentBinding = .init(id: "future.engine", version: 1)
            record.conversation.run?.status = status
            record.conversation.run?.updatedAt = Date(timeIntervalSince1970: 0)
            record.conversation.run?.budgetEnabled = true
            record.conversation.run?.clientToolApproval = true
            record.conversation.run?.pending = [.init(id: "call", type: "function", function: .init(name: "update_plan", arguments: "{}"))]
            record.approvedCloudCallId = "call"
            let before = try write(record)
            let engine = AskLocalEngine(directory: directory)
            let loaded = try await engine.conversation(id: id, token: "")
            // JSONValue stores raw bytes whose object-key order is not semantic.
            let encoder = AskCoding.encoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(loaded), try encoder.encode(read(id).conversation))
            let listed = try await engine.list(token: "", offset: 0)
            XCTAssertTrue(listed.contains { $0.id == id })
            let operations: [() async throws -> AskConversation] = [
                { try await engine.send(conversationId: id, request: request, token: "") },
                { try await engine.result(conversationId: id, request: .init(approveExecution: true, runId: run.id,
                    deviceId: run.deviceId, toolCallId: "call", content: "approved", isError: false), token: "") },
                { try await engine.inferenceResult(conversationId: id, request: .init(runId: run.id, deviceId: run.deviceId,
                    inferenceId: run.inference!.id, content: "late answer"), token: "") },
                { try await engine.cancel(conversationId: id, runId: run.id, token: "") },
                { try await engine.retry(conversationId: id, runId: run.id, deviceId: run.deviceId, modelRef: nil, token: "") },
                { try await engine.regenerate(conversationId: id, request: .init(messageId: "answer", deviceId: run.deviceId, modelRef: nil), token: "") },
                { try await engine.steer(conversationId: id, request: .init(runId: run.id, message: request), token: "") },
                { try await engine.resume(conversationId: id, runId: run.id, token: "") }
            ]
            for operation in operations {
                do { _ = try await operation(); XCTFail("Unsupported \(status) must reject") }
                catch let error as AskLocalError { XCTAssertEqual(error.code, AskAgentBinding.errorCode) }
                catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(id + ".json")), before)
            }
            do {
                _ = try await engine.result(conversationId: id, request: .init(runId: run.id, deviceId: "other-device",
                    toolCallId: "call", content: "", isError: false), token: "")
                XCTFail("Wrong device must fail before binding")
            } catch let error as AskLocalError { XCTAssertNil(error.code) }
        }
    }

    func testLocalizedErrorUsesStableCodeWithoutBindingDetails() {
        let error = AskLocalError.implementationUnavailable
        XCTAssertEqual(error.code, "AGENT_IMPLEMENTATION_UNAVAILABLE")
        XCTAssertFalse(error.localizedDescription.contains("typeflux.default"))
        XCTAssertFalse(error.localizedDescription.contains("AGENT_IMPLEMENTATION_UNAVAILABLE"))
        XCTAssertEqual(TypefluxCloudServerErrorMessage.localizationKey(for: AskAgentBinding.errorCode), "ask.implementationUnavailable")
        XCTAssertEqual(AskLocalError.message("message").errorDescription, "message")
    }
}
