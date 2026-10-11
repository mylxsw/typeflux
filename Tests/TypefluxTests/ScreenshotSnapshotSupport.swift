import AppKit
import SwiftUI
@testable import Typeflux

/// Pictures of the screenshot editor for reviews: a made-up app window marked up with the real
/// renderer, the region's outline, and the real toolbar under it. Written as PNGs only when
/// `TYPEFLUX_SCREENSHOT_SNAPSHOTS` names a directory; otherwise only rendered.
@MainActor
enum ScreenshotSnapshotSupport {
    static let environmentKey = "TYPEFLUX_SCREENSHOT_SNAPSHOTS"
    static let screenSize = CGSize(width: 760, height: 420)

    /// Where the sample window's content is, in its points, so marks can be put on it.
    enum Layout {
        static let title = CGRect(x: 40, y: 32, width: 360, height: 30)
        static let rows: [CGRect] = (0 ..< 5).map { CGRect(x: 160, y: 96 + CGFloat($0) * 40, width: 300, height: 22) }
        static let phone = rows[1]
        static let email = rows[2]
        static let address = rows[3]
        static let amount = rows[4]
        static let chart = CGRect(x: 40, y: 310, width: 380, height: 90)
        static let primaryButton = CGRect(x: 500, y: 316, width: 120, height: 34)
        static let secondaryButton = CGRect(x: 500, y: 360, width: 120, height: 34)
    }

    private static let labels = ["Name", "Phone", "Email", "Address", "Total"]
    private static let values = ["Alex Chen", "138 0013 8000", "alex.chen@example.com", "100 Century Ave, Floor 21",
                                 "$ 98.00"]

    /// An order page in a dark app: a title, five rows, a bar chart and two buttons.
    static func sampleScreen() -> CGImage {
        let width = Int(screenSize.width), height = Int(screenSize.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.09, green: 0.094, blue: 0.11, alpha: 1))
        context.fill(CGRect(origin: .zero, size: screenSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor = NSColor(white: 0.9, alpha: 1)) {
            (string as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                                  .foregroundColor: color])
        }
        text("Order #TF-20261011-0832", at: Layout.title.origin, size: 22, weight: .bold)
        text("2026-10-11 09:32 · Paid · Pro yearly", at: CGPoint(x: 40, y: 64), size: 13,
             color: NSColor(white: 0.6, alpha: 1))
        for (index, row) in Layout.rows.enumerated() {
            text(labels[index], at: CGPoint(x: 40, y: row.minY + 2), size: 14, color: NSColor(white: 0.6, alpha: 1))
            text(values[index], at: row.origin, size: 15, weight: .medium)
            context.setFillColor(CGColor(gray: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: row.maxY + 9, width: 680, height: 1))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.05))
        context.addPath(CGPath(roundedRect: Layout.chart, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.55, blue: 1, alpha: 1))
        for (index, value) in [0.4, 0.62, 0.48, 0.8, 0.55, 0.92, 0.7].enumerated() {
            let barHeight = CGFloat(value) * 60
            context.fill(CGRect(x: Layout.chart.minX + 16 + CGFloat(index) * 50, y: Layout.chart.maxY - 10 - barHeight,
                                width: 34, height: barHeight))
        }
        context.addPath(CGPath(roundedRect: Layout.primaryButton, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        text("Download", at: CGPoint(x: Layout.primaryButton.minX + 28, y: Layout.primaryButton.minY + 8), size: 14,
             weight: .semibold, color: .white)
        context.setFillColor(CGColor(gray: 1, alpha: 0.1))
        context.addPath(CGPath(roundedRect: Layout.secondaryButton, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        text("Refund", at: CGPoint(x: Layout.secondaryButton.minX + 36, y: Layout.secondaryButton.minY + 8),
             size: 14, weight: .semibold)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// The sample window as a 1× display, for the renderer.
    static func sampleDisplay() -> ScreenSnapshot.Display {
        ScreenSnapshot.Display(id: 1, frame: CGRect(origin: .zero, size: screenSize), scale: 1, image: sampleScreen())
    }

    /// A SwiftUI view drawn in a borderless window in the dark or light appearance.
    static func bitmap(of view: some View, dark: Bool = true) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(view))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// The toolbar in a state, with room around it for its shadow.
    static func toolbar(_ state: ScreenshotEditorToolbarModel.State, dark: Bool = true) async throws
        -> NSBitmapImageRep {
        try await bitmap(of: ScreenshotEditorToolbar(state: state) { _ in }.padding(14), dark: dark)
    }

    /// The marked-up window inside a dark backdrop with the region's outline, and the toolbar
    /// right-aligned under it, as the overlay shows them.
    static func composite(annotations: [ScreenshotAnnotation], toolbar: NSBitmapImageRep,
                          extra: ((CGContext) -> Void)? = nil) throws -> CGImage {
        let display = sampleDisplay()
        let marked = try ScreenshotRenderer.render(display, crop: display.frame, annotations: annotations)
        let margin: CGFloat = 40
        let toolbarSize = toolbar.size
        let width = max(screenSize.width, toolbarSize.width) + margin * 2
        let height = margin + screenSize.height + 4 + toolbarSize.height + margin / 2
        let scale: CGFloat = 2
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let region = CGRect(x: margin, y: margin, width: screenSize.width, height: screenSize.height)
        ScreenshotRenderer.drawImage(marked, in: region, context: context)
        context.setStrokeColor(ScreenshotOverlayChromeView.accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(region)
        extra?(context)
        if let toolbarImage = toolbar.cgImage {
            let frame = CGRect(x: region.maxX - toolbarSize.width + 14, y: region.maxY + 4 - 14,
                               width: toolbarSize.width, height: toolbarSize.height)
            ScreenshotRenderer.drawImage(toolbarImage, in: frame, context: context)
        }
        return context.makeImage()!
    }

    /// Writes the picture when snapshots are asked for.
    static func write(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment[environmentKey] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
