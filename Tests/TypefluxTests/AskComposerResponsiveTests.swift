import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask responsive composer", .serialized, .exclusiveUIState)
@MainActor
struct AskComposerResponsiveTests {
    @Test func workspaceDensityReservesPrimaryControlsAndLauncherKeepsItsChrome() {
        for width: CGFloat in [320, 360, 440, 599, 600, 960] {
            for compact in [false, true] {
                let workspace = AskComposerLayout(launcher: false, compact: compact, width: width)
                #expect(workspace.condensedFooter == (width < 600))
                #expect(workspace.editorMaximumHeight == (compact ? 48 : 148))
                #expect(workspace.supplementalMaximumHeight == (compact ? 40 : 160))
                #expect(workspace.editorTopInset == (compact ? 6 : 14))
                #expect(workspace.editorBottomInset == (compact ? 2 : 4))
                #expect(workspace.footerHeight == (compact ? 40 : 48))
                let launcher = AskComposerLayout(launcher: true, compact: compact, width: width)
                #expect(!launcher.condensedFooter)
                #expect(launcher.editorMaximumHeight == 148)
                #expect(launcher.editorTopInset == AskComposerChrome.launcher.editorTopInset)
                #expect(launcher.editorBottomInset == AskComposerChrome.launcher.editorBottomInset)
                #expect(launcher.footerHeight == AskComposerChrome.launcher.footerHeight)
            }
        }
    }

    @Test func queuedEditReservesTwoFooterRowsOnlyInNarrowWorkspaces() {
        for width: CGFloat in [296, 320, 336, 440, 599, 600, 960] {
            for compact in [false, true] {
                let workspace = AskComposerLayout(launcher: false, compact: compact, width: width,
                                                   editingQueued: true)
                #expect(workspace.stackedQueueActions == (width < 600))
                #expect(workspace.footerHeight == workspace.footerRowHeight * (width < 600 ? 2 : 1))
                let launcher = AskComposerLayout(launcher: true, compact: compact, width: width,
                                                  editingQueued: true)
                #expect(!launcher.stackedQueueActions)
                #expect(launcher.footerHeight == AskComposerChrome.launcher.footerHeight)
            }
        }
    }

    @Test func narrowQueuedDraftAndCommandPickerFitWithAttachments() {
        for height: CGFloat in [280, 320, 500, 700] {
            let short = height < 500
            let available = height - 52 - (short ? 12 : 24)
            for supplements: CGFloat in [0, 40, 400] {
                let layout = AskComposerLayout(launcher: false, compact: short, width: 296,
                                               availableHeight: available, paletteOpen: true,
                                               supplementalHeight: supplements, editingQueued: true)
                #expect(layout.editorMaximumHeight >= 32)
                if supplements > 0 { #expect(layout.supplementalMaximumHeight >= 20) }
                #expect(layout.maximumCardHeight + (layout.paletteMaximumHeight(composerHeight: 0) ?? 0) + 8
                    <= available)
            }
        }
    }

