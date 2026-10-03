@testable import Typeflux
import XCTest

final class AskTypedContentIntegrationTests: XCTestCase {
    func testActivityUsesModernOutcomeAndShowsEveryImage() throws {
        let call = AskToolCall(id: "c", function: .init(name: "mcp_example", arguments: "{}"))
        let group = AskActivityGroup(id: "a", messages: [.init(id: "a", role: "assistant", text: "", toolCalls: [call], createdAt: Date())])
        var request = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "", isError: false)
        request.record(AskTypedContent.output(from: try AskTypedContentTests.result()))
        var message = request.message(step: 1, now: Date())
        XCTAssertEqual(message.isError, true, "the legacy projection is incomplete")
        XCTAssertEqual(AskPresentation.toolState(result: message), .done)
        XCTAssertEqual(AskActivity.status(group, results: [message], streamingId: nil, approvalToolId: nil), .done)
        XCTAssertEqual(AskActivity.outputs(group, results: [message]).artifacts.count, 2)
        XCTAssertEqual(AskPresentation.toolStatusText(result: message, call: call), L("ask.image.generated"))
        for status in ["denied", "invalid", "timeout", "cancelled", "unknown", "future"] {
            message.harness?.outcome?.status = status
            message.isError = false
            XCTAssertEqual(AskPresentation.toolState(result: message), .failed)
            XCTAssertEqual(AskActivity.status(group, results: [message], streamingId: nil, approvalToolId: nil), .failed)
            XCTAssertTrue(AskActivity.title(group, status: .failed, plan: nil, results: [message]).contains(L("ask.activity.failures", 1)))
        }
        message.harness?.version = 2
        message.harness?.outcome?.status = "ok"
        XCTAssertEqual(AskPresentation.toolState(result: message), .failed)
        message.harness = .init(version: 1)
        XCTAssertEqual(AskPresentation.toolState(result: message), .done)
    }

    func testProviderSchemaAndMultipleImagesRetainP07Limits() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/harness/p06-fixtures/schema.json")
        let schema = JSONValue(data: try Data(contentsOf: fixture))
        let original = try JSONSerialization.jsonObject(with: schema.data) as! NSDictionary
        let definitions = [AskToolDefinition(name: "mcp_example", description: "Example", parameters: schema)]
        let image = try AskTypedContentTests.image()
        let output = AskTypedContent.output(from: .init(content: [.init(type: "image", data: image, mimeType: "image/jpeg"), .init(type: "image", data: image, mimeType: "image/jpeg")], isError: false))
        var receipt = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "", isError: false)
        receipt.record(output)
        let call = AskToolCall(id: "c", type: "function", function: .init(name: "mcp_example", arguments: #"{"count":2}"#))
        let messages = AskLocalPrompt.messages([.init(id: "step", role: "assistant", text: "", toolCalls: [call], createdAt: Date()), receipt.message(step: 1, now: Date())], typedContentEnabled: true)
        XCTAssertFalse((messages[1]["content"] as? String ?? "").contains("failed"), "complete modern multi-image output is not a failure")
        let body: [String: Any] = ["messages": messages, "max_tokens": 8192, "tools": AskLocalPrompt.tools(definitions)]
        for anthropic in [true, false] {
            let native = try AskCustomInference.nativeBody(body, model: "fixture", anthropic: anthropic)
            if anthropic {
                XCTAssertEqual(native["max_tokens"] as? Int, 8192)
                let tools = native["tools"] as! [[String: Any]]
                XCTAssertEqual(tools[0]["input_schema"] as? NSDictionary, original)
                let parts = (native["messages"] as! [[String: Any]]).flatMap { $0["content"] as? [[String: Any]] ?? [] }
                XCTAssertEqual(parts.filter { $0["type"] as? String == "image" }.count, 2)
            } else {
                XCTAssertEqual((native["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 8192)
                let tool = (native["tools"] as! [[String: Any]])[0]
                let functions = tool["functionDeclarations"] as! [[String: Any]]
                XCTAssertEqual(functions[0]["parametersJsonSchema"] as? NSDictionary, original)
                XCTAssertNil(functions[0]["parameters"])
                let parts = (native["contents"] as! [[String: Any]]).flatMap { $0["parts"] as? [[String: Any]] ?? [] }
                XCTAssertEqual(parts.filter { $0["inlineData"] != nil }.count, 2)
            }
        }
    }

    func testSQLiteJournalAndCacheReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let cache = try AskConversationCache(url:directory.appendingPathComponent("cache.sqlite"))
        let output = AskTypedContent.output(from:try AskTypedContentTests.result())
        var req = AskToolResultRequest(runId:"r",deviceId:"d",toolCallId:"c",content:"",isError:false)
        req.record(output)
        try await cache.saveToolResult(req,owner:"owner")
        let c = AskConversation(id:"conversation",title:"t",revision:1,updatedAt:Date(),messages:[req.message(step:1,now:Date())])
        try await cache.save(c,owner:"owner")
        let reopened = try AskConversationCache(url:directory.appendingPathComponent("cache.sqlite"))
        let receipt = try await reopened.toolResult(id:"r/c",owner:"owner")
        XCTAssertEqual(receipt?.harness?.outcome?.content?.count,7)
        let saved = try await reopened.load(id:c.id,owner:"owner")
        XCTAssertEqual(saved?.messages.first?.resultImages.count,2)
        let other = try await reopened.load(id:c.id,owner:"other");XCTAssertNil(other)
        var oldServer = c;oldServer.revision=2;oldServer.messages[0].harness=nil
        try await reopened.save(oldServer,owner:"owner")
        let merged = try await reopened.load(id:c.id,owner:"owner")
        XCTAssertEqual(merged?.messages.first?.resultImages.count,2)
    }
}
