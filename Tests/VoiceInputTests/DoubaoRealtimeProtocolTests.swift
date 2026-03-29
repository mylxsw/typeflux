import XCTest
@testable import VoiceInput

final class DoubaoRealtimeProtocolTests: XCTestCase {
    func testBuildClientRequestIncludesHotwordsContext() throws {
        let data = DoubaoProtocol.buildClientRequest(uid: "user-1", hotwords: ["火山引擎", "豆包"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(request["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request["show_utterances"] as? Bool, true)

        let contextString = try XCTUnwrap(request["context"] as? String)
        let contextData = try XCTUnwrap(contextString.data(using: .utf8))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: contextData) as? [String: Any])
        let hotwords = try XCTUnwrap(context["hotwords"] as? [[String: Any]])
        XCTAssertEqual(hotwords.count, 2)
        XCTAssertEqual(hotwords.first?["word"] as? String, "火山引擎")
    }

    func testDecodeServerResponseBuildsFinalSnapshot() throws {
        let payload: [String: Any] = [
            "result": [
                "text": "你好世界",
                "utterances": [
                    ["text": "你好", "definite": true],
                    ["text": "世界", "definite": true]
                ]
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let data = DoubaoProtocol.encodeMessage(
            header: DoubaoHeader(
                messageType: .serverResponse,
                flags: .asyncFinal,
                serialization: .json,
                compression: .none
            ),
            payload: payloadData
        )

        let response = try DoubaoProtocol.decodeServerResponse(data)
        XCTAssertEqual(response.snapshot.text, "你好世界")
        XCTAssertTrue(response.snapshot.isFinal)
        XCTAssertEqual(response.utterances.count, 2)
    }
}
