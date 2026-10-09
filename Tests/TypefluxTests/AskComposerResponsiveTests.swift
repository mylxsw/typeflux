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

    // Run native NSMenu interactions in their own process: in SwiftPM's test
    // host, this test can interrupt subsequent window tests after it completes.
    // TYPEFLUX_ASK_CONTEXT_MENU_TESTS=1 swift test --no-parallel --filter 'AskComposerResponsiveTests.*compactContextMenu'
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_ASK_CONTEXT_MENU_TESTS"] == "1"))
    func compactContextMenuTogglesMemoryAndOpensUsage() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        fixture.model.draft.memory = AskMemory(global: "Use short answers")
        fixture.model.draft.includeScreenshot = true
        fixture.model.captureWarning = L("ask.capture.permission")
        var usageOpens = 0
        let window = makeWindow()
        let host = NSHostingView(rootView: VStack {
            Spacer(minLength: 0)
            AskComposer(model: fixture.model, compact: true, launcher: false,
                        onToggleUsage: { usageOpens += 1 })
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
        let screenshotState = try selectMenuItem(L("ask.screenshot"), using: button)
        #expect(screenshotState == .on)
        #expect(!fixture.model.draft.includeScreenshot,
                "A failed screenshot remains an explicit checked inclusion toggle, never a misleading retry action.")
        try await settle(host)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try selectMenuItem(memoryTitle, using: button)
        try await settle(host)
        #expect(fixture.model.memorySwitchedOff(launcher: false))
        try selectMenuItem(memoryTitle, using: button)
        try await settle(host)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try selectMenuItem(L("ask.usage.title"), using: button)
        try await settle(host)
        #expect(usageOpens == 1)
    }

    @Test func narrowQueuedEditKeepsVoiceSaveAndCancelReachable() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        let call = AskToolCall(id: "responsive-edit", type: "function",
                               function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        await fixture.api.setTool(call)
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.draft.text = "Initial request"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        await fixture.api.setTool(nil)
        let conversation = try #require(fixture.model.selectedId)
        fixture.model.draft.text = "Queued request"
        fixture.model.submitDraft()
        let queued = try #require(fixture.model.queuedMessages.first)
        fixture.model.editQueued(queued.id)
        fixture.model.draft.text = "Updated request"
        #expect(fixture.model.isEditingQueued)
        let window = makeWindow()
        let host = NSHostingView(rootView: VStack {
            Spacer(minLength: 0)
            AskComposer(model: fixture.model, compact: true, launcher: false)
                .padding(.horizontal, 12)
        })
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { fixture.model.resetSession(); window.close() }
        try await settle(host)
        #expect(fixture.model.isEditingQueued)
        let voice = try #require(findVoice(host))
        #expect(host.bounds.contains(voice.convert(voice.bounds, to: host)))
        let voicePoint = voice.convert(NSPoint(x: voice.bounds.midX, y: voice.bounds.midY), to: host.superview)
        #expect(host.hitTest(voicePoint) === voice)
        let save = try accessibilityElement(identifier: "ask.queue.save", in: window)
        let cancel = try accessibilityElement(identifier: "ask.queue.cancel", in: window)
        let model = try accessibilityElement(identifier: "ask.composer.model", in: window)
        for control in [save, cancel, model] {
            let rect = try #require(control.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            #expect(window.frame.contains(rect))
        }
        try click(save, in: window)
        try await settle(host)
        #expect(!fixture.model.isEditingQueued)
        #expect(fixture.model.queuedMessages.first?.draft.text == "Updated request")
        fixture.model.editQueued(queued.id)
        fixture.model.draft.text = "Cancelled edit"
        try await settle(host)
        try click(accessibilityElement(identifier: "ask.queue.cancel", in: window), in: window)
        try await settle(host)
        #expect(!fixture.model.isEditingQueued)
        #expect(fixture.model.queuedMessages.first?.draft.text == "Updated request")
        fixture.model.approve(conversationId: conversation, allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
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
    private func selectMenuItem(_ title: String, using button: NSPopUpButton) throws -> NSControl.StateValue? {
        var selected = false
        var state: NSControl.StateValue?
        var titles: [String] = []
        // SwiftUI populates the NSMenu only when tracking starts. Run the
        // selection in that tracking loop, then close it before dispatching.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu else { return }
                titles = menu.items.map(\.title)
                let index = menu.items.firstIndex { $0.title == title }
                menu.cancelTrackingWithoutAnimation()
                if let index {
                    state = menu.items[index].state
                    menu.performActionForItem(at: index)
                    selected = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)
        timer.invalidate()
        try #require(selected, "Menu item \(title) missing from \(titles)")
        return state
    }

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

    private func click(_ element: NSObject, in window: NSWindow) throws {
        let rect = try #require(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let frame = window.convertFromScreen(rect)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1,
                                                        pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
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
