import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Typeflux

/// The launcher rendered in a real window: captured context stays out of the editor's
/// row, the switches sit in the bottom bar, and recording swaps the results for
/// the voice panel without moving the rest.
@Suite("Ask launcher header", .serialized)
@MainActor
struct AskLauncherHeaderTests {
    private final class Reported { var height: CGFloat = 0 }

    private func host(_ fixture: AskTestFixture) -> (NSWindow, Reported) {
        _ = NSApplication.shared
        // SwiftUI builds its accessibility tree only for assistive clients. It is a
        // process-wide flag other suites also set, so it is never switched off here:
        // doing so mid-run would hide their controls from them.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let reported = Reported()
        let size = NSSize(width: AskMetrics.launcherWidth, height: 360)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {},
                                                              onHeightChange: { reported.height = $0 })
            .environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        return (window, reported)
    }

    private func captured(_ fixture: AskTestFixture) {
        var draft = AskDraft()
        draft.source = "Google Chrome — Issues | Multica - Google Chrome"
        draft.sourceBundleID = "com.google.Chrome"
        draft.selection = "first line\nsecond line"
        draft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft = draft
    }

    @Test func capturedContextLeavesTheEditorClearAndKeepsTheOriginalFooterSwitches() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.token", in: window) == nil)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        let scroll = try #require(editor.enclosingScrollView)
        let editorFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        #expect(editorFrame.minX < window.frame.minX + 40, "the editor starts at the card's left inset")
        // Captured content is no longer a row of chips above the editor.
        #expect(find("ask.content.source.preview", in: window) == nil)
        #expect(find("ask.content.selection.preview", in: window) == nil)
        // The model menu sits in the bottom bar, below the suggestions.
        let model = try element("ask.composer.model", in: window)
        #expect(model.frame.maxY < editorFrame.minY - AskLauncherSuggestions.height + 8)
        let screenshot = try element("ask.context.screenshot.toggle", in: window)
        let memory = try #require(find(L("ask.memory"), attribute: "accessibilityLabel", in: window))
        #expect(find("ask.context.settings", in: window) == nil)
        #expect(abs(memory.frame.midY - model.frame.midY) < 2)
        #expect(abs(screenshot.frame.midY - model.frame.midY) < 2)
        #expect(memory.frame.width == AskMetrics.composerControlHeight)
        #expect(abs(memory.frame.minX - screenshot.frame.maxX - AskContextChips.spacing) < 1)
        let request = fixture.model.launcherDraft.request(deviceId: "device", tools: [])
        #expect(request.source == fixture.model.launcherDraft.source)
        #expect(request.selection == "first line\nsecond line")
        let expected = AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: true)
        #expect(abs(reported.height - expected) <= 4, "reported \(reported.height), expected \(expected)")
        try click(memory, in: window)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == true }
        try click(try #require(find(L("ask.memory"), attribute: "accessibilityLabel", in: window)), in: window)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == nil }
    }

    @Test func recordingSwapsTheResultsForTheVoicePanel() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let resting = reported.height
        #expect(AskVoicePanel.minimumHeight <= AskLauncherSuggestions.height)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        #expect(fixture.model.voiceInput.begin(in: editor))
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.voice.panel", in: window) != nil)
        #expect(find("ask.voice.cancel", in: window) != nil)
        #expect(find("ask.context.token", in: window) == nil)
        #expect(find("ask.composer.send", in: window) == nil)
        #expect(find("ask.composer.model", in: window) != nil, "the bottom bar stays")
        // The panel takes the suggestions' height, so the launcher does not move.
        #expect(abs(reported.height - resting) <= 1, "recording \(reported.height), resting \(resting)")
        fixture.model.voiceInput.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.voice.panel", in: window) == nil)
        #expect(find("ask.context.token", in: window) == nil)
        #expect(find("ask.context.settings", in: window) == nil)
        #expect(find(L("ask.memory"), attribute: "accessibilityLabel", in: window) != nil)
    }

    @Test func voicePanelIsAtLeastItsMinimumWhenThereWereNoResults() async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft.text = "a question with no quick results"
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let resting = reported.height
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        #expect(fixture.model.voiceInput.begin(in: editor))
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(reported.height - resting - AskVoicePanel.minimumHeight) <= 1)
        fixture.model.voiceInput.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(reported.height - resting) <= 1)
    }

    @Test func screenshotHoverPreviewsTheCaptureWithoutTakingFocusOrTheToggleClick() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        captured(fixture)
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png)
        fixture.model.launcherDraft.screenshot = "data:image/png;base64," + png.base64EncodedString()
        fixture.model.launcherDraft.capturedAt = Date()
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        let restingHeight = reported.height
        let screenshot = try element("ask.context.screenshot.toggle", in: window)
        try hover(screenshot, in: window, inside: true)
        try await Task.sleep(for: .milliseconds(300))
        let card = try #require(window.childWindows?.first { $0 is AskHoverCardPresenter.Panel })
        #expect(find("ask.context.screenshot.hoverPreview", in: card) != nil)
        #expect(card.ignoresMouseEvents && !card.canBecomeKey)
        #expect(window.firstResponder === editor)
        #expect(abs(reported.height - restingHeight) <= 1, "preview does not resize the launcher")
        try saveSnapshot(window.contentView!, name: "launcher")
        try saveSnapshot(try #require(card.contentView), name: "screenshot-hover")
        let point = window.convertPoint(fromScreen: NSPoint(x: screenshot.frame.midX, y: screenshot.frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await fixture.wait { !fixture.model.launcherDraft.includeScreenshot }
        #expect(!card.isVisible)
        #expect(fixture.model.launcherDraft.screenshot != nil, "the captured image can still be restored")
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).image == nil)
        try hover(try element("ask.context.screenshot.toggle", in: window), in: window, inside: false)
        try hover(try element("ask.context.screenshot.toggle", in: window), in: window, inside: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.screenshot.hoverPreview", in: card) != nil,
                "a screenshot switched off can be previewed before restoring it")
        fixture.model.launcherDraft.screenshot = nil
        try await Task.sleep(for: .milliseconds(200))
        #expect(!card.isVisible || find("ask.context.screenshot.hoverPreview", in: card) == nil,
                "an open card must update when its capture disappears")
        try hover(try element("ask.context.screenshot.toggle", in: window), in: window, inside: false)
        #expect(!card.isVisible)
    }

    @Test func commandKOpensAndClosesContextSettingsWithoutAnExtraFooterButton() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.settings", in: window) == nil)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(editor.performKeyEquivalent(with: event))
        try await fixture.wait { NSApp.windows.contains { $0.isVisible && find("ask.context.panel", in: $0) != nil } }
        #expect(editor.performKeyEquivalent(with: event))
        try await fixture.wait { !NSApp.windows.contains { $0.isVisible && find("ask.context.panel", in: $0) != nil } }
    }

    @Test func hoverUsesTheCaptureThatArrivesDuringItsDelay() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = try element("ask.context.screenshot.toggle", in: window)
        try hover(screenshot, in: window, inside: true)
        try await Task.sleep(for: .milliseconds(20))
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png)
        fixture.model.launcherDraft.screenshot = "data:image/png;base64," + png.base64EncodedString()
        fixture.model.launcherDraft.capturedAt = Date()
        try await Task.sleep(for: .milliseconds(300))
        let card = try #require(window.childWindows?.first { $0 is AskHoverCardPresenter.Panel })
        #expect(find("ask.context.screenshot.hoverPreview", in: card) != nil,
                "the hover task must use the latest capture, not its initial empty snapshot")
        try hover(screenshot, in: window, inside: false)
    }

    @Test(arguments: ["missing", "invalid", "failed"])
    func screenshotHoverWithoutAUsableCaptureShowsOnlyItsExplanation(_ state: String) async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        fixture.model.launcherDraft.capturedAt = Date()
        if state == "invalid" { fixture.model.launcherDraft.screenshot = "invalid-image" }
        if state == "failed" { fixture.model.captureWarning = L("ask.capture.unavailable") }
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = try element("ask.context.screenshot.toggle", in: window)
        try hover(screenshot, in: window, inside: true)
        try await Task.sleep(for: .milliseconds(300))
        let card = try #require(window.childWindows?.first { $0 is AskHoverCardPresenter.Panel })
        #expect(find("ask.context.screenshot.hoverPreview", in: card) == nil)
        #expect(card.frame.height < 180, "no empty image placeholder")
        try hover(screenshot, in: window, inside: false)
        #expect(!card.isVisible)
    }

    private func saveSnapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("gul235-\(name).png"))
    }

    private func click(_ element: Element, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func hover(_ element: Element, in window: NSWindow, inside: Bool) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        var delivered = false
        for view in descendants(try #require(window.contentView)) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)) else { continue }
                guard let owner = area.owner as? NSResponder else { continue }
                let event = HeaderHoverEvent(area: area, point: point, window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                delivered = true
            }
        }
        #expect(delivered, "the screenshot button has a native hover tracking area")
    }

    // MARK: - Accessibility lookup

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// SwiftUI's accessibility nodes expose the Objective-C selectors but do
    /// not conform to NSAccessibilityProtocol. KVC boxes their NSRect safely.
    private struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
        var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func find(_ value: String, attribute: String = "accessibilityIdentifier", in window: NSWindow) -> Element? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> Element? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = Element(object: object)
            if element.value(attribute) as? String == value { return element }
            for child in element.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> Element {
        try #require(find(identifier, in: window), "Missing accessibility element: \(identifier)")
    }
}

/// SwiftUI routes an enter/exit event through its tracking area. The event factory
/// leaves that area nil; supply it explicitly without moving the user's pointer.
private final class HeaderHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { eventType }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
