import AppKit
import Testing
@testable import Typeflux

@Suite("Shortcut panel presentation", .exclusiveUIState)
@MainActor
struct ShortcutPanelPresentationTests {
    private final class Panel: NSPanel {
        var operations: [String] = []
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func orderFront(_ sender: Any?) {
            operations.append("order")
            super.orderFront(sender)
        }
        override func makeKey() {
            operations.append("key")
            super.makeKey()
        }
    }

    @Test func ordersBeforeFocusWithoutActivatingSourceApplicationOrOtherWindows() throws {
        _ = NSApplication.shared
        let panel = Panel(contentRect: .init(x: 100, y: 100, width: 300, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
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
        #expect(panel.operations == ["order", "key"])
        #expect(panel.isVisible && panel.isKeyWindow)
        #expect(!other.isVisible)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp)
        #expect(collector.stages == [.windowOrderStarted, .windowOrderFinished, .windowKeyStarted, .windowKeyFinished])
        panel.operations = []
        ShortcutPanelPresentation.show(panel)
        #expect(panel.operations == ["order"])
        panel.orderOut(nil)
        ShortcutPanelPresentation.show(panel)
        #expect(panel.isVisible && panel.isKeyWindow)
    }
}
