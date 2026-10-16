import AppKit
import XCTest
import SwiftUI
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

@MainActor private final class MosaicPending: ScreenshotTextHeightMeasuring {
    var continuation: CheckedContinuation<ScreenshotTextGeometry, Error>?
    var calls = 0
    func geometry(in image: CGImage) async throws -> ScreenshotTextGeometry {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(lines: [CGRect(x: 4, y: 4, width: 20, height: 8)], height: 8))
        continuation = nil
    }
}
private struct MosaicFixed: ScreenshotTextHeightMeasuring {
    var value: ScreenshotTextGeometry
    func geometry(in image: CGImage) async throws -> ScreenshotTextGeometry { value }
}

@MainActor final class MosaicGeometryIsolationTests: XCTestCase {
    static func waitFor(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Preparation did not complete")
    }
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/mosaic-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request
            request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    private func editor() -> ScreenshotAnnotationEditor {
        var editor = ScreenshotAnnotationEditor(); editor.preparesMosaicGeometry = true
        editor.selectTool(.mosaic); editor.setMosaicScope(.text)
        _ = editor.mouseDown(at: .init(x: 10, y: 10), crop: .init(x: 0, y: 0, width: 300, height: 300), cropHit: .inside)
        editor.mouseDragged(to: .init(x: 100, y: 70)); editor.mouseUp(at: .init(x: 100, y: 70))
        return editor
    }
    private func canvas(_ measurer: any ScreenshotTextHeightMeasuring) -> ScreenshotLongImageCanvas {
        let view = ScreenshotLongImageCanvas(image: ScreenCaptureTestSupport.image(width: 400, height: 300), scale: 1, textMeasurer: measurer)
        view.perform(.tool(.mosaic)); view.perform(.mosaicScope(.text))
        view.mouseDown(at: .init(x: 10, y: 10), clickCount: 1)
        view.mouseDragged(to: .init(x: 100, y: 70)); view.mouseUp(at: .init(x: 100, y: 70))
        return view
    }

    func testProtocolBoundsIdentityAndMixedPayloadsFailClosed() throws {
        var request = MediaRequest(operation: .textGeometry)
        XCTAssertThrowsError(try request.validate())
        request.textInput = .init(width: 200, height: 100); try request.validate()
        var response = MediaResponse(id: request.id); response.geometry = .init(boxes: [.init(x: 0.1, y: 0.2, width: 0.5, height: 0.1)])
        try response.validate(for: request)
        let decoded = try JSONDecoder().decode(MediaResponse.self, from: JSONEncoder().encode(response)); try decoded.validate(for: request)
        for box in [CGRect.zero, .init(x: CGFloat.nan, y: 0, width: 1, height: 1), .init(x: 0.9, y: 0, width: 0.2, height: 1)] {
            response.geometry = .init(boxes: [box]); XCTAssertThrowsError(try response.validate(for: request))
        }
        response.geometry = .init(boxes: Array(repeating: .init(x: 0, y: 0, width: 1, height: 1), count: 1025))
        XCTAssertThrowsError(try response.validate(for: request))
        response.geometry = .init(boxes: []); response.recognition = .init(lines: [])
        XCTAssertThrowsError(try response.validate(for: request))
        response.recognition = nil; response.failure = .unavailable; XCTAssertThrowsError(try response.validate(for: request))
        response.failure = nil; request.operation = .recognizeText; XCTAssertThrowsError(try response.validate(for: request))
        request.operation = .image; XCTAssertThrowsError(try request.validate())
    }

