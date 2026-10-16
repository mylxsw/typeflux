import AppKit
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private actor SharedOCRPending: ImageTextRecognizing {
    private var continuation: CheckedContinuation<RecognizedText, Error>?
    var started: Bool { continuation != nil }
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: .init(lines: [.init(text: "late", confidence: 1, boundingBox: .zero)])); continuation = nil }
}
private struct SharedOCRFailure: ScreenshotSensitiveInfoScanning {
    func scan(_ image: CGImage) async throws -> [ScreenshotSensitiveFinding] { throw MediaFailure.unavailable }
}
private final class SharedOCRBlock: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0), lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}

@MainActor final class SharedOCRIsolationTests: XCTestCase {
    private let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1)
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/shared-ocr-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Work did not finish")
    }
    func testUnicodeExactGeometrySurvivesSerializationAndTilingWithoutEstimation() throws {
        let text = "👨‍👩‍👦 联系人 a@example.com", match = try XCTUnwrap(MediaSensitiveText.matches(in: text).first)
        let region = MediaTextRecognition.Region(kind: match.kind, range: match.range, box: box)
        let value = MediaTextRecognition(lines: [.init(text: text, confidence: 0.9, box: .init(x: 0, y: 0, width: 1, height: 0.3), regions: [region])])
        let decoded = try JSONDecoder().decode(MediaTextRecognition.self, from: JSONEncoder().encode(value))
        try decoded.validate()
        let result = VisionImageTextRecognizer.materialize(decoded), line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.locate?(match.range), box)
        XCTAssertNil(line.locate?(.init(location: 0, length: 1)))
        let finding = try XCTUnwrap(ScreenshotSensitiveInfoDetector.findings(in: result).first)
        XCTAssertEqual(finding.text, "a@example.com"); XCTAssertEqual(finding.boundingBox.midX, box.midX, accuracy: 0.0001)
        let tiled = ImageTiling.merge([(.init(start: 400, end: 800), result)], imageSize: .init(width: 1000, height: 1000))
        let located = try XCTUnwrap(tiled.lines.first?.locate?(match.range))
        XCTAssertEqual(located.minY, 0.48, accuracy: 0.0001); XCTAssertEqual(located.height, 0.04, accuracy: 0.0001)
        XCTAssertEqual(tiled.lines.first?.sensitiveMatches, [match])
    }

    func testProtocolRejectsBoundsUTF16OverlapAndMixedResponses() throws {
        for shape in [MediaTextInput(width: 0, height: 1), .init(width: Int.max, height: 1), .init(width: 8000, height: 4000)] {
            XCTAssertThrowsError(try shape.validate())
        }
        var request = MediaRequest(operation: .recognizeText); request.textInput = .init(width: 20, height: 10)
        try request.validate(); XCTAssertEqual(request.textInput?.byteCount, 800)
        var response = MediaResponse(id: request.id)
        response.recognition = .init(lines: [.init(text: "😀x", confidence: 1, box: box, regions: [])])
        try response.validate(for: request)
        for range in [NSRange(location: 1, length: 1), .init(location: Int.max, length: 1), .init(location: 0, length: Int.max), .init(location: -1, length: 1)] {
            var bad = response; bad.recognition?.lines[0].regions = [.init(kind: .email, range: range, box: box)]
            XCTAssertThrowsError(try bad.validate(for: request))
        }
        for bounds in [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), .zero, .init(x: 0.5, y: 0, width: 1, height: 1)] {
            var bad = response; bad.recognition?.lines[0].box = bounds; XCTAssertThrowsError(try bad.validate(for: request))
        }
        var bad = response; bad.recognition?.lines[0].confidence = .nan; XCTAssertThrowsError(try bad.validate(for: request))
        bad = response; bad.ocr = .init(lines: []); XCTAssertThrowsError(try bad.validate(for: request))
        bad = response; bad.failure = .unavailable; XCTAssertThrowsError(try bad.validate(for: request))
        request.operation = .image; XCTAssertThrowsError(try request.validate())
        request.textInput = nil; XCTAssertThrowsError(try response.validate(for: request))
        let region = MediaTextRecognition.Region(kind: .email, range: .init(location: 0, length: 2), box: box)
        for regions in [[region, region], Array(repeating: region, count: 129)] {
            XCTAssertThrowsError(try MediaTextRecognition(lines: [.init(text: "😀x", confidence: 1, box: box, regions: regions)]).validate())
        }
    }

    func testChildReadsRawOrEncodedInputAndRejectsTruncationBeforeEngine() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        var request = MediaRequest(operation: .recognizeText); request.textInput = .init(width: 20, height: 10)
        try Data(repeating: 255, count: 800).write(to: file)
        let response = try MediaTextDecoder.decode(request, directory: root) { image in
            XCTAssertEqual(image.width, 20); XCTAssertEqual(image.height, 10)
            return .init(lines: [])
        }
        XCTAssertEqual(response.recognition?.lines.count, 0)
        try Data(repeating: 0, count: 799).write(to: file)
        XCTAssertThrowsError(try MediaTextDecoder.decode(request, directory: root))
        try Data(repeating: 0, count: 801).write(to: file)
        XCTAssertThrowsError(try MediaTextDecoder.decode(request, directory: root))
        request.textInput = nil
        for data in [Data(), Data([1, 2, 3])] {
            try data.write(to: file); XCTAssertThrowsError(try MediaTextDecoder.decode(request, directory: root))
        }
        try ClipboardTestSupport.imageData(width: 200, height: 100).write(to: file)
        let empty = try MediaTextDecoder.decode(request, directory: root) { _ in .init(lines: []) }
        XCTAssertEqual(empty.recognition?.lines.count, 0)
        XCTAssertThrowsError(try MediaTextDecoder.decode(.init(operation: .image), directory: root))
    }

    func testRealHelperKeepsSensitiveGlyphBoxesAndRawImageOrientation() async throws {
        let data = ClipboardTestSupport.imageData(width: 1400, height: 240, text: "Contact a@example.com")
        let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage), worker = try worker()
        let recognizer = VisionImageTextRecognizer(worker: worker)
        let result = try await recognizer.recognizeText(in: .image(image))
        let findings = ScreenshotSensitiveInfoDetector.findings(in: result)
        XCTAssertEqual(findings.first?.text, "a@example.com")
        let line = try XCTUnwrap(result.lines.first { !$0.sensitiveMatches!.isEmpty })
        let match = try XCTUnwrap(line.sensitiveMatches?.first)
        let exact = try XCTUnwrap(line.locate?(match.range))
        XCTAssertGreaterThan(exact.width, 0); XCTAssertLessThan(exact.width, line.boundingBox.width)
        // Same native request in the test fixture gives the exact reference geometry.
        let reference = try MediaTextDecoder.recognize(image)
        let region = try XCTUnwrap(reference.lines.flatMap(\.regions).first)
        XCTAssertEqual(exact.minX, region.box.minX, accuracy: 0.01)
        XCTAssertEqual(exact.minY, region.box.minY, accuracy: 0.01)
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png"); try data.write(to: url)
        let file = try await recognizer.recognizeText(in: .url(url))
        XCTAssertEqual(file.string, result.string)
        await worker.shutdown()
    }

    func testUncooperativeCancellationRetainsTwoAdmissionsAndShutdownRefusesMore() async throws {
        let block = SharedOCRBlock(), worker = MediaWorker(run: { _, _ in try block.run() })
        let recognizer = VisionImageTextRecognizer(worker: worker), image = ScreenCaptureTestSupport.image(width: 20, height: 20)
        let first = Task { try await recognizer.recognizeText(in: .image(image)) }, second = Task { try await recognizer.recognizeText(in: .image(image)) }
        try await wait { block.count == 2 }; first.cancel(); second.cancel()
        do { _ = try await recognizer.recognizeText(in: .image(image)); XCTFail() } catch {}
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = await first.result; _ = await second.result
        await worker.shutdown()
        do { _ = try await recognizer.recognizeText(in: .image(image)); XCTFail() } catch {}
    }

    func testTilingRejectsExcessBandsAndAccumulatedOutput() async throws {
        struct Large: ImageTextRecognizing {
            func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
                .init(lines: Array(repeating: .init(text: "x", confidence: 1, boundingBox: .zero), count: 4097))
            }
        }
        let image = ScreenCaptureTestSupport.image(width: 10, height: 1000)
        for value in [TiledImageTextRecognizer(base: Large(), bandHeight: 1, overlap: 0), .init(base: Large(), bandHeight: 400, overlap: 400), .init(base: Large(), bandHeight: 400, overlap: 40)] {
            do { _ = try await value.recognizeText(in: .image(image)); XCTFail() } catch {}
        }
    }

    func testRedactionFailureIsNotAnEmptySuccessfulScanAndRevocationClearsPanel() async throws {
        let controller = ScreenshotSensitiveInfoController(scanner: SharedOCRFailure())
        controller.scan(ScreenCaptureTestSupport.image(width: 10, height: 10), scale: 1)
        await controller.waitForScan()
        XCTAssertEqual(controller.suggestions.status, .failed); XCTAssertTrue(controller.isPanelShown)
        XCTAssertFalse(controller.hasFindings)
        let view = NSView(frame: .init(x: 0, y: 0, width: 280, height: 230))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        controller.layout(in: view, crop: nil) { CGRect(x: 12, y: 12, width: $0.width, height: $0.height) }
        let panel = try XCTUnwrap(controller.host); XCTAssertFalse(panel.isHidden)
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/shared-ocr-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("shared-ocr.png"))
        NotificationCenter.default.post(name: .authDidLogout, object: nil)
        XCTAssertNil(controller.host); XCTAssertTrue(controller.suggestions.items.isEmpty)
        controller.scan(ScreenCaptureTestSupport.image(width: 10, height: 10), scale: 1)
        XCTAssertEqual(controller.suggestions.status, .idle)
    }

    func testTranslationActualHideAndAccountChangeRejectLateOCR() async throws {
        for logout in [false, true] {
            let fixture = TranslationPanelFixture(), pending = SharedOCRPending()
            let controller = AskTranslationPanelController(model: fixture.model)
            let entry = AskTranslationPanelCoordinator(model: fixture.model, controller: controller,
                injector: TranslationPanelInjector(), recognizer: pending)
            entry.frontmost = { nil }
            entry.openScreenshot(translationPanelImage())
            for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
            if logout { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            else { controller.presentedWindow?.orderOut(nil) }
            await pending.finish(); try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(fixture.model.screenshot); XCTAssertTrue(fixture.model.text.isEmpty)
            controller.hide()
        }
    }

    func testLauncherReplacementResetAndRevocationCancelOriginalRecognition() async throws {
        for action in 0..<3 {
            let fixture = try AskTestFixture(), pending = SharedOCRPending()
            fixture.model.screenshotTextRecognizer = pending
            let original = fixture.model.makeLauncherScreenshot(translationPanelImage())
            fixture.model.launcherScreenshot = original
            for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
            switch action {
            case 0:
                var replacement = original.source; replacement.id = UUID()
                replacement.recognition = Task { RecognizedText(lines: []) }
                fixture.model.launcherScreenshot = .init(image: original.image, source: replacement)
            case 1: fixture.model.resetSession()
            default: fixture.model.invalidateRemoteImages()
            }
            await pending.finish()
            do { _ = try await original.source.recognition.value; XCTFail("Retired screenshot escaped") } catch {}
            fixture.model.resetSession()
        }
    }

    func testSourceMutationAndOversizeNeverReturnPreparedText() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.png"); try Data([1]).write(to: file)
        let worker = MediaWorker(run: { request, _ in
            let input = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
            var response = MediaResponse(id: input.id); response.recognition = .init(lines: [])
            try Data([2, 3]).write(to: file, options: .atomic)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let recognizer = VisionImageTextRecognizer(worker: worker)
        do { _ = try await recognizer.recognizeText(in: .url(file)); XCTFail("Changed source accepted") } catch {}
        try Data(repeating: 0, count: MediaOCRResult.inputBytes + 1).write(to: file)
        do { _ = try await recognizer.recognizeText(in: .url(file)); XCTFail("Oversize accepted") } catch {}
        await worker.shutdown()
    }
}
