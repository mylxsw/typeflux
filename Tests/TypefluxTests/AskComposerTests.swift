import AppKit
import Testing
@testable import Typeflux

@Suite("Ask native composer")
@MainActor
struct AskComposerTests {
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