    func testChildRejectsTruncatedRawInputBeforeDetectionAndReturnsOnlyGeometry() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = MediaRequest(operation: .textGeometry); request.textInput = .init(width: 20, height: 10)
        let file = root.appendingPathComponent("input"); try Data(repeating: 255, count: 800).write(to: file)
        let value = try MediaTextDecoder.decode(request, directory: root, geometry: { image in
            XCTAssertEqual(image.width, 20); return .init(boxes: [.init(x: 0, y: 0, width: 1, height: 1)])
        })
        XCTAssertEqual(value.geometry?.boxes.count, 1); XCTAssertNil(value.recognition)
        try Data(repeating: 0, count: 799).write(to: file)
        XCTAssertThrowsError(try MediaTextDecoder.decode(request, directory: root, geometry: { _ in XCTFail("Truncated input reached detector"); return .init(boxes: []) }))
        request.textInput = .init(width: Int.max, height: 1); XCTAssertThrowsError(try request.validate())
    }

    func testRealHelperDetectsBlankAndTextWithoutHostVisionObjects() async throws {
        let worker = try worker(); defer { worker.preventNewWork() }
        let detector = VisionTextHeightMeasurer(recognizer: .init(worker: worker))
        let blank = try await detector.geometry(in: ScreenCaptureTestSupport.image(width: 200, height: 200, gray: 1))
        XCTAssertTrue(blank.lines.isEmpty); XCTAssertNil(blank.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 600, height: 160, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(.init(x: 0, y: 0, width: 600, height: 160))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Private 123456" as NSString).draw(at: .init(x: 20, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let value = try await detector.geometry(in: XCTUnwrap(ctx.makeImage()))
        XCTAssertFalse(value.lines.isEmpty); XCTAssertGreaterThan(try XCTUnwrap(value.height), 20)
        await worker.shutdown()
    }

    func testCropCoordinatesScaleAndMalformedGeometry() async throws {
        let image = ScreenCaptureTestSupport.image(width: 400, height: 300)
        let mosaic = ScreenshotMosaic(shape: .rect(.init(x: 20, y: 30, width: 80, height: 40)))
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        let good = MosaicFixed(value: .init(lines: [.init(x: 4, y: 6, width: 20, height: 10)], height: 10))
        let result = try await ScreenshotMosaicPreparation.prepare(mosaic, crop: bounds, image: image, bounds: bounds, measurer: good)
        XCTAssertEqual(result.lines, [.init(x: 22, y: 33, width: 10, height: 5)]); XCTAssertEqual(result.height, 5)
        for bad in [ScreenshotTextGeometry(lines: [.zero], height: nil), .init(lines: [], height: .infinity), .init(lines: [.init(x: 0, y: 0, width: 1000, height: 1)], height: nil)] {
            do { _ = try await ScreenshotMosaicPreparation.prepare(mosaic, crop: bounds, image: image, bounds: bounds, measurer: MosaicFixed(value: bad)); XCTFail("Invalid geometry accepted") } catch {}
        }
        for malformed in [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), .init(x: 0, y: 0, width: CGFloat.infinity, height: 10)] {
            do { _ = try await ScreenshotMosaicPreparation.prepare(mosaic, crop: malformed, image: image, bounds: bounds, measurer: good); XCTFail("Nonfinite geometry accepted") } catch {}
        }
        do { _ = try await ScreenshotMosaicPreparation.prepare(mosaic, crop: .zero, image: image, bounds: bounds, measurer: good); XCTFail("Empty crop accepted") } catch {}
    }

    func testCompletionPreservesIdentitySingleUndoAndRedoAndSafePendingExport() throws {
        var editor = editor(); let original = try XCTUnwrap(editor.document.annotations.first)
        XCTAssertNil(original.mosaic?.textRuns); XCTAssertEqual(original.mosaic?.textHeight, 60)
        let id = try XCTUnwrap(editor.geometryRequest?.id)
        editor.completeGeometry(UUID(), geometry: .init(lines: [], height: 1)); XCTAssertEqual(editor.document.annotations.first, original)
        editor.completeGeometry(id, geometry: .init(lines: [.init(x: 20, y: 20, width: 30, height: 8), .init(x: 200, y: 200, width: 10, height: 8)], height: 8))
        let final = try XCTUnwrap(editor.document.annotations.first)
        XCTAssertEqual(final.id, original.id); XCTAssertEqual(final.mosaic?.textRuns?.count, 1); XCTAssertEqual(editor.document.undoDepth, 1)
        XCTAssertTrue(editor.undo()); XCTAssertTrue(editor.document.isEmpty); XCTAssertTrue(editor.redo()); XCTAssertEqual(editor.document.annotations.first, final)
        var cancelled = self.editor(); let pending = try XCTUnwrap(cancelled.geometryRequest?.id); cancelled.cancelGeometry()
        cancelled.completeGeometry(pending, geometry: .init(lines: [], height: 1)); XCTAssertEqual(cancelled.document.annotations.first?.mosaic?.textHeight, 60)
    }

    func testFailedPreparationKeepsWholeMaskAndDoesNotRetryFromRefresh() async throws {
        let owner = ScreenshotMosaicPreparation(); let editor = editor(); var calls = 0
        func update() { owner.update(editor: editor, region: .init(x: 0, y: 0, width: 200, height: 100), prepare: { _ in calls += 1; throw MediaFailure.unavailable }, commit: { _, _ in XCTFail("Failure committed") }) }
        update(); try await Self.waitFor { owner.state != .preparing }; update(); update()
        XCTAssertEqual(calls, 1); XCTAssertEqual(owner.state, .unavailable); XCTAssertNil(editor.document.annotations.first?.mosaic?.textRuns)
    }

    func testCancelledUncooperativeWorkRetainsOwnerSlotAndCannotOverwriteNewGesture() async throws {
        let pending = MosaicPending()
        let owner = ScreenshotMosaicPreparation(); var editor = editor(); var commits = 0
        func update() { owner.update(editor: editor, region: .init(x: 0, y: 0, width: 200, height: 100), prepare: { _ in try await pending.geometry(in: ScreenCaptureTestSupport.image(width: 100, height: 100)) }, commit: { _, _ in commits += 1 }) }
        update(); try await Self.waitFor { pending.calls == 1 }
        editor.undo(); update(); editor = self.editor(); update()
        XCTAssertEqual(pending.calls, 1); pending.finish()
        try await Task.sleep(for: .milliseconds(20)); update(); XCTAssertEqual(commits, 0); XCTAssertEqual(pending.calls, 1)
    }

    func testExportAndAccountChangeFenceLateCanvasResults() async throws {
        for revoke in [false, true] {
            let pending = MosaicPending(), view = canvas(pending)
            try await Self.waitFor { pending.calls == 1 }
            var exports: [[ScreenshotAnnotation]] = []
            view.onEvent = { if case let .finish(_, marks) = $0 { exports.append(marks) } }
            if revoke { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            else { view.perform(.save) }
            let before = view.editor.document.annotations; pending.finish()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(view.editor.document.annotations, before)
            if !revoke { XCTAssertEqual(exports, [before]) }
            view.releaseImage()
        }
    }

    func testActualPanelHideAndOwnerReleaseFenceResults() async throws {
        let pending = MosaicPending(), view = canvas(pending)
        let panel = ScreenshotFloatingPanel(frame: view.bounds, becomesKey: true)
        panel.onHide = { [weak view] in view?.releaseImage() }; panel.contentView = view; panel.orderFrontRegardless()
        try await Self.waitFor { pending.calls == 1 }; let original = view.editor.document
        panel.orderOut(nil); pending.finish(); try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(view.editor.document, original); XCTAssertEqual(view.mosaicPreparation.state, .retired)
        panel.close(); panel.contentView = nil
        var owner: ScreenshotMosaicPreparation? = ScreenshotMosaicPreparation(); weak var weakOwner = owner
        owner?.retire(); owner = nil; XCTAssertNil(weakOwner)
    }
    func testAnnotationIdentityAndEmptyGeometryDoNotChangeAnotherMask() throws {
        var editor = editor()
        let first = try XCTUnwrap(editor.document.annotations.first)
        let request = try XCTUnwrap(editor.geometryRequest)
        editor.addMosaics(over: [first.frame])
        let second = try XCTUnwrap(editor.document.annotations.last)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(request.annotationID, first.id)
        editor.completeGeometry(request.id, geometry: .init(lines: [], height: nil))
        XCTAssertEqual(editor.document.annotations.last, second)
        XCTAssertNil(editor.document.annotations.first?.mosaic?.textHeight)
        XCTAssertNil(editor.document.annotations.first?.mosaic?.textRuns)
    }

    func testPendingAndFailureNoticeRendersWithWholeMask() async throws {
        _ = NSApplication.shared
        let prior = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(prior) }
        var state = ScreenshotEditorToolbarModel.State()
        state.showsMosaicOptions = true; state.showsOptions = true; state.tool = .mosaic
        state.mosaicPreparation = .preparing
        XCTAssertNotNil(state.mosaicPreparation.noticeKey)
        let pending = NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar)
        state.mosaicPreparation = .unavailable
        let failed = NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar)
        let host = NSView(frame: .init(x: 0, y: 0, width: 950, height: 150))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pending.frame = .init(x: 10, y: 80, width: 930, height: 60)
        failed.frame = .init(x: 10, y: 10, width: 930, height: 60)
        host.addSubview(pending); host.addSubview(failed)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/mosaic-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("mosaic-geometry.png"))
        XCTAssertGreaterThan(pending.fittingSize.width, 300); XCTAssertGreaterThan(failed.fittingSize.width, 300)
        XCTAssertNil(ScreenshotMosaicPreparation.State.ready.noticeKey)
        XCTAssertNil(ScreenshotMosaicPreparation.State.idle.noticeKey)
        XCTAssertNotNil(ScreenshotMosaicPreparation.State.retired.noticeKey)
    }

}
