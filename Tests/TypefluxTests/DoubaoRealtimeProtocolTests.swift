import XCTest
@testable import Typeflux

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

// MARK: - Extended DoubaoProtocol tests

final class DoubaoProtocolExtendedTests: XCTestCase {

    // MARK: - DoubaoHeader encode/decode

    func testDoubaoHeaderEncodeDecodeRoundTrip() throws {
        let original = DoubaoHeader(
            messageType: .serverResponse,
            flags: .asyncFinal,
            serialization: .json,
            compression: .none
        )
        let encoded = original.encode()
        let decoded = try DoubaoHeader.decode(from: encoded)

        XCTAssertEqual(decoded.messageType, original.messageType)
        XCTAssertEqual(decoded.flags, original.flags)
        XCTAssertEqual(decoded.serialization, original.serialization)
        XCTAssertEqual(decoded.compression, original.compression)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.headerSize, original.headerSize)
    }

    func testDoubaoHeaderDecodeThrowsOnTooShortData() {
        XCTAssertThrowsError(try DoubaoHeader.decode(from: Data([0x11]))) { error in
            if let protoError = error as? DoubaoProtocolError,
               case .headerTooShort = protoError {
                // expected
            } else {
                XCTFail("Expected headerTooShort, got \(error)")
            }
        }
    }

    func testDoubaoHeaderDecodeThrowsOnUnknownMessageType() {
        // Build 4 bytes where message type nibble is invalid
        var data = Data([0x11, 0xF0, 0x10, 0x00])  // 0xF high nibble = 0xF message type
        XCTAssertThrowsError(try DoubaoHeader.decode(from: data)) { error in
            guard let protoError = error as? DoubaoProtocolError else {
                XCTFail("Expected DoubaoProtocolError")
                return
            }
            if case .unknownMessageType = protoError {
                // expected
            } else {
                XCTFail("Expected unknownMessageType, got \(protoError)")
            }
        }
    }

    func testDoubaoHeaderEncode4Bytes() {
        let header = DoubaoHeader(
            messageType: .audioOnlyRequest,
            flags: .noSequence,
            serialization: .none,
            compression: .none
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 4)
    }

    // MARK: - DoubaoMessageType raw values

    func testDoubaoMessageTypeRawValues() {
        XCTAssertEqual(DoubaoMessageType.audioOnlyRequest.rawValue, 0b0001)
        XCTAssertEqual(DoubaoMessageType.fullClientRequest.rawValue, 0b0010)
        XCTAssertEqual(DoubaoMessageType.serverResponse.rawValue, 0b1001)
        XCTAssertEqual(DoubaoMessageType.serverError.rawValue, 0b1111)
    }

    // MARK: - DoubaoMessageFlags

    func testDoubaoMessageFlagsRawValues() {
        XCTAssertEqual(DoubaoMessageFlags.noSequence.rawValue, 0b0000)
        XCTAssertEqual(DoubaoMessageFlags.lastPacketNoSequence.rawValue, 0b0010)
        XCTAssertEqual(DoubaoMessageFlags.hasSequence.rawValue, 0b0001)
        XCTAssertEqual(DoubaoMessageFlags.asyncFinal.rawValue, 0b0011)
    }

    func testDoubaoMessageFlagsHasSequence() {
        XCTAssertFalse(DoubaoMessageFlags.noSequence.hasSequence)
        XCTAssertFalse(DoubaoMessageFlags.lastPacketNoSequence.hasSequence)
        XCTAssertTrue(DoubaoMessageFlags.hasSequence.hasSequence)
        XCTAssertTrue(DoubaoMessageFlags.asyncFinal.hasSequence)
    }

    // MARK: - DoubaoSerialization and DoubaoCompression

    func testDoubaoSerializationRawValues() {
        XCTAssertEqual(DoubaoSerialization.none.rawValue, 0b0000)
        XCTAssertEqual(DoubaoSerialization.json.rawValue, 0b0001)
    }

    func testDoubaoCompressionRawValues() {
        XCTAssertEqual(DoubaoCompression.none.rawValue, 0b0000)
        XCTAssertEqual(DoubaoCompression.gzip.rawValue, 0b0001)
    }

    // MARK: - DoubaoProtocol.buildClientRequest

    func testBuildClientRequestWithoutHotwords() throws {
        let data = DoubaoProtocol.buildClientRequest(uid: "user-123", hotwords: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(request["model_name"] as? String, "bigmodel")
        XCTAssertNil(request["context"])
    }

    func testBuildClientRequestAudioConfiguration() throws {
        let data = DoubaoProtocol.buildClientRequest(uid: "test-uid", hotwords: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["codec"] as? String, "raw")
        XCTAssertEqual(audio["rate"] as? Int, 16_000)
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)
    }

    func testBuildClientRequestUserUID() throws {
        let data = DoubaoProtocol.buildClientRequest(uid: "my-user-id", hotwords: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let user = try XCTUnwrap(json["user"] as? [String: Any])
        XCTAssertEqual(user["uid"] as? String, "my-user-id")
    }

    func testBuildClientRequestIncludesRequiredFlags() throws {
        let data = DoubaoProtocol.buildClientRequest(uid: "u1", hotwords: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(request["enable_punc"] as? Bool, true)
        XCTAssertEqual(request["enable_ddc"] as? Bool, true)
        XCTAssertEqual(request["show_utterances"] as? Bool, true)
    }

    // MARK: - DoubaoProtocol.encodeMessage

    func testEncodeMessageWithoutSequence() throws {
        let header = DoubaoHeader(
            messageType: .audioOnlyRequest,
            flags: .noSequence,
            serialization: .none,
            compression: .none
        )
        let payload = Data([0x01, 0x02, 0x03])
        let message = DoubaoProtocol.encodeMessage(header: header, payload: payload)

        // message = 4 (header) + 4 (size) + 3 (payload)
        XCTAssertEqual(message.count, 11)
    }

    func testEncodeMessageWithSequenceNumber() throws {
        let header = DoubaoHeader(
            messageType: .audioOnlyRequest,
            flags: .hasSequence,
            serialization: .none,
            compression: .none
        )
        let payload = Data([0xAA, 0xBB])
        let message = DoubaoProtocol.encodeMessage(header: header, payload: payload, sequenceNumber: 42)

        // message = 4 (header) + 4 (sequence) + 4 (size) + 2 (payload)
        XCTAssertEqual(message.count, 14)
    }

    // MARK: - DoubaoProtocol.encodeAudioPacket

    func testEncodeAudioPacketIsNotLastPacket() {
        let audio = Data([0x01, 0x02])
        let packet = DoubaoProtocol.encodeAudioPacket(audioData: audio, isLast: false)
        // Decode the header to check flags
        let header = try? DoubaoHeader.decode(from: packet)
        XCTAssertEqual(header?.flags, .noSequence)
        XCTAssertEqual(header?.messageType, .audioOnlyRequest)
    }

    func testEncodeAudioPacketIsLastPacket() {
        let audio = Data([0x01, 0x02])
        let packet = DoubaoProtocol.encodeAudioPacket(audioData: audio, isLast: true)
        let header = try? DoubaoHeader.decode(from: packet)
        XCTAssertEqual(header?.flags, .lastPacketNoSequence)
    }

    // MARK: - DoubaoProtocolError descriptions

    func testDoubaoProtocolErrorDescriptions() {
        XCTAssertNotNil(DoubaoProtocolError.headerTooShort.errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.invalidPayload.errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.decompressionFailed.errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.unknownMessageType(0xFF).errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.unknownFlags(0xFF).errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.unknownSerialization(0xFF).errorDescription)
        XCTAssertNotNil(DoubaoProtocolError.unknownCompression(0xFF).errorDescription)
    }

    func testDoubaoProtocolErrorServerError() {
        let error = DoubaoProtocolError.serverError(code: 500, message: "Internal server error")
        XCTAssertEqual(error.errorDescription, "Internal server error")
    }

    func testDoubaoProtocolErrorServerErrorWithNilMessage() {
        let error = DoubaoProtocolError.serverError(code: 404, message: nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("404"))
    }

    // MARK: - DoubaoUtterance

    func testDoubaoUtteranceEquality() {
        let u1 = DoubaoUtterance(text: "hello", definite: true)
        let u2 = DoubaoUtterance(text: "hello", definite: true)
        XCTAssertEqual(u1, u2)
    }

    func testDoubaoUtteranceInequality() {
        let u1 = DoubaoUtterance(text: "hello", definite: true)
        let u2 = DoubaoUtterance(text: "world", definite: false)
        XCTAssertNotEqual(u1, u2)
    }
}
