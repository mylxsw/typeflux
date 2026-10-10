import CoreGraphics
@testable import Typeflux
import XCTest

final class ImageTilingTests: XCTestCase {
    private typealias Band = ImageTiling.Band

    private func line(_ text: String, x: CGFloat = 0.1, y: CGFloat, height: CGFloat,
                      width: CGFloat = 0.5) -> RecognizedText.Line {
        RecognizedText.Line(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }

    // MARK: Bands

    func testAnImageThatFitsIsOneBand() {
        XCTAssertEqual(ImageTiling.bands(imageHeight: 4000), [Band(start: 0, end: 4000)])
        XCTAssertEqual(ImageTiling.bands(imageHeight: 10), [Band(start: 0, end: 10)])
        XCTAssertEqual(ImageTiling.bands(imageHeight: 0), [])
        XCTAssertEqual(ImageTiling.bands(imageHeight: -5), [])
    }

    func testTallImagesAreCutIntoOverlappingBandsThatCoverEveryRow() {
        let bands = ImageTiling.bands(imageHeight: 10000)
        XCTAssertEqual(bands, [Band(start: 0, end: 4000), Band(start: 3800, end: 7800), Band(start: 6000, end: 10000)])
        XCTAssertTrue(bands.allSatisfy { $0.height <= ImageTiling.textBandHeight })
        for (previous, next) in zip(bands, bands.dropFirst()) {
            XCTAssertGreaterThanOrEqual(previous.end - next.start, ImageTiling.textBandOverlap, "Neighbours overlap")
        }
        XCTAssertEqual(bands.first?.start, 0)
        XCTAssertEqual(bands.last?.end, 10000)
    }

    func testAShortLastBandIsMadeFullHeight() {
        // 4100 rows: the second band would be 300 rows, mostly overlap.
        XCTAssertEqual(ImageTiling.bands(imageHeight: 4100), [Band(start: 0, end: 4000), Band(start: 100, end: 4100)])
    }

    func testOddParametersAreClamped() {
        XCTAssertEqual(ImageTiling.bands(imageHeight: 5, height: 0, overlap: 3).count, 5, "At least one row per band")
        XCTAssertEqual(ImageTiling.bands(imageHeight: 30, height: 10, overlap: 50),
                       (0 ..< 21).map { Band(start: $0, end: $0 + 10) }, "Overlap below the band height")
        XCTAssertEqual(ImageTiling.bands(imageHeight: 25, height: 10, overlap: -4),
                       [Band(start: 0, end: 10), Band(start: 10, end: 20), Band(start: 15, end: 25)])
    }

    // MARK: Merging

    func testOneBandKeepsVisionsOrderAndPlacesLinesOnTheImage() {
        let text = RecognizedText(lines: [
            line("second", y: 0.5, height: 0.1),
            line("right", x: 0.6, y: 0.1, height: 0.1, width: 0.3),
            line("left", x: 0.1, y: 0.12, height: 0.1, width: 0.3)
        ])
        let merged = ImageTiling.merge([(Band(start: 0, end: 100), text)], imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(merged.lines.map(\.text), ["second", "right", "left"], "Vision follows columns; no re-sorting")
        XCTAssertEqual(merged.lines[2].boundingBox.minY, 0.12, accuracy: 0.0001)
    }

    func testLinesInTheOverlapAreKeptOnceAndPlacedOnTheWholeImage() {
        // Two bands of 100 rows over a 160-row image, sharing rows 60..<100 (split at 80).
        let first = Band(start: 0, end: 100), second = Band(start: 60, end: 160)
        let top = RecognizedText(lines: [
            line("alpha", y: 0.10, height: 0.10), // rows 10–20
            line("beta", y: 0.65, height: 0.10), // rows 65–75: centre 70, first band's side
            line("gamma", y: 0.85, height: 0.10) // rows 85–95: centre 90, second band's side
        ])
        let bottom = RecognizedText(lines: [
            line("beta", y: 0.05, height: 0.10), // rows 65–75 again
            line("gamma", y: 0.25, height: 0.10), // rows 85–95 again
            line("delta", y: 0.80, height: 0.10) // rows 140–150
        ])
        let merged = ImageTiling.merge([(first, top), (second, bottom)], imageSize: CGSize(width: 100, height: 160))

        XCTAssertEqual(merged.lines.map(\.text), ["alpha", "beta", "gamma", "delta"])
        XCTAssertEqual(merged.lines[3].boundingBox.minY, 140.0 / 160, accuracy: 0.0001)
        XCTAssertEqual(merged.lines[3].boundingBox.height, 10.0 / 160, accuracy: 0.0001)
        XCTAssertEqual(merged.lines[2].boundingBox.minY, 85.0 / 160, accuracy: 0.0001, "From the second band")
        XCTAssertEqual(merged.string, "alpha\nbeta\ngamma\ndelta")
    }

    func testExactBoundsFollowTheLineOntoTheWholeImage() throws {
        let first = Band(start: 0, end: 100), second = Band(start: 60, end: 160)
        var located = line("delta", y: 0.8, height: 0.1)
        located.locate = { _ in CGRect(x: 0.2, y: 0.8, width: 0.3, height: 0.1) }
        let merged = ImageTiling.merge([(first, RecognizedText(lines: [])), (second, RecognizedText(lines: [located]))],
                                       imageSize: CGSize(width: 100, height: 160))
        let box = try XCTUnwrap(merged.lines.first?.locate?(NSRange(location: 0, length: 2)))
        XCTAssertEqual(box.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 140.0 / 160, accuracy: 0.0001, "Row 60 + 80 of 160")
        XCTAssertEqual(box.height, 10.0 / 160, accuracy: 0.0001)
        XCTAssertNil(ImageTiling.merge([(first, RecognizedText(lines: [line("x", y: 0.1, height: 0.1)]))],
                                       imageSize: CGSize(width: 10, height: 100)).lines.first?.locate)
    }

    func testARepeatReadSlightlyOffTheSplitIsDropped() {
        let first = Band(start: 0, end: 100), second = Band(start: 60, end: 160)
        // The same line read at rows 74–84 by the first band and 76–86 by the second: the
        // centres (79 and 81) fall on either side of the split at 80.
        let top = RecognizedText(lines: [line("Total 128,430", y: 0.74, height: 0.10)])
        let bottom = RecognizedText(lines: [line("Total 128, 430", y: 0.16, height: 0.10)])
        let merged = ImageTiling.merge([(first, top), (second, bottom)], imageSize: CGSize(width: 100, height: 160))
        XCTAssertEqual(merged.lines.map(\.text), ["Total 128,430"])
    }

    func testRepeatedTextFarApartIsKept() {
        let first = Band(start: 0, end: 100), second = Band(start: 60, end: 160)
        let top = RecognizedText(lines: [line("OK", y: 0.1, height: 0.1)])
        let bottom = RecognizedText(lines: [line("OK", y: 0.8, height: 0.1)])
        let merged = ImageTiling.merge([(first, top), (second, bottom)], imageSize: CGSize(width: 100, height: 160))
        XCTAssertEqual(merged.lines.map(\.text), ["OK", "OK"], "The same word on two rows")
        XCTAssertTrue(ImageTiling.merge([], imageSize: CGSize(width: 10, height: 10)).lines.isEmpty)
        XCTAssertTrue(ImageTiling.merge([(first, top)], imageSize: .zero).lines.isEmpty)
    }

    func testDuplicatesNeedTheSameTextAndPlace() {
        let size = CGSize(width: 100, height: 100)
        let base = line("Hello World", y: 0.5, height: 0.05)
        XCTAssertTrue(ImageTiling.isDuplicate(base, line("hello  world", y: 0.52, height: 0.05), imageSize: size))
        XCTAssertFalse(ImageTiling.isDuplicate(base, line("Hello", y: 0.5, height: 0.05), imageSize: size))
        XCTAssertFalse(ImageTiling.isDuplicate(base, line("Hello World", y: 0.7, height: 0.05), imageSize: size))
        XCTAssertFalse(ImageTiling.isDuplicate(base, line("Hello World", x: 0.6, y: 0.5, height: 0.05),
                                               imageSize: size))
    }

    // MARK: Slices for a question

    func testAnImageThatFitsIsOneSlice() throws {
        let rects = try ImageTiling.slices(imageSize: CGSize(width: 1600, height: 2000)).get()
        XCTAssertEqual(rects, [CGRect(x: 0, y: 0, width: 1600, height: 2000)])
        // Wider than tall: shrunk, never cut.
        XCTAssertEqual(try ImageTiling.slices(imageSize: CGSize(width: 6000, height: 3000)).get().count, 1)
    }

    func testLongImagesAreCutIntoOverlappingSlices() throws {
        let size = CGSize(width: 1456, height: 5000)
        let rects = try ImageTiling.slices(imageSize: size).get()
        XCTAssertEqual(rects.count, 3)
        XCTAssertTrue(rects.allSatisfy { $0.height == 2048 && $0.width == 1456 && $0.minX == 0 })
        XCTAssertEqual(rects.first?.minY, 0)
        XCTAssertEqual(rects.last?.maxY, 5000, "The last slice ends at the bottom")
        for (previous, next) in zip(rects, rects.dropFirst()) {
            XCTAssertGreaterThanOrEqual(previous.maxY - next.minY, 204, "At least 10% shared")
            XCTAssertGreaterThan(next.minY, previous.minY)
        }
    }

    func testWideLongImagesUseTallerSlicesThatShrinkToTheLimit() throws {
        // 4096 wide shrinks by half, so a slice may be 4096 tall before shrinking.
        let rects = try ImageTiling.slices(imageSize: CGSize(width: 4096, height: 10000)).get()
        XCTAssertTrue(rects.allSatisfy { $0.height == 4096 })
        XCTAssertEqual(rects.count, 3)
    }

    func testTooManySlicesAreRefused() {
        XCTAssertEqual(ImageTiling.slices(imageSize: CGSize(width: 1000, height: 40000)),
                       .failure(.tooManySlices(22)))
        // Exactly eight fit.
        let eight = 2048 + 7 * (2048 - 204)
        XCTAssertEqual(try ImageTiling.slices(imageSize: CGSize(width: 1000, height: eight)).get().count, 8)
        XCTAssertEqual(ImageTiling.slices(imageSize: CGSize(width: 1000, height: eight + 1)),
                       .failure(.tooManySlices(9)))
        XCTAssertEqual(ImageTiling.slices(imageSize: CGSize(width: 1000, height: 3000), maximumCount: 1),
                       .failure(.tooManySlices(2)))
    }

    func testEmptyImagesCannotBeSliced() {
        XCTAssertEqual(ImageTiling.slices(imageSize: .zero), .failure(.empty))
        XCTAssertEqual(ImageTiling.slices(imageSize: CGSize(width: 10, height: 10), longEdge: 0), .failure(.empty))
    }

    func testOverlapIsClamped() throws {
        let none = try ImageTiling.slices(imageSize: CGSize(width: 100, height: 300), longEdge: 100,
                                          overlapFraction: -1).get()
        XCTAssertEqual(none.map(\.minY), [0, 100, 200])
        let most = try ImageTiling.slices(imageSize: CGSize(width: 100, height: 120), longEdge: 100,
                                          overlapFraction: 5).get()
        XCTAssertEqual(most.map(\.minY), [0, 10, 20])
    }

    // MARK: Recognizer

    private final class RecordingRecognizer: ImageTextRecognizing, @unchecked Sendable {
        private(set) var heights: [Int] = []
        private(set) var urls: [URL] = []

        func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
            switch source {
            case let .url(url):
                urls.append(url)
                return RecognizedText(lines: [])
            case let .image(image):
                heights.append(image.height)
                // One line in the middle of each band, and one in every band's shared top rows.
                return RecognizedText(lines: [
                    RecognizedText.Line(text: "band \(heights.count)", confidence: 1,
                                        boundingBox: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.01)),
                    RecognizedText.Line(text: "shared", confidence: 1,
                                        boundingBox: CGRect(x: 0, y: 0.002, width: 0.5, height: 0.001))
                ])
            }
        }
    }

