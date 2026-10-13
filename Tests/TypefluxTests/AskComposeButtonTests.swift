import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The title bar's compose button starts a new chat with the sidebar open and
/// collapsed. Assert the control metadata and drive its bound model action.
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

            #expect(fixture.model.selectedId == nil)
            fixture.model.draft.text = "Unsent question"
            #expect(fixture.model.draft.text == "Unsent question", "collapsed: \(collapsed)")
            await fixture.model.select("compose")
            try await Task.sleep(for: .milliseconds(400))
            // Existing and empty chats share the single title-bar compose action.
            try AskWorkspaceTestAccessibility.assertButton("ask.workspace.new", label: L("ask.new"), in: window)
            fixture.model.newConversation()
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
            try AskWorkspaceTestAccessibility.assertButton("ask.workspace.new", label: L("ask.new"), in: window)
            fixture.model.newConversation()
            try await fixture.wait { fixture.model.selectedId == nil }
            #expect(fixture.model.selectedId == nil, "collapsed: \(collapsed)")
        }
    }
}

/// Resolve controls from the owned window, including its separately hosted toolbar and informal AX nodes.
@MainActor
struct AskWorkspaceTestAccessibility {
    init() {
        TypefluxTestApplicationEnvironment.prepare()
    }

    func restore() {
        NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    }

    static func elements(in window: NSWindow) -> [SettingsBehaviorTestSupport.Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [SettingsBehaviorTestSupport.Element] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = SettingsBehaviorTestSupport.Element(object: object, window: window)
            let children = (element.value("accessibilityChildren") as? [NSObject] ?? [])
                + (element.value("accessibilityRows") as? [NSObject] ?? [])
                + ((object as? NSView)?.subviews ?? [])
            return [element] + children.flatMap(walk)
        }
        let roots: [NSObject] = [window] + [window.contentView?.superview ?? window.contentView].compactMap { $0 }
            + (window.toolbar?.items.compactMap(\.view) ?? [])
        return roots.flatMap(walk)
    }

    static func frame(identifier: String, in window: NSWindow) -> NSRect? {
        for element in elements(in: window) where element.value("accessibilityIdentifier") as? String == identifier {
            if usable(element.frame) { return element.frame }
            if let view = element.object as? NSView, view.window === window {
                let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                if usable(frame) { return frame }
            }
        }
        // SwiftUI may expose an identifier on the toolbar item rather than its transient AX button proxy.
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains(identifier) }),
           let view = item.view, view.window === window {
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            if usable(frame) { return frame }
        }
        return nil
    }

    static func center(identifier: String, in window: NSWindow) throws -> NSPoint {
        let frame = try #require(frame(identifier: identifier, in: window), "Missing native control: \(identifier)")
        let local = window.convertFromScreen(frame)
        return NSPoint(x: local.midX, y: local.midY)
    }

    static func assertButton(_ identifier: String, label: String, in window: NSWindow) throws {
        let identified = elements(in: window).filter {
            $0.value("accessibilityIdentifier") as? String == identifier
        }
        _ = try #require(!identified.isEmpty, "Missing control identifier: \(identifier)")
        // SwiftUI may put the identifier on a container and the button label on its accessible child.
        let candidates = identified.flatMap { [$0] + SettingsBehaviorTestSupport.elements(in: $0.object) }
        _ = try #require(candidates.contains {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == label
        }, "Missing accessible button in \(identifier): \(label)")
    }

    private static func usable(_ frame: NSRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.width.isFinite && frame.height.isFinite
            && frame.minX.isFinite && frame.minY.isFinite
    }
}

@MainActor
private final class ComposeClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
