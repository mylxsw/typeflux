import AppKit
import SwiftUI

/// The floating header has its own surface and input region. A transcript mask
/// only changes pixels; without this region, hidden text still receives drags.
struct AskConversationTitleBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ZStack(alignment: .top) {
            if style.usesGlass {
                let base = AskWindowBackdrop.base(dark: colorScheme == .dark)
                LinearGradient(stops: [
                    .init(color: base.opacity(reduceTransparency || contrast == .increased ? 1 : 0.96), location: 0),
                    .init(color: base.opacity(reduceTransparency || contrast == .increased ? 1 : 0.82),
                          location: AskMetrics.titleBarRowHeight / (AskMetrics.titleBarRowHeight + AskMetrics.transcriptEdgeFade)),
                    .init(color: base.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: AskMetrics.titleBarRowHeight + AskMetrics.transcriptEdgeFade)
                .allowsHitTesting(false)
            }
            // The gradient's tail is decorative: text below the title row stays selectable.
            AskConversationTitleBarDragArea()
                .frame(height: AskMetrics.titleBarRowHeight)
        }
        .accessibilityHidden(true)
    }
}

private struct AskConversationTitleBarDragArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> AskConversationTitleBarDragView { AskConversationTitleBarDragView() }
    func updateNSView(_: AskConversationTitleBarDragView, context _: Context) {}
}

final class AskConversationTitleBarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
