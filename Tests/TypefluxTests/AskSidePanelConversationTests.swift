import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The side panel inside the Chat window: what it reads from the conversation, and its shortcuts.
@Suite("Ask side panel in the conversation", .serialized, .exclusiveUIState)
@MainActor
struct AskSidePanelConversationTests {
    private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func shows(_ text: String, in window: NSWindow) -> Bool {
        SettingsBehaviorTestSupport.elements(in: window).contains { $0.label.contains(text) || $0.text.contains(text) }
    }

    private func fixture() async throws -> (AskTestFixture, AskConversationWorkspaceStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let fixture = try AskTestFixture(workspaces: store)
        await fixture.api.seed(.init(id: "files-chat", title: "Sales analysis", revision: 1, updatedAt: Date(), messages: [
            .init(id: "m1", role: "user", text: "  Analyse the sales sheet  \nand chart it", createdAt: Date()),
            .init(id: "m2", role: "assistant", text: "\n", createdAt: Date())
        ]))
        await fixture.model.select("files-chat")
        return (fixture, store, base)
    }

    @Test func readsTheSelectedConversationsFilesAndMessages() async throws {
        let (fixture, store, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        let model = fixture.model
        #expect(model.sidePanelMessageOrder == ["m1", "m2"])
        #expect(model.sidePanelMessageTitle("m1") == "Analyse the sales sheet")
        #expect(model.sidePanelMessageTitle("m2") == nil, "A blank message has no title")
        #expect(model.sidePanelMessageTitle("missing") == nil)
        #expect(model.sidePanelRoots(nil).isEmpty)

        let owner = try #require(model.credentials(for: "files-chat")).account
        _ = try await store.saveOutput(Data("<p>chart</p>".utf8), name: "chart.html", owner: owner,
                                       conversationId: "files-chat")
        let source = base.appendingPathComponent("extra.csv")
        try Data("a,b".utf8).write(to: source)
        try await model.addSidePanelFiles([source], conversationId: "files-chat")

        let listing = try #require(try await model.sidePanelFiles("files-chat"))
        #expect(Set(listing.files.map(\.name)) == ["chart.html", "extra.csv"])
        let roots = model.sidePanelRoots("files-chat")
        #expect(roots.first == listing.root.path)
        let chart = try #require(listing.files.first { $0.name == "chart.html" })
        let target = try AskSidePanelFileAccess.resolve(chart.relativePath, workspaceRoot: listing.root)
        #expect(try AskSidePanelFileAccess.read(target, roots: roots, limit: 100) == Data("<p>chart</p>".utf8))
    }

    @Test func withoutAWorkspaceStoreThereAreNoFiles() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "plain", title: "Plain", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.select("plain")
        #expect(try await fixture.model.sidePanelFiles("plain") == nil)
        #expect(fixture.model.sidePanelRoots("plain").isEmpty)
        try await fixture.model.addSidePanelFiles([URL(fileURLWithPath: "/missing")], conversationId: "plain")
    }

    @Test func commandShiftFOpensTheFilesTab() async throws {
        let (fixture, store, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        let owner = try #require(fixture.model.credentials(for: "files-chat")).account
        _ = try await store.saveOutput(Data("# Report".utf8), name: "report.md", owner: owner, conversationId: "files-chat")
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let suite = "AskSidePanelConversationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = NSSize(width: 1300, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model)
            .defaultAppStorage(defaults)
            .environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        #expect(find("ask.workspace.sidePanel", in: window) != nil)
        #expect(find("ask.sidePanel", in: window) == nil)

        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "f", charactersIgnoringModifiers: "f",
                                                isARepeat: false, keyCode: 3))
        #expect(window.performKeyEquivalent(with: key))
        try await SettingsBehaviorTestSupport.wait {
            hosting.layoutSubtreeIfNeeded()
            return find("ask.sidePanel.filesTab", in: window) != nil
                && shows("report.md", in: window)
        }
        // The panel's close button hides it again.
        let close = try #require(find("ask.workspace.drawer.close", in: window))
        _ = close.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await SettingsBehaviorTestSupport.wait {
            hosting.layoutSubtreeIfNeeded()
            return find("ask.sidePanel", in: window) == nil
        }
    }
}
