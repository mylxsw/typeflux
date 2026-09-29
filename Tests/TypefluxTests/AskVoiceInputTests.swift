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

@Suite("Ask voice transaction", .serialized)
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
        voice.releaseHotkey()
        #expect(voice.phase == .listening)
        voice.stop()
        try await wait { !voice.isOccupied }
        #expect(recorder.stops == 1)
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
