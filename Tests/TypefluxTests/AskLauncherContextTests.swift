import Foundation
import Testing
@testable import Typeflux

@Suite("Ask launcher context token", .exclusiveUIState)
struct AskLauncherContextTests {
    private func draft(source: String? = "Google Chrome — Issues | Multica - Google Chrome",
                       selection: String? = nil, screenshot: String? = "data:image/png;base64,AA==",
                       includeScreenshot: Bool = true) -> AskDraft {
        var draft = AskDraft()
        draft.source = source
        draft.sourceBundleID = source == nil ? nil : "com.google.Chrome"
        draft.selection = selection
        draft.screenshot = screenshot
        draft.includeScreenshot = includeScreenshot
        return draft
    }

    @Test func shortTitleDropsTheAppNameTheIconAlreadyShows() {
        #expect(AskLauncherContext.shortTitle(app: "Google Chrome", window: "Issues | Multica - Google Chrome")
            == "Issues | Multica")
        #expect(AskLauncherContext.shortTitle(app: "Google Chrome", window: "Inbox - Google Chrome - Work")
            == "Inbox", "a trailing profile name goes with it")
        #expect(AskLauncherContext.shortTitle(app: "Safari", window: "Docs — safari") == "Docs", "case-insensitive")
        #expect(AskLauncherContext.shortTitle(app: "Notes", window: "Shopping | Notes") == "Shopping")
    }

    @Test func shortTitleKeepsTitlesThatOnlyMentionTheApp() {
        #expect(AskLauncherContext.shortTitle(app: "Xcode", window: "Xcode - Release Notes") == "Xcode - Release Notes")
        #expect(AskLauncherContext.shortTitle(app: "Chrome", window: "Chrome - tips for Chrome users")
            == "Chrome - tips for Chrome users", "the app name is not the title's last part")
        #expect(AskLauncherContext.shortTitle(app: "Finder", window: "Downloads") == "Downloads")
    }

    @Test func shortTitleFallsBackToTheAppName() {
        #expect(AskLauncherContext.shortTitle(app: "Finder", window: nil) == "Finder")
        #expect(AskLauncherContext.shortTitle(app: "Finder", window: "  ") == "Finder")
        #expect(AskLauncherContext.shortTitle(app: "Finder", window: "Finder") == "Finder")
        #expect(AskLauncherContext.shortTitle(app: " ", window: "Untitled") == "Untitled")
    }

    @Test func tokenShowsTheShortTitleUntilTheEditorHasText() throws {
        let open = try #require(AskLauncherContext.token(draft: draft(selection: "a\nb"), screenshotState: .attached,
                                                         capturing: false, restored: true, collapsed: false))
        #expect(open.hasSource)
        #expect(open.bundleID == "com.google.Chrome")
        #expect(open.title == "Issues | Multica")
        #expect(open.help == "Google Chrome · Issues | Multica - Google Chrome")
        #expect(open.selectionLines == 2)
        #expect(open.screenshot == .attached)
        #expect(open.restored)

        let typing = try #require(AskLauncherContext.token(draft: draft(selection: "a\nb"), screenshotState: .attached,
                                                           capturing: false, restored: false, collapsed: true))
        #expect(typing.title == nil)
        #expect(typing.selectionLines == nil)
        #expect(typing.hasSource)
        #expect(typing.screenshot == .attached, "the icons stay")
    }

    @Test func tokenDimsAnExcludedSourceAndHidesItsTitle() throws {
        var value = draft()
        value.sourceOff = true
        let token = try #require(AskLauncherContext.token(draft: value, screenshotState: .attached, capturing: false,
                                                          restored: false, collapsed: false))
        #expect(token.sourceOff)
        #expect(token.title == nil)
    }

    @Test func tokenIsNilWithNothingCaptured() {
        #expect(AskLauncherContext.token(draft: draft(source: nil, screenshot: nil), screenshotState: .attached,
                                         capturing: false, restored: false, collapsed: false) == nil)
        #expect(AskLauncherContext.token(draft: draft(source: "  ", screenshot: nil, includeScreenshot: false),
                                         screenshotState: .off, capturing: false, restored: false,
                                         collapsed: false) == nil)
    }

    @Test func tokenStaysForSelectionThatWasSwitchedOff() throws {
        var value = draft(source: nil, selection: "quote", screenshot: nil)
        value.selectionOff = true
        let token = try #require(AskLauncherContext.token(draft: value, screenshotState: .attached, capturing: false,
                                                          restored: false, collapsed: false))
        #expect(token.selectionLines == nil, "only content that is sent is counted")
        #expect(!token.hasSource)
    }

    @Test func screenshotStateFollowsTheDraft() {
        #expect(AskLauncherContext.screenshot(draft: draft(), state: .attached, capturing: false) == .attached)
        #expect(AskLauncherContext.screenshot(draft: draft(), state: .attached, capturing: true) == .capturing)
        #expect(AskLauncherContext.screenshot(draft: draft(screenshot: nil), state: .attached, capturing: false) == .none)
        #expect(AskLauncherContext.screenshot(draft: draft(includeScreenshot: false), state: .off, capturing: false) == .off)
        #expect(AskLauncherContext.screenshot(draft: draft(screenshot: nil, includeScreenshot: false), state: .off,
                                              capturing: false) == .none)
        #expect(AskLauncherContext.screenshot(draft: draft(screenshot: nil),
                                              state: .failed(permission: true, message: "denied"),
                                              capturing: false) == .failed)
        #expect(AskLauncherContext.screenshot(draft: draft(), state: .unavailable(reason: "no vision"),
                                              capturing: false) == .failed)
        #expect(AskLauncherContext.screenshot(draft: draft(), state: .off, capturing: false) == .off)
    }

    @Test func backspaceRemovesTheScreenshotThenSelectionThenSource() {
        var value = draft(selection: "picked")
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .attached) == .screenshot)
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .failed) == .screenshot)
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .capturing) == .screenshot)
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .none) == .selection,
                "a screenshot the token does not show is skipped")
        value.includeScreenshot = false
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .off) == .selection)
        value.selectionOff = true
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .off) == .source)
        value.sourceOff = true
        #expect(AskLauncherContext.backspaceTarget(value, screenshot: .off) == nil)
    }

    @Test func hintExplainsRecordingQuickResultsAndContext() throws {
        #expect(AskLauncherContext.hint(voice: .listening, quickResults: nil, hasContext: true)
            == L("ask.launcher.hint.voice"))
        #expect(AskLauncherContext.hint(voice: .transcribing, quickResults: nil, hasContext: false)
            == L("ask.launcher.hint.transcribing"))
        #expect(AskLauncherContext.hint(voice: .idle, quickResults: nil, hasContext: false) == L("ask.launcher.hint"))
        #expect(AskLauncherContext.hint(voice: .idle, quickResults: nil, hasContext: true)
            == L("ask.launcher.hint.context"))
        let results = try #require(AskQuickResults.resolve(text: "1+1", previous: nil, chinese: true))
        #expect(AskLauncherContext.hint(voice: .idle, quickResults: results, hasContext: true)
            == AskQuickResultsView.hint(for: results))
        #expect(L("ask.launcher.hint.context").contains("⌘K"))
    }

    @Test func hintsNeverSpendRoomOnEscClosing() {
        for key in ["ask.launcher.hint", "ask.launcher.hint.context", "ask.quick.hint", "ask.quick.hint.app",
                    "ask.quick.hint.file", "ask.quick.hint.showAll", "ask.plugin.hint.keyword", "ask.plugin.hint.failed",
                    "ask.home.hint.chip"] {
            #expect(!L(key).contains("esc"), "\(key)")
        }
        #expect(L("ask.launcher.hint.voice").contains("esc"), "esc still cancels a recording")
    }

    @Test func hintTiersShortenToTheMainKeyAndContext() {
        #expect(AskLauncherContext.hintTiers("").isEmpty)
        #expect(AskLauncherContext.hintTiers("↩ Send") == ["↩ Send"])
        #expect(AskLauncherContext.hintTiers("↩ Send · ⌘K Context") == ["↩ Send · ⌘K Context", "↩ Send"])
        #expect(AskLauncherContext.hintTiers("↩ Use keyword · ←→ Switch · ⌘K Context")
            == ["↩ Use keyword · ←→ Switch · ⌘K Context", "↩ Use keyword · ⌘K Context", "↩ Use keyword"])
        #expect(AskLauncherContext.hintTiers("↩ Open · → More · ⌘↩ Ask AI") == ["↩ Open · → More · ⌘↩ Ask AI", "↩ Open"])
    }

    @Test func sendIsLitOnlyWhenReturnAsksTheAI() throws {
        #expect(AskLauncherContext.sendIsProminent(quickResults: nil))
        var results = try #require(AskQuickResults.resolve(text: "1+1", previous: nil, chinese: true))
        #expect(!AskLauncherContext.sendIsProminent(quickResults: results), "Return copies the result")
        results.highlight(results.rows.count - 1)
        #expect(AskLauncherContext.sendIsProminent(quickResults: results))
    }

    @Test func elapsedIsMinutesAndSeconds() {
        #expect(AskLauncherContext.elapsed(0) == "0:00")
        #expect(AskLauncherContext.elapsed(4.9) == "0:04")
        #expect(AskLauncherContext.elapsed(90) == "1:30")
        #expect(AskLauncherContext.elapsed(-3) == "0:00")
    }

    @Test func launcherPlaceholderSaysWhatItDoes() {
        #expect(L("ask.launcher.placeholder") != "ask.launcher.placeholder")
        #expect(!L("ask.launcher.placeholder").contains("/"))
    }
}
