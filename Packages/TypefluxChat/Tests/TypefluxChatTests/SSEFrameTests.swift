import XCTest
@testable import TypefluxChat

final class SSEFrameTests: XCTestCase {
    func testUTF8SplitAtEveryByteAndMultilineCRLFFrame() throws {
        var parser = SSEFrame()
        let wire = ": comment\r\nid: 1\r\nevent: snapshot\r\ndata: 中文🦆\r\ndata: second\r\n\r\ndata: next\n\n"
        var frames: [(String, String)] = []
        for byte in wire.utf8 { if let frame = try parser.push(byte) { frames.append(frame) } }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].0, "snapshot")
        XCTAssertEqual(frames[0].1, "中文🦆\nsecond")
        XCTAssertEqual(frames[1].0, "message")
        XCTAssertEqual(frames[1].1, "next")
    }

    func testEmptyCommentsUnknownFieldsAndEventOnlyFramesAreIgnored() throws {
        var parser = SSEFrame()
        XCTAssertNil(try parser.append("event: stale"))
        XCTAssertNil(try parser.append(":"))
        XCTAssertNil(try parser.append("retry: 1000"))
        XCTAssertNil(try parser.append(""))
        XCTAssertNil(try parser.append("data:without-space"))
        let result = try parser.append("")
        XCTAssertEqual(result?.0, "message")
        XCTAssertEqual(result?.1, "without-space")
    }

    func testRejectsInvalidUTF8OversizedLineAndOversizedAccumulatedFrame() throws {
        var invalid = SSEFrame()
        XCTAssertNil(try invalid.push(255))
        XCTAssertThrowsError(try invalid.push(10))
        var line = SSEFrame(limit: 4)
        for byte in "abcd".utf8 { XCTAssertNil(try line.push(byte)) }
        XCTAssertThrowsError(try line.push(101))
        var frame = SSEFrame(limit: 12)
        XCTAssertNil(try frame.append("data:123456"))
        XCTAssertThrowsError(try frame.append("data:abcdef"))
        XCTAssertThrowsError(try SSEFrame(limit: 1).appendingForTest("too large"))
    }
}

private extension SSEFrame {
    func appendingForTest(_ line: String) throws -> (String, String)? {
        var copy = self
        return try copy.append(line)
    }
}
