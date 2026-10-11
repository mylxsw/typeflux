import Testing
@testable import Typeflux

@Suite("Launcher whitespace", .exclusiveUIState)
@MainActor
struct AskLauncherWhitespaceTests {
    @Test(arguments: ["", " ", "   ", "\t", "\n", " \t\r\n ", "\u{00A0}\u{3000}"])
    func whitespaceKeepsTheLauncherEmpty(text: String) throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.text = text
        let draft = fixture.model.launcherDraft
        #expect(!draft.hasText)
        #expect(!draft.canSend)
        #expect(draft.text == text)
        #expect(AskLauncherWindowMode.simple.isCollapsed(draft: draft))
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: draft, engaged: true))
        fixture.model.launcherWindowMode = .complete
        #expect(AskComposer(model: fixture.model, launcher: true).showsLauncherSuggestions)
        fixture.model.launcherWindowMode = .simple
        #expect(!AskComposer(model: fixture.model, launcher: true).showsLauncherSuggestions)

        fixture.model.launcherDraft.attachments = [.init(kind: .file, name: "notes.txt", text: "Notes")]
        #expect(fixture.model.launcherDraft.canSend)
        #expect(!fixture.model.launcherIsCollapsed)
        #expect(!AskComposer(model: fixture.model, launcher: true).showsLauncherSuggestions)
    }

    @Test(arguments: ["query", "  query  ", "\n question\t", "你 好"])
    func meaningfulTextExpandsTheLauncherAndHidesSuggestions(text: String) throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.text = text
        #expect(fixture.model.launcherDraft.hasText)
        #expect(fixture.model.launcherDraft.canSend)
        #expect(fixture.model.launcherDraft.text == text)
        #expect(!AskLauncherWindowMode.simple.isCollapsed(draft: fixture.model.launcherDraft))
        fixture.model.launcherWindowMode = .complete
        #expect(!AskComposer(model: fixture.model, launcher: true).showsLauncherSuggestions)
    }

    @Test func whitespaceDoesNotKeepStaleCapturedContext() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        let captures = fixture.capture.calls
        fixture.model.launcherDraft.text = " \t\n "
        await fixture.model.prepareLauncher()
        #expect(fixture.capture.calls == captures + 1)
        #expect(!fixture.model.launcherContextRestored)
        #expect(fixture.model.launcherDraft.text == " \t\n ")
    }

    @Test func whitespaceAllowsRestoringAMeaningfulCachedDraft() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        let captures = fixture.capture.calls
        try await fixture.cache.saveDraft(.init(text: "Saved question"), key: "launcher", owner: "owner")
        fixture.model.launcherDraft.text = " \t\n "
        await fixture.model.prepareLauncher()
        #expect(fixture.model.launcherDraft.text == "Saved question")
        #expect(fixture.model.launcherContextRestored)
        #expect(fixture.capture.calls == captures)
    }
}