    @Test func editorHeightLimitChangesWithoutDiscardingTextSelectionOrScrollability() async throws {
        let state = EditorState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ResizingEditor(state: state))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await settle(host)
        let editor = try #require(findEditor(host))
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.contentSize.height == 148)
        #expect(editor.bounds.height > scroll.contentSize.height)
        let selection = NSRange(location: 7, length: 11)
        editor.setSelectedRange(selection)

        state.maximumHeight = 48
        try await settle(host)
        #expect(findEditor(host) === editor)
        #expect(scroll.contentSize.height == 48)
        #expect(editor.bounds.height > scroll.contentSize.height)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string == state.text)
        #expect(scroll.hasVerticalScroller)

        window.setContentSize(NSSize(width: 600, height: 500))
        state.maximumHeight = 148
        try await settle(host)
        #expect(findEditor(host) === editor)
        #expect(scroll.contentSize.height == 148)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string == state.text)

        state.text = "Short draft"
        try await settle(host)
        #expect(scroll.contentSize.height == 32)
    }

    @Test func longestCompactDraftAndCommandPickerFitBelowTheNativeTitlebar() {
        let layout = AskComposerLayout(launcher: false, compact: true, width: 336)
        let composerHeight = layout.editorMaximumHeight + layout.editorTopInset + layout.editorBottomInset
            + layout.footerHeight + layout.supplementalMaximumHeight
        let paletteHeight: CGFloat = 68
        // The minimum supported window keeps 52 pt for its titlebar and 12 pt
        // for the composer's lower inset, even with all draft content present.
        #expect(composerHeight + paletteHeight + 8 + 52 + 12 <= 280)
    }

    @Test func commandPickerReservesACompleteRowAtIntermediateWindowHeights() {
        for height: CGFloat in [280, 320, 500, 560, 600, 700, 880] {
            let short = height < 500
            let available = height - 52 - (short ? 12 : 24)
            for supplements: CGFloat in [0, 40, 400] {
                let layout = AskComposerLayout(launcher: false, compact: short, width: 416,
                                               availableHeight: available, paletteOpen: true,
                                               supplementalHeight: supplements)
                let maximum = layout.paletteMaximumHeight(composerHeight: 0) ?? 0
                #expect(maximum >= 68)
                #expect(layout.maximumCardHeight + maximum + 8 <= available)
                #expect(layout.paletteMaximumHeight(composerHeight: layout.maximumCardHeight) == maximum)
                let closed = AskComposerLayout(launcher: false, compact: short, width: 416,
                                               availableHeight: available, supplementalHeight: supplements)
                #expect(closed.usesCompactMetrics == short)
            }
        }
        let launcher = AskComposerLayout(launcher: true, compact: false, width: 680,
                                          paletteOpen: true, supplementalHeight: 400)
        #expect(!launcher.usesCompactMetrics)
        #expect(launcher.paletteMaximumHeight(composerHeight: 400) == nil)
    }

    @Test func shortComposerBoundsManyAttachmentsWithoutHidingTheEditor() async throws {
        let fixture = try AskTestFixture()
        fixture.model.draft.text = String(repeating: "Long draft line\n", count: 30)
        fixture.model.draft.skills = (1 ... 18).map { "example-skill-\($0)" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack {
            Spacer(minLength: 0)
            AskComposer(model: fixture.model, compact: true, launcher: false)
        })
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await settle(host)
        let editor = try #require(findEditor(host))
        let scroll = try #require(editor.enclosingScrollView)
        let editorRect = scroll.convert(scroll.bounds, to: host)
        #expect(host.bounds.contains(editorRect))
        #expect(scroll.contentSize.height == 48)
        #expect(editor.string == fixture.model.draft.text)
        #expect(fixture.model.draft.skills?.count == 18)
        let voice = try #require(findVoice(host))
        #expect(host.bounds.contains(voice.convert(voice.bounds, to: host)))
    }

    @Test
    func compactContextMenuTogglesMemoryAndOpensUsage() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        fixture.model.draft.memory = AskMemory(global: "Use short answers")
        fixture.model.draft.includeScreenshot = true
        fixture.model.captureWarning = L("ask.capture.permission")
        var usageOpens = 0
        let openUsage = { usageOpens += 1 }
        let window = makeWindow()
        let host = NSHostingView(rootView: VStack {
            Spacer(minLength: 0)
            AskComposer(model: fixture.model, compact: true, launcher: false,
                        onToggleUsage: openUsage)
        })
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(host)
        let context = try accessibilityElement(identifier: "ask.context.menu", in: window)
        let contextRect = try #require(context.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let button = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first { candidate in
            let frame = window.convertToScreen(candidate.convert(candidate.bounds, to: nil))
            return contextRect.contains(NSPoint(x: frame.midX, y: frame.midY))
        })
        let memoryTitle = try #require(fixture.model.draft.memory?.chipTitle)
        let screenshotState = try await AppKitTestActions.inspectMenuItem(L("ask.screenshot"), using: button) { _ in
            fixture.model.removeCapturedContent(.screenshot, launcher: false)
        }
        #expect(screenshotState == .on)
        #expect(!fixture.model.draft.includeScreenshot,
                "A failed screenshot remains an explicit checked inclusion toggle, never a misleading retry action.")
        try await settle(host)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try await AppKitTestActions.inspectMenuItem(memoryTitle, using: button) { _ in
            fixture.model.toggleMemory(launcher: false)
        }
        try await settle(host)
        #expect(fixture.model.memorySwitchedOff(launcher: false))
        try await AppKitTestActions.inspectMenuItem(memoryTitle, using: button) { _ in
            fixture.model.toggleMemory(launcher: false)
        }
        try await settle(host)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try await AppKitTestActions.inspectMenuItem(L("ask.usage.title"), using: button) { _ in openUsage() }
        try await settle(host)
        #expect(usageOpens == 1)
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func narrowQueuedEditKeepsVoiceSaveAndCancelReachable(style: InterfaceStyle, dark: Bool) async throws {
        try await withQueuedEditWindow(style: style, dark: dark) { fixture, window, host in
            let conversation = try #require(fixture.model.selectedId)
            let queued = try #require(fixture.model.queuedMessages.first)
            for width: CGFloat in [320, 360, 440, 640, 360] {
                window.setContentSize(NSSize(width: width, height: 280))
                try await settle(host)
                #expect(fixture.model.isEditingQueued)
                let voice = try #require(findVoice(host))
                #expect(host.bounds.contains(voice.convert(voice.bounds, to: host)))
                let point = voice.convert(NSPoint(x: voice.bounds.midX, y: voice.bounds.midY), to: host.superview)
                #expect(host.hitTest(point) === voice)
                let voiceFrame = window.convertToScreen(voice.convert(voice.bounds, to: nil))
                var actionFrames: [(identifier: String, rect: NSRect)] = []
                for identifier in ["ask.queue.save", "ask.queue.cancel", "ask.composer.model"] {
                    let control = try accessibilityElement(identifier: identifier, in: window)
                    let rect = try #require(control.value(forKey: "accessibilityFrame") as? NSValue).rectValue
                    let context = "\(identifier): \(rect), width \(width), \(style.rawValue), dark=\(dark)"
                    if identifier == "ask.composer.model" {
                        #expect(rect.width > 0 && rect.height > 0, "\(context) must remain visible")
                    } else {
                        #expect(rect.width >= 20 && rect.height >= 20, "\(context) must retain its hit target")
                    }
                    #expect(window.frame.contains(rect), "\(context) must fit inside the window")
                    #expect(!rect.intersects(voiceFrame), "\(context) must not overlap voice")
                    actionFrames.append((identifier, rect))
                }
                for (index, left) in actionFrames.enumerated() {
                    for right in actionFrames.dropFirst(index + 1) {
                        #expect(!left.rect.intersects(right.rect), "\(left.identifier) overlaps \(right.identifier)")
                    }
                }
                #expect(try queueAction("ask.queue.save", in: window).label == L("ask.queue.save"))
                #expect(try queueAction("ask.queue.cancel", in: window).label == L("ask.queue.cancel"))
                #expect(fixture.model.draft.text == "Updated request")
                try await AskLibraryTestSupport.capture(window,
                    name: "queued-edit-\(style.rawValue)-\(dark ? "dark" : "light")-\(Int(width))")
            }
            fixture.model.draft.text = ""
            try await settle(host)
            let disabledSave = try queueAction("ask.queue.save", in: window)
            #expect(disabledSave.value("isAccessibilityEnabled") as? Bool == false)
            #expect(disabledSave.frame.width >= 20 && disabledSave.frame.height >= 20)
            #expect(window.frame.contains(disabledSave.frame), "Empty drafts keep the disabled save control visible")
            #expect(disabledSave.label == L("ask.queue.save"))
            try disabledSave.press()
            fixture.model.submitDraft()
            #expect(fixture.model.isEditingQueued && fixture.model.queuedMessages.first?.draft.text == "Queued request")
            try await AskLibraryTestSupport.capture(window,
                name: "queued-edit-empty-\(style.rawValue)-\(dark ? "dark" : "light")")
            fixture.model.draft.text = "Updated request"
            try await settle(host)
            try queueAction("ask.queue.save", in: window).press()
            try await settle(host)
            #expect(!fixture.model.isEditingQueued)
            #expect(fixture.model.queuedMessages.first?.draft.text == "Updated request")
            fixture.model.editQueued(queued.id)
            fixture.model.draft.text = "Cancelled edit"
            try await settle(host)
            try queueAction("ask.queue.cancel", in: window).press()
            try await settle(host)
            #expect(!fixture.model.isEditingQueued)
            #expect(fixture.model.queuedMessages.first?.draft.text == "Updated request")
            fixture.model.approve(conversationId: conversation, allowed: false)
            try await fixture.wait { fixture.model.busyIds.isEmpty }
        }
    }

    @Test func failedQueuedEditCheckReleasesItsWindowQueueAndApprovals() async throws {
        var failedFixture: AskTestFixture?
        var failedWindow: NSWindow?
        var conversationID: String?
        _ = NSApplication.shared
        let enhanced = NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool ?? false
        do {
            try await withQueuedEditWindow(style: .liquidGlass, dark: false) { fixture, window, _ in
                failedFixture = fixture
                failedWindow = window
                conversationID = fixture.model.selectedId
                #expect(fixture.model.isEditingQueued && !fixture.model.pendingApprovals.isEmpty)
                throw QueuedEditCheckFailure.expected
            }
            Issue.record("The fixture must propagate a failed check after teardown")
        } catch QueuedEditCheckFailure.expected { }
        let fixture = try #require(failedFixture)
        let window = try #require(failedWindow)
        #expect(!window.isVisible && window.contentView == nil)
        #expect(window.childWindows?.isEmpty != false)
        #expect(fixture.model.sendQueue.messages(try #require(conversationID)).isEmpty)
        #expect(fixture.model.sendQueue.editing == nil && fixture.model.pendingApprovals.isEmpty)
        #expect(fixture.model.busyIds.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool == enhanced)
    }

    private enum QueuedEditCheckFailure: Error { case expected }

    private func withQueuedEditWindow(style: InterfaceStyle, dark: Bool,
                                     run: (AskTestFixture, NSWindow, NSView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let enhanced = NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(enhanced, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        var hostedWindow: NSWindow?
        defer {
            if let window = hostedWindow { TypefluxNavigationTestSupport.closeWindow(window) }
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let call = AskToolCall(id: "responsive-edit", type: "function",
                               function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        await fixture.api.setTool(call)
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.draft.text = "Initial request"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        await fixture.api.setTool(nil)
        fixture.model.draft.text = "Queued request"
        fixture.model.submitDraft()
        let queued = try #require(fixture.model.queuedMessages.first)
        fixture.model.editQueued(queued.id)
        fixture.model.draft.text = "Updated request"
        #expect(fixture.model.isEditingQueued)
        let window = makeWindow()
        hostedWindow = window
        let host = NSHostingView(rootView: VStack {
            Spacer(minLength: 0)
            AskComposer(model: fixture.model, compact: true, launcher: false)
                .padding(.horizontal, 12)
        }.environment(\.interfaceStyle, style).environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try await run(fixture, window, host)
    }

    private func queueAction(_ identifier: String, in window: NSWindow) throws -> SettingsBehaviorTestSupport.Element {
        // Include native controls even when SwiftUI omits disabled proxies from AX children.
        let identified = AskWorkspaceTestAccessibility.elements(in: window).filter {
            $0.value("accessibilityIdentifier") as? String == identifier
        }
        let candidates = identified.flatMap { [$0] + SettingsBehaviorTestSupport.elements(in: $0.object) }
        let element = try #require(candidates.first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.frame.width > 0 && $0.frame.height > 0
        }, "Missing accessible button: \(identifier)")
        return SettingsBehaviorTestSupport.Element(object: element.object, window: window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 280),
                                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @discardableResult
    private func accessibilityElement(identifier: String, in window: NSWindow) throws -> NSObject {
        var seen = Set<ObjectIdentifier>()
        func find(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier {
                return object
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let match = find(child) {
                    return match
                }
            }
            return nil
        }
        if let element = find(window) {
            return element
        }
        if let content = window.contentView, let element = find(content) {
            return element
        }
        return try #require(nil as NSObject?, "Missing control: \(identifier)")
    }

    private func findEditor(_ view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(findEditor).first
    }

    private func findVoice(_ view: NSView) -> AskVoiceButton.Control? {
        (view as? AskVoiceButton.Control) ?? view.subviews.lazy.compactMap(findVoice).first
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0 ..< 20 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class EditorState: ObservableObject {
    @Published var text = String(repeating: "An editable long line of text\n", count: 30)
    @Published var maximumHeight: CGFloat = 148
    @Published var height: CGFloat = 32
}

private struct ResizingEditor: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack {
            AskComposerTextView(text: $state.text, placeholder: "Draft", maximumHeight: state.maximumHeight,
                                onSubmit: {}, onHeightChange: { state.height = $0 })
                .frame(height: min(state.height, state.maximumHeight))
            Spacer(minLength: 0)
        }
    }
}
