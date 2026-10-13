import AppKit
import Testing
@testable import Typeflux

@Suite("Library window lifetime", .serialized, .exclusiveUIState)
@MainActor
struct AskLibraryWindowLifecycleTests {
    private struct FixtureFailure: Error {}

    @Test func closingTheLastWindowDoesNotRequestApplicationTermination() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(!UITestApplicationLifetime().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func closingLibrariesReleasesTheirHostedActionsAndLeavesTheAppAvailable() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let notes = try #require(libraries.notes.window)
            let words = try #require(libraries.words.window)
            libraries.notes.windowWillClose(.init(name: NSWindow.willCloseNotification, object: words))
            #expect(libraries.notes.window === notes, "unrelated close notifications are ignored")
            notes.performClose(nil)
            #expect(libraries.notes.window == nil && libraries.notes.model == nil)
            #expect(notes.contentView == nil && notes.toolbar == nil)
            #expect(words.isVisible, "closing Notes leaves Word Book open")
            words.performClose(nil)
            #expect(libraries.words.window == nil && libraries.words.model == nil)
            #expect(words.contentView == nil && words.toolbar == nil)
            libraries.notes.show(selecting: libraries.noteID)
            #expect(libraries.notes.window?.isVisible == true, "a new library window can still open")
        }
    }

    @Test func failedFixturesStillCloseBothWindowsAndTheNextCaseCanOpen() async throws {
        for _ in 0 ..< 2 {
            var libraries: AskLibraryTestSupport.Libraries?
            var windows: [NSWindow] = []
            var caught = false
            do {
                try await AskLibraryTestSupport.withLibraries(style: .liquidGlass, dark: true) { fixture in
                    libraries = fixture
                    let notes = try #require(fixture.notes.window)
                    let words = try #require(fixture.words.window)
                    windows = [notes, words]
                    throw FixtureFailure()
                }
            } catch is FixtureFailure {
                caught = true
            }
            #expect(caught)
            #expect(libraries?.notes.window == nil && libraries?.words.window == nil)
            #expect(windows.count == 2)
            #expect(windows.allSatisfy { !$0.isVisible && $0.contentView == nil && $0.toolbar == nil })
        }
    }
}
