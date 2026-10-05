import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Records the live handlers so a test can play the microphone and recogniser.
@MainActor
final class AskLiveTestRecorder: AskVoiceRecording {
    var level: (@MainActor (Float) -> Void)?
    var transcript: (@MainActor (String, Bool) -> Void)?
    var holdTranscript = false
    private(set) var stops = 0
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?

    func observe(level: @escaping @MainActor (Float) -> Void,
                 transcript: @escaping @MainActor (String, Bool) -> Void) {
        self.level = level
        self.transcript = transcript
    }
    func start() async throws {}
    func transcribe() async throws -> String {
        stops += 1
        if holdTranscript, !released { await withCheckedContinuation { gate = $0 } }
        return "done"
    }
    func cancel() async {}
    /// Lets a held transcription finish, now or as soon as it starts.
    func release() { released = true; gate?.resume(); gate = nil }
}

@Suite("Ask voice live data", .serialized)
@MainActor
struct AskVoiceLiveTests {
    @Test func levelsArePublishedAtMostEveryIntervalKeepingThePeak() {
        let live = AskVoiceLive()
        var clock: TimeInterval = 10
        live.now = { clock }
        live.receive(level: 0.3)
        #expect(live.levels.last == 0.3)
        #expect(live.levels.count == AskVoiceLive.barCount)
        clock += 0.01
        live.receive(level: 0.9)
        clock += 0.01
        live.receive(level: 0.2)
        #expect(live.levels.last == 0.3, "too soon for another bar")
        clock += AskVoiceLive.levelInterval
        live.receive(level: 0.1)
        #expect(live.levels.last == 0.9, "the loudest level since the last bar")
        #expect(live.levels.dropLast().last == 0.3)
        #expect(live.levels.count == AskVoiceLive.barCount)
    }

    @Test func levelsAreClampedToTheUnitRange() {
        let live = AskVoiceLive()
        var clock: TimeInterval = 0
        live.now = { clock }
        live.receive(level: 4)
        #expect(live.levels.last == 1)
        clock += 1
        live.receive(level: -1)
        #expect(live.levels.last == 0)
        clock += 1
        live.receive(level: .nan)
        #expect(live.levels.last == 0)
    }

    @Test func resetClearsLevelsTextAndStart() {
        let live = AskVoiceLive()
        let start = Date()
        live.reset(startedAt: start)
        live.receive(level: 0.5)
        live.receive(text: "hello", isFinal: false)
        #expect(live.startedAt == start)
        live.reset()
        #expect(live.levels == AskVoiceLive.silence)
        #expect(live.transcript.isEmpty)
        #expect(live.startedAt == nil)
    }

    @Test func transcriptSplitsCommittedTextFromTheGuessAfterIt() {
        var transcript = AskVoiceTranscript()
        transcript.apply("  ", isFinal: true)
        #expect(transcript.isEmpty)
        transcript.apply("帮我翻译", isFinal: false)
        #expect(transcript.confirmed.isEmpty)
        #expect(transcript.pending == "帮我翻译")
        transcript.apply("帮我翻译成英文，", isFinal: true)
        #expect(transcript.confirmed == "帮我翻译成英文，")
        #expect(transcript.pending.isEmpty)
        transcript.apply("帮我翻译成英文，语气正式", isFinal: false)
        #expect(transcript.confirmed == "帮我翻译成英文，")
        #expect(transcript.pending == "语气正式")
        transcript.apply("完全不同的结果", isFinal: false)
        #expect(transcript.confirmed.isEmpty, "a rewrite no longer starts with the committed text")
        #expect(transcript.pending == "完全不同的结果")
    }

    @Test func waveformBarsGrowWithTheLevel() {
        #expect(AskLevelWaveform.barHeight(level: 0) == 4)
        #expect(AskLevelWaveform.barHeight(level: 1) == AskLevelWaveform.maximumHeight)
        #expect(AskLevelWaveform.barHeight(level: 2) == AskLevelWaveform.maximumHeight)
        #expect(AskLevelWaveform.barHeight(level: .nan) == 4)
        #expect(AskVoiceOrb.scale(level: 0) == 0.9)
        #expect(AskVoiceOrb.scale(level: 1) == 1.15)
    }

