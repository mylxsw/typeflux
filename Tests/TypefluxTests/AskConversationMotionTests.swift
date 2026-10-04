import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The window's panels move instead of popping: after a toggle the transcript
/// column passes through intermediate positions before it settles. These send
/// clicks, so they live in the serialized event-delivery suite.
extension AskComposerInteractionTests {
    @Test func sidebarSlidesWhenToggled() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        // Isolated preferences: suites run in parallel and others read the real key.
        let suite = "ask-motion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await motionFixture()
        let (window, hosting) = try await hostMotionView(AskConversationView(model: fixture.model).defaultAppStorage(defaults))
        defer { window.close() }
        let editor = try #require(motionEditors(hosting).first)
        let start = editor.convert(editor.bounds, to: nil).minX
        let samples = try await clickAndSample(AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.sidebar", in: window),
                                               in: window) { editor.convert(editor.bounds, to: nil).minX }
        let end = try #require(samples.last)
        #expect(end < start - 50, "The transcript column takes the sidebar's space")
        #expect(samples.contains { $0 < start - 1 && $0 > end + 1 }, "Expected intermediate frames, got \(samples)")
        #expect(defaults.bool(forKey: "ask.sidebarCollapsed"))
        fixture.model.resetSession()
    }

    @Test func usagePanelSlidesWhenToggled() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let suite = "ask-motion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await motionFixture()
        let (window, hosting) = try await hostMotionView(AskConversationView(model: fixture.model).defaultAppStorage(defaults))
        defer { window.close() }
        let editor = try #require(motionEditors(hosting).first)
        let start = editor.convert(editor.bounds, to: nil).maxX
        let samples = try await clickAndSample(AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.usage", in: window),
                                               in: window) { editor.convert(editor.bounds, to: nil).maxX }
        let end = try #require(samples.last)
        #expect(end < start - 50, "The usage panel takes room from the transcript column")
        #expect(samples.contains { $0 < start - 1 && $0 > end + 1 }, "Expected intermediate frames, got \(samples)")
        fixture.model.resetSession()
    }

    private func motionFixture() async throws -> AskTestFixture {
        let fixture = try AskTestFixture()
        let now = Date()
        await fixture.api.seed(.init(id: "motion", title: "Motion", revision: 1, updatedAt: now, messages: [
            .init(id: "q", role: "user", text: "Hello", createdAt: now),
            .init(id: "a", role: "assistant", text: "Hi there", createdAt: now)
        ]))
        await fixture.model.refreshHistory()
        await fixture.model.select("motion")
        return fixture
    }

    /// Clicks until the layout starts to move (a loaded test host can drop a
    /// click that lands before the header is laid out), then samples each frame.
    private func clickAndSample(_ point: NSPoint, in window: NSWindow,
                                _ value: () -> CGFloat) async throws -> [CGFloat] {
        let start = value()
        var values: [CGFloat] = []
        for _ in 0 ..< 3 where values.allSatisfy({ abs($0 - start) < 0.5 }) {
            try clickPoint(point, in: window)
            values = []
            for _ in 0 ..< 20 {
                try await Task.sleep(for: .milliseconds(16))
                values.append(value())
                if abs(values.last! - start) >= 0.5 { break }
            }
        }
        for _ in 0 ..< 60 {
            try await Task.sleep(for: .milliseconds(16))
            values.append(value())
        }
        return values
    }

    private func motionEditors(_ view: NSView) -> [AskComposerTextView.Editor] {
        (view as? AskComposerTextView.Editor).map { [$0] } ?? view.subviews.flatMap(motionEditors)
    }

    private func clickPoint(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }

    private func hostMotionView<V: View>(_ view: V) async throws -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = MotionWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: .borderless,
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }
}

@MainActor
private final class MotionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@Suite("Ask motion")
struct AskMotionTests {
    @Test func motionFollowsReduceMotion() {
        // Reduce Motion keeps the change but drops the travel and the spring.
        #expect(AskMotion.panelAnimation(reduceMotion: false) != AskMotion.panelAnimation(reduceMotion: true))
        #expect(AskMotion.revealAnimation(reduceMotion: true) != AskMotion.revealAnimation(reduceMotion: false))
        #expect(AskMotion.progressDelay > .zero)
    }
}
