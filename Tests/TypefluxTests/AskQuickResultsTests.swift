import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask quick results")
struct AskQuickResultsTests {
    private func resolve(_ text: String, previous: AskQuickResults? = nil, chinese: Bool = true) -> AskQuickResults? {
        AskQuickResults.resolve(text: text, previous: previous, chinese: chinese)
    }

    @Test func aCalculationOffersItsRowsAndHighlightsTheResult() throws {
        let results = try #require(resolve("1234567.89*2"))
        #expect(results.rows == [.calculation, .format(0), .format(1), .format(2), .askAI])
        #expect(results.highlightedRow == .calculation)
        #expect(results.value(of: .calculation) == "2469135.78")
        #expect(results.value(of: .format(0)) == "贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分")
        #expect(results.value(of: .format(9)) == nil)
        #expect(results.value(of: .askAI) == nil)
        #expect(!results.stale)
    }

    @Test func otherTextHasNoQuickResults() {
        #expect(resolve("hello") == nil)
        #expect(resolve("") == nil)
        #expect(resolve("12*3+") == nil, "nothing to keep yet")
    }

    @Test func anUnfinishedExpressionKeepsTheLastResultDimmed() throws {
        let first = try #require(resolve("12*3"))
        let pending = try #require(resolve("12*3+", previous: first))
        #expect(pending.stale)
        #expect(pending.pendingExpression == "12 × 3 +")
        #expect(pending.value(of: .calculation) == "36")
        let next = try #require(resolve("12*3+4", previous: pending))
        #expect(!next.stale)
        #expect(next.value(of: .calculation) == "40")
    }

    @Test func aFailedCalculationHighlightsAskAI() throws {
        let results = try #require(resolve("100/0"))
        #expect(results.formats.isEmpty)
        #expect(results.highlightedRow == .askAI)
        #expect(!results.isEnabled(.calculation))
        #expect(results.value(of: .calculation) == nil)
        #expect(resolve("100/", previous: results) == nil, "an error is not kept while typing")
        let fixed = try #require(resolve("100/5", previous: results))
        #expect(fixed.highlightedRow == .calculation, "the default highlight follows the new result")
    }

    @Test func movingWrapsAndSkipsRowsThatCannotRun() throws {
        var results = try #require(resolve("1+1"))
        #expect(results.rows == [.calculation, .format(0), .format(1), .askAI])
        results.move(-1)
        #expect(results.highlightedRow == .askAI)
        #expect(results.chosen)
        results.move(1)
        #expect(results.highlightedRow == .calculation)

        var failed = try #require(resolve("1/0"))
        #expect(failed.rows == [.calculation, .askAI])
        failed.move(1)
        #expect(failed.highlightedRow == .askAI, "the failed calculation is passed over")
        failed.highlight(0)
        #expect(failed.highlightedRow == .askAI)
        failed.highlight(7)
        #expect(failed.highlightedRow == .askAI)
    }

    @Test func aChosenRowIsKeptWhileTyping() throws {
        var results = try #require(resolve("1+1"))
        results.highlight(3)
        #expect(results.highlightedRow == .askAI)
        let next = try #require(resolve("1+12", previous: results))
        #expect(next.highlightedRow == .askAI)

        var format = try #require(resolve("1+1"))
        format.highlight(1)
        let kept = try #require(resolve("1+2", previous: format))
        #expect(kept.highlightedRow == .format(0))
        #expect(kept.chosen)

        var calculation = try #require(resolve("1+1"))
        calculation.highlight(0)
        let stillThere = try #require(resolve("1+2", previous: calculation))
        #expect(stillThere.highlightedRow == .calculation)

        var lastFormat = try #require(resolve("1234*1"))
        lastFormat.highlight(3)
        let fewer = try #require(resolve("2*1", previous: lastFormat))
        #expect(fewer.highlightedRow == .calculation, "a row that is gone falls back to the default")
        #expect(!fewer.chosen)
    }

    @Test @MainActor func copyingWritesPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ask.quick.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        AskQuickResults.copy("2469135.78", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "2469135.78")
    }

    @Test func theViewHeightCountsEveryRow() throws {
        let three = try #require(resolve("1234567.89*2"))
        let none = try #require(resolve("1/0"))
        let rowAndSpacing = AskQuickResultsView.formatHeight + AskQuickResultsView.rowSpacing
        #expect(AskQuickResultsView.height(for: three) - AskQuickResultsView.height(for: none) == rowAndSpacing * 3)
        // Hairline, list padding, calculation, "Ask AI", one gap between them, hint.
        let bare: CGFloat = 147
        #expect(AskQuickResultsView.height(for: none) == bare)
    }

    @Test func theHintFollowsTheHighlight() throws {
        var results = try #require(resolve("1+1"))
        #expect(AskQuickResultsView.hint(for: results) == L("ask.quick.hint"))
        results.highlight(results.rows.count - 1)
        #expect(AskQuickResultsView.hint(for: results) == L("ask.launcher.hint"))
    }

    @Test func theCalculatorCanBeTurnedOff() throws {
        let suite = "ask.quick.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askQuickCalculatorEnabled)
        settings.askQuickCalculatorEnabled = false
        #expect(!settings.askQuickCalculatorEnabled)
    }

    @Test @MainActor func finishingClearsTheLauncherText() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        #expect(fixture.model.quickResultsEnabled)
        fixture.model.launcherDraft.text = "1+1"
        fixture.model.finishQuickResult()
        #expect(fixture.model.launcherDraft.text.isEmpty)
        fixture.model.modelLibrary.settings.askQuickCalculatorEnabled = false
        #expect(!fixture.model.quickResultsEnabled)
    }
}
