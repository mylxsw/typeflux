import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Real clicks through the composer's model chip and its glass menu: the card lives in
/// the menu's own panel, and a change made on it must redraw it at once. Part of the
/// serialized event-delivery suite so clicks never overlap other click tests.
extension AskComposerInteractionTests {
    /// The glass menu renders the card once, so a binding alone never redraws it. A change
    /// made on the card must still redraw it at once and reach the model. Its clicks
    /// would close another test's open glass menu, so it runs in this serialized suite.
    @Test func theCardRedrawsWhileOpen() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ask-effort-redraw-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "deep", name: "Deep", reference: "cloud:deep", scenarios: ["ask"], reasoning: true,
                  reasoningEfforts: ["low", "medium", "high", "xhigh", "max"])
        ], providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        final class Box { var effort = AskReasoningEffort.high; var reference = "cloud:deep" }
        final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
        let box = Box()
        let card = AskModelEffortCard(library: fixture.model.modelLibrary,
                                      reference: Binding(get: { box.reference }, set: { box.reference = $0 }),
                                      effort: Binding(get: { box.effort }, set: { box.effort = $0 }), loggedIn: true)
        let size = NSSize(width: AskModelEffortCard.width, height: 160)
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: card.frame(width: size.width, height: size.height))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        func click(_ point: NSPoint) throws {
            try AskWorkspaceTestMouse.click(at: point, in: window)
        }
        /// Rows where the fill's blue is drawn at `column`, in points from the top.
        func blueRows(atX column: CGFloat) throws -> [CGFloat] {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            return stride(from: CGFloat(0), to: size.height, by: 1).filter { top in
                guard let color = bitmap.colorAt(x: Int(column * scale), y: Int(top * scale))?.usingColorSpace(.sRGB)
                else { return false }
                return color.blueComponent - color.redComponent > 0.3
            }
        }

        // At "High" the fill covers the start of the track.
        #expect(try !blueRows(atX: 30).isEmpty)
        // ↺ writes "Auto" through the binding; scan the right edge for it.
        var reset = false
        for row in stride(from: CGFloat(4), to: size.height - 4, by: 2) {
            try click(NSPoint(x: size.width - 24, y: row))
            try await Task.sleep(for: .milliseconds(10))
            if box.effort == .providerDefault { reset = true; break }
        }
        #expect(reset, "the reset button reached the binding")
        try await Task.sleep(for: .milliseconds(400))
        // The card redraws at once, without reopening: the fill is gone.
        #expect(try blueRows(atX: 30).isEmpty)
    }

    @Test func effortCardInTheGlassMenuRedrawsWhileOpen() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
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
        window.contentView = NSHostingView(rootView: AskModelMenu(
            library: library, reference: Binding(get: { fixture.model.modelReference(launcher: false) },
                                                set: { fixture.model.selectModel($0, launcher: false) }),
            compact: true, cloudAvailable: true, effort: Binding(
                get: { fixture.model.reasoningEffort }, set: { fixture.model.reasoningEffort = $0 }
            ), controlIdentifier: "ask.test.model"
        ).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.orderFront(nil)
        let presenter = AskGlassMenuPresenter.shared
        defer {
            presenter.hide()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))

        try await SettingsBehaviorTestSupport.wait("The model menu button") {
            AskWorkspaceTestAccessibility.frame(identifier: "ask.test.model", in: window) != nil
        }

        func click(_ point: NSPoint, in target: NSWindow) throws {
            try AskWorkspaceTestMouse.click(at: point, in: target)
        }

        try click(AskWorkspaceTestAccessibility.center(identifier: "ask.test.model", in: window), in: window)
        try await Task.sleep(for: .milliseconds(150))
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
