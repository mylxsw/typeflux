@testable import Typeflux
import XCTest

@MainActor final class AskProjectProtocolTests: XCTestCase {
    func testLocalProtocolPreservesOrderedEffectsFailuresAndDuplicateReceipts() async throws {
        for failure in ["", "test_failure", "preview_failure", "source_conflict", "cancelled", "unknown_lease"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = AskLocalEngine(directory: directory, webTools: .init(resolve: { _ in [] }))
            let definitions = try [
                AskLocalTools.projectDefinition(roots: ["/fixture"]),
                AskLocalTools.terminalDefinition,
                AskLocalTools.artifactDefinition
            ]
            let request = AskSendRequest(
                id: UUID().uuidString,
                deviceId: "device",
                text: "Complete the project benchmark",
                tools: definitions,
                modelRef: "custom:fixture"
            )
            var conversation = try await engine.send(conversationId: "conversation", request: request, token: "")
            let stages = [("project_files", "read"), ("project_files", "edit"), ("project_files", "review"),
                          ("project_terminal", "start"), ("project_terminal", "status"), (
                              "project_terminal",
                              "preview"
                          ),
                          ("artifact", "capture"), ("project_terminal", "stop")]
            var receipts: [AskToolResultRequest] = []
            for (name, action) in stages {
                let run = try XCTUnwrap(conversation.run), inference = try XCTUnwrap(run.inference)
                let call = AskToolCall(
                    id: UUID().uuidString,
                    function: .init(name: name, arguments: "{\"action\":\"\(action)\"}")
                )
                conversation = try await engine.inferenceResult(conversationId: conversation.id,
                                                                request: .init(
                                                                    runId: run.id,
                                                                    deviceId: "device",
                                                                    inferenceId: inference.id,
                                                                    content: "",
                                                                    toolCalls: [call]
                                                                ), token: "")
                XCTAssertEqual(conversation.run?.status, "waiting_tool")
                let output = AskLocalToolOutput(
                    content: "observed: \(action); failure: \(failure)",
                    isError: !failure.isEmpty,
                    outcome: .init(status: failure.isEmpty ? "ok" : "invalid", effectVerified: failure.isEmpty)
                )
                var receipt = AskToolResultRequest(
                    runId: run.id,
                    deviceId: "device",
                    toolCallId: call.id,
                    content: "",
                    isError: false
                )
                receipt.record(output); receipts.append(receipt)
                conversation = try await engine.result(conversationId: conversation.id, request: receipt, token: "")
                let duplicate = try await engine.result(conversationId: conversation.id, request: receipt, token: "")
                XCTAssertEqual(duplicate.revision, conversation.revision)
                XCTAssertTrue(conversation.run?.inference?.payload.contains("failure: \(failure)") == true)
            }
            let run = try XCTUnwrap(conversation.run)
            conversation = try await engine.inferenceResult(conversationId: conversation.id,
                                                            request: .init(
                                                                runId: run.id,
                                                                deviceId: "device",
                                                                inferenceId: XCTUnwrap(run.inference?.id),
                                                                content: "All steps complete"
                                                            ), token: "")
            let reopened = try await AskLocalEngine(directory: directory, webTools: .init(resolve: { _ in [] }))
                .conversation(id: conversation.id, token: "")
            let results = reopened.messages.filter { $0.role == "tool" }
            XCTAssertEqual(results.map(\.toolCallId), receipts.map(\.toolCallId))
            for result in results {
                XCTAssertEqual(AskPresentation.toolState(result: result), failure.isEmpty ? .done : .failed,
                               "Model completion cannot turn failed device evidence into success")
            }
        }
    }
}
