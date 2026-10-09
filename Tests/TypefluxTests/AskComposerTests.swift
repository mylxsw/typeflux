import AppKit
import Testing
@testable import Typeflux

@Suite("Ask native composer", .exclusiveUIState)
@MainActor
struct AskComposerTests {
    @Test func nativeHoldAllowsSelectionAndIMEToKeepTheirMeanings() throws {
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let voice = AskVoiceInput(); editor.voice = voice
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        #expect(editor.acceptsFirstMouse(for: nil))
        #expect(AskComposerTextView.Editor.mouseHoldDelay == 0.35)
        func event(clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        #expect(editor.canStartMouseHold(with: try event()))
        #expect(!editor.canStartMouseHold(with: try event(clicks: 2)))
        #expect(!editor.canStartMouseHold(with: try event(flags: .shift)))
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.canStartMouseHold(with: try event()))
    }

    @Test func returnEscapeAndIMECompositionHaveSeparateMeanings() throws {
        let editor = AskComposerTextView.Editor()
        var sends = 0, dismissals = 0
        editor.onSubmit = { sends += 1 }
        editor.onDismiss = { dismissals += 1 }
        func event(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code))
        }
        editor.string = "Question"
        editor.keyDown(with: try event(36, "\r"))
        #expect(sends == 1)
        editor.keyDown(with: try event(53, "\u{1b}"))
        #expect(dismissals == 1)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: try event(36, "\r", flags: .shift))
        #expect(sends == 1)
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: try event(36, "\r"))
        #expect(sends == 1)
    }
}
