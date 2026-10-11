import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Arrow, pen, highlighter, text and counter options as they look; PNGs with `TYPEFLUX_SCREENSHOT_SNAPSHOTS`.
@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ScreenshotToolOptionsVisualTests {
    private typealias Layout = ScreenshotSnapshotSupport.Layout
    private typealias Style = ScreenshotAnnotationStyle

    private static func style(_ tool: ScreenshotAnnotationTool, _ change: (inout Style) -> Void) -> Style {
        var style = tool.defaultStyle
        change(&style)
        return style
    }

    @Test func `arrows, highlights, text and counters`() async throws {
        let annotations = [
            ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 700, y: 400), to: CGPoint(x: 628, y: 334)),
                                 style: Self.style(.arrow) {
                                     $0.arrowPath = .curve
                                     $0.arrowBend = -0.35
                                 }),
            ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 600, y: 60), to: CGPoint(x: 470, y: 150)),
                                 style: Self.style(.arrow) {
                                     $0.arrowPath = .elbow
                                     $0.arrowBend = 1
                                     $0.arrowHead = .open
                                     $0.color = .yellow
                                 }),
            ScreenshotAnnotation(kind: .highlight([CGPoint(x: Layout.address.minX, y: Layout.address.midY),
                                                   CGPoint(x: Layout.address.minX + 250, y: Layout.address.midY)]),
                                 style: ScreenshotAnnotationTool.highlighter.defaultStyle),
            ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 360, y: Layout.amount.minY - 2), "Paid twice?",
                                             fontSize: 18),
                                 style: Self.style(.text) { $0.font = .rounded }),
            ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 230, y: 330), "Peak on Saturday", fontSize: 18),
                                 style: Self.style(.text) {
                                     $0.textStyle = .outline
                                     $0.color = .blue
                                 }),
            ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 140, y: Layout.phone.midY)),
                                 style: Self.style(.counter) { $0.counterLabel = .letter }),
            ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 140, y: Layout.email.midY)),
                                 style: Self.style(.counter) {
                                     $0.counterLabel = .letter
                                     $0.counterShape = .bubble
                                     $0.counterAngle = 0
                                 })
        ]
        var editor = ScreenshotAnnotationEditor()
        editor.selectTool(.arrow)
        editor.setArrowPath(.curve)
        let state = ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false, isPickingColor: false)
        let toolbar = try await ScreenshotSnapshotSupport.toolbar(state)
        let image = try ScreenshotSnapshotSupport.composite(annotations: annotations, toolbar: toolbar)
        #expect(image.width > 0)
        try ScreenshotSnapshotSupport.write(image, name: "s2-tool-options")
    }
}
