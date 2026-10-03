import Foundation
@testable import Typeflux
import XCTest

final class MCPSSEParserTests: XCTestCase {
    func testEveryPossibleChunkBoundaryProducesIdenticalEvents() throws {
        let bytes = Data("\u{FEFF}: hello\r\nevent: message\r\nid: 1\r\ndata: 你好🌍\r\ndata: second\r\n\r\ndata\n\ndata:last\r\r"
            .utf8)
        for boundary in 0 ... bytes.count {
            var parser = MCPSSEParser()
            var events: [String] = []
            let receive: (Data) -> Bool = { events.append(String(decoding: $0, as: UTF8.self)); return true }
            try parser.append(Data(bytes.prefix(boundary)), receive: receive)
            try parser.append(Data(bytes.dropFirst(boundary)), receive: receive)
            XCTAssertEqual(events, ["你好🌍\nsecond", "last"], "boundary \(boundary)")
        }
    }

    func testWhitespaceUnknownFieldsAndEmptyFrames() throws {
        var parser = MCPSSEParser()
        var events: [Data] = []
        try parser.append(Data("\n:heartbeat\n\nid: 1\n\ndata:\n\nretry: 10\ndata:  space \ndata:\n\n".utf8)) {
            events.append($0); return true
        }
        XCTAssertEqual(events.map { String(decoding: $0, as: UTF8.self) }, [" space \n"])
    }

    func testTruncatedFrameIsNotDispatchedAndReceiverCanStop() throws {
        var parser = MCPSSEParser()
        var events: [Data] = []
        try parser.append(Data("data: partial\n".utf8)) { events.append($0); return true }
        XCTAssertTrue(events.isEmpty)
        try parser.append(Data("\ndata: second\n\n".utf8)) { events.append($0); return false }
        XCTAssertEqual(events, [Data("partial".utf8)])
    }

    func testInvalidUTF8AndAccumulatedEventSizeAreRejected() throws {
        var parser = MCPSSEParser()
        XCTAssertThrowsError(try parser.append(Data([0xFF, 10])) { _ in true })
        var bounded = MCPSSEParser(maximumEventBytes: 32)
        XCTAssertThrowsError(try bounded.append(Data(String(repeating: "data: abc\n", count: 20).utf8)) { _ in true })
    }
}
