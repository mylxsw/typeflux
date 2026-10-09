import AppKit
import Testing
@testable import Typeflux

@MainActor
final class AskTestVoiceRecorder: AskVoiceRecording {
    var starts = 0, stops = 0, cancels = 0
    var holdStart = false, holdTranscript = false
    var startError = false
    var transcript = "spoken words"
    private var startGate: CheckedContinuation<Void, Never>?
    private var transcriptGate: CheckedContinuation<Void, Never>?
    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        if startError { throw NSError(domain: "Microphone unavailable", code: 1) }
    }
    func transcribe() async throws -> String {
        stops += 1
        if holdTranscript { await withCheckedContinuation { transcriptGate = $0 } }
        return transcript
    }
    func cancel() async { cancels += 1 }
    func releaseStart() { startGate?.resume(); startGate = nil }
    func releaseTranscript() { transcriptGate?.resume(); transcriptGate = nil }
}

/// Command-line test runners cannot become the active application. Keep the
/// destination validation deterministic while exercising real NSTextView edits.
@MainActor
final class AskTestVoiceWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@Suite("Ask voice transaction", .serialized, .exclusiveUIState)
@MainActor
struct AskVoiceInputTests {
    private func setup() async throws -> (AskVoiceInput, AskTestVoiceRecorder, AskComposerTextView.Editor, NSWindow) {
        _ = NSApplication.shared
        let voice = AskVoiceInput(), recorder = AskTestVoiceRecorder()
        voice.recorder = recorder
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.voice = voice; editor.string = "before selected after"
        editor.setSelectedRange(NSRange(location: 7, length: 8))
        let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        #expect(window.isKeyWindow)
        return (voice, recorder, editor, window)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func releaseDuringStartupInsertsAtOriginalSelectionWithoutSending() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdStart = true
        var sends = 0
        editor.onSubmit = { sends += 1 }
        #expect(voice.begin(in: editor))
        try await wait { recorder.starts == 1 }
        #expect(!voice.begin(in: editor))
        voice.stop()
        #expect(voice.phase == .transcribing)
        recorder.releaseStart()
        try await wait { !voice.isOccupied }
        #expect(editor.string == "before spoken words after")
        #expect(editor.selectedRange() == NSRange(location: 19, length: 0))
        #expect(recorder.stops == 1)
        #expect(sends == 0)
    }

