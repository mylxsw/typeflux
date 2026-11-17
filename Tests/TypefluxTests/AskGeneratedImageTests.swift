import XCTest
@testable import Typeflux

final class AskGeneratedImageTests: XCTestCase {
    func testImageCardKeepsGenerationSeparateFromFailureAndDownload() {
        XCTAssertEqual(AskImageCardState.resolve(result: nil, status: .running, active: true, started: true), .generating)
        XCTAssertEqual(AskImageCardState.resolve(result: nil, status: .running, active: false, started: true), .interrupted)
        XCTAssertEqual(AskImageCardState.resolve(result: nil, status: .paused, active: true, started: true), .interrupted)
        XCTAssertEqual(AskImageCardState.resolve(result: nil, status: .attention, active: true, started: false), .hidden)
        let image = AskGeneratedImage(assetId: "job", url: "https://cdn.example/result.png")
        var result = AskMessage(id: "result", role: "tool", text: "", toolCallId: "call", createdAt: Date(), generatedImage: image)
        XCTAssertEqual(AskImageCardState.resolve(result: result, status: .running, active: true, started: true), .ready(image))
        XCTAssertEqual(AskImageCardState.resolve(result: result, status: .done, active: false, started: true), .ready(image))
        result.isError = true
        XCTAssertEqual(AskImageCardState.resolve(result: result, status: .running, active: true, started: true), .failed)
        result.isError = false
        result.generatedImage?.url = "javascript:bad"
        XCTAssertEqual(AskImageCardState.resolve(result: result, status: .done, active: false, started: true), .failed)
    }

    func testImageCardStaysHiddenBeforeDispatchAndAfterRefusal() {
        for status in [AskActivity.Status.running, .attention, .paused, .done, .failed] {
            for active in [true, false] {
                XCTAssertEqual(AskImageCardState.resolve(result: nil, status: status, active: active, started: false), .hidden)
            }
        }
        for status in ["denied", "invalid", "cancelled"] {
            let result = AskMessage(id: "refusal", role: "tool", text: "Not executed", toolCallId: "call",
                isError: true, createdAt: Date(), harness: .init(version: 1, outcome: .init(status: status)))
            XCTAssertEqual(AskImageCardState.resolve(result: result, status: .done, active: false, started: false), .hidden)
        }
        // Another tool's approval must not hide an image that already started.
        XCTAssertEqual(AskImageCardState.resolve(result: nil, status: .attention, active: true, started: true), .generating)
    }

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
