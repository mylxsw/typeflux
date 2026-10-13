import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Present the production reasoning card without input tracking, then verify model changes redraw it.
extension AskComposerInteractionTests {
    @Test func theCardRedrawsWhileOpen() async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let defaults = try #require(UserDefaults(suiteName: "ask-effort-redraw-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "deep", name: "Deep", reference: "cloud:deep", scenarios: ["ask"], reasoning: true,
                  reasoningEfforts: ["low", "medium", "high", "xhigh", "max"])
        ], providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        fixture.model.selectModel("cloud:deep", launcher: false)
        fixture.model.reasoningEffort = .high
        final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
        let card = EffortCardModelView(model: fixture.model)
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
        _ = try SettingsBehaviorTestSupport.button(L("ask.reasoning.reset"), in: hosting)
        fixture.model.reasoningEffort = .providerDefault
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

        _ = try AskWorkspaceTestAccessibility.center(identifier: "ask.test.model", in: window)
        let anchor = try #require(window.contentView)
        presenter.show(EffortCardModelView(model: fixture.model), owner: UUID(), anchor: anchor, onClose: {})
        try await Task.sleep(for: .milliseconds(150))
        #expect(presenter.isShowing, "the reasoning presentation opened its glass menu")
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

        _ = try SettingsBehaviorTestSupport.button(L("ask.reasoning.reset"), in: content)
        fixture.model.reasoningEffort = .providerDefault
        #expect(fixture.model.reasoningEffort == .providerDefault, "the reset model action applied")
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

@MainActor
private struct EffortCardModelView: View {
    @ObservedObject var model: AskConversationModel

    var body: some View {
        AskModelEffortCard(library: model.modelLibrary,
            reference: Binding(get: { model.modelReference(launcher: false) },
                               set: { model.selectModel($0, launcher: false) }),
            effort: Binding(get: { model.reasoningEffort }, set: { model.reasoningEffort = $0 }), loggedIn: true)
    }
}
