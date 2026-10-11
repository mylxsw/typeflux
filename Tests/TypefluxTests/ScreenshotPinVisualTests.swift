import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The More menu, the pin button and grip, and a pinned screenshot; PNGs with `TYPEFLUX_SCREENSHOT_SNAPSHOTS`.
@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ScreenshotPinVisualTests {
    @Test func `the More menu and the grip`() async throws {
        let editor = ScreenshotAnnotationEditor()
        let state = ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false, isPickingColor: false,
                                                       showsMoreMenu: true, canShowSensitivePanel: true,
                                                       showsSensitivePanel: true)
        let toolbar = try await ScreenshotSnapshotSupport.toolbar(state)
        let image = try ScreenshotSnapshotSupport.composite(annotations: [], toolbar: toolbar)
        #expect(image.width > 0)
        try ScreenshotSnapshotSupport.write(image, name: "s4-more-menu")
    }

    @Test func `a pinned screenshot with its bar`() async throws {
        let display = ScreenshotSnapshotSupport.sampleDisplay()
        let pinned = try ScreenshotRenderer.render(display, crop: CGRect(x: 0, y: 0, width: 760, height: 280),
                                                   annotations: [])
        var pinState = ScreenshotPinState()
        pinState.zoom = 0.8
        let bar = try await ScreenshotSnapshotSupport.bitmap(of: ScreenshotPinBar(state: pinState) { _ in })
        #expect(bar.pixelsWide > 0)

        // A pin over another app's window, the bar along its bottom, as when the pointer is on it.
        let width: CGFloat = 1000, height: CGFloat = 520
        let context = CGContext(data: nil, width: Int(width * 2), height: Int(height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let editorWindow = CGRect(x: 40, y: 40, width: 560, height: 440)
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.addPath(CGPath(roundedRect: editorWindow, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (index, line) in ["func render(_ display: ScreenSnapshot.Display) throws -> CGImage {",
                              "    // Lay the page out like the pinned design on the right",
                              "    let toolbar = ScreenshotEditorToolbar(state: state)",
                              "    let options = toolbar.optionsBar", "}"].enumerated() {
            (line as NSString).draw(at: CGPoint(x: 64, y: 70 + CGFloat(index) * 24), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(white: 0.75, alpha: 1)
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        let pin = CGRect(x: 380, y: 140, width: 760 * pinState.zoom, height: 280 * pinState.zoom)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(pin)
        context.restoreGState()
        ScreenshotRenderer.drawImage(pinned, in: pin, context: context)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        context.stroke(pin)
        if let barImage = bar.cgImage {
            let size = bar.size
            ScreenshotRenderer.drawImage(barImage, in: CGRect(x: pin.midX - size.width / 2, y: pin.maxY - size.height - 8,
                                                              width: size.width, height: size.height),
                                         context: context)
        }
        try ScreenshotSnapshotSupport.write(context.makeImage()!, name: "s4-pin")
    }
}
