import AppKit
import Testing
@testable import Typeflux

@Suite("Launcher window mode", .exclusiveUIState)
@MainActor
struct AskLauncherWindowModeTests {
    @Test func `defaults to complete and persists both modes`() throws {
        let suite = "launcher-window-mode-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askLauncherWindowMode == .complete)
        for mode in AskLauncherWindowMode.allCases {
            settings.askLauncherWindowMode = mode
            #expect(SettingsStore(defaults: defaults).askLauncherWindowMode == mode)
        }
        defaults.set("unknown", forKey: "ask.launcher.windowMode")
        #expect(settings.askLauncherWindowMode == .complete)
    }

    @Test func `settings selection writes through and reloads`() throws {
        let suite = "launcher-window-mode-view-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                    initialSection: .settings,
                                    modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false))
        model.setLauncherWindowMode(.simple)
        #expect(model.launcherWindowMode == .simple)
        #expect(settings.askLauncherWindowMode == .simple)
        model.setLauncherWindowMode(.complete)
        #expect(model.launcherWindowMode == .complete)
        #expect(settings.askLauncherWindowMode == .complete)
    }

    @Test func `simple only collapses an idle draft and ignores captured context`() {
        var draft = AskDraft(includeScreenshot: true, screenshot: "image", selection: "Selected text", source: "Safari")
        #expect(AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        #expect(!AskLauncherWindowMode.complete.isCollapsed(draft: draft))
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft, engaged: true))
        draft.text = "query"
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        draft.text = ""
        draft.references = [.init(messageId: "m", text: "Quote")]
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        draft.references = []
        draft.attachments = [.init(kind: .file, name: "notes.txt", text: "Notes")]
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        draft.attachments = []
        draft.skills = ["skill"]
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        draft.skills = []
        draft.mcpServers = ["server"]
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        draft.mcpServers = []
        #expect(AskLauncherWindowMode.simple.isCollapsed(draft: draft))
    }

    @Test func `both modes share the same opening top and remembered position`() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for anchor in [nil, AskLauncherPlacement.Anchor(left: 40, fromTop: 80)] {
            let complete = AskLauncherPlacement.preferredFrame(on: screen, anchor: anchor)
            let simple = AskLauncherPlacement.preferredFrame(on: screen, anchor: anchor,
                                                             height: AskLauncherWindowMode.simpleHeight)
            #expect(complete.maxY == simple.maxY)
            #expect(complete.minX == simple.minX)
            #expect(simple.height == AskLauncherWindowMode.simpleHeight)
            #expect(complete.height == AskLauncherPlacement.restingHeight)
        }
    }
}

extension AskLauncherToggleTests {
    @Test func `simple window expands for typing and collapses without losing focus`() async throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture(authenticated: false)
        let suite = "launcher-simple-panel-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        settings.askLauncherWindowMode = .simple
        let controller = AskConversationWindowController(settings: settings, model: fixture.model)
        defer {
            controller.dismissLauncher()
            fixture.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
        controller.prewarmLauncher()
        controller.showLauncher()
        let panel = try #require(controller.launcherWindow)
        try await fixture.wait { fixture.capture.calls > 0 && !fixture.model.capturing }
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)
        let top = panel.frame.maxY
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.wait { panel.frame.height > AskLauncherWindowMode.simpleHeight }
        #expect(panel.frame.maxY == top)
        #expect(panel.firstResponder === editor)
        #expect(fixture.model.launcherDraft.text == "abc")

        editor.selectAll(nil)
        editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.wait { panel.frame.height == AskLauncherWindowMode.simpleHeight }
        #expect(panel.frame.maxY == top)
        #expect(panel.firstResponder === editor)
        editor.insertText("   ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.wait { fixture.model.launcherDraft.text == "   " }
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)
        #expect(panel.firstResponder === editor)
        fixture.model.launcherDraft.attachments = [.init(kind: .file, name: "notes.txt", text: "Notes")]
        try await fixture.wait { panel.frame.height > AskLauncherWindowMode.simpleHeight }
        fixture.model.launcherDraft.attachments = []
        try await fixture.wait { panel.frame.height == AskLauncherWindowMode.simpleHeight }
        controller.recenterLauncher()
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)

        // Settings take effect on the next opening, including reuse of a prewarmed panel.
        settings.askLauncherWindowMode = .complete
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)
        controller.dismissLauncher()
        controller.showLauncher()
        #expect(panel.frame.height > AskLauncherWindowMode.simpleHeight)
        #expect(controller.launcherWindow === panel)
        settings.askLauncherWindowMode = .simple
        controller.dismissLauncher()
        controller.showLauncher()
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)
    }

    @Test func `simple mode starts blank even with an existing draft`() throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture(authenticated: false)
        let suite = "launcher-simple-draft-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        settings.askLauncherWindowMode = .simple
        fixture.model.launcherDraft.text = "Unfinished question"
        let controller = AskConversationWindowController(settings: settings, model: fixture.model)
        defer {
            controller.dismissLauncher()
            fixture.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
        controller.showLauncher()
        let panel = try #require(controller.launcherWindow)
        #expect(panel.frame.height == AskLauncherWindowMode.simpleHeight)
        #expect((panel.firstResponder as? NSTextView)?.string.isEmpty == true)
    }
}
