import AppKit
import Testing
@testable import Typeflux

@Suite("Emoji navigation from the launcher editor", .serialized, .exclusiveUIState)
@MainActor
struct AskEmojiKeyboardTests {
    private func pressHorizontal(_ code: UInt16, in launcher: AskQuickResultsInteractionTests.Launcher,
                                 flags: NSEvent.ModifierFlags = []) throws {
        let characters = code == 123 ? "\u{f702}" : "\u{f703}"
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: launcher.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
        launcher.editor.keyDown(with: event)
    }

    private func launcher(query: String) async throws -> AskQuickResultsInteractionTests.Launcher {
        let sequences = [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗"
        ]
        let catalog = EmojiCatalog(schema: 1, entries: sequences.enumerated().map { index, sequence in
            EmojiSearchTests.entry(sequence, "grid \(index)", ["grid"])
        })
        let service = EmojiSearchService(load: { catalog }, supported: { _ in true })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: query, waitForSearch: false,
            prepare: { model in
                model.plugins.replacePlugins([AskEmojiPlugin(service: service)])
                model.plugins.enter(AskEmojiPlugin.keywords[0])
            }
        )
        try await launcher.fixture.wait {
            launcher.fixture.model.plugins.isPlanCurrent
                && launcher.fixture.model.plugins.output?.emoji?.results.count == sequences.count
        }
        #expect(launcher.window.makeFirstResponder(launcher.editor))
        return launcher
    }

    @Test(arguments: ["", "grid"])
    func `all four arrows navigate results while the search editor retains focus`(_ query: String) async throws {
        let launcher = try await launcher(query: query)
        defer { launcher.close() }
        let session = launcher.fixture.model.plugins
        #expect(session.output?.selectedItem == 0)
        // Horizontal navigation must work with the caret inside the query too.
        launcher.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await launcher.press(124)
        #expect(session.output?.selectedItem == 1)
        try await launcher.press(125)
        #expect(session.output?.selectedItem == 9)
        try await launcher.press(123)
        #expect(session.output?.selectedItem == 8)
        try await launcher.press(126)
        #expect(session.output?.selectedItem == 0)
        try await launcher.press(123)
        #expect(session.output?.selectedItem == 0)
        #expect(session.selectItem(17))
        try await launcher.press(124)
        #expect(session.output?.selectedItem == 17)
        #expect(launcher.window.firstResponder === launcher.editor)
        #expect(launcher.editor.string == query)
        #expect(launcher.fixture.model.launcherDraft.text == query)
    }

    @Test func `modified arrows and IME composition do not navigate emoji`() async throws {
        let launcher = try await launcher(query: "grid")
        defer { launcher.close() }
        let session = launcher.fixture.model.plugins
        #expect(session.selectItem(2))
        for modifier in [NSEvent.ModifierFlags.shift, .command, .option, .control] {
            try await launcher.press(123, modifier)
            try await launcher.press(124, modifier)
            #expect(session.output?.selectedItem == 2)
        }
        var horizontalMoves = 0
        var commandKeys = 0
        for code: UInt16 in [123, 124] {
            launcher.editor.setMarkedText(
                "候选", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(launcher.editor.hasMarkedText())
            launcher.editor.onHorizontalArrow = { _ in horizontalMoves += 1; return true }
            launcher.editor.onCommandKey = { _ in commandKeys += 1; return true }
            try pressHorizontal(code, in: launcher)
        }
        #expect(horizontalMoves == 0 && commandKeys == 0, "IME arrows must reach the native input context")
    }

    @Test func `ordinary launcher text retains horizontal caret movement and selection`() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "ordinary text", waitForSearch: false)
        defer { launcher.close() }
        #expect(launcher.window.makeFirstResponder(launcher.editor))
        launcher.editor.setSelectedRange(NSRange(location: 4, length: 0))
        try pressHorizontal(123, in: launcher)
        #expect(launcher.editor.selectedRange() == NSRange(location: 3, length: 0))
        try pressHorizontal(124, in: launcher)
        #expect(launcher.editor.selectedRange() == NSRange(location: 4, length: 0))
        try pressHorizontal(123, in: launcher, flags: .shift)
        #expect(launcher.editor.selectedRange() == NSRange(location: 3, length: 1))
        #expect(launcher.editor.string == "ordinary text")
    }

    @Test func `an empty emoji search keeps horizontal arrows available for editing`() async throws {
        let launcher = try await launcher(query: "grid")
        defer { launcher.close() }
        launcher.editor.selectAll(nil)
        launcher.editor.insertText("missing", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.fixture.wait {
            launcher.fixture.model.plugins.isPlanCurrent
                && launcher.fixture.model.plugins.output?.emoji?.results.isEmpty == true
        }
        launcher.editor.setSelectedRange(NSRange(location: 4, length: 0))
        try pressHorizontal(123, in: launcher)
        #expect(launcher.editor.selectedRange() == NSRange(location: 3, length: 0))
        try pressHorizontal(124, in: launcher)
        #expect(launcher.editor.selectedRange() == NSRange(location: 4, length: 0))
        #expect(launcher.editor.string == "missing")
    }
}
