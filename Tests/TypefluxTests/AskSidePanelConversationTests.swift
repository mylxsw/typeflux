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

extension AskSidePanelConversationTests {
    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func aRoundRecordsTheFilesItChangedWithItsAnswer() async throws {
        let (fixture, store, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        let model = fixture.model
        let owner = try #require(model.credentials(for: "files-chat")).account
        let root = try await store.ensure(owner: owner, conversationId: "files-chat")
        try write("old", "work/keep.py", in: root)
        try write("draft", "outputs/report.md", in: root)
        await model.loadFileChanges("files-chat")
        #expect(model.fileChanges.isEmpty)

        model.beginFileTracking("files-chat", account: owner)
        let baseline = try #require(model.fileBaselines["files-chat"])
        _ = await baseline.snapshot.value
        model.beginFileTracking("files-chat", account: owner)
        #expect(model.fileBaselines["files-chat"]?.snapshot == baseline.snapshot, "A round keeps its first baseline")
        try write("<p>chart</p>", "outputs/chart.html", in: root)
        try write("final version", "outputs/report.md", in: root)
        try write("print(1)", "work/clean.py", in: root)

        model.finishFileTracking("files-chat")
        #expect(model.fileBaselines["files-chat"] == nil)
        try await SettingsBehaviorTestSupport.wait { model.fileChanges["m2"] != nil }
        let expected: [AskWorkspaceFileChange] = [.init(path: "outputs/chart.html", kind: .added),
                                         .init(path: "outputs/report.md", kind: .modified),
                                         .init(path: "work/clean.py", kind: .added)]
        #expect(model.fileChanges["m2"] == expected)
        #expect(model.lastFileSnapshots[owner + "\0files-chat"]?.entries["outputs/chart.html"] != nil,
                "The next round reuses this round's digests")

        // Reloading the history reads the same list back from files.json.
        await model.loadFileChanges(nil)
        #expect(model.fileChanges.isEmpty)
        await model.loadFileChanges("files-chat")
        #expect(model.fileChanges == ["m2": expected])
        // The Files tab now groups the new files under the answer.
        let listing = try #require(try await model.sidePanelFiles("files-chat"))
        #expect(listing.files.first { $0.relativePath == "outputs/chart.html" }?.messageId == "m2")

        // A round that changed nothing records nothing.
        model.beginFileTracking("files-chat", account: owner)
        _ = await model.fileBaselines["files-chat"]?.snapshot.value
        model.finishFileTracking("files-chat")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.fileChanges == ["m2": expected])
        model.finishFileTracking("missing")
    }

    @Test func aPausedRunKeepsItsBaselineUntilTheRoundEnds() async throws {
        let (fixture, _, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        var run = AskRun(id: "run", deviceId: "device", status: "paused_credits", steps: 1, updatedAt: Date(),
                         tools: [], pending: [])
        run.stopReason = "credits_exhausted"
        await fixture.api.seed(.init(id: "paused", title: "Paused", revision: 1, updatedAt: Date(), messages: [
            .init(id: "u", role: "user", text: "Go", createdAt: Date(), runId: "run")
        ], run: run))
        await fixture.model.select("paused")
        let owner = try #require(fixture.model.credentials(for: "paused")).account
        fixture.model.beginFileTracking("paused", account: owner)
        fixture.model.finishFileTracking("paused")
        #expect(fixture.model.fileBaselines["paused"] != nil, "The round continues after the pause")
    }

    @Test func workspacePathsResolveForFileTabsAndExternalApps() async throws {
        let (fixture, store, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        let model = fixture.model
        let owner = try #require(model.credentials(for: "files-chat")).account
        let root = try await store.ensure(owner: owner, conversationId: "files-chat")
        try write("print(1)", "work/analyze.py", in: root)
        let target = try await model.sidePanelTarget("work/analyze.py", conversationId: "files-chat")
        #expect(target.relativePath == "work/analyze.py")
        await #expect(throws: AskSidePanelFileAccess.AccessError.self) {
            try await model.sidePanelTarget("work/missing.py", conversationId: "files-chat")
        }
        await #expect(throws: AskSidePanelFileAccess.AccessError.self) {
            try await model.sidePanelTarget("../escape", conversationId: "files-chat")
        }
        #expect(model.sidePanelFileURL("work/analyze.py", conversationId: "files-chat")?.path
            == root.appendingPathComponent("work/analyze.py").path)
        #expect(model.sidePanelFileURL("work/../x", conversationId: "files-chat") == nil)
        #expect(model.sidePanelFileURL("work/analyze.py", conversationId: nil) == nil)

        model.locateMessage("m1")
        #expect(model.referenceLocation == "m1")
        #expect(model.highlightedMessageId == "m1")
        try await SettingsBehaviorTestSupport.wait { model.highlightedMessageId == nil }
    }
}

extension AskSidePanelConversationTests {
    @Test func anAnswerListsItsFilesAndOpensTheFilesTab() async throws {
        let (fixture, store, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base); fixture.model.resetSession() }
        let owner = try #require(fixture.model.credentials(for: "files-chat")).account
        let root = try await store.ensure(owner: owner, conversationId: "files-chat")
        try write("<p>chart</p>", "outputs/chart.html", in: root)
        try await store.recordChanges([.init(path: "outputs/chart.html", kind: .added)], messageId: "m2",
                                      owner: owner, conversationId: "files-chat")
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

        // The recorded change is read back and listed at the end of the answer.
        try await SettingsBehaviorTestSupport.wait {
            hosting.layoutSubtreeIfNeeded()
            return find("ask.fileChanges", in: window) != nil && shows("chart.html", in: window)
        }
        #expect(find("ask.sidePanel", in: window) == nil)
        let showAll = try #require(find("ask.fileChanges.showAll", in: window))
        _ = showAll.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await SettingsBehaviorTestSupport.wait {
            hosting.layoutSubtreeIfNeeded()
            return find("ask.sidePanel.filesTab", in: window) != nil
        }
    }
}
