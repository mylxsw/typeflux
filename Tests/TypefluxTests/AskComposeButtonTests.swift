import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The title bar's compose button starts a new chat with the sidebar open and
/// collapsed. Clicks go through the serialized event-delivery suite.
extension AskComposerInteractionTests {
    @Test func emptyWorkspaceKeepsOnlyTheTitleBarComposeButton() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
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

            func clickHeader(_ point: NSPoint) throws {
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
            let formerDuplicate = NSPoint(x: emptyComposeX, y: window.frame.height - AskMetrics.titleBarRowHeight / 2)
            try clickHeader(formerDuplicate)
            #expect(fixture.model.draft.text == "Unsent question", "collapsed: \(collapsed)")
            await fixture.model.select("compose")
            try await Task.sleep(for: .milliseconds(400))
            // Existing and empty chats share the single title-bar compose action.
            try clickHeader(AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window))
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil)
            try await Task.sleep(for: .milliseconds(400))
            fixture.model.draft.text = "Another unsent question"
            try clickHeader(formerDuplicate)
            #expect(fixture.model.draft.text == "Another unsent question", "collapsed: \(collapsed)")
        }
    }

    @Test func composeButtonStartsANewChatInBothSidebarStates() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
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
            let point = try AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window)
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

/// SwiftUI creates its AX nodes on demand. Read their actual screen frames,
/// then keep event-delivery tests using native mouse events rather than AXPress.
@MainActor
struct AskWorkspaceTestAccessibility {
    init() {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    }

    func restore() {
        NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    }

    static func center(identifier: String, in window: NSWindow) throws -> NSPoint {
        var seen = Set<ObjectIdentifier>()
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func find(_ object: NSObject) -> NSRect? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if value(object, "accessibilityIdentifier") as? String == identifier,
               let frame = value(object, "accessibilityFrame") as? NSValue,
               frame.rectValue.width > 0, frame.rectValue.height > 0 {
                return frame.rectValue
            }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        let frame = try #require(find(window) ?? window.contentView.flatMap(find),
                                 "Missing native control: \(identifier)")
        let local = window.convertFromScreen(frame)
        return NSPoint(x: local.midX, y: local.midY)
    }
}

@MainActor
private final class ComposeClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
