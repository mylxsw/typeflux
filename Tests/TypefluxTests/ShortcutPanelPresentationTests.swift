import AppKit
import Testing
@testable import Typeflux

@Suite("Shortcut panel presentation", .exclusiveUIState)
@MainActor
struct ShortcutPanelPresentationTests {
    private final class Panel: NSPanel {
        var operations: [String] = []
        var beforeFocus: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func orderFrontRegardless() {
            operations.append("order")
            super.orderFrontRegardless()
        }
        override func displayIfNeeded() {
            operations.append("display")
            super.displayIfNeeded()
        }
        override func makeKey() {
            operations.append("key")
            beforeFocus?()
            super.makeKey()
        }
    }

    private final class DrawingView: NSView {
        var drew = false
        override func draw(_ dirtyRect: NSRect) {
            NSColor.green.setFill()
            dirtyRect.fill()
            drew = true
        }
    }

    @Test func ordersBeforeFocusWithoutActivatingSourceApplicationOrOtherWindows() throws {
        _ = NSApplication.shared
        let panel = Panel(contentRect: .init(x: 100, y: 100, width: 300, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = DrawingView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = content
        panel.beforeFocus = { #expect(content.drew, "The first frame must be drawn before native focus can block") }
        let other = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { panel.close(); other.close() }
        let originalApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let collector = ShortcutLatencyEventCollector()
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.$current.withValue(diagnosticTestTrace(.launcher)) {
                ShortcutPanelPresentation.show(panel)
            }
        }
        #expect(panel.operations.first == "order")
        #expect(panel.operations.firstIndex(of: "display")! < panel.operations.firstIndex(of: "key")!)
        #expect(panel.isVisible && panel.isKeyWindow)
        #expect(!other.isVisible)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp)
        #expect(collector.stages == [.windowOrderStarted, .windowOrderFinished,
                                    .windowDisplayStarted, .windowDisplayFinished, .windowKeyStarted, .windowKeyFinished])
        panel.operations = []
        ShortcutPanelPresentation.show(panel)
        #expect(panel.operations.first == "order")
        #expect(!panel.operations.contains("key"))
        panel.orderOut(nil)
        ShortcutPanelPresentation.show(panel)
        #expect(panel.isVisible && panel.isKeyWindow)
    }
}