    @Test func cancelDuringStartupKeepsReservationUntilCleanup() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdStart = true
        #expect(voice.begin(in: editor))
        try await wait { recorder.starts == 1 }
        voice.cancel()
        #expect(voice.phase == .idle && voice.isOccupied)
        #expect(!voice.begin(in: editor))
        recorder.releaseStart()
        try await wait { !voice.isOccupied }
        #expect(recorder.cancels == 1 && recorder.stops == 0)
        #expect(editor.string == "before selected after")
        #expect(voice.begin(in: editor))
        voice.cancel()
        try await wait { !voice.isOccupied }
        #expect(recorder.starts == 1)
    }

    @Test func lateTranscriptCannotOverwriteNewConversationOrDraft() async throws {
        for changeContext in [true, false] {
            let (voice, recorder, editor, window) = try await setup()
            recorder.holdTranscript = true
            #expect(voice.begin(in: editor))
            voice.stop()
            try await wait { recorder.stops == 1 }
            if changeContext { editor.contextID = "another-conversation" }
            else { editor.string = "edited meanwhile" }
            recorder.releaseTranscript()
            try await wait { !voice.isOccupied }
            #expect(editor.string == (changeContext ? "before selected after" : "edited meanwhile"))
            window.close()
        }
    }

    @Test func escapeCancelsTranscriptionAndFocusLossCancelsListening() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdTranscript = true
        #expect(voice.begin(in: editor))
        voice.stop()
        try await wait { recorder.stops == 1 }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        recorder.releaseTranscript()
        try await wait { !voice.isOccupied }
        #expect(editor.string == "before selected after")
        #expect(voice.begin(in: editor))
        try await wait { recorder.starts == 2 }
        window.makeFirstResponder(nil)
        try await wait { !voice.isOccupied }
        #expect(recorder.cancels == 2)
    }

    @Test func permissionFailureIsInlineAndMarkedTextCannotStartRecording() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.startError = true
        #expect(voice.begin(in: editor))
        try await wait { !voice.isOccupied }
        #expect(voice.error != nil)
        #expect(editor.string == "before selected after")
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!voice.begin(in: editor))
    }

    @Test func shortFnReleaseLocksButMouseReleaseAlwaysStops() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        #expect(voice.begin(in: editor))
        try await wait { recorder.starts == 1 }
        voice.releaseHotkey()
        #expect(voice.phase == .listening)
        voice.promoteHotkey(at: 10, locked: false)
        voice.releaseHotkey(at: 20)
        #expect(voice.phase == .listening)
        voice.stop()
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
    }

    @Test func buttonClickLocksAndSecondClickTranscribesWithoutSending() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        var sends = 0
        editor.onSubmit = { sends += 1 }
        #expect(voice.pressButton(in: editor, at: 10))
        voice.releaseButton(inside: true, at: 10.1)
        try await wait { recorder.starts == 1 }
        voice.releaseHotkey() // An unrelated key release must not stop button recording.
        #expect(voice.phase == .listening)
        #expect(!voice.pressButton(in: editor, at: 11))
        voice.releaseButton(inside: true, at: 11.1)
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
        #expect(editor.string == "before spoken words after")
        #expect(sends == 0)
    }

    @Test func buttonHoldReleaseDuringStartupTranscribesOnceEvenOutside() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdStart = true
        #expect(voice.pressButton(in: editor, at: 10))
        try await wait { recorder.starts == 1 }
        voice.releaseButton(inside: false, at: 10.5)
        #expect(voice.phase == .transcribing)
        #expect(!voice.pressButton(in: editor, at: 11))
        voice.releaseButton(inside: true, at: 12)
        recorder.releaseStart()
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
        #expect(editor.string == "before spoken words after")
    }

    @Test func shortOutsideReleaseCancelsAndLateReleaseCannotStopNewRecording() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        #expect(voice.pressButton(in: editor, at: 10))
        try await wait { recorder.starts == 1 }
        voice.releaseButton(inside: false, at: 10.1)
        try await wait { !voice.isOccupied }
        #expect(recorder.cancels == 1 && recorder.stops == 0)
        #expect(voice.begin(in: editor))
        voice.releaseButton(inside: true, at: 12)
        #expect(voice.phase == .listening)
        voice.cancel()
        try await wait { !voice.isOccupied }
    }

    @Test func longShortcutReleaseTranscribesAndOtherEditorCannotStopRecording() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        #expect(voice.begin(in: editor))
        let otherEditor = AskComposerTextView.Editor()
        #expect(!voice.pressButton(in: otherEditor))
        #expect(voice.phase == .listening)
        try await Task.sleep(for: .seconds(WorkflowController.tapToLockThreshold + 0.05))
        voice.releaseHotkey()
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
        #expect(editor.string == "before spoken words after")
    }

    @Test func physicalReleaseDuringSlowStartupLocksUntilExplicitStop() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        var now = 10.0
        voice.monotonicNow = { now }
        recorder.holdStart = true
        #expect(voice.begin(in: editor, hotkeyUptime: now))
        try await wait { recorder.starts == 1 }
        now = 12
        voice.releaseHotkey(at: now)
        #expect(voice.phase == .listening)
        recorder.releaseStart()
        try await Task.sleep(for: .milliseconds(10))
        voice.releaseHotkey(at: 15)
        #expect(voice.phase == .listening)
        voice.stop()
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
    }

    @Test func delayedDispatchUsesPhysicalPressTimeAndMinimumAudioDuration() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        var now = 12.0
        voice.monotonicNow = { now }
        #expect(voice.begin(in: editor, hotkeyUptime: 10))
        try await wait { recorder.starts == 1 }
        now = 12.1
        voice.releaseHotkey(at: now)
        #expect(voice.phase == .listening)
        voice.stop()
        try await wait { !voice.isOccupied }
        now = 20
        #expect(voice.begin(in: editor, hotkeyUptime: 18))
        try await wait { recorder.starts == 2 }
        now = 20.5
        voice.releaseHotkey(at: now)
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 2)
    }

    @Test func buttonHelpUsesConfiguredShortcutAndOmitsUnassignedShortcut() {
        let binding = HotkeyBinding(keyCode: 0, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
        #expect(AskVoiceButton.help(shortcut: binding).contains(HotkeyFormat.display(binding)))
        #expect(AskVoiceButton.help(shortcut: nil) == L("ask.voice.buttonHint"))
    }

    @Test func historyPullRequiresTopStartThresholdAndRelease() {
        var gesture = AskHistoryPullGesture()
        gesture.begin(atTop: false)
        gesture.update(overscroll: 200)
        #expect({ gesture.end() }() == false)
        gesture.begin(atTop: true)
        gesture.update(overscroll: AskHistoryPullGesture.threshold - 1)
        #expect({ gesture.end() }() == false)
        gesture.begin(atTop: true)
        gesture.update(overscroll: AskHistoryPullGesture.threshold)
        gesture.update(overscroll: 10) // letting the band recede keeps the peak
        #expect({ gesture.end() }() == true)
        #expect({ gesture.end() }() == false)
        gesture.begin(atTop: true)
        gesture.update(overscroll: 200)
        #expect({ gesture.end(cancelled: true) }() == false)
        gesture.update(overscroll: 200) // momentum bounce after release is ignored
        #expect({ gesture.end() }() == false)
    }

    @Test func overscrollMeasuresDistancePastTheTopEdge() {
        let document = NSRect(x: 0, y: 0, width: 200, height: 600)
        #expect(AskHistoryPullGesture.overscroll(bounds: NSRect(x: 0, y: -30, width: 200, height: 200), documentBounds: document, flipped: true) == 30)
        #expect(AskHistoryPullGesture.overscroll(bounds: NSRect(x: 0, y: 10, width: 200, height: 200), documentBounds: document, flipped: true) == 0)
        #expect(AskHistoryPullGesture.overscroll(bounds: NSRect(x: 0, y: -10, width: 200, height: 200), documentBounds: document, flipped: true, topInset: 20) == 0)
        #expect(AskHistoryPullGesture.overscroll(bounds: NSRect(x: 0, y: 440, width: 200, height: 200), documentBounds: document, flipped: false) == 40)
        #expect(AskHistoryPullGesture.overscroll(bounds: NSRect(x: 0, y: 300, width: 200, height: 200), documentBounds: document, flipped: false) == 0)
    }
}
