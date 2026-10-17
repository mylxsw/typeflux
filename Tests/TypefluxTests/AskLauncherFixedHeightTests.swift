import AppKit
import Testing
@testable import Typeflux

/// The expanded launcher keeps one height and its primary button does not
/// flicker while a search catches up.
@Suite("Launcher fixed height and steady controls", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherFixedHeightTests {
    @Test func `typing and deleting report one launcher height`() async throws {
        let apps = AskTestAppIndex((0 ..< 8).map { AskTestAppIndex.app("Alpha \($0)", id: "fixed.\($0)") })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", apps: apps)
        defer { launcher.close() }
        for text in ["a", "al", "alpha", "alpha 7", "zzqqxx", "al", ""] {
            launcher.fixture.model.launcherDraft.text = text
            try await AskQuickSearchSessionTests.wait { !launcher.fixture.model.quickSearch.isSearching }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The reserve settles after typing pauses; it must not change the height either.
        try await Task.sleep(for: AskLauncherHeightReserve.settleDelay + .milliseconds(100))
        #expect(!launcher.heights.isEmpty)
        #expect(Set(launcher.heights) == [AskLauncherWindowMode.expandedHeight],
                "reported heights: \(Set(launcher.heights))")
    }

    @Test func `a pending search only waits and never reads as unavailable`() throws {
        let results = try #require(AskQuickResults.search("json", sources: .init(entries: [
            AskLauncherSearchEntry(keyword: .init(keyword: "js", pluginID: "json"), title: "JSON Tools",
                                   detail: "", symbol: "curlybraces")
        ])))
        let chat = AskLauncherPrimaryAction(mode: .askAI)
        let pending = AskLauncherPrimaryAction.quickResult(results, pending: true, chat: chat)
        #expect(!pending.enabled && pending.waiting, "a search catching up is drawn as ready")
        let ready = AskLauncherPrimaryAction.quickResult(results, pending: false, chat: chat)
        #expect(ready.enabled && !ready.waiting)
        let reason = L("ask.launcher.action.input")
        let unavailable = AskLauncherPrimaryAction.confirm("Run", enabled: false, reason: reason)
        #expect(!unavailable.waiting, "missing input is a real disabled state")
    }
}
