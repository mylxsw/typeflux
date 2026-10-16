import AppKit
import CoreText
import ImageIO
import PDFKit
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

final class MediaPreviewTests: XCTestCase {
    private func request(_ operation: MediaRequest.Operation = .previewImage, page: Int? = nil,
                         passage: String? = nil) -> MediaRequest {
        var request = MediaRequest(operation: operation)
        request.preview = .init(width: 100, height: 80, page: page, passage: passage)
        return request
    }

    func testRejectsUnboundedOptionsAndMixedProtocols() throws {
        var request = request()
        try request.validate()
        for options in [MediaPreviewOptions(width: 0, height: 1), .init(width: Int.max, height: 1),
                        .init(width: 4096, height: 4096), .init(width: 1, height: -1),
                        .init(width: 1, height: 1, passage: String(repeating: "a", count: 16385))] {
            request.preview = options
            XCTAssertThrowsError(try request.validate())
        }
        request.preview = nil
        XCTAssertThrowsError(try request.validate())
        request = self.request(.image)
        XCTAssertThrowsError(try request.validate())
        request = self.request()
        var response = MediaResponse(id: request.id)
        XCTAssertThrowsError(try response.validate(for: request))
        response.preview = .init(rasters: [.init(width: 20, height: 10)])
        try response.validate(for: request)
        response.id = UUID()
        XCTAssertThrowsError(try response.validate(for: request))
        response.id = request.id; response.items = [.init(text: "unexpected", pages: 1)]
        XCTAssertThrowsError(try response.validate(for: request))
        response.items = []; response.failure = .unreadable
        XCTAssertThrowsError(try response.validate(for: request))
        response.failure = nil
        request.operation = .image; request.preview = nil
        XCTAssertThrowsError(try response.validate(for: request))
        XCTAssertThrowsError(try MediaDecoder.decode(self.request(), input: URL(fileURLWithPath: "/missing")))
    }

    func testRasterDimensionsStrideAndPageIdentityAreValidatedBeforeAllocation() throws {
        let options = try XCTUnwrap(request().preview)
        let good = MediaRaster(width: 20, height: 10)
        for change in [ { (r: inout MediaRaster) in r.width = Int.max }, { $0.height = -1 },
                       { $0.stride = Int.max }, { $0.bytes += 1 }, { $0.width = 101 }] {
            var bad = good; change(&bad)
            XCTAssertThrowsError(try bad.validate(for: options))
        }
        let image = request()
        for result in [MediaPreviewResult(rasters: []), .init(rasters: [good, good]),
                       .init(rasters: [good], pages: 1), .init(rasters: [.init(width: 20, height: 10, page: 1)])] {
            XCTAssertThrowsError(try result.validate(for: image))
        }
        let pdf = request(.previewPDF, page: 4)
        try MediaPreviewResult(rasters: [.init(width: 20, height: 10, page: 4)], pages: 6).validate(for: pdf)
        for result in [MediaPreviewResult(rasters: [good], pages: 0),
                       .init(rasters: [.init(width: 20, height: 10, page: 3)], pages: 6),
                       .init(rasters: Array(repeating: good, count: 4), pages: 6)] {
            XCTAssertThrowsError(try result.validate(for: pdf))
        }
        try MediaPreviewResult(rasters: (1...3).map { .init(width: 20, height: 10, page: $0) }, pages: 3)
            .validate(for: request(.previewPDF, page: 99))
    }

