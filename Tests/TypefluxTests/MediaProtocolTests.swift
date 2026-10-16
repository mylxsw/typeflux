import AppKit
import ImageIO
import CoreText
import PDFKit
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

final class MediaProtocolTests: XCTestCase {
    func testInvalidIdentityVersionAndAmbiguousResponsesFailClosed() throws {
        let request = MediaRequest(operation: .pdf)
        let valid = MediaResponse(id: request.id, items: [.init(text: "hello", pages: 1)])
        try valid.validate(for: request)
        var bad = valid; bad.version = 2
        XCTAssertThrowsError(try bad.validate(for: request))
        bad = valid; bad.id = UUID()
        XCTAssertThrowsError(try bad.validate(for: request))
        bad = valid; bad.failure = .unreadable
        XCTAssertThrowsError(try bad.validate(for: request))
        var wrong = request; wrong.version = 2
        XCTAssertThrowsError(try valid.validate(for: wrong))
        for items: [MediaItem] in [[], [.init()], [.init(text: "", pages: 1)], [.init(text: "x", pages: 0)],
                                  [.init(text: "x", pages: 1, page: 1)],
                                  [.init(text: String(repeating: "x", count: MediaLimits.textCharacters + 1), pages: 1)],
                                  [.init(text: "x", pages: 1), .init(text: "y", pages: 1)]] {
            XCTAssertThrowsError(try MediaResponse(id: request.id, items: items).validate(for: request))
        }
        XCTAssertThrowsError(try MediaResponse(id: request.id, failure: .tooLarge).validate(for: request)) {
            XCTAssertEqual($0 as? MediaFailure, .tooLarge)
        }
    }

    func testJPEGEnvelopeRejectsMixedWrongTypeBrokenBase64AndPageOrdering() throws {
        let jpeg = try XCTUnwrap(MediaDecoder.image(AskAttachmentFixture.encode(
            AskAttachmentFixture.image(width: 10, height: 10), type: .png)).image)
        let request = MediaRequest(operation: .image)
        try MediaResponse(id: request.id, items: [.init(image: jpeg)]).validate(for: request)
        for item in [MediaItem(image: jpeg, text: "x"), .init(image: jpeg, truncated: true),
                     .init(image: jpeg, pages: 1), .init(image: jpeg, page: 1), .init(image: "data:image/png;base64,xxx"),
                     .init(image: "data:image/jpeg;base64,@@"), .init(image: "data:image/jpeg;base64,YQ=="),
                     .init(image: "data:image/jpeg;base64," + Data([0, 0, 0, 0]).base64EncodedString()),
                     .init(image: String(repeating: "x", count: MediaLimits.imageBytes + 1)), .init(text: "x", pages: 1)] {
            XCTAssertThrowsError(try MediaResponse(id: request.id, items: [item]).validate(for: request))
        }
        let pdf = MediaRequest(operation: .pdf)
        try MediaResponse(id: pdf.id, items: [.init(image: jpeg, page: 1), .init(image: jpeg, page: 3)]).validate(for: pdf)
        for items in [[MediaItem(image: jpeg)], [.init(image: jpeg, page: 9)],
                      [.init(image: jpeg, page: 2), .init(image: jpeg, page: 1)],
                      Array(repeating: MediaItem(image: jpeg, page: 1), count: 9)] {
            XCTAssertThrowsError(try MediaResponse(id: pdf.id, items: items).validate(for: pdf))
        }
    }

    func testJPEGHeaderRejectsOversizedFramesMetadataAndTruncatedSegments() {
        let frame: [UInt8] = [0xff, 0xc0, 0, 11, 8, 0, 10, 0, 10, 1, 1, 0x11, 0]
        let scan: [UInt8] = [0xff, 0xda, 0, 6, 1, 1, 0, 0, 0xff, 0xd9]
        let valid = [UInt8]([0xff, 0xd8]) + frame + scan
        XCTAssertTrue(MediaJPEG.isNormalized(Data(valid)))
        XCTAssertEqual(MediaJPEG.removingMetadata(Data([0xff, 0xd8, 0xff, 0xe1, 0, 2] + frame + scan)), Data(valid))
        XCTAssertNil(MediaJPEG.removingMetadata(Data()))
        var oversized = frame; oversized[7] = 0x20
        var empty = frame; empty[6] = 0
        var precision = frame; precision[4] = 12
        var components = frame; components[9] = 4
        for payload in [oversized + scan, empty + scan, precision + scan, components + scan,
                        frame + frame + scan, [0xff, 0xe1, 0, 2] + frame + scan,
                        [0xff, 0xc0, 0, 100] + scan, [0xff, 0xc0, 0, 1] + scan,
                        [0xff, 0xda, 0, 2, 0xff, 0xd9], [0, 1, 0xff, 0xd9],
                        [0xff, 0xff, 0xff, 0xff, 0xd9], [0xff, 0xd9], frame + [0xff, 0xd9]] {
            XCTAssertTrue(!MediaJPEG.isNormalized(Data([0xff, 0xd8] + payload)))
            if payload.first != 0xff || payload.count < 5 { XCTAssertNil(MediaJPEG.removingMetadata(Data([0xff, 0xd8] + payload))) }
        }
    }

