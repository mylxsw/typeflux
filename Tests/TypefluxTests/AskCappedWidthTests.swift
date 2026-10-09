import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask capped width", .exclusiveUIState)
@MainActor
struct AskCappedWidthTests {
    private func width<V: View>(_ view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view.font(.system(size: 12.5, weight: .medium)))
        return hosting.fittingSize.width
    }

    /// Width the view is laid out at inside a 600pt-wide row.
    private func placedWidth<V: View>(_ view: V) async throws -> CGFloat {
        let box = WidthBox()
        let row = HStack(spacing: 0) {
            view.background(GeometryReader { proxy in
                Color.clear.onAppear { box.value = proxy.size.width }
            })
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, weight: .medium))
        .frame(width: 600, height: 28)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: row)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0 ..< 50 where box.value < 0 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return box.value
    }

    @Test func proposalIsCappedButOtherwisePreserved() {
        let layout = AskCappedWidth(maxWidth: 132)
        #expect(layout.capped(ProposedViewSize(width: 400, height: 28)) == ProposedViewSize(width: 132, height: 28))
        #expect(layout.capped(ProposedViewSize(width: 80, height: nil)) == ProposedViewSize(width: 80, height: nil))
        #expect(layout.capped(.unspecified) == ProposedViewSize(width: 132, height: nil))
        #expect(AskCappedWidth(maxWidth: .infinity).capped(.unspecified) == .unspecified)
        #expect(AskCappedWidth(maxWidth: .infinity).capped(ProposedViewSize(width: 90, height: 20))
            == ProposedViewSize(width: 90, height: 20))
    }

    @Test func shortModelNameHugsItsText() async throws {
        let text = Text(verbatim: "MiniMax M3").lineLimit(1)
        let natural = width(text)
        #expect(natural > 0 && natural < AskMetrics.modelMenuMaxWidth)
        #expect(width(AskCappedWidth(maxWidth: AskMetrics.modelMenuMaxWidth) { text }) == natural)
        // Offered far more room than the cap, a short name still takes only its own width,
        // where `.frame(maxWidth:)` would have grown to the cap.
        let hugged = try await placedWidth(AskCappedWidth(maxWidth: AskMetrics.modelMenuMaxWidth) { text })
        let stretched = try await placedWidth(text.frame(maxWidth: AskMetrics.modelMenuMaxWidth))
        #expect(abs(hugged - natural) < 0.5)
        #expect(stretched == AskMetrics.modelMenuMaxWidth)
    }

    @Test func longModelNameStopsAtTheCap() {
        let text = Text(verbatim: String(repeating: "Very Long Model Name ", count: 6))
            .lineLimit(1).truncationMode(.middle)
        #expect(width(text) > AskMetrics.modelMenuMaxWidth)
        #expect(width(AskCappedWidth(maxWidth: AskMetrics.modelMenuMaxWidth) { text }) <= AskMetrics.modelMenuMaxWidth)
    }

    @Test func modelMenuIsNarrowerThanBefore() {
        #expect(AskMetrics.modelMenuMaxWidth == 132)
    }
}

@MainActor
private final class WidthBox {
    var value: CGFloat = -1
}
