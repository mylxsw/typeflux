import AppKit
import Foundation
import Testing
@testable import Typeflux

/// The launcher's height, Esc, highlight and notice rules, as pure values.
@Suite("Ask launcher polish")
@MainActor
struct AskLauncherPolishTests {
    // MARK: - Height

    @Test func typingHoldsTheTallestHeightUpToTheSlack() {
        let slack = AskLauncherHeightReserve.maximumSlack
        #expect(AskLauncherHeightReserve.holding(0, content: 120) == 120, "new results take their own height")
        #expect(AskLauncherHeightReserve.holding(200, content: 300) == 300, "taller results grow the area")
        #expect(AskLauncherHeightReserve.holding(200, content: 180) == 200, "a row less keeps the panel still")
        #expect(AskLauncherHeightReserve.holding(480, content: 100) == 100 + slack,
                "two rows under a tall list leave at most the slack empty")
    }

    @Test func pausingSettlesToTheRows() {
        #expect(AskLauncherHeightReserve.settled(480, content: 100) == 100)
        #expect(AskLauncherHeightReserve.settled(80, content: 100) == 80, "never grows on its own")
        #expect(AskLauncherHeightReserve.settleDelay > .zero && AskLauncherHeightReserve.settleAnimation > 0)
    }

    // MARK: - Esc

    @Test func escapeStepsBackOneLayerAtATime() {
        typealias Escape = AskLauncherEscape
        var state = Escape.State(quickLook: true, menu: true, actions: true, approval: true, running: true, keyword: true)
        #expect(Escape.resolve(state) == .closeQuickLook)
        state.quickLook = false
        #expect(Escape.resolve(state) == .closeMenu)
        state.menu = false
        #expect(Escape.resolve(state) == .closeActions)
        state.actions = false
        #expect(Escape.resolve(state) == .declineApproval)
        state.approval = false
        #expect(Escape.resolve(state) == .cancelRun)
        state.running = false
        #expect(Escape.resolve(state) == .exitKeyword)
        state.keyword = false
        #expect(Escape.resolve(state) == .closeLauncher)
    }

    // MARK: - Highlight and Return

    private let plan = AskPluginPlan(mode: .onSubmit, title: "History")

    @Test func theHighlightedHintRowIsWhatReturnDoes() {
        let history = AskHistoryPlugin.keywords[0]
        let entering = AskPluginDisplay(hint: history, title: "History", symbol: "clock", phase: .waiting)
        #expect(!entering.asksAI)
        #expect(AskPluginResultsView.hint(for: entering) == L("ask.plugin.hint.keyword.enter"))
        #expect(AskPluginResultsView.hintRowKeys(history, highlighted: true) == L("ask.plugin.enter.return"))
        var asking = entering
        asking.highlighted = 1
        #expect(asking.asksAI && AskPluginResultsView.hint(for: asking) == L("ask.plugin.hint.keyword"))
        #expect(AskPluginResultsView.hintRowKeys(history, highlighted: false) == L("ask.plugin.enter"))
        #expect(AskPluginResultsView.hintRowKeys(AskOpenChatPlugin.keywords[0], highlighted: true) == "↩")
    }

    // MARK: - Ask AI

    @Test func askAIIsOfferedOnlyWithSomethingToAsk() {
        let asks = AskPluginDisplay.offersAskAI
        #expect(!asks("", nil, false, nil))
        #expect(!asks("   ", "Selected", false, nil), "a selection the keyword ignores is not a question")
        #expect(asks("tr", nil, false, nil))
        #expect(asks("", "Selected", true, nil))
        #expect(!asks("", "  ", true, nil))
        let action = AskPluginAction(kind: .askAI("About this"), title: "Ask", symbol: "sparkles")
        let output = AskPluginOutput(body: "x", original: "", meta: [], source: "", actions: [action])
        #expect(asks("", nil, false, output))
    }

    @Test func withoutAskAITheListIsShorterAndTheBarLeavesItOut() {
        let item = AskPluginItem(id: "a", title: "a", actions: [
            AskPluginAction(kind: .enterKeyword("a"), title: "Use", symbol: "arrow.right", shortcut: .enter)
        ])
        let output = AskPluginOutput(body: "a", original: "", meta: [], source: "", actions: [], items: [item])
        var display = AskPluginDisplay(title: "Keywords", symbol: "list.bullet", phase: .done(plan, output), highlighted: 1)
        let offered = AskPluginResultsView.height(for: display)
        #expect(display.asksAI)
        display.offersAskAI = false
        #expect(!display.asksAI, "Return falls back to the list when there is no Ask AI row")
        #expect(offered - AskPluginResultsView.height(for: display)
            == AskPluginResultsView.sectionHeight + AskPluginResultsView.rowSpacing * 2 + AskPluginResultsView.askHeight)
        #expect(AskPluginResultsView.hint(for: display) == L("ask.plugin.hint.action", "Use"))
        display.phase = .ready(AskPluginPlan(mode: .onSubmit, title: "Search", actions: [
            AskPluginAction(kind: .open(URL(string: "https://example.com")!), title: "Open", symbol: "safari", shortcut: .enter)
        ]))
        #expect(!AskPluginResultsView.hint(for: display).contains(L("ask.plugin.hint.askAI")))
    }

    @Test func aResultWithoutAMainActionHasNoBareReturnInTheBar() {
        let empty = AskPluginOutput(body: "Nothing", original: "", meta: [], source: "", actions: [])
        let display = AskPluginDisplay(title: "History", symbol: "clock", phase: .done(plan, empty))
        let hint = AskPluginResultsView.hint(for: display)
        #expect(hint == L("ask.plugin.hint.askAI"), "no “↩ ·” with nothing after it")
        var quiet = display
        quiet.offersAskAI = false
        #expect(AskPluginResultsView.hint(for: quiet).isEmpty)
    }

    @Test func anEmptyHistorySaysSoQuietly() async throws {
        let plugin = AskHistoryPlugin(conversations: { .empty })
        let request = AskPluginRequest(text: "", origin: .argument, keyword: AskHistoryPlugin.keywords[0], options: [:],
                                       interfaceLanguage: .english)
        let output = try await plugin.run(request, plan: await plugin.plan(request))
        #expect(output.items.map(\.title) == [L("ask.history.empty")] && output.items.allSatisfy { !$0.valid })
        let display = AskPluginDisplay(title: plugin.title, symbol: plugin.symbol, phase: .done(plan, output))
        let card = AskPluginDisplay(title: plugin.title, symbol: plugin.symbol, phase: .done(plan, AskPluginOutput(
            body: output.body, original: "", meta: [], source: "", actions: [])))
        #expect(AskPluginResultsView.height(for: display) < AskPluginResultsView.height(for: card),
                "one list row instead of a result card")
    }

    // MARK: - Indexing notice

    @Test func questionsAreNotFileNames() {
        #expect(AskQuickResults.looksLikeName("readme"))
        #expect(AskQuickResults.looksLikeName("季度报告"))
        #expect(AskQuickResults.looksLikeName("invoice 2026.pdf"))
        #expect(!AskQuickResults.looksLikeName("用三句话介绍一下 Typeflux"))
        #expect(!AskQuickResults.looksLikeName("what is the weather like today"))
        #expect(!AskQuickResults.looksLikeName("why?"))
        #expect(!AskQuickResults.looksLikeName("   "))
        #expect(!AskQuickResults.looksLikeName(String(repeating: "a", count: 41)))
        #expect(!AskQuickResults.looksLikeName("今日の会議を延期しましょう"))
    }

    @Test func theIndexingNoticeStaysOutOfQuestions() throws {
        let index = AskTestFileIndex()
        index.status = AskFileIndexStatus(phase: .building(found: 0, estimate: nil))
        var settings = AskLauncherSearchSettings()
        func resolve(_ text: String) -> AskQuickResults? {
            AskQuickResults.resolve(text: text, previous: nil, chinese: true, calculator: true,
                                    sources: .init(apps: nil, files: index, settings: settings))
        }
        #expect(resolve("用三句话介绍一下 Typeflux") == nil, "a question shows no file-index status")
        #expect(try #require(resolve("readme")).notice == .indexing(found: 0, progress: nil))
        #expect(try #require(resolve("introduce typeflux in three sentences .pdf")).notice != nil, "filters are file searches")
        settings.mode = .filesFirst
        #expect(try #require(resolve("用三句话介绍一下 Typeflux")).notice != nil, "files first always says so")
    }

    // MARK: - Materials, sidebar, screenshot

    @Test func menusAreNeverClearerThanTheLauncherUnderThem() {
        for dark in [false, true] {
            #expect(AskGlassPlacement.menu.frost(dark: dark) >= AskGlassPlacement.floating.frost(dark: dark))
        }
    }

    @Test func theSignedOutFooterKeepsTheFullLineAsItsTooltip() {
        #expect(AskLocalModeIdentity.detail(source: "Ollama") == String(format: L("ask.local.identity.detail"), "Ollama"))
        #expect(!L("ask.local.identity.storage").isEmpty)
    }

    @Test func aMissingScreenshotSaysWhy() {
        #expect(AskContextCapture.missingScreenshotWarning(allowed: false) == L("ask.capture.permission"))
        #expect(AskContextCapture.missingScreenshotWarning(allowed: true) == L("ask.capture.unavailable"))
    }

    @Test func aKeptDraftWithoutItsScreenshotDoesNotReadAsAttached() async throws {
        let fixture = try AskTestFixture()
        // The first opening takes the account (and captures); the next keeps the unfinished draft.
        await fixture.model.prepareLauncher()
        let captures = fixture.capture.calls
        fixture.model.launcherDraft = AskDraft(text: "Unfinished question", includeScreenshot: true)
        fixture.model.captureWarning = nil
        await fixture.model.prepareLauncher()
        #expect(fixture.model.launcherContextRestored)
        #expect(fixture.model.captureWarning == L("ask.capture.permission"), "the capture double has no permission")
        #expect(fixture.capture.calls == captures, "a kept draft is not captured again")

        fixture.model.captureWarning = "Earlier failure"
        await fixture.model.prepareLauncher()
        #expect(fixture.model.captureWarning == "Earlier failure", "the reason from the last capture stays")

        fixture.model.launcherDraft.screenshot = "data:image/jpeg;base64,YQ=="
        fixture.model.captureWarning = nil
        await fixture.model.prepareLauncher()
        #expect(fixture.model.captureWarning == nil, "a kept screenshot is attached")
        fixture.model.resetSession()
    }
}
