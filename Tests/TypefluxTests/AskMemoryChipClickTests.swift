import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Real mouse events on the composer's memory chip, in the chat window and the
/// launcher: a click must switch the memory off and a second click back on.
/// Part of the serialized event-delivery suite: its hold-to-talk tests watch
/// every mouse-up in the app, so clicks must never overlap with them.
extension AskComposerInteractionTests {
    @Test func memoryChipTogglesInTheChatWindow() async throws {
        let fixture = try AskTestFixture()
        fixture.model.newConversation()
        fixture.model.draft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        let (window, hosting) = try await hostChipView(AskConversationView(model: fixture.model), size: NSSize(width: 1000, height: 640))
        defer { window.close() }
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == true)
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == nil)
        fixture.model.resetSession()
    }

    @Test func pinnedMemoryTogglesOnClick() async throws {
        let fixture = try AskTestFixture()
        var value = AskConversation(id: "pinned", title: "Pinned", revision: 1, updatedAt: Date(), messages: [
            .init(id: "q", role: "user", text: "Hi", createdAt: Date())
        ])
        value.memory = AskMemory(global: "Prefers short answers.", app: nil)
        await fixture.api.seed(value)
        await fixture.model.select("pinned")
        let (window, hosting) = try await hostChipView(AskConversationView(model: fixture.model), size: NSSize(width: 1000, height: 640))
        defer { window.close() }
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == true)
        #expect(fixture.model.memorySwitchedOff(launcher: false))
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == false)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        fixture.model.resetSession()
    }

    @Test func readOnlyChipExplainsItselfOnClick() async throws {
        let item = AskContextChips.items(screenshot: .unavailable(reason: "This model does not support images"),
                                         source: nil, sourceBundleID: nil, selection: nil, memory: nil,
                                         memoryPinned: false)[0]
        let (window, hosting) = try await hostChipView(AskIconChip(item: item).padding(24),
                                                       size: NSSize(width: 120, height: 100))
        defer { window.close(); NSApp.windows.filter { $0 is AskHoverCardPresenter.Panel }.forEach { $0.orderOut(nil) } }
        func cardShown() -> Bool { NSApp.windows.contains { $0 is AskHoverCardPresenter.Panel && $0.isVisible } }
        #expect(!cardShown())
        // An unavailable screenshot has no action, so a click explains its state.
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(cardShown())
        // Opened without the pointer on the chip, it closes by itself.
        try await Task.sleep(nanoseconds: AskContextChips.explainDuration + 300_000_000)
        #expect(!cardShown())
    }

    @Test func memoryChipTogglesInTheLauncher() async throws {
        let fixture = try AskTestFixture()
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft.source = nil
        fixture.model.launcherDraft.selection = nil
        let (window, hosting) = try await hostChipView(AskLauncherView(model: fixture.model, onDismiss: {}),
                                               size: NSSize(width: AskMetrics.launcherWidth, height: 120))
        defer { window.close() }
        try clickChip(memoryChipAnchors(hosting).last, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.launcherDraft.memoryOff == true)
        fixture.model.resetSession()
    }

    private func memoryChipAnchors(_ root: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)).contains("Passthrough") ? [view] : []) + view.subviews.flatMap(walk)
        }
        return walk(root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func clickChip(_ anchor: NSView?, in window: NSWindow) throws {
        let anchor = try #require(anchor)
        let frame = anchor.convert(anchor.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }

    private func hostChipView<V: View>(_ view: V, size: NSSize) async throws -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = ChipClickWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }
}

@MainActor
private final class ChipClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
