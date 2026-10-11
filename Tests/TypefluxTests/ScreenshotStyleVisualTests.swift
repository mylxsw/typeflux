import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The shape options and the color panel as they look; PNGs for review with `TYPEFLUX_SCREENSHOT_SNAPSHOTS`.
@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ScreenshotStyleVisualTests {
    private typealias Layout = ScreenshotSnapshotSupport.Layout

    @Test func `shapes with fills, dashes and corners, and the color panel`() async throws {
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.rect)
        editor.setFill(.soft)
        editor.setCornerRadius(8)
        editor.setColor(.blue)
        editor.setColor(.red)
        let annotations = [
            ScreenshotAnnotation(kind: .rect(Layout.email.insetBy(dx: -8, dy: -6)),
                                 style: ScreenshotAnnotationStyle(color: .red, size: 3, fill: .soft, cornerRadius: 8)),
            ScreenshotAnnotation(kind: .ellipse(Layout.primaryButton.insetBy(dx: -14, dy: -10)),
                                 style: ScreenshotAnnotationStyle(color: .yellow, size: 3, dash: .dashed)),
            ScreenshotAnnotation(kind: .rect(Layout.amount.insetBy(dx: -6, dy: -4)),
                                 style: ScreenshotAnnotationStyle(color: .pink, fill: .solid, cornerRadius: 4)),
            ScreenshotAnnotation(kind: .line(from: CGPoint(x: 40, y: 290), to: CGPoint(x: 720, y: 290)),
                                 style: ScreenshotAnnotationStyle(color: .teal, size: 2, dash: .dashed))
        ]
        let state = ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: true, isPickingColor: false)
        #expect(state.showsColorPanel)
        let toolbar = try await ScreenshotSnapshotSupport.toolbar(state)
        #expect(toolbar.pixelsWide > 0)
        let image = try ScreenshotSnapshotSupport.composite(annotations: annotations, toolbar: toolbar)
        #expect(image.width > Int(ScreenshotSnapshotSupport.screenSize.width))
        try ScreenshotSnapshotSupport.write(image, name: "s1-shapes-color-panel")

        let light = try await ScreenshotSnapshotSupport.toolbar(state, dark: false)
        try ScreenshotSnapshotSupport.write(
            try ScreenshotSnapshotSupport.composite(annotations: annotations, toolbar: light),
            name: "s1-shapes-color-panel-light"
        )
    }

    @Test func `every tool's second row`() async throws {
        var images: [NSBitmapImageRep] = []
        for tool in ScreenshotAnnotationTool.allCases {
            var state = ScreenshotEditorToolbarModel.State()
            state.tool = tool
            state.optionsTool = tool
            state.style = tool.defaultStyle
            state.size = tool.defaultStyle.size
            state.showsOptions = true
            state.showsColor = tool.usesColor
            state.showsMosaicOptions = tool == .mosaic
            images.append(try await ScreenshotSnapshotSupport.bitmap(
                of: ScreenshotEditorToolbar(state: state) { _ in }.optionsBar.padding(10)
            ))
        }
        #expect(images.allSatisfy { $0.pixelsWide > 0 })
        guard ProcessInfo.processInfo.environment[ScreenshotSnapshotSupport.environmentKey] != nil else { return }
        // One row per tool, stacked.
        let width = images.map(\.size.width).max() ?? 0, height = images.map(\.size.height).reduce(0, +)
        let context = CGContext(data: nil, width: Int(width * 2), height: Int(height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for image in images {
            top -= image.size.height
            if let cgImage = image.cgImage {
                context.draw(cgImage, in: CGRect(x: 0, y: top, width: image.size.width, height: image.size.height))
            }
        }
        try ScreenshotSnapshotSupport.write(context.makeImage()!, name: "options-rows")
    }
}