    private func directory() throws -> URL { try AskAttachmentFixture.directory() }
    private func png() -> Data {
        AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 120, height: 60), type: .png)
    }
    private func pdf(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 1...4 {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 300)
            let line = NSAttributedString(string: "Café project expenses", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(line), context); context.endPDFPage()
        }
        context.closePDF()
    }

    func testDecoderFitsImageAndRejectsTruncationAndBadPDF() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try png().write(to: input)
        let response = try MediaPreviewDecoder.decode(request(), directory: root)
        let raster = try XCTUnwrap(response.preview?.rasters.first)
        XCTAssertEqual(raster.width, 100); XCTAssertEqual(raster.height, 50)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("raster-0")).count, raster.bytes)
        try png().prefix(20).write(to: input)
        XCTAssertThrowsError(try MediaPreviewDecoder.decode(request(), directory: root))
        XCTAssertThrowsError(try MediaPreviewDecoder.decode(request(.previewPDF), directory: root))
        XCTAssertThrowsError(try MediaPreviewDecoder.decode(MediaRequest(operation: .image), directory: root))
        let handle = try FileHandle(forWritingTo: input)
        try handle.truncate(atOffset: UInt64(MediaLimits.inputBytes + 1)); try handle.close()
        XCTAssertThrowsError(try MediaPreviewDecoder.decode(request(), directory: root))
    }

    func testImageOrientationAndRequestFrameLimits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 120, height: 60), type: .jpeg,
            properties: [kCGImagePropertyOrientation: 6])
        try image.write(to: root.appendingPathComponent("input"))
        let result = try XCTUnwrap(MediaPreviewDecoder.decode(request(), directory: root).preview)
        XCTAssertEqual(result.rasters.first?.width, 40); XCTAssertEqual(result.rasters.first?.height, 80)
        let input = root.appendingPathComponent("request"), output = root.appendingPathComponent("response")
        func command(_ bytes: Data) throws -> Data {
            try bytes.write(to: input); try Data().write(to: output)
            let reader = try FileHandle(forReadingFrom: input), writer = try FileHandle(forWritingTo: output)
            defer { try? reader.close(); try? writer.close() }
            MediaHelperCommand.run(input: reader, output: writer, directory: root)
            return try Data(contentsOf: output)
        }
        XCTAssertTrue(try command(Data(count: MediaPreviewOptions.requestBytes + 1)).isEmpty)
        var attachment = try JSONEncoder().encode(MediaRequest(operation: .image))
        attachment.append(Data(repeating: 32, count: 1024))
        XCTAssertTrue(try command(attachment).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("raster-0"))
        let large = request(.previewPDF, page: 4, passage: String(repeating: "a", count: 12000))
        // A complete long frame produces a typed media failure, not a truncated request.
        let response = try JSONDecoder().decode(MediaResponse.self, from: command(JSONEncoder().encode(large)))
        XCTAssertEqual(response.id, large.id); XCTAssertEqual(response.failure, .unreadable)
        let normal = request()
        try JSONDecoder().decode(MediaResponse.self, from: command(JSONEncoder().encode(normal))).validate(for: normal)
    }

    func testPDFSelectionRotationHighlightsAndDefaultPages() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try pdf(at: input)
        func decode(_ request: MediaRequest) throws -> (MediaPreviewResult, Data) {
            for index in 0..<3 { try? FileManager.default.removeItem(at: root.appendingPathComponent(MediaRaster.filename(index))) }
            let response = try MediaPreviewDecoder.decode(request, directory: root)
            return (try XCTUnwrap(response.preview), try Data(contentsOf: root.appendingPathComponent("raster-0")))
        }
        let plain = try decode(request(.previewPDF, page: 4))
        let highlighted = try decode(request(.previewPDF, page: 4, passage: "CAFE project expenses"))
        XCTAssertEqual(highlighted.0.rasters.map(\.page), [4]); XCTAssertEqual(highlighted.0.pages, 4)
        XCTAssertNotEqual(plain.1, highlighted.1)
        XCTAssertEqual(try decode(request(.previewPDF)).0.rasters.map(\.page), [1, 2, 3])
        XCTAssertEqual(try decode(request(.previewPDF, page: 99)).0.rasters.map(\.page), [1, 2, 3])
        let document = try XCTUnwrap(PDFDocument(url: input)); document.page(at: 3)?.rotation = 90
        XCTAssertTrue(document.write(to: input))
        let rotated = try decode(request(.previewPDF, page: 4)).0.rasters[0]
        XCTAssertEqual(rotated.width, 100); XCTAssertEqual(rotated.height, 50)
        let encrypted = root.appendingPathComponent("encrypted")
        XCTAssertTrue(document.write(to: encrypted, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
        try Data(contentsOf: encrypted).write(to: input)
        XCTAssertThrowsError(try decode(request(.previewPDF)))
    }

    func testTextRangesKeepUnicodeOffsets() {
        let text = "😀 项目\n报销　流程"
        let ranges = MediaPreviewText.ranges(in: text, passage: "项目 报销流程")
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["项目\n报销　流程"])
        XCTAssertEqual(MediaPreviewText.ranges(in: "Café", passage: "CAFE"), [NSRange(location: 0, length: 4)])
        XCTAssertTrue(MediaPreviewText.ranges(in: text, passage: "missing").isEmpty)
        XCTAssertTrue(MediaPreviewText.ranges(in: text, passage: " \n").isEmpty)
    }

    private func worker(_ output: @escaping @Sendable (URL, MediaRequest) throws -> MediaResponse) -> MediaWorker {
        MediaWorker(run: { process, _ in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(process.directoryDescriptor, F_GETPATH, &path), 0)
            let root = URL(fileURLWithPath: String(cString: path))
            let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
            let response = try output(root, request)
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }

    func testHostRejectsMissingTruncatedSymlinkDirectoryAndOversizedRasterFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original"); try png().write(to: input)
        for mode in 0..<6 {
            let worker = worker { root, request in
                let output = root.appendingPathComponent("raster-0")
                switch mode {
                case 1: try Data(count: 3).write(to: output)
                case 2: try FileManager.default.createSymbolicLink(at: output, withDestinationURL: input)
                case 3: try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                case 4: try Data(count: 5).write(to: output)
                case 5: XCTAssertEqual(mkfifo(output.path, 0o600), 0)
                default: break
                }
                var response = MediaResponse(id: request.id)
                response.preview = .init(rasters: [.init(width: 1, height: 1)])
                return response
            }
            XCTAssertThrowsError(try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80),
                pdf: false, evidence: nil, cancellation: AskSearchCancellation(), worker: worker))
            XCTAssertEqual(worker.activeCount, 0)
        }
    }

    func testHostValidatesPixelsAndOwnsCopiedRasterAfterCleanup() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original"); try png().write(to: input)
        let worker = worker { root, request in try MediaPreviewDecoder.decode(request, directory: root) }
        let result = try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
            evidence: nil, cancellation: AskSearchCancellation(), worker: worker)
        XCTAssertEqual(worker.activeCount, 0)
        XCTAssertEqual(result.images[0].width, 100)
        XCTAssertEqual((result.images[0].dataProvider?.data as Data?)?.count, 100 * 50 * 4)
        for pixels in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1), .init(width: 5000, height: 1)] {
            XCTAssertThrowsError(try MediaPreviewDisplay.render(input, pixels: pixels, pdf: false,
                evidence: nil, cancellation: AskSearchCancellation(), worker: worker))
        }
        XCTAssertThrowsError(try worker.perform(.previewPDF, input: .file(input),
            preview: .init(width: 1, height: 1, passage: String(repeating: "\u{1}", count: 16000)),
            isCancelled: { false }) { _, _ in () })
    }

    func testRetainedPreviewFilesAndSlotsWaitForActualReaping() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original"); try png().write(to: input)
        let state = PreviewRetirementState()
        defer { state.reapers.forEach { $0() } }
        let worker = MediaWorker(run: { process, _ in
            process.onStarted?()
            state.reapers.append(process.onReaped!)
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(process.directoryDescriptor, F_GETPATH, &path), 0)
            let directory = URL(fileURLWithPath: String(cString: path)); state.directories.append(directory)
            let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
            let response = try MediaPreviewDecoder.decode(request, directory: directory)
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        for _ in 0..<2 {
            _ = try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
                evidence: nil, cancellation: AskSearchCancellation(), worker: worker)
        }
        XCTAssertEqual(worker.activeCount, 2)
        XCTAssertThrowsError(try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
            evidence: nil, cancellation: AskSearchCancellation(), worker: worker))
        for directory in state.directories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("raster-0").path))
        }
        state.reapers.forEach { $0() }
        let deadline = Date().addingTimeInterval(2)
        while worker.activeCount > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(worker.activeCount, 0)
        for directory in state.directories { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
    }

    func testPreviewCrashAndHangReturnWithoutReplaying() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original"); try png().write(to: input)
        for script in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let executable = root.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let worker = MediaWorker(executable: executable, timeout: 0.1)
            let start = ContinuousClock.now
            XCTAssertThrowsError(try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
                evidence: nil, cancellation: AskSearchCancellation(), worker: worker))
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        }
    }

    func testRealHelperAndLateCancellationCannotPublish() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original"); try png().write(to: input)
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/preview-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process
            process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        let result = try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
            evidence: nil, cancellation: AskSearchCancellation(), worker: worker)
        XCTAssertEqual(result.images.first?.height, 50)
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        let token = AskSearchCancellation()
        let late = self.worker { root, request in
            let response = try MediaPreviewDecoder.decode(request, directory: root)
            token.cancel()
            return response
        }
        XCTAssertThrowsError(try MediaPreviewDisplay.render(input, pixels: .init(width: 100, height: 80), pdf: false,
            evidence: nil, cancellation: token, worker: late))
        XCTAssertEqual(late.activeCount, 0)
    }
}

private final class PreviewRetirementState: @unchecked Sendable {
    var directories: [URL] = []
    var reapers: [@Sendable () -> Void] = []
}