    func testTheTiledRecognizerReadsLongImagesBandByBand() async throws {
        let base = RecordingRecognizer()
        let recognizer = TiledImageTextRecognizer(base: base, bandHeight: 400, overlap: 40)

        let tall = ScreenCaptureTestSupport.image(width: 50, height: 1000)
        let text = try await recognizer.recognizeText(in: .image(tall))

        XCTAssertEqual(base.heights, [400, 400, 400])
        XCTAssertEqual(text.lines.filter { $0.text.hasPrefix("band") }.map(\.text), ["band 1", "band 2", "band 3"])
    }

    func testTheTiledRecognizerPassesShortImagesAndFilesThrough() async throws {
        let base = RecordingRecognizer()
        let recognizer = TiledImageTextRecognizer(base: base, bandHeight: 400, overlap: 40)

        _ = try await recognizer.recognizeText(in: .image(ScreenCaptureTestSupport.image(width: 50, height: 400)))
        _ = try await recognizer.recognizeText(in: .url(URL(fileURLWithPath: "/tmp/x.png")))

        XCTAssertEqual(base.heights, [400])
        XCTAssertEqual(base.urls.count, 1)
    }

    func testTheTiledRecognizerStopsWhenCancelled() async {
        let base = RecordingRecognizer()
        let recognizer = TiledImageTextRecognizer(base: base, bandHeight: 100, overlap: 10)
        let task = Task {
            try await recognizer.recognizeText(in: .image(ScreenCaptureTestSupport.image(width: 10, height: 1000)))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
