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
                                            styleMask: [.titled, .closable, .fullSizeContentView],
                                            backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
            window.contentView = hosting
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.toolbar = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))

            func clickHeader(_ point: NSPoint) throws {
                try AskWorkspaceTestMouse.click(at: point, in: window)
            }

            #expect(fixture.model.selectedId == nil)
            fixture.model.draft.text = "Unsent question"
            #expect(fixture.model.draft.text == "Unsent question", "collapsed: \(collapsed)")
            await fixture.model.select("compose")
            try await Task.sleep(for: .milliseconds(400))
            // Existing and empty chats share the single title-bar compose action.
            try clickHeader(AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window))
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil)
            try await Task.sleep(for: .milliseconds(400))
            fixture.model.draft.text = "Another unsent question"
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
            defer { fixture.model.resetSession() }
            let now = Date()
            await fixture.api.seed(.init(id: "compose", title: "Compose", revision: 1, updatedAt: now, messages: [
                .init(id: "q", role: "user", text: "Hello", createdAt: now),
                .init(id: "a", role: "assistant", text: "Hi", createdAt: now)
            ]))
            await fixture.model.refreshHistory()
            await fixture.model.select("compose")
            let window = ComposeClickWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                                            styleMask: [.titled, .closable, .fullSizeContentView],
                                            backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.toolbar = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(fixture.model.selectedId == "compose")
            let point = try AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window)
            try AskWorkspaceTestMouse.click(at: point, in: window)
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil, "collapsed: \(collapsed)")
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
            SettingsBehaviorTestSupport.Element(object: object, window: window).value(key)
        }
        func find(_ object: NSObject) -> NSRect? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if value(object, "accessibilityIdentifier") as? String == identifier,
               let frame = value(object, "accessibilityFrame") as? NSValue,
               frame.rectValue.width > 0, frame.rectValue.height > 0 {
                return frame.rectValue
            }
            let children = value(object, "accessibilityChildren") as? [NSObject] ?? []
            let subviews = (object as? NSView)?.subviews ?? []
            for child in children + subviews {
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
