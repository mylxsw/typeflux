import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowNoticeTests {
    @Test(arguments: InterfaceStyle.allCases)
    func `notice uses voice input presentation for three seconds`(style: InterfaceStyle) async throws {
        let suite = "AskWorkflowNoticeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let overlay = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { overlay.dismissImmediately() }
        let notice = AskWorkflowNoticePanel(overlay: overlay)
        #expect(notice.duration == 3)
        #expect(!notice.isVisible)
        let keyWindow = NSApplication.shared.keyWindow
        notice.show(L("workflow.result.copied"))
        let window = try #require(notice.presentedWindow)
        #expect(window === overlay.presentedWindow)
        #expect(!overlay.isShowingPassiveNotice)
        #expect(window.isVisible && !window.ignoresMouseEvents && !window.canBecomeKey)
        #expect(NSApplication.shared.keyWindow === keyWindow)
        #expect(window.frame.width == NoticeToastLayout.width)
        try await Task.sleep(for: .milliseconds(100))
        try capture(window, name: "workflow-copied-\(style.rawValue)")
        NotificationCenter.default.post(name: .voiceCapsuleDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(notice.isVisible, "feedback remains visible beyond the old two-second timeout")
        NotificationCenter.default.post(name: .voiceCapsuleDidChange, object: nil)
        try await waitUntilHidden(notice)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `close button dismisses feedback without taking keyboard focus`(style: InterfaceStyle) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let suite = "AskWorkflowNoticeCloseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(style.rawValue, forKey: "ui.overlayStyle")
        let overlay = OverlayController(appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults))
        defer { overlay.dismissImmediately() }
        let notice = AskWorkflowNoticePanel(overlay: overlay)
        notice.duration = 30
        let keyWindow = NSApplication.shared.keyWindow
        notice.show("Copied")
        let window = try #require(notice.presentedWindow)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func findCloseButton(_ node: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               node.value(forKey: "accessibilityIdentifier") as? String == "overlay.dismiss" { return node }
            guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in node.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] {
                if let button = findCloseButton(child) { return button }
            }
            return nil
        }
        let button = try #require(findCloseButton(window) ?? window.contentView.flatMap(findCloseButton))
        let frame = try #require(button.value(forKey: "accessibilityFrame") as? NSRect)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await waitUntilHidden(notice)
        #expect(NSApplication.shared.keyWindow === keyWindow)
    }

    @Test func `a new notice restarts its dismissal`() async throws {
        let overlay = OverlayController(appState: AppStateStore())
        defer { overlay.dismissImmediately() }
        let notice = AskWorkflowNoticePanel(overlay: overlay)
        notice.duration = 0.6
        notice.show("First")
        let window = try #require(notice.presentedWindow)
        try await Task.sleep(for: .milliseconds(350))
        notice.show("Second")
        try await Task.sleep(for: .milliseconds(350))
        #expect(notice.isVisible && notice.presentedWindow === window)
        try await waitUntilHidden(notice)
    }

    @Test(arguments: ["none", "text"])
    func `a copy only workflow shows feedback after the launcher closes`(display: String) async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.write("copy", manifest: AskWorkflowFixture.inline(
                "copy", keyword: "clipcopy", script: "print -r -- result",
                extra: ["output": ["display": display, "close": display == "text",
                                   "onSuccess": [["action": "copy", "value": "{output}"]]]]
            ))
            workflows.store.reload()
            workflows.store.trust("copy")
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "") { model in
                model.workflows = workflows.store
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            await model.refreshLauncherWorkflows()
            let keyword = try #require(model.plugins.availableKeywords.first { $0.keyword == "clipcopy" })
            model.enterLauncherKeyword(keyword, run: false)
            try await launcher.fixture.wait { launcher.dismissed == 1 }
            #expect(pasteboard.string(forType: .string) == "result")
            let notice = AskWorkflowNoticePanel.shared
            #expect(notice.isVisible, "the model's default presenter survives launcher dismissal")
            #expect(notice.presentedWindow?.ignoresMouseEvents == false)
            try await waitUntilHidden(notice, attempts: 400)
        }
    }

    @Test func `an explicit HUD after copy overrides the default confirmation`() async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            var events: [String] = []
            fixture.model.passiveNotice = { events.append($0) }
            let host = AskWorkflowLauncherActionHost(model: fixture.model) { events.append("dismiss") }
            host.copy("result")
            host.hud("Custom confirmation")
            #expect(events.isEmpty)
            host.close()
            host.close()
            #expect(events == ["dismiss", "Custom confirmation"])
            #expect(pasteboard.string(forType: .string) == "result")
            host.copy("after close")
            #expect(events.last == L("workflow.result.copied"))
        }
    }

    @Test func `workflow feedback does not replace an active recording`() {
        let recording = OverlayController(appState: AppStateStore())
        defer { recording.dismissImmediately() }
        recording.show()
        let feedback = OverlayController(appState: AppStateStore())
        defer { feedback.dismissImmediately() }
        let notice = AskWorkflowNoticePanel(overlay: feedback)
        notice.show("Copied")
        #expect(recording.recordingPresentationForTesting == .recordingHold)
        #expect(recording.presentedWindow?.isVisible == true)
        #expect(!feedback.isShowingPassiveNotice && notice.isVisible)
    }

    private func waitUntilHidden(_ notice: AskWorkflowNoticePanel, attempts: Int = 150) async throws {
        for _ in 0 ..< attempts where notice.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!notice.isVisible)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SCREENSHOT_DIR"] else { return }
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
