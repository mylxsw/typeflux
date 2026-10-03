@testable import Typeflux
import AppKit
import XCTest

final class AskTypedContentTests: XCTestCase {
    static func image() throws -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        return try XCTUnwrap(bitmap.representation(using:.jpeg,properties:[:])).base64EncodedString()
    }
    static func result() throws -> MCPToolsCallResult {
        let image = try image()
        return try JSONDecoder().decode(MCPToolsCallResult.self,from:JSONSerialization.data(withJSONObject:[
            "content":[["type":"text","text":"hello"],["type":"image","data":image,"mimeType":"image/jpeg","_meta":["a":1]],
                       ["type":"image","data":image,"mimeType":"image/jpeg"],["type":"resource_link","uri":"https://example.invalid/data"],
                       ["type":"future","data":"private binary","_meta":["camelCase":1,"flag":false]]],
            "structuredContent":["count":1,"camelCase":true],"_meta":["version":1]]))
    }
    func testOpaqueMCPAndStructuredOnlyRoundTrip() throws {
        let raw = #"{"structuredContent":{"count":1,"camelCase":false},"_meta":{"unknown_key":[true,0,1]},"content":[{"type":"resource","resource":{"uri":"file:///private","blob":"aGVsbG8=","mimeType":"text/plain","_meta":{"testKey":1}},"annotations":{"audience":["user"]}},{"type":"future","vendorThing":{"ok":false}}]}"#
        let value = try JSONDecoder().decode(MCPToolsCallResult.self,from:Data(raw.utf8))
        XCTAssertEqual(try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? NSDictionary, try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? NSDictionary)
        let structured = try JSONDecoder().decode(MCPToolsCallResult.self,from:Data(#"{"structuredContent":{"count":1}}"#.utf8))
        let output = AskTypedContent.output(from:structured)
        XCTAssertTrue(output.content.contains("Structured content"));XCTAssertFalse(output.isError)
        XCTAssertEqual(output.outcome?.content?.count,1)
    }
    func testLegacyAccessorsReadOpaqueBlocksWithoutDroppingMetadata() throws {
        let raw = #"{"type":"resource","text":"caption","data":"payload","mimeType":"text/plain","resource":{"uri":"file:///example","text":"embedded","blob":"opaque"},"extra":{"count":1}}"#
        let block = try JSONDecoder().decode(MCPContentBlock.self, from: Data(raw.utf8))
        XCTAssertEqual(block.type, "resource"); XCTAssertEqual(block.text, "caption")
        XCTAssertEqual(block.data, "payload"); XCTAssertEqual(block.mimeType, "text/plain")
        XCTAssertEqual(block.resource?.text, "embedded")
        XCTAssertEqual((block.object["resource"] as? [String: Any])?["blob"] as? String, "opaque")
        XCTAssertNil(MCPContentBlock(type: "text").resource)
        let schema = try JSONDecoder().decode(MCPObjectSchema.self, from: Data(#"{"type":"object","description":"root","properties":{"x":{"type":"integer"}},"required":["x"],"additionalProperties":false}"#.utf8))
        XCTAssertEqual(schema.description, "root"); XCTAssertEqual(schema.required, ["x"])
        XCTAssertEqual(schema.additionalProperties?.value as? Bool, false)
        XCTAssertEqual((schema.properties?["x"]?.value as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual(MCPToolsListParams(cursor: "next").cursor, "next")
        XCTAssertThrowsError(try JSONEncoder().encode(AnyCodable(Date())))
        XCTAssertThrowsError(try JSONDecoder().decode(MCPMessageId.self, from: Data("true".utf8)))
        XCTAssertThrowsError(try MCPJsonRPCMessage().decodeToolsCallResult())
        XCTAssertThrowsError(try MCPJsonRPCMessage().decodeInitializeResult())
        XCTAssertThrowsError(try MCPJsonRPCMessage(error: .init(code: 1, message: "failure", data: nil)).decodeInitializeResult())
        XCTAssertFalse(MCPClientError.notConnected.localizedDescription.isEmpty)
        XCTAssertFalse(MCPClientError.encodingError("failure").localizedDescription.isEmpty)
    }

    func testAllBlocksSurviveAndUnsupportedIsVisible() throws {
        let output = AskTypedContent.output(from:try Self.result())
        let outcome = try XCTUnwrap(output.outcome)
        XCTAssertEqual(outcome.content?.count,7)
        XCTAssertEqual(AskTypedContent.project(outcome).images.count,2)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.content.contains("automatic retrieval is unsupported"))
        XCTAssertTrue(output.content.contains("Unsupported content retained: future"))
        XCTAssertFalse(output.content.contains("private binary"))
        let request = AskToolResultRequest(runId:"run",deviceId:"device",toolCallId:"call",content:output.content,isError:output.isError,image:output.image,harness:.init(version:1,outcome:outcome))
        let decoded = try AskCoding.decoder().decode(AskToolResultRequest.self,from:AskCoding.encoder().encode(request))
        let unknown = AskTypedContent.object(decoded.harness!.outcome!.content![4])
        XCTAssertEqual((unknown["_meta"] as? [String:Any])?["camelCase"] as? Int,1)
        XCTAssertEqual((unknown["_meta"] as? [String:Any])?["flag"] as? Bool,false)
        let message = request.message(step:2,now:Date())
        XCTAssertEqual(message.resultImages.count,2)
        XCTAssertEqual(message.diagnostic?.stepId,"2")
        let log = String(decoding:try AskCoding.encoder().encode(message.diagnostic),as:UTF8.self)
        XCTAssertFalse(log.contains("private binary"));XCTAssertFalse(log.contains("example.invalid"))
    }
    func testLimitsAndMalformedContentAreVisible() throws {
        let huge = AskTypedContent.json(["type":"text","text":String(repeating:"大",count:210000)])
        let bounded = AskTypedContent.bounded(.init(status:"ok",content:[huge]))
        XCTAssertEqual(bounded.truncated,true)
        XCTAssertTrue(AskTypedContent.project(bounded).text.contains("truncated"))
        let many = AskTypedContent.bounded(.init(status:"ok",content:Array(repeating:AskTypedContent.json(["type":"text","text":"x"]),count:100)))
        XCTAssertEqual(many.content?.count,64);XCTAssertEqual(many.truncated,true)
        let exactly = AskTypedContent.bounded(.init(status:"ok",content:Array(repeating:AskTypedContent.json(["type":"text","text":"x"]),count:64)))
        XCTAssertNil(exactly.truncated)
        let total = AskTypedContent.bounded(.init(status:"ok",content:Array(repeating:AskTypedContent.json(["type":"text","text":String(repeating:"x",count:400000)]),count:3)))
        XCTAssertEqual(total.truncated,true)
        let invalid = AskTypedContent.bounded(.init(status:"ok",content:[AskTypedContent.json(["missing":true])]))
        XCTAssertEqual(invalid.truncated,true)
        let hugeType = AskTypedContent.bounded(.init(status: "ok", content: [AskTypedContent.json(["type": String(repeating: "x", count: 700000)])]))
        XCTAssertLessThan(try AskCoding.encoder().encode(hugeType).count, 1000)
        let projected = AskTypedContent.project(.init(status:"ok",content:[AskTypedContent.json(["type":"text","text":String(repeating:"大",count:30000)])]))
        XCTAssertTrue(projected.incomplete);XCTAssertLessThan(projected.text.utf8.count,61000)
        XCTAssertEqual(AskTypedContent.clip("abc",bytes:3),"abc")
        for block in [["type":"text"],["type":"image"],["type":"structured_content"],["type":"audio","data":"secret"]] {
            let p = AskTypedContent.project(.init(status:"ok",content:[AskTypedContent.json(block)]))
            XCTAssertTrue(p.incomplete);XCTAssertFalse(p.text.isEmpty);XCTAssertFalse(p.text.contains("secret"))
        }
        XCTAssertTrue(AskTypedContent.project(.init(status:"future")).text.contains("unknown"))
        XCTAssertNil(AskTypedContent.imageURL(["mimeType":"image/jpeg","data":"aGVsbG8="]))
        XCTAssertNil(AskTypedContent.imageURL(["mimeType":"image/png","data":try Self.image()]))
    }
    func testTrustedNegotiationDoesNotReadPayloadCapabilities() throws {
        var request = AskToolResultRequest(runId:"r",deviceId:"d",toolCallId:"c",content:"x",isError:false)
        request.record(.init(content:"x"))
        XCTAssertEqual(request.harness?.outcome?.safeStatus,.ok)
        request.harness?.capabilities = ["typed_content_v1"]
        XCTAssertNil(request.forPeer(nil,enabled:[.typedContent]).harness)
        XCTAssertNil(request.forPeer(AskTypedContent.advertisement).harness)
        XCTAssertNotNil(request.forPeer(AskTypedContent.advertisement,enabled:[.typedContent]).harness)
        request.record(.init(content:"failed",isError:true))
        XCTAssertEqual(request.harness?.outcome?.safeStatus,.unknown)
        let legacy = AskMessage(id:"old",role:"tool",text:"old text",image:"legacy-image",createdAt:Date())
        XCTAssertEqual(legacy.resultText,"old text");XCTAssertEqual(legacy.resultImages,["legacy-image"])
    }
    func testLegacyProjectionRejectsInconsistentSuccessAndKeepsSimpleImages() throws {
        var receipt = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "denied", isError: false,
                                          image: "legacy-image", harness: .init(version: 1, outcome: .init(status: "denied")))
        let projected = receipt.forPeer(nil)
        XCTAssertTrue(projected.isError); XCTAssertEqual(projected.content, "denied"); XCTAssertEqual(projected.image, "legacy-image")
        XCTAssertEqual(receipt.message(step: 1, now: Date()).resultText, "denied")
        receipt.harness?.version = 9
        XCTAssertTrue(receipt.legacyProjection().content.contains("Unsupported result contract"))
        XCTAssertEqual(receipt.message(step: 1, now: Date()).diagnostic?.status, "unknown")
        receipt.harness = .init(version: 1)
        XCTAssertEqual(receipt.legacyProjection().content, "denied")
        receipt.harness = nil
        receipt.record(.init(content: "screenshot", image: "legacy-image"))
        XCTAssertEqual(receipt.message(step: 1, now: Date()).resultImages, ["legacy-image"])
        let huge = AskTypedContent.output(from: .init(content: [.init(type: "text", text: String(repeating: "x", count: 700000))], isError: false))
        receipt.record(huge)
        let reopened = try AskCoding.decoder().decode(AskToolResultRequest.self, from: AskCoding.encoder().encode(receipt))
        XCTAssertEqual(reopened.harness?.outcome?.truncated, true)
        XCTAssertTrue(reopened.isError)
        XCTAssertTrue(reopened.content.contains("truncated"))
    }


}
