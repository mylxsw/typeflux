import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Real clicks through the composer's model chip and its glass menu: the card lives in
/// the menu's own panel, and a change made on it must redraw it at once. Part of the
/// serialized event-delivery suite so clicks never overlap other click tests.
extension AskComposerInteractionTests {
    @Test func effortCardInTheGlassMenuRedrawsWhileOpen() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ask-effort-click-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "deep", name: "Deep", reference: "cloud:deep", scenarios: ["ask"], reasoning: true,
                  reasoningEfforts: ["low", "medium", "high", "xhigh", "max"])
        ], providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        fixture.model.selectModel("cloud:deep", launcher: false)
        fixture.model.reasoningEffort = .high

        let window = EffortClickWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: AskConversationView(model: fixture.model))
        window.orderFront(nil)
        let presenter = AskGlassMenuPresenter.shared
        defer {
            presenter.hide()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))

        func click(_ point: NSPoint, in target: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: target.windowNumber, context: nil,
                                                            eventNumber: 0, clickCount: 1,
                                                            pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
            }
        }

        // Open the chip's menu: the chip sits in the composer footer, left of centre.
        for x in stride(from: CGFloat(380), through: 560, by: 20) where !presenter.isShowing {
            try click(NSPoint(x: x, y: 46), in: window)
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(presenter.isShowing, "the chip opened its glass menu")
        let panel = try #require(presenter.panel)
        try await Task.sleep(for: .milliseconds(400))
        let content = try #require(panel.contentView)

        /// Whether the fill's blue shows near the start of the track.
        func fillVisible() throws -> Bool {
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
            for column in [CGFloat(28), 34, 40] {
                for row in stride(from: CGFloat(0), to: content.bounds.height, by: 1) {
                    if let color = bitmap.colorAt(x: Int(column * scale), y: Int(row * scale))?.usingColorSpace(.sRGB),
                       color.blueComponent - color.redComponent > 0.3 { return true }
                }
            }
            return false
        }
        #expect(try fillVisible(), "the high level draws its fill")

        // ↺ sits in the card's top-right corner; scan down its column until it takes the click.
        let size = content.bounds.size
        for row in stride(from: size.height - 4, to: 4, by: -2) where fixture.model.reasoningEffort != .providerDefault {
            try click(NSPoint(x: size.width - 24, y: row), in: panel)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.model.reasoningEffort == .providerDefault, "↺ reached the model")
        try await Task.sleep(for: .milliseconds(400))
        // Still open, and already redrawn: "Auto" draws no fill.
        #expect(presenter.isShowing)
        #expect(try !fillVisible())
    }
}

@MainActor
private final class EffortClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
