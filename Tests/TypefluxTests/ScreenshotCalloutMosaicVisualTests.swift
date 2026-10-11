import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Callouts and mosaics that only cover text, as they look; PNGs with `TYPEFLUX_SCREENSHOT_SNAPSHOTS`.
@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ScreenshotCalloutMosaicVisualTests {
    private typealias Layout = ScreenshotSnapshotSupport.Layout

    @Test func `callouts and a text-only mosaic`() async throws {
        var callout = ScreenshotAnnotationTool.callout.defaultStyle
        var outlined = callout
        outlined.textStyle = .outline
        outlined.calloutAnchor = .arrow
        outlined.color = .yellow
        callout.size = 15
        // The contact rows are covered line by line; the labels and the layout stay readable.
        var textOnly = ScreenshotMosaic(shape: .rect(CGRect(x: 150, y: 128, width: 330, height: 120)),
                                        effect: .pixelate, strength: .high)
        textOnly.textRuns = [Layout.phone, Layout.email, Layout.address].map {
            CGRect(x: $0.minX, y: $0.minY + 2, width: $0.width - 60, height: $0.height - 2)
        }
        textOnly.textHeight = 18
        let annotations = [
            ScreenshotAnnotation(kind: .mosaic(textOnly)),
            ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .ellipse(CGRect(x: 640, y: 40, width: 80,
                                                                                         height: 50)),
                                                                effect: .blur))),
            ScreenshotAnnotation(kind: .callout(anchor: CGPoint(x: 330, y: 300), origin: CGPoint(x: 520, y: 248),
                                                "Total is wrong", fontSize: 15), style: callout),
            ScreenshotAnnotation(kind: .callout(anchor: CGPoint(x: 618, y: 377), origin: CGPoint(x: 640, y: 120),
                                                "Hide refunds", fontSize: 15), style: outlined)
        ]
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.callout)
        let calloutBar = try await ScreenshotSnapshotSupport.toolbar(
            ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false, isPickingColor: false)
        )
        let image = try ScreenshotSnapshotSupport.composite(annotations: annotations, toolbar: calloutBar)
        #expect(image.width > 0)
        try ScreenshotSnapshotSupport.write(image, name: "s3-callout")

        editor.selectTool(.mosaic)
        editor.setMosaicScope(.text)
        let mosaicBar = try await ScreenshotSnapshotSupport.toolbar(
            ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false, isPickingColor: false)
        )
        try ScreenshotSnapshotSupport.write(
            try ScreenshotSnapshotSupport.composite(annotations: annotations, toolbar: mosaicBar), name: "s3-mosaic"
        )
    }
}
