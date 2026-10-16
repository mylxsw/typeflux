import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotRedactionSuggestionsTests: XCTestCase {
    private func finding(_ kind: ScreenshotSensitiveFinding.Kind, _ box: CGRect) -> ScreenshotSensitiveFinding {
        ScreenshotSensitiveFinding(kind: kind, text: "13800138000", boundingBox: box)
    }

    /// A 400 × 200 px image at 2×: 200 × 100 pt. One finding left, one right.
    private func scanned() -> ScreenshotRedactionSuggestions {
        var suggestions = ScreenshotRedactionSuggestions()
        suggestions.beginScan()
        XCTAssertEqual(suggestions.status, .scanning)
        suggestions.finishScan([
            finding(.phone, CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
            finding(.email, CGRect(x: 0.6, y: 0.5, width: 0.3, height: 0.1))
        ], imageSize: CGSize(width: 400, height: 200), scale: 2)
        return suggestions
    }

    private func mosaics(for items: [ScreenshotRedactionSuggestions.Item]) -> [ScreenshotAnnotation] {
        items.map { ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect($0.rect)))) }
    }

    func testFindingsArePlacedInPointsWithPadding() {
        let suggestions = scanned()
        XCTAssertEqual(suggestions.status, .done)
        XCTAssertEqual(suggestions.items.map(\.rect), [CGRect(x: 18, y: 8, width: 44, height: 14),
                                                       CGRect(x: 118, y: 48, width: 64, height: 14)])
        XCTAssertEqual(suggestions.items.map(\.id), suggestions.items.map(\.finding.id))
    }

    func testOnlyFindingsMostlyInTheRegionAreListed() {
        let suggestions = scanned()
        XCTAssertEqual(suggestions.visibleItems(in: nil).count, 2)
        XCTAssertEqual(suggestions.visibleItems(in: CGRect(x: 0, y: 0, width: 100, height: 100)).map(\.finding.kind),
                       [.phone])
        // Half of the phone (x 18–62) is left of x 40.
        XCTAssertEqual(suggestions.visibleItems(in: CGRect(x: 40, y: 0, width: 50, height: 50)).count, 1)
        XCTAssertEqual(suggestions.visibleItems(in: CGRect(x: 41, y: 0, width: 50, height: 50)).count, 0)
        XCTAssertTrue(suggestions.visibleItems(in: CGRect(x: 0, y: 90, width: 10, height: 10)).isEmpty)
    }

    func testTickingCoversAndUntickingUncovers() throws {
        var suggestions = scanned()
        let phone = suggestions.items[0]
        guard case let .add(items) = suggestions.toggle(phone.id, in: []) else { return XCTFail("Expected add") }
        XCTAssertEqual(items, [phone])
        let annotations = mosaics(for: items)
        suggestions.record(annotations.map(\.id), for: items)
        XCTAssertTrue(suggestions.isApplied(phone.id, in: annotations))

        XCTAssertEqual(suggestions.toggle(phone.id, in: annotations), .remove([annotations[0].id]))
        // Undo took the mosaic away: the item is unticked and ticking adds it again.
        XCTAssertFalse(suggestions.isApplied(phone.id, in: []))
        XCTAssertEqual(suggestions.toggle(phone.id, in: []), .add([phone]))
        XCTAssertEqual(suggestions.toggle(UUID(), in: []), .none)
    }

    func testCoverAllAddsOnlyWhatIsUncoveredInTheRegion() {
        var suggestions = scanned()
        let all = suggestions.applyAll(in: nil, annotations: [])
        XCTAssertEqual(all, .add(suggestions.items))

        let phone = suggestions.items[0]
        let covered = mosaics(for: [phone])
        suggestions.record(covered.map(\.id), for: [phone])
        XCTAssertEqual(suggestions.applyAll(in: nil, annotations: covered), .add([suggestions.items[1]]))
        XCTAssertEqual(suggestions.applyAll(in: CGRect(x: 0, y: 0, width: 100, height: 100), annotations: covered),
                       .none)
    }

    func testThePanelShowsOnlyFinishedVisibleFindingsUntilClosed() throws {
        var suggestions = ScreenshotRedactionSuggestions()
        XCTAssertNil(suggestions.panelState(crop: nil, annotations: []))
        suggestions.beginScan()
        XCTAssertNil(suggestions.panelState(crop: nil, annotations: []), "Nothing while scanning")

        suggestions = scanned()
        let state = try XCTUnwrap(suggestions.panelState(crop: nil, annotations: []))
        XCTAssertEqual(state.rows.map(\.kind), [.phone, .email])
        XCTAssertEqual(state.rows.map(\.text), ["13•••••••00", "13•••••••00"])
        XCTAssertFalse(state.allApplied)
        XCTAssertNil(suggestions.panelState(crop: CGRect(x: 0, y: 90, width: 5, height: 5), annotations: []))

        suggestions.isDismissed = true
        XCTAssertNil(suggestions.panelState(crop: nil, annotations: []))
    }

    // MARK: Controller

    private struct Scanner: ScreenshotSensitiveInfoScanning {
        var findings: [ScreenshotSensitiveFinding]
        func scan(_ image: CGImage) async -> [ScreenshotSensitiveFinding] { findings }
    }

    func testTheControllerScansOnceAndEditsTheDocumentThroughItsHost() async throws {
        let found = [finding(.phone, CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))]
        let controller = ScreenshotSensitiveInfoController(scanner: Scanner(findings: found))
        var editor = ScreenshotAnnotationEditor()
        var changes = 0
        controller.annotations = { editor.document.annotations }
        controller.addMosaics = { editor.addMosaics(over: $0) }
        controller.removeAnnotations = { editor.removeAnnotations($0) }
        controller.onChange = { changes += 1 }
        let image = ScreenCaptureTestSupport.image(width: 400, height: 200)

        controller.scan(image, scale: 2)
        controller.scan(image, scale: 2)
        await controller.waitForScan()
        XCTAssertEqual(changes, 1, "One scan")
        XCTAssertEqual(controller.suggestions.items.count, 1)

        let host = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        controller.layout(in: host, crop: nil) { CGRect(origin: .zero, size: $0) }
        let panel = try XCTUnwrap(controller.host)
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(panel.superview === host)
        XCTAssertGreaterThan(panel.frame.height, 0)

        controller.perform(.applyAll, crop: nil)
        XCTAssertEqual(editor.document.annotations.count, 1)
        XCTAssertEqual(editor.document.annotations.first?.mosaic?.textHeight, 14)
        controller.perform(.toggle(controller.suggestions.items[0].id), crop: nil)
        XCTAssertTrue(editor.document.annotations.isEmpty)
        editor.undo()
        XCTAssertEqual(editor.document.annotations.count, 1, "Undo puts the mosaic back")
        XCTAssertTrue(controller.suggestions.isApplied(controller.suggestions.items[0].id,
                                                       in: editor.document.annotations))

        controller.layout(in: host, crop: nil, hidden: true) { CGRect(origin: .zero, size: $0) }
        XCTAssertTrue(panel.isHidden)
        controller.perform(.close, crop: nil)
        controller.layout(in: host, crop: nil) { CGRect(origin: .zero, size: $0) }
        XCTAssertTrue(panel.isHidden, "Closed for this screenshot")
        XCTAssertEqual(changes, 4)
    }

    func testAControllerWithoutAScannerOrCancelledFindsNothing() async {
        let none = ScreenshotSensitiveInfoController(scanner: nil)
        none.scan(ScreenCaptureTestSupport.image(width: 10, height: 10), scale: 1)
        XCTAssertEqual(none.suggestions.status, .idle)

        let cancelled = ScreenshotSensitiveInfoController(scanner: Scanner(findings: []))
        cancelled.scan(ScreenCaptureTestSupport.image(width: 10, height: 10), scale: 1)
        cancelled.cancel()
        await cancelled.waitForScan()
        XCTAssertEqual(cancelled.suggestions.status, .idle, "A cancelled scan clears private findings")
    }

    func testThePanelGoesBesideTheRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 248, height: 200)
        XCTAssertEqual(ScreenshotSensitiveInfoController.panelFrame(
            beside: CGRect(x: 100, y: 100, width: 300, height: 200), size: size, in: bounds
        ).origin, CGPoint(x: 412, y: 100), "Right")
        XCTAssertEqual(ScreenshotSensitiveInfoController.panelFrame(
            beside: CGRect(x: 600, y: 100, width: 300, height: 200), size: size, in: bounds
        ).origin, CGPoint(x: 340, y: 100), "Left")
        XCTAssertEqual(ScreenshotSensitiveInfoController.panelFrame(
            beside: CGRect(x: 100, y: 500, width: 800, height: 100), size: size, in: bounds
        ).origin, CGPoint(x: 640, y: 400), "Inside, kept on the display")
        XCTAssertEqual(ScreenshotSensitiveInfoController.panelFrame(
            beside: CGRect(x: 0, y: 0, width: 100, height: 50), size: CGSize(width: 248, height: 900), in: bounds
        ).origin, CGPoint(x: 112, y: 0), "Taller than the display: from the top")
    }

    func testTheVisionScannerReadsThenDetects() async throws {
        struct Reader: ImageTextRecognizing {
            var fails = false
            func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
                if fails { throw ImageTilingError.unreadable }
                let box = CGRect(x: 0, y: 0, width: 1, height: 0.1)
                return RecognizedText(lines: [RecognizedText.Line(text: "mail a@example.com", confidence: 1,
                                                                  boundingBox: box)])
            }
        }
        let image = ScreenCaptureTestSupport.image(width: 10, height: 10)
        let findings = try await VisionSensitiveInfoScanner(recognizer: Reader()).scan(image)
        XCTAssertEqual(findings.map(\.kind), [.email])
        do { _ = try await VisionSensitiveInfoScanner(recognizer: Reader(fails: true)).scan(image); XCTFail("Failure became no findings") }
        catch {}
    }

    func testTheDocumentAddsAndRemovesSeveralAsOneStep() {
        var document = ScreenshotAnnotationDocument()
        let marks = (0 ..< 3).map { _ in ScreenshotAnnotation(kind: .rect(CGRect(x: 0, y: 0, width: 5, height: 5))) }
        document.add([])
        XCTAssertFalse(document.canUndo)
        document.add(marks)
        XCTAssertEqual(document.undoDepth, 1)
        XCTAssertFalse(document.remove(ids: [UUID()]))
        XCTAssertTrue(document.remove(ids: [marks[0].id, marks[2].id]))
        XCTAssertEqual(document.annotations.map(\.id), [marks[1].id])
        document.undo()
        XCTAssertEqual(document.annotations.count, 3)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
    }

    func testTheEditorAddsMosaicsInItsCurrentStyle() {
        var editor = ScreenshotAnnotationEditor()
        editor.setMosaicEffect(.solid)
        editor.setMosaicStrength(.high)
        let ids = editor.addMosaics(over: [CGRect(x: 0, y: 0, width: 40, height: 12)])
        let mosaic = editor.document.annotation(id: ids[0])?.mosaic
        XCTAssertEqual(mosaic?.effect, .solid)
        XCTAssertEqual(mosaic?.strength, .high)
        XCTAssertEqual(mosaic?.textHeight, 12)
        XCTAssertFalse(editor.removeAnnotations([UUID()]))
        XCTAssertTrue(editor.removeAnnotations(Set(ids)))
        XCTAssertTrue(editor.document.isEmpty)
    }
}
