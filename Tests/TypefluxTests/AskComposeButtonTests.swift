import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The title bar's compose button starts a new chat with the sidebar open and
/// collapsed. Clicks go through the serialized event-delivery suite.
extension AskComposerInteractionTests {
    @Test func emptyWorkspaceKeepsOnlyTheTitleBarComposeButton() async throws {
        for collapsed in [false, true] {
            let suite = "ask-compose-visibility-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(collapsed, forKey: "ask.sidebarCollapsed")
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            await fixture.api.seed(.init(id: "compose", title: "Compose", revision: 1, updatedAt: Date(), messages: []))
            await fixture.model.refreshHistory()
            let window = ComposeClickWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                                            styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))

            func clickHeader(_ positionX: CGFloat) throws {
                let point = NSPoint(x: positionX, y: window.frame.height - AskMetrics.titleBarRowHeight / 2)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber,
                                                              context: nil, eventNumber: 0,
                                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    NSApp.sendEvent(event)
                }
            }

            #expect(fixture.model.selectedId == nil)
            fixture.model.draft.text = "Unsent question"
            // The empty page used to put a compose button here, which cleared the draft.
            let emptyComposeX = window.frame.width - 14 - 3 - 15
            try clickHeader(emptyComposeX)
            #expect(fixture.model.draft.text == "Unsent question", "collapsed: \(collapsed)")
            await fixture.model.select("compose")
            try await Task.sleep(for: .milliseconds(400))
            // An existing chat keeps its compose button between usage and delete.
            try clickHeader(emptyComposeX - 30 - 2)
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil)
            try await Task.sleep(for: .milliseconds(400))
            fixture.model.draft.text = "Another unsent question"
            try clickHeader(emptyComposeX)
            #expect(fixture.model.draft.text == "Another unsent question", "collapsed: \(collapsed)")
        }
    }

    @Test func composeButtonStartsANewChatInBothSidebarStates() async throws {
        for collapsed in [false, true] {
            let suite = "ask-compose-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(collapsed, forKey: "ask.sidebarCollapsed")
            let fixture = try AskTestFixture()
            let now = Date()
            await fixture.api.seed(.init(id: "compose", title: "Compose", revision: 1, updatedAt: now, messages: [
                .init(id: "q", role: "user", text: "Hello", createdAt: now),
                .init(id: "a", role: "assistant", text: "Hi", createdAt: now)
            ]))
            await fixture.model.refreshHistory()
            await fixture.model.select("compose")
            let window = ComposeClickWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                                            styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(fixture.model.selectedId == "compose")
            let width = AskMetrics.titleBarButtonWidth
            // Expanded: [compose][toggle] right-aligned in the sidebar's title row.
            // Collapsed: [toggle][search][compose] in the pill after the traffic lights.
            let x = collapsed
                ? AskMetrics.trafficLightInset + 3 + width * 2.5
                : AskMetrics.sidebarWidth - 6 - AskMetrics.sidebarPanelInset - width - 2 - width / 2
            let point = NSPoint(x: x, y: window.frame.height - AskMetrics.titleBarRowHeight / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
            }
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil, "collapsed: \(collapsed)")
            fixture.model.resetSession()
        }
    }
}

@MainActor
private final class ComposeClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
