// swiftlint:disable file_length type_body_length
import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Native regression checks opt in because they create key windows and dispatch
/// real mouse events. Use TYPEFLUX_ASK_RESPONSIVE_TESTS=1; additionally set
/// TYPEFLUX_ASK_RESPONSIVE_SNAPSHOTS to save each production window's rendering.
/// All conversations, account information and tools are synthetic.
@Suite("Ask responsive workspace", .serialized)
@MainActor
struct AskResponsiveWorkspaceTests {
    private static let sizes: [NSSize] = [
        NSSize(width: 1180, height: 760), NSSize(width: 760, height: 560),
        NSSize(width: 440, height: 880), NSSize(width: 960, height: 320),
        NSSize(width: 440, height: 320), NSSize(width: 360, height: 280)
    ]

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESPONSIVE_TESTS"] != nil
            || ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESPONSIVE_SNAPSHOTS"] != nil
    }

    @Test func productionWindowKeepsControlsInsideEveryViewport() async throws {
        guard enabled else { return }
        let session = PreviewSession()
        defer { session.restore() }
        for scene in ["empty", "chat", "approval"] {
            let host = try await makeHost(scene: scene)
            defer { host.close() }
            for size in Self.sizes {
                try await resize(host.window, to: size)
                try assertControls(in: host.window, hasConversation: scene != "empty")
                if scene == "approval" {
                    let input = try #require(editor(in: host.window).enclosingScrollView)
                    for label in [L("ask.deny"), L("ask.allowOnce")] {
                        let action = try element(label: label, in: host.window)
                        assertVisible(action, in: host.window)
                        let frame = host.window.convertFromScreen(action.accessibilityFrame())
                        #expect(frame.minY >= input.convert(input.bounds, to: nil).maxY + 6,
                                "Both pending approval actions must remain above the composer when following the end.")
                    }
                }
                try await snapshot(host.window, name: "\(scene)-\(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    @Test func narrowDrawersAndInlineUsageKeepTheirCloseControlsReachable() async throws {
        guard enabled else { return }
        let session = PreviewSession()
        defer { session.restore() }
        let host = try await makeHost(scene: "chat")
        defer { host.close() }

        for size in [NSSize(width: 440, height: 880), NSSize(width: 440, height: 320)] {
            try await resize(host.window, to: size)
            try click(identifier: "ask.workspace.sidebar", in: host.window)
            try await settle(host.window)
            let close = try element(identifier: "ask.workspace.drawer.close", in: host.window)
            assertVisible(close, in: host.window)
            try await snapshot(host.window, name: "history-\(Int(size.width))x\(Int(size.height))")
            try click(close, in: host.window)
            try await settle(host.window)
            #expect(find(identifier: "ask.workspace.drawer.close", in: host.window) == nil)
            try assertControls(in: host.window, hasConversation: true)
        }

        try await resize(host.window, to: NSSize(width: 1180, height: 760))
        try click(identifier: "ask.workspace.usage", in: host.window)
        try await settle(host.window)
        let input = try editor(in: host.window)
        host.window.makeFirstResponder(input)
        try key("/", code: 44, in: host.window)
        try await settle(host.window)
        _ = try element(identifier: "ask.command.palette", in: host.window)
        try key("\u{1b}", code: 53, in: host.window)
        try await settle(host.window)
        #expect(find(identifier: "ask.command.palette", in: host.window) == nil)
        #expect(find(label: L("ask.usage.close"), in: host.window) != nil,
                "Escape belongs to the active editor palette before an inline usage panel.")
        #expect(host.fixture.model.draft.text == "/")
        host.fixture.model.draft.text = ""
        // Keep the same open panel while crossing its inline/overlay threshold.
        for size in Self.sizes {
            try await resize(host.window, to: size)
            let close = try element(label: L("ask.usage.close"), in: host.window)
            assertVisible(close, in: host.window)
            try await snapshot(host.window, name: "usage-\(Int(size.width))x\(Int(size.height))")
        }
        try click(try element(label: L("ask.usage.close"), in: host.window), in: host.window)
        try await settle(host.window)
        #expect(find(label: L("ask.usage.close"), in: host.window) == nil)
        try assertControls(in: host.window, hasConversation: true)

        // A history drawer opened over inline usage must remain the only
        // modal if a later resize would also turn usage into a drawer.
        try await resize(host.window, to: NSSize(width: 1000, height: 560))
        try click(identifier: "ask.workspace.usage", in: host.window)
        try await settle(host.window)
        try click(identifier: "ask.workspace.sidebar", in: host.window)
        try await settle(host.window)
        _ = try element(identifier: "ask.workspace.drawer.close", in: host.window)
        try await resize(host.window, to: NSSize(width: 700, height: 560))
        try click(identifier: "ask.workspace.drawer.close", in: host.window)
        try await settle(host.window)
        #expect(find(identifier: "ask.workspace.drawer.close", in: host.window) == nil)
        #expect(find(label: L("ask.usage.close"), in: host.window) == nil)
        try assertControls(in: host.window, hasConversation: true)
    }

    @Test func resizePreservesDraftSelectionAndTheLiveNativeEditor() async throws {
        guard enabled else { return }
        let session = PreviewSession()
        defer { session.restore() }
        let host = try await makeHost(scene: "chat")
        defer { host.close() }
        let text = (1...12).map { "Draft line \($0): keep this text while resizing." }.joined(separator: "\n")
        host.fixture.model.draft.text = text
        host.fixture.model.draft.screenshot = AskLivePreviewHarness.screenshotDataURL()
        host.fixture.model.draft.includeScreenshot = true
        let expectedDraft = host.fixture.model.draft
        let selectedID = host.fixture.model.selectedId
        try await settle(host.window)
        let editor = try editor(in: host.window)
        editor.setSelectedRange(NSRange(location: 12, length: 7))
        for size in Self.sizes + [Self.sizes[0]] {
            try await resize(host.window, to: size)
            let current = try self.editor(in: host.window)
            #expect(current === editor, "A resize must preserve the live NSTextView and its marked text.")
            #expect(current.string == text)
            #expect(current.selectedRange() == NSRange(location: 12, length: 7))
            #expect(host.fixture.model.draft == expectedDraft)
            #expect(host.fixture.model.selectedId == selectedID)
            try assertControls(in: host.window, hasConversation: true)
            let viewport = try #require(current.enclosingScrollView)
            #expect(viewport.contentSize.height <= (size.height < 500 ? 48 : 148) + 1)
            #expect(current.frame.height > viewport.contentSize.height)
            try await snapshot(host.window, name: "long-draft-\(Int(size.width))x\(Int(size.height))")
        }
    }

    @Test func compactSearchAndDrawersPreserveDraftAndSidebarPreference() async throws {
        guard enabled else { return }
        let session = PreviewSession()
        defer { session.restore() }
        let host = try await makeHost(scene: "chat")
        defer { host.close() }
        try await resize(host.window, to: Self.sizes[0])
        host.fixture.model.draft.text = "Keep this unfinished question"
        try await settle(host.window)
        let editor = try editor(in: host.window)
        let selection = NSRange(location: 5, length: 4)
        editor.setSelectedRange(selection)
        host.window.makeFirstResponder(editor)
        try click(identifier: "ask.workspace.sidebar", in: host.window)
        try await settle(host.window)
        #expect(UserDefaults.standard.bool(forKey: "ask.sidebarCollapsed"))

        try await resize(host.window, to: NSSize(width: 440, height: 320))
        try click(identifier: "ask.workspace.sidebar", in: host.window)
        try await settle(host.window)
        _ = try element(identifier: "ask.workspace.drawer.close", in: host.window)
        try key("\u{1b}", code: 53, in: host.window)
        try await settle(host.window)
        #expect(find(identifier: "ask.workspace.drawer.close", in: host.window) == nil)
        #expect(UserDefaults.standard.bool(forKey: "ask.sidebarCollapsed"))

        #expect(host.window.makeFirstResponder(editor))
        #expect(host.window.firstResponder === editor)
        // SwiftPM's command-line helper can dispatch native keys but does not
        // acquire NSApp.keyWindow on this host. Focus restoration after closing
        // a modal therefore requires a separate check in the activated app.
        try key("k", code: 40, modifiers: .command, in: host.window)
        try await settle(host.window)
        let field = try element(identifier: "ask.workspace.search.field", in: host.window)
        assertVisible(field, in: host.window)
        let frame = host.window.convertFromScreen(field.accessibilityFrame())
        #expect(frame.maxY <= host.window.frame.height - AskMetrics.titleBarRowHeight)
        try await snapshot(host.window, name: "search-440x320")
        try key("\u{1b}", code: 53, in: host.window)
        try await settle(host.window)
        #expect(find(identifier: "ask.workspace.search.field", in: host.window) == nil)
        #expect(host.fixture.model.draft.text == "Keep this unfinished question")
        #expect(editor.selectedRange() == selection)
        try assertControls(in: host.window, hasConversation: true)

        try click(identifier: "ask.workspace.usage", in: host.window)
        try await settle(host.window)
        _ = try element(label: L("ask.usage.close"), in: host.window)
        try key("\u{1b}", code: 53, in: host.window)
        try await settle(host.window)
        #expect(find(label: L("ask.usage.close"), in: host.window) == nil)
        try await resize(host.window, to: Self.sizes[0])
        #expect(UserDefaults.standard.bool(forKey: "ask.sidebarCollapsed"))
        #expect(host.fixture.model.draft.text == "Keep this unfinished question")
    }

    @Test func longDraftPaletteStaysBelowTheTitleBarAcrossHeightThresholds() async throws {
        guard enabled else { return }
        let session = PreviewSession()
        defer { session.restore() }
        let host = try await makeHost(scene: "chat")
        defer { host.close() }
        host.fixture.model.draft.text = String(repeating: "An unfinished line that must survive resizing.\n", count: 12)
        host.fixture.model.draft.append((1...6).map {
            AskAttachment(kind: .file, name: "example-\($0).txt", text: "Synthetic attachment \($0)")
        })
        host.fixture.model.draft.skills = ["meeting-notes", "summarize"]
        host.fixture.model.attachmentNotice = "Synthetic attachment notice"
        try await settle(host.window)
        let input = try editor(in: host.window)
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        host.window.makeFirstResponder(input)
        try key("/", code: 44, in: host.window)
        try await settle(host.window)
        let expectedDraft = host.fixture.model.draft

        for size in [NSSize(width: 760, height: 700), NSSize(width: 760, height: 560),
                     NSSize(width: 760, height: 500), NSSize(width: 440, height: 320),
                     NSSize(width: 360, height: 280)] {
            try await resize(host.window, to: size)
            #expect(try editor(in: host.window) === input)
            #expect(host.fixture.model.draft == expectedDraft)
            let palette = try element(identifier: "ask.command.palette", in: host.window)
            assertVisible(palette, in: host.window)
            let frame = host.window.convertFromScreen(palette.accessibilityFrame())
            #expect(frame.maxY <= host.window.frame.height - AskMetrics.titleBarRowHeight,
                    "The command list must stay below the native title bar even with a full draft and attachments.")
            #expect(frame.height >= 68, "Keep one complete command row available.")
            let viewport = try #require(input.enclosingScrollView)
            #expect(frame.minY >= viewport.convert(viewport.bounds, to: nil).maxY + 8)
            try assertControls(in: host.window, hasConversation: true)
            try await snapshot(host.window, name: "palette-\(Int(size.width))x\(Int(size.height))")
        }
        try key("\u{1b}", code: 53, in: host.window)
        try await settle(host.window)
        #expect(find(identifier: "ask.command.palette", in: host.window) == nil)
        #expect(host.fixture.model.draft == expectedDraft)
    }

    private func assertControls(in window: NSWindow, hasConversation: Bool) throws {
        let editor = try editor(in: window)
        let viewport = try #require(editor.enclosingScrollView)
        assertVisible(viewport.convert(viewport.bounds, to: nil), in: window, name: "editor viewport")
        let voice = try #require(descendants(window.contentView!).compactMap { $0 as? AskVoiceButton.Control }.first)
        assertVisible(voice.convert(voice.bounds, to: nil), in: window, name: "voice button")
        let point = voice.convert(NSPoint(x: voice.bounds.midX, y: voice.bounds.midY), to: window.contentView?.superview)
        #expect(window.contentView?.hitTest(point) === voice, "An overlay must not swallow voice clicks.")
        var identifiers = ["ask.workspace.sidebar", "ask.workspace.new", "ask.composer.attach",
                           "ask.composer.model", "ask.composer.send"]
        if AskWorkspaceLayout(size: window.frame.size, sidebarCollapsed: false, showsUsage: false).compactContent {
            identifiers += ["ask.context.menu"]
        }
        if hasConversation {
            identifiers += ["ask.workspace.usage"]
            if AskWorkspaceLayout(size: window.frame.size, sidebarCollapsed: false, showsUsage: false).compactContent {
                identifiers += ["ask.workspace.more"]
            }
        }
        for identifier in identifiers {
            assertVisible(try element(identifier: identifier, in: window), in: window)
        }
    }

    private func assertVisible(_ element: AccessibleElement, in window: NSWindow) {
        let frame = window.convertFromScreen(element.accessibilityFrame())
        assertVisible(frame, in: window, name: element.accessibilityIdentifier() ?? element.accessibilityLabel() ?? "control")
    }

    private func assertVisible(_ frame: NSRect, in window: NSWindow, name: String) {
        let content = window.contentView!
        let viewport = content.convert(content.bounds, to: nil).insetBy(dx: -1, dy: -1)
        #expect(frame.width > 0 && frame.height > 0, "\(name) must have a nonzero frame: \(frame)")
        #expect(viewport.contains(frame), "\(name) \(frame) must be within viewport \(viewport)")
    }

    private func editor(in window: NSWindow) throws -> AskComposerTextView.Editor {
        try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func accessibilityElements(in window: NSWindow) -> [AccessibleElement] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> [AccessibleElement] {
            guard let object = value as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = AccessibleElement(object: object)
            return [element] + element.children.flatMap(walk)
        }
        return walk(window)
    }

    /// SwiftUI's accessibility nodes expose the Objective-C selectors but do
    /// not conform to NSAccessibilityProtocol. KVC boxes their NSRect safely.
    @MainActor
    private struct AccessibleElement {
        let object: NSObject
        private func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
        func accessibilityIdentifier() -> String? { value("accessibilityIdentifier") as? String }
        func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
        func accessibilityFrame() -> NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func find(identifier: String, in window: NSWindow) -> (AccessibleElement)? {
        accessibilityElements(in: window).first { $0.accessibilityIdentifier() == identifier }
    }

    private func find(label: String, in window: NSWindow) -> (AccessibleElement)? {
        accessibilityElements(in: window).first { $0.accessibilityLabel() == label }
    }

    private func element(identifier: String, in window: NSWindow) throws -> AccessibleElement {
        try #require(find(identifier: identifier, in: window), "Missing native accessibility element: \(identifier)")
    }

    private func element(label: String, in window: NSWindow) throws -> AccessibleElement {
        try #require(find(label: label, in: window), "Missing native accessibility element: \(label)")
    }

    private func click(identifier: String, in window: NSWindow) throws {
        try click(try element(identifier: identifier, in: window), in: window)
    }

    private func click(_ element: AccessibleElement, in window: NSWindow) throws {
        let frame = window.convertFromScreen(element.accessibilityFrame())
        let point = NSPoint(x: frame.midX, y: frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        if modifiers.contains(.command) {
            #expect(window.performKeyEquivalent(with: event), "The window must handle its search shortcut.")
        } else {
            NSApp.sendEvent(event)
        }
    }

    private func resize(_ window: NSWindow, to size: NSSize) async throws {
        window.setFrame(NSRect(origin: NSPoint(x: 80, y: 50), size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        #expect(abs(window.frame.width - size.width) < 1)
        #expect(abs(window.frame.height - size.height) < 1)
    }

    private func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func makeHost(scene: String) async throws -> Host {
        _ = NSApplication.shared
        let suite = "ask-responsive-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels(AskLivePreviewHarness.cloudModels(), providerID: "typefluxCloud")
        library.defaultReference = "cloud:minimax-m3"
        let fixture = try AskTestFixture(modelLibrary: scene == "approval" ? nil : library)
        for conversation in AskLivePreviewHarness.history() { await fixture.api.seed(conversation) }
        await fixture.model.refreshHistory()
        if scene == "empty" {
            fixture.model.newConversation()
        } else {
            await fixture.model.select(scene == "approval" ? "c3" : "c1")
            if scene == "approval" {
                let call = AskToolCall(id: "approval-preview", type: "function", function: .init(
                    name: "browser", arguments: #"{"action":"click","target":"Send comment"}"#))
                await fixture.api.setTool(call)
                fixture.model.draft.text = "Reply with the agreed summary"
                fixture.model.submitDraft()
                try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
            }
        }
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model,
            conversationFrameAutosaveName: suite)
        controller.showConversation()
        let window = try #require(NSApp.windows.first {
            !oldWindows.contains(ObjectIdentifier($0))
                && $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-conversations"
        })
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(window)
        return Host(fixture: fixture, controller: controller, window: window, defaults: defaults, suite: suite)
    }

    private func snapshot(_ window: NSWindow, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESPONSIVE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "width": window.frame.width, "height": window.frame.height,
            "minimumWidth": window.minSize.width, "minimumHeight": window.minSize.height,
            "usesOriginalControllerContent": true,
            "controls": accessibilityElements(in: window).compactMap { element -> [String: Any]? in
                guard let identifier = element.accessibilityIdentifier(), identifier.hasPrefix("ask.") else { return nil }
                let rect = window.convertFromScreen(element.accessibilityFrame())
                return ["identifier": identifier, "x": rect.minX, "y": rect.minY,
                        "width": rect.width, "height": rect.height]
            }
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".json"))
        if let filter = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESPONSIVE_CAPTURE_FILTER"],
           !filter.split(separator: ",").contains(Substring(name)) { return }
        let file = root.appendingPathComponent(name + ".png")
        if ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESPONSIVE_EXTERNAL_CAPTURE"] != nil {
            let acknowledged = root.appendingPathComponent(name + ".next")
            try? FileManager.default.removeItem(at: acknowledged)
            let ready: [String: Any] = ["name": name, "window": window.windowNumber,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "width": window.frame.width, "height": window.frame.height]
            let marker = root.appendingPathComponent("capture-ready.json")
            try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
                .write(to: marker, options: [.atomic])
            let deadline = ContinuousClock.now + .seconds(60)
            while !FileManager.default.fileExists(atPath: acknowledged.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try? FileManager.default.removeItem(at: marker)
            try #require(FileManager.default.fileExists(atPath: acknowledged.path), "External capture did not acknowledge \(name).")
            return
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        let data = try Data(contentsOf: file)
        #expect(data.count > 2000, "The captured production window must contain rendered content.")

    }

    @MainActor
    private struct Host {
        let fixture: AskTestFixture
        let controller: AskConversationWindowController
        let window: NSWindow
        let defaults: UserDefaults
        let suite: String

        func close() {
            AskGlassMenuPresenter.shared.hide()
            fixture.model.resetSession()
            window.orderOut(nil)
            window.delegate = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            NSWindow.removeFrame(usingName: suite)
        }
    }

    @MainActor
    private struct PreviewSession {
        let language = AppLocalization.shared.language
        let profile = AuthState.shared.userProfile
        let loggedIn = AuthState.shared.isLoggedIn
        let collapsed = UserDefaults.standard.object(forKey: "ask.sidebarCollapsed")
        let activationPolicy = NSApplication.shared.activationPolicy()

        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // SwiftUI builds its native accessibility tree only while an AX
            // client requests the enhanced interface; no system permission is changed.
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            UserDefaults.standard.set(false, forKey: "ask.sidebarCollapsed")
            AuthState.shared.userProfile = UserProfile(id: "responsive-preview", email: "preview@example.com",
                name: "Preview User", status: 1, provider: "email", createdAt: "", updatedAt: "")
            AuthState.shared.isLoggedIn = true
        }

        func restore() {
            AppLocalization.shared.setLanguage(language)
            AuthState.shared.userProfile = profile
            AuthState.shared.isLoggedIn = loggedIn
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            UserDefaults.standard.set(collapsed, forKey: "ask.sidebarCollapsed")
            NSApp.setActivationPolicy(activationPolicy)
        }
    }
}
