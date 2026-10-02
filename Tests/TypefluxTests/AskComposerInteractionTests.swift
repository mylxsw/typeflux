import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer event delivery", .serialized)
@MainActor
struct AskComposerInteractionTests {
    @Test func idleUpdatesDoNotCycleFocusOrResizeTheEditor() async throws {
        let fixture = try AskTestFixture()
        let (window, editor) = try await host(AskConversationView(model: fixture.model))
        defer { window.close() }
        var focusChanges = 0
        let observation = fixture.model.voiceInput.$focusedContext.dropFirst().sink { _ in focusChanges += 1 }
        defer { observation.cancel() }
        let initialFrame = editor.frame
        for _ in 0..<10 {
            fixture.model.objectWillChange.send()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(focusChanges == 0)
        #expect(editor.frame == initialFrame)
        #expect(editor.frame.height >= editor.enclosingScrollView!.contentSize.height)
    }

    @Test func twoWindowsDoNotCompeteForComposerFocus() async throws {
        let fixture = try AskTestFixture()
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let (launcher, launcherEditor) = try await host(AskLauncherView(model: fixture.model, onDismiss: {}))
        launcher.composerIsKey = false
        launcher.orderOut(nil)
        let (chat, chatEditor) = try await host(AskConversationView(model: fixture.model))
        defer { launcher.close(); chat.close() }
        var changes = 0
        let observation = fixture.model.voiceInput.$focusedContext.dropFirst().sink { _ in changes += 1 }
        defer { observation.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)
        #expect(fixture.model.voiceInput.focusedContext == chatEditor.contextID)
        #expect(launcher.firstResponder === launcherEditor)
        try await holdAndTranscribe(window: chat, editor: chatEditor, fixture: fixture, recorder: recorder, launcher: false)

        // Returning to the existing launcher must transfer focus without creating
        // another editor, and recording must still work on the second surface.
        chat.composerIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: chat)
        launcher.composerIsKey = true
        launcher.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: launcher)
        #expect(fixture.model.voiceInput.focusedContext == "launcher")
        try await holdAndTranscribe(window: launcher, editor: launcherEditor, fixture: fixture, recorder: recorder, launcher: true)
    }

    @Test func windowMouseEventsHoldRecordAndReleaseTranscribeInBothComposers() async throws {
        for launcher in [true, false] {
            let fixture = try AskTestFixture()
            let recorder = AskTestVoiceRecorder()
            recorder.holdTranscript = true
            fixture.model.voiceInput.recorder = recorder
            let view = launcher ? AnyView(AskLauncherView(model: fixture.model, onDismiss: {})) : AnyView(AskConversationView(model: fixture.model))
            let (window, editor) = try await host(view)
            defer { window.close() }
            try await holdAndTranscribe(window: window, editor: editor, fixture: fixture, recorder: recorder, launcher: launcher)
        }
    }

    @Test func shortClickAndDragStillEditWithoutStartingVoice() async throws {
        let fixture = try AskTestFixture()
        fixture.model.draft.text = "Select these words with the mouse"
        let recorder = AskTestVoiceRecorder()
        fixture.model.voiceInput.recorder = recorder
        let (window, editor) = try await host(AskConversationView(model: fixture.model))
        defer { window.close() }
        let point = editor.convert(NSPoint(x: 8, y: 8), to: nil)
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        NSApp.sendEvent(try mouse(.leftMouseUp, window: window, point: point))
        #expect(editor.selectedRange().length == 0)
        let end = NSPoint(x: point.x + 130, y: point.y)
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        NSApp.sendEvent(try mouse(.leftMouseDragged, window: window, point: end))
        NSApp.sendEvent(try mouse(.leftMouseUp, window: window, point: end))
        try await Task.sleep(for: .milliseconds(450))
        #expect(editor.selectedRange().length > 0)
        #expect(recorder.starts == 0)
        #expect(fixture.model.draft.text == "Select these words with the mouse")
    }

    @Test func releaseInAnotherWindowStopsAndFillsTheOriginalEditor() async throws {
        let fixture = try AskTestFixture()
        let recorder = AskTestVoiceRecorder()
        fixture.model.voiceInput.recorder = recorder
        let (window, editor) = try await host(AskConversationView(model: fixture.model))
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        let point = editor.convert(NSPoint(x: 20, y: 8), to: nil)
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        try await fixture.wait { recorder.starts == 1 }
        #expect(recorder.starts == 1)
        NSApp.sendEvent(try mouse(.leftMouseUp, window: other, point: .zero))
        try await fixture.wait { !fixture.model.voiceInput.isOccupied }
        #expect(recorder.stops == 1)
        #expect(fixture.model.draft.text == "spoken words")
    }

    @Test func escapeBeforeThresholdAndFocusLossDuringRecordingCancelTheHold() async throws {
        let fixture = try AskTestFixture()
        let recorder = AskTestVoiceRecorder()
        fixture.model.voiceInput.recorder = recorder
        let (window, editor) = try await host(AskConversationView(model: fixture.model))
        defer { window.close() }
        let point = editor.convert(NSPoint(x: 20, y: 8), to: nil)
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        try await Task.sleep(for: .milliseconds(450))
        #expect(recorder.starts == 0)
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        try await fixture.wait { recorder.starts == 1 }
        #expect(recorder.starts == 1)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await fixture.wait { !fixture.model.voiceInput.isOccupied }
        #expect(recorder.cancels == 1)
        #expect(recorder.stops == 0)
        #expect(fixture.model.draft.text.isEmpty)
    }

    @Test func voiceButtonClickAndHoldWorkInBothComposers() async throws {
        for launcher in [true, false] {
            let fixture = try AskTestFixture()
            let recorder = AskTestVoiceRecorder()
            recorder.holdTranscript = true
            fixture.model.voiceInput.recorder = recorder
            let view = launcher ? AnyView(AskLauncherView(model: fixture.model, onDismiss: {})) : AnyView(AskConversationView(model: fixture.model))
            let (window, editor) = try await host(view, size: NSSize(width: launcher ? 680 : 760, height: 600))
            defer { window.close() }
            func findButton(_ view: NSView) -> AskVoiceButton.Control? {
                (view as? AskVoiceButton.Control) ?? view.subviews.lazy.compactMap(findButton).first
            }
            let button = try #require(findButton(window.contentView!))
            #expect(button.title.isEmpty)
            #expect(button.frame.size == NSSize(width: AskMetrics.composerControlHeight,
                                                height: AskMetrics.composerControlHeight))
            #expect(button.accessibilityLabel() == L("ask.voice.input"))
            var restingFrame = button.convert(button.bounds, to: nil)
            let hover = try mouse(.mouseMoved, window: window, point: restingFrame.origin)
            button.mouseEntered(with: hover)
            #expect(button.hovered)
            button.highlight(true)
            #expect(button.isHighlighted)
            button.highlight(false)
            button.mouseExited(with: hover)
            #expect(!button.hovered)
            #expect(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)

            let shortcut = HotkeyBinding(keyCode: 0, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
            fixture.model.modelLibrary.settings.activationHotkey = shortcut
            try await fixture.wait { button.toolTip?.contains(HotkeyFormat.display(shortcut)) == true }
            for hold in [false, true] {
                // A filled launcher drops its suggestions, so each round measures its own resting place.
                restingFrame = button.convert(button.bounds, to: nil)
                let starts = recorder.starts, stops = recorder.stops
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
                if hold { try await Task.sleep(for: .milliseconds(400)) }
                NSApp.sendEvent(try mouse(.leftMouseUp, window: window, point: point))
                try await fixture.wait { recorder.starts == starts + 1 }
                #expect(window.firstResponder === editor)
                if !hold {
                    #expect(fixture.model.voiceInput.phase == .listening)
                    try await fixture.wait { button.accessibilityLabel() == L("ask.voice.stop") }
                    #expect(button.convert(button.bounds, to: nil) == restingFrame)
                    NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
                    NSApp.sendEvent(try mouse(.leftMouseUp, window: window, point: point))
                }
                try await fixture.wait { recorder.stops == stops + 1 }
                try await fixture.wait { !button.isEnabled }
                #expect(button.accessibilityLabel() == L("ask.voice.transcribing"))
                #expect(button.visualPhase == .transcribing)
                #expect(button.convert(button.bounds, to: nil) == restingFrame)

                #expect(!(launcher ? fixture.model.canSendLauncher : fixture.model.canSend))
                recorder.releaseTranscript()
                try await fixture.wait { !fixture.model.voiceInput.isOccupied }
                try await fixture.wait { button.isEnabled }
            }
            // Accessibility activation must also start and stop without stealing focus.
            #expect(button.sendAction(button.action, to: button.target))
            try await fixture.wait { fixture.model.voiceInput.phase == .listening }
            #expect(button.sendAction(button.action, to: button.target))
            try await fixture.wait { recorder.stops == 3 }
            recorder.releaseTranscript()
            try await fixture.wait { !fixture.model.voiceInput.isOccupied }
            #expect((launcher ? fixture.model.launcherDraft.text : fixture.model.draft.text) == "spoken wordsspoken wordsspoken words")
            #expect(await fixture.api.sends.isEmpty)
        }
    }

    private func holdAndTranscribe(window: NSWindow, editor: AskComposerTextView.Editor, fixture: AskTestFixture, recorder: AskTestVoiceRecorder, launcher: Bool) async throws {
        let starts = recorder.starts, stops = recorder.stops
        // Press the blank part of the editor, not just the existing glyphs.
        let point = editor.enclosingScrollView!.convert(NSPoint(x: 20, y: 8), to: nil)
        NSApp.sendEvent(try mouse(.mouseMoved, window: window, point: point))
        NSApp.sendEvent(try mouse(.leftMouseDown, window: window, point: point))
        try await Task.sleep(for: .milliseconds(100))
        NSApp.sendEvent(try mouse(.leftMouseDragged, window: window, point: NSPoint(x: point.x + 1, y: point.y)))
        try await fixture.wait { recorder.starts == starts + 1 && fixture.model.voiceInput.phase == .listening }
        #expect(recorder.starts == starts + 1)
        #expect(fixture.model.voiceInput.phase == .listening)
        // SwiftUI updates while recording must neither steal focus nor cancel it.
        fixture.model.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.model.voiceInput.phase == .listening)
        NSApp.sendEvent(try mouse(.leftMouseUp, window: window, point: point))
        try await fixture.wait { recorder.stops == stops + 1 }
        #expect(fixture.model.voiceInput.phase == .transcribing)
        #expect(!(launcher ? fixture.model.canSendLauncher : fixture.model.canSend))
        recorder.releaseTranscript()
        try await fixture.wait { !fixture.model.voiceInput.isOccupied }
        #expect((launcher ? fixture.model.launcherDraft.text : fixture.model.draft.text) == "spoken words")
        #expect(await fixture.api.sends.isEmpty)
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 900, height: 600)) async throws -> (ComposerEventWindow, AskComposerTextView.Editor) {
        let window = ComposerEventWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting; window.orderFront(nil)
        func editors(_ view: NSView) -> [AskComposerTextView.Editor] {
            (view as? AskComposerTextView.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        var found: AskComposerTextView.Editor?
        for _ in 0 ..< 1000 {
            hosting.layoutSubtreeIfNeeded()
            found = editors(hosting).first
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let editor = try #require(found)
        // SwiftUI keeps relaying out after the editor appears; wait until its frame stops moving.
        var stableFrames = 0
        var lastFrame = NSRect.null
        for _ in 0 ..< 1000 where stableFrames < 3 {
            hosting.layoutSubtreeIfNeeded()
            let frame = editor.convert(editor.bounds, to: nil)
            stableFrames = frame == lastFrame ? stableFrames + 1 : 0
            lastFrame = frame
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0 ..< 1000 {
            window.makeFirstResponder(editor)
            if window.firstResponder === editor { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        return (window, editor)
    }

    private func mouse(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}

@MainActor
private final class ComposerEventWindow: NSWindow {
    var composerIsKey = true
    override var isKeyWindow: Bool { composerIsKey }
    override var canBecomeKey: Bool { true }
}
