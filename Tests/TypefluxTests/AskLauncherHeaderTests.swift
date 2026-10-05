import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The launcher rendered in a real window: the context token leads the editor's
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
        let hosting = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {},
                                                              onHeightChange: { reported.height = $0 }))
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
        fixture.model.launcherDraft = draft
    }

    @Test func capturedContextIsOneTokenBeforeTheEditor() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let token = try element("ask.context.token", in: window)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        let scroll = try #require(editor.enclosingScrollView)
        let editorFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        #expect(token.frame.maxX <= editorFrame.minX + 1, "the token leads the editor")
        #expect(abs(token.frame.midY - editorFrame.midY) < 12, "on the same row")
        #expect(token.frame.width < 260, "a short title, not the full app and window name")
        // Captured content is no longer a row of chips above the editor.
        #expect(find("ask.content.source.preview", in: window) == nil)
        #expect(find("ask.content.selection.preview", in: window) == nil)
        // The model menu sits in the bottom bar, below the suggestions.
        let model = try element("ask.composer.model", in: window)
        #expect(model.frame.maxY < editorFrame.minY - AskLauncherSuggestions.height + 8)
        let expected = AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: true)
        #expect(abs(reported.height - expected) <= 4, "reported \(reported.height), expected \(expected)")
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
        #expect(find("ask.context.token", in: window) == nil, "the recording dot takes the token's place")
        #expect(find("ask.composer.send", in: window) == nil)
        #expect(find("ask.composer.model", in: window) != nil, "the bottom bar stays")
        // The panel takes the suggestions' height, so the launcher does not move.
        #expect(abs(reported.height - resting) <= 1, "recording \(reported.height), resting \(resting)")
        fixture.model.voiceInput.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.voice.panel", in: window) == nil)
        #expect(find("ask.context.token", in: window) != nil)
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
        var identifier: String? { value("accessibilityIdentifier") as? String }
        var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func find(_ identifier: String, in window: NSWindow) -> Element? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> Element? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = Element(object: object)
            if element.identifier == identifier { return element }
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
