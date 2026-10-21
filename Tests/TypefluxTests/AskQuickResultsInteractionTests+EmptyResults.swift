import AppKit
import Foundation
import Testing
@testable import Typeflux

/// The results area offers something whenever it would be empty: starters for a
/// question with context, and Ask AI first when a search finds nothing.
extension AskQuickResultsInteractionTests {
    /// Arrow keys and Tab reach the results area's own monitor through the application.
    private func send(_ keyCode: UInt16, to launcher: Launcher) async throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: launcher.window.windowNumber, context: nil,
                                                  characters: keyCode == Self.tab ? "\t" : "",
                                                  charactersIgnoringModifiers: keyCode == Self.tab ? "\t" : "",
                                                  isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(50))
    }

    private static let report = AskAttachment(kind: .file, name: "Report.pdf", byteSize: 2048,
                                              text: "Revenue grew 12%.", pages: 2)

    @Test func aStarterFillsTheEditorOrSendsWithTheContext() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            model.launcherDraft.attachments = [Self.report]
            try await Task.sleep(for: .milliseconds(100))
            let starters = AskLauncherContextHome.starters(for: .file)

            // ↓ enters the starters, Tab puts the highlighted one in the editor.
            try await send(Self.down, to: launcher)
            try await send(Self.tab, to: launcher)
            #expect(model.launcherDraft.text == starters[0].prompt)
            #expect(!model.plugins.isActive, "a starter's first word is not a keyword")
            #expect(await launcher.fixture.api.sends.isEmpty, "filling never sends")

            // Clearing the text brings the starters back; ↓ ↓ Return sends the second.
            model.launcherDraft.text = ""
            try await Task.sleep(for: .milliseconds(50))
            try await send(Self.down, to: launcher)
            try await send(Self.down, to: launcher)
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            let sent = await launcher.fixture.api.sends.first
            #expect(sent?.text == starters[1].prompt)
            #expect(sent?.attachments?.map(\.name) == ["Report.pdf"])
        }
    }

    @Test func returnWithoutAHighlightedStarterStillSendsTheContextAlone() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            model.launcherDraft.attachments = [Self.report]
            try await Task.sleep(for: .milliseconds(100))
            // ↑ in the editor is not the starters' to take: ↓ then ↑ returns to the editor.
            try await send(Self.down, to: launcher)
            try await send(Self.up, to: launcher)
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(await launcher.fixture.api.sends.first?.attachments?.map(\.name) == ["Report.pdf"])
        }
    }

    @Test func aSearchWithoutMatchesAsksTheAIOnReturn() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "zqxv weekly summary")
            defer { launcher.close() }
            let model = launcher.fixture.model
            #expect(model.quickSearch.presentation == nil, "nothing matched")
            if !model.launcherNoMatchDestinations(query: "zqxv weekly summary").isEmpty {
                // ↓ highlights a destination; ↑ returns to Ask AI.
                try await send(Self.down, to: launcher)
                try await send(Self.up, to: launcher)
                #expect(!model.plugins.isActive)
            }
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(await launcher.fixture.api.sends.first?.text == "zqxv weekly summary")
        }
    }

    @Test func aDestinationEntersItsKeywordWithTheTypedText() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "zqxv weekly")
            defer { launcher.close() }
            let model = launcher.fixture.model
            let destinations = model.launcherNoMatchDestinations(query: "zqxv weekly")
            guard let first = destinations.first else { return }
            try await send(Self.down, to: launcher)
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.keyword == first.keyword.keyword)
            #expect(model.launcherDraft.text == "zqxv weekly")
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func anEmptyHomeGreetsAndItsChipsTakeTheArrows() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            #expect(model.presentedLauncherHome().isEmpty, "no applications to list")
            guard let chip = model.presentedLauncherChips().chips.first else { return }
            try await send(Self.down, to: launcher)
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.keyword == chip.keyword.keyword)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func removingTheContextReturnsToTheHome() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            model.launcherDraft.attachments = [Self.report, Self.report]
            model.removeLauncherAttachments()
            #expect((model.launcherDraft.attachments ?? []).isEmpty)
        }
    }
}