    private func setup() async throws -> (AskVoiceInput, AskLiveTestRecorder, AskComposerTextView.Editor, NSWindow) {
        _ = NSApplication.shared
        let voice = AskVoiceInput(), recorder = AskLiveTestRecorder()
        voice.recorder = recorder
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.voice = voice
        let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        return (voice, recorder, editor, window)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func recordingFeedsTheLiveDataAndClearsItAfterwards() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdTranscript = true
        #expect(voice.begin(in: editor))
        #expect(voice.live.startedAt != nil)
        recorder.level?(0.6)
        recorder.transcript?("hello wor", false)
        #expect(voice.live.levels.last == 0.6)
        #expect(voice.live.transcript.pending == "hello wor")
        voice.stop()
        recorder.level?(0.9)
        #expect(voice.live.levels.last == 0.6, "levels stop once listening ends")
        recorder.transcript?("hello world", true)
        #expect(voice.live.transcript.confirmed == "hello world", "words still arrive while recognising")
        recorder.release()
        try await wait { !voice.isOccupied }
        #expect(editor.string == "done")
        #expect(voice.live.transcript.isEmpty)
        #expect(voice.live.startedAt == nil)
        #expect(voice.live.levels == AskVoiceLive.silence)
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func returnFinishesRecordingAndOtherKeysWait() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        recorder.holdTranscript = true
        #expect(voice.begin(in: editor))
        editor.keyDown(with: try key(0, "a"))
        #expect(voice.phase == .listening, "typing does not end the recording")
        editor.contextID = "another"
        editor.keyDown(with: try key(36, "\r"))
        #expect(voice.phase == .listening, "only the recording's own editor finishes it")
        editor.contextID = "launcher"
        editor.keyDown(with: try key(36, "\r"))
        #expect(voice.phase == .transcribing)
        recorder.release()
        try await wait { !voice.isOccupied }
        #expect(editor.string == "done")
    }

    @Test func deleteInAnEmptyEditorRemovesContextFirst() async throws {
        let (_, _, editor, window) = try await setup()
        defer { window.close() }
        var asked = 0
        editor.onEmptyBackspace = { asked += 1; return true }
        editor.keyDown(with: try key(51, "\u{8}"))
        #expect(asked == 1)
        editor.keyDown(with: try key(51, "\u{8}", flags: .option))
        #expect(asked == 1, "modified deletes keep their text meaning")
        editor.string = "ab"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.keyDown(with: try key(51, "\u{8}"))
        #expect(asked == 1, "text is deleted before any context")
        #expect(editor.string == "a")
        editor.string = ""
        editor.onEmptyBackspace = { asked += 1; return false }
        editor.keyDown(with: try key(51, "\u{8}"))
        #expect(asked == 2)
    }

    @Test func commandKOpensTheContextPanel() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        var opened = 0
        editor.onContextShortcut = { opened += 1; return true }
        #expect(editor.performKeyEquivalent(with: try key(40, "k", flags: .command)))
        #expect(opened == 1)
        #expect(!AskComposerTextView.Editor.isContextShortcut(try key(40, "k", flags: [.command, .shift])))
        #expect(!AskComposerTextView.Editor.isContextShortcut(try key(40, "k")))
        #expect(!AskComposerTextView.Editor.isContextShortcut(try key(38, "j", flags: .command)))
        recorder.holdTranscript = true
        #expect(voice.begin(in: editor))
        _ = editor.performKeyEquivalent(with: try key(40, "k", flags: .command))
        #expect(opened == 1, "not while recording")
        voice.cancel()
        recorder.release()
        try await wait { !voice.isOccupied }
    }

    @Test func cancelledRecordingIgnoresLateLiveData() async throws {
        let (voice, recorder, editor, window) = try await setup()
        defer { window.close() }
        #expect(voice.begin(in: editor))
        let staleLevel = recorder.level, staleTranscript = recorder.transcript
        voice.cancel()
        #expect(voice.live.startedAt == nil)
        staleLevel?(0.8)
        staleTranscript?("late", true)
        #expect(voice.live.levels == AskVoiceLive.silence)
        #expect(voice.live.transcript.isEmpty)
        try await wait { !voice.isOccupied }
        #expect(voice.begin(in: editor))
        staleTranscript?("from the old recording", false)
        #expect(voice.live.transcript.isEmpty, "an earlier recording's handler cannot write into a new one")
        recorder.transcript?("new", false)
        #expect(voice.live.transcript.pending == "new")
        voice.cancel()
        try await wait { !voice.isOccupied }
    }
}