    func testNativeImageNormalizesPixelsMetadataAndRefusesMalformedOversize() throws {
        let original = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 4000, height: 1000, alpha: true), type: .png,
            properties: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2]])
        let image = try XCTUnwrap(MediaDecoder.image(original).image)
        XCTAssertEqual(AskAttachmentFixture.pixelSize(image).0, MediaLimits.imageLongEdge)
        let properties = CGImageSourceCopyPropertiesAtIndex(AskAttachmentFixture.decode(image), 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
        XCTAssertThrowsError(try MediaDecoder.image(Data("garbage".utf8)))
        XCTAssertThrowsError(try MediaDecoder.image(original.prefix(12)))
        XCTAssertThrowsError(try MediaDecoder.image(Data(count: MediaLimits.inputBytes + 1)))
        XCTAssertNil(MediaDecoder.jpegDataURL(AskAttachmentFixture.image(width: 10, height: 10), limit: 10))
        XCTAssertNotNil(MediaDecoder.jpegDataURL(AskAttachmentFixture.image(width: 1000, height: 1000), limit: 4000))
    }

    func testScannedPDFOrderingCapLockedAndMalformedRefusal() throws {
        let document = PDFDocument()
        for index in 0 ..< 10 {
            let image = NSImage(cgImage: AskAttachmentFixture.image(width: 20, height: 30), size: NSSize(width: 20, height: 30))
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let data = try XCTUnwrap(document.dataRepresentation())
        XCTAssertEqual(try MediaDecoder.pdf(data).map(\.page), Array(1 ... 8))
        XCTAssertThrowsError(try MediaDecoder.pdf(Data("broken pdf".utf8)))
        XCTAssertThrowsError(try MediaDecoder.pdf(data.prefix(20)))
        XCTAssertThrowsError(try MediaDecoder.pdf(Data(count: MediaLimits.inputBytes + 1)))
        let locked = try XCTUnwrap(document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "secret", PDFDocumentWriteOption.ownerPasswordOption: "owner"]))
        XCTAssertThrowsError(try MediaDecoder.pdf(locked))
    }

    func testPDFTextExtractionAndCharacterBound() throws {
        var requests = 0
        let text = try XCTUnwrap(MediaDecoder.text(pages: 210, readPage: { _ in
            requests += 1
            return String(repeating: "字", count: 1000)
        }))
        XCTAssertEqual(text.pages, 210)
        XCTAssertEqual(text.text?.count, MediaLimits.textCharacters)
        XCTAssertEqual(text.truncated, true)
        XCTAssertLessThan(requests, 210)
        XCTAssertNil(MediaDecoder.text(pages: 2, readPage: { _ in nil }))
        XCTAssertEqual(MediaDecoder.text(pages: 1, readPage: { _ in "small" })?.truncated, false)
    }

    func testCommandFramesReadFailureAndSuccessfulResponse() throws {
        let directory = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("request"), outputURL = directory.appendingPathComponent("response")
        func command(_ data: Data) throws -> Data {
            try data.write(to: inputURL); try Data().write(to: outputURL)
            let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
            defer { try? input.close(); try? output.close() }
            MediaHelperCommand.run(input: input, output: output, directory: directory)
            return try Data(contentsOf: outputURL)
        }
        XCTAssertTrue(try command(Data("bad".utf8)).isEmpty)
        XCTAssertTrue(try command(Data(count: MediaLimits.requestBytes + 1)).isEmpty)
        var invalid = MediaRequest(operation: .image); invalid.version = 2
        XCTAssertTrue(try command(JSONEncoder().encode(invalid)).isEmpty)
        let request = MediaRequest(operation: .image)
        let failure = try JSONDecoder().decode(MediaResponse.self, from: command(JSONEncoder().encode(request)))
        XCTAssertEqual(failure.failure, .unreadable)
        let image = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 10, height: 20), type: .png)
        try image.write(to: directory.appendingPathComponent("input"))
        let response = try JSONDecoder().decode(MediaResponse.self, from: command(JSONEncoder().encode(request)))
        try response.validate(for: request)
        XCTAssertEqual(response.items.count, 1)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("input"))
        try handle.truncate(atOffset: UInt64(MediaLimits.inputBytes + 1)); try handle.close()
        XCTAssertThrowsError(try MediaDecoder.decode(request, input: directory.appendingPathComponent("input")))
    }
}
