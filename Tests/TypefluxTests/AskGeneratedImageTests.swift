import XCTest
@testable import Typeflux

final class AskGeneratedImageTests: XCTestCase {
    func testGeneratedImageDecodesAndRejectsUnsafeLinks() throws {
        let json = #"{"asset_id":"job-id","url":"https://cdn.example/image.png"}"#
        let image = try AskCoding.decoder().decode(AskGeneratedImage.self, from: Data(json.utf8))
        XCTAssertEqual(image.assetId, "job-id")
        XCTAssertNotNil(image.safeURL)
        for url in ["javascript:alert(1)", "http://cdn.example/x", "https://user:secret@cdn.example/x", "file:///tmp/image"] {
            XCTAssertNil(AskGeneratedImage(assetId: "id", url: url).safeURL)
        }
    }

    func testImageResultsAreAdvertisedAndWaitingStateIsKnown() throws {
        let request = AskSendRequest(id: "id", deviceId: "device", text: "Draw a cat", tools: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: AskCoding.encoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["image_results"] as? Bool, true)
        XCTAssertFalse(AskRunRecovery(state: "waiting_image", sequence: 1).blocksExecution)
    }

    func testSuccessfulImageToolsProduceCardsButFailuresDoNot() {
        let call = AskToolCall(id: "call", function: .init(name: "image_generate", arguments: "{}"))
        let assistant = AskMessage(id: "assistant", role: "assistant", text: "", toolCalls: [call], createdAt: Date())
        var result = AskMessage(id: "result", role: "tool", text: "Created", toolCallId: "call", createdAt: Date())
        result.generatedImage = AskGeneratedImage(assetId: "job", url: "https://cdn.example/image.png")
        let group = AskActivityGroup(id: "activity", messages: [assistant])
        let outputs = AskActivity.outputs(group, results: [result])
        XCTAssertEqual(outputs.generatedImages.count, 1)
        XCTAssertFalse(outputs.isEmpty)
        result.isError = true
        XCTAssertTrue(AskActivity.outputs(group, results: [result]).generatedImages.isEmpty)
        result.isError = false
        result.generatedImage?.url = "javascript:bad"
        XCTAssertTrue(AskActivity.outputs(group, results: [result]).generatedImages.isEmpty)
    }
}
