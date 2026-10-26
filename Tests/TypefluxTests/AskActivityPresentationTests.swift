import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Stable task presentation", .exclusiveUIState)
@MainActor struct AskActivityPresentationTests {
    private let now = Date(timeIntervalSince1970: 1)
    private func user(_ id: String) -> AskMessage { .init(id: id, role: "user", text: "Build", createdAt: now) }
    private func step(_ id: String) -> AskMessage {
        .init(id: id, role: "assistant", text: "Checking", toolCalls: [
            .init(id: "call-" + id, function: .init(name: "web_fetch", arguments: "{\"url\":\"https://example.com/\(id)\"}"))
        ], createdAt: now, reasoning: "Thinking", runId: "run")
    }
    private func result(_ id: String) -> AskMessage {
        .init(id: "result-" + id, role: "tool", text: "OK", toolCallId: "call-" + id, createdAt: now)
    }
    private func outcome(_ items: [AskTranscriptItem]) -> AskTranscriptItem? {
        items.first { if case .outcome = $0.kind { return true }; return false }
    }

    @Test func replacementPlanDoesNotClaimNoWorkWasPerformed() throws {
        let previous = AskMessage(id: "old-plan", role: "assistant", text: "", toolCalls: [
            .init(id: "old", function: .init(name: "update_plan", arguments:
                #"{"items":[{"step":"Write HTML","status":"completed"}]}"#))
        ], createdAt: now, runId: "run")
        let replacement = AskMessage(id: "new-plan", role: "assistant", text: "", toolCalls: [
            .init(id: "new", function: .init(name: "update_plan", arguments:
                #"{"items":[{"step":"Inspect","status":"in_progress"},{"step":"Write JS","status":"pending"},{"step":"Verify","status":"pending"}]}"#))
        ], createdAt: now, runId: "run")
        let group = AskActivityGroup(id: "old-plan", messages: [previous, replacement, step("read")])
        let plan = try #require(AskActivity.plan(for: group, run: nil, isLatest: false))
        #expect(plan.count == 3)
        #expect(AskActivity.title(group, status: .done, plan: plan, results: [])
            .hasPrefix(L("ask.activity.planRemaining", 3)))
        #expect(AskActivity.attentionTitle(plan: plan) == L("ask.activity.planRemaining", 3))
        let progressed = [AskPlanItem(step: "Inspect", status: "completed"),
                          AskPlanItem(step: "Write", status: "pending")]
        #expect(AskActivity.planSummary(progressed) == L("ask.activity.plan", 1, 2))
        #expect(AskActivity.planSummary([progressed[0]]) == L("ask.activity.plan", 1, 1))
    }

    @Test func taskResultsSurviveStreamingToolCallsSteeringCompletionAndReload() throws {
        let cache = AskActivityOutputCache()
        var messages = [user("question"), step("one")]
        var results = [result("one")]
        let changes = ["one": [AskWorkspaceFileChange(path: "outputs/site.html", kind: .added)]]
        func prepare() -> [AskTranscriptItem] {
            cache.prepare(conversationID: "chat", messages: messages, results: results, changes: changes)
        }
        let first = try #require(outcome(prepare()))
        #expect(first.id == "outcome-question")
        // A new streaming answer used to steal the outputs, then hide them until it ended.
        messages.append(.init(id: "live", role: "assistant", text: "Starting", createdAt: now, runId: "run"))
        #expect(outcome(prepare())?.id == first.id)
        #expect(outcome(prepare())?.outputs == first.outputs)
        messages[messages.count - 1].text += " the next step"
        #expect(outcome(prepare())?.outputs == first.outputs)
        var steer = user("steer"); steer.steered = true
        messages.append(steer)
        messages.append(step("two")); results.append(result("two"))
        let continued = try #require(outcome(prepare()))
        #expect(continued.id == first.id)
        #expect(continued.outputs.sources.count == 2)
        messages.append(.init(id: "final", role: "assistant", text: "Done", createdAt: now, runId: "run"))
        let completed = prepare()
        let reloaded = AskActivityOutputCache().prepare(conversationID: "chat", messages: messages, results: results, changes: changes)
        #expect(completed == reloaded)
        messages.append(user("next")); messages.append(step("three")); results.append(result("three"))
        let next = prepare()
        #expect(outcome(next) == outcome(completed))
        #expect(next.contains { $0.id == "outcome-next" })
        if case let .outcome(value) = first.kind {
            #expect(value.changes.count == 1)
            #expect(value.runIDs == ["run"])
        }
    }

    @Test func completedReceiptsAreNotDecodedAgainAndConversationSwitchDropsCache() throws {
        let cache = AskActivityOutputCache()
        var messages = [user("u"), step("a"), step("b")]
        var results = [result("a"), result("b")]
        func prepare(_ conversation: String = "chat") -> [AskTranscriptItem] {
            cache.prepare(conversationID: conversation, messages: messages, results: results, changes: [:])
        }
        _ = prepare()
        #expect(cache.decodeCount == 2)
        _ = prepare()
        #expect(cache.preparationCount == 1)
        messages[2].reasoning = "More thinking"
        _ = prepare()
        #expect(cache.decodeCount == 2)
        results[1].text = "Changed evidence"
        _ = prepare()
        #expect(cache.decodeCount == 3)
        messages.removeLast(); results.removeLast()
        _ = prepare()
        messages.append(step("b")); results.append(result("b"))
        _ = prepare()
        #expect(cache.decodeCount == 4, "Removed receipts must not remain retained")
        _ = prepare("other-account-chat")
        #expect(cache.decodeCount == 6)
        _ = cache.prepare(conversationID: nil, messages: [], results: [], changes: [:])
        #expect(cache.resultsByID.isEmpty)
    }

    @Test func inspectionActionHasStableIdentityAcrossParentUpdates() {
        let identity = UUID()
        var followed = true
        let action = AskTranscriptInspectionAction(identity: identity, action: { followed = false })
        #expect(action == AskTranscriptInspectionAction(identity: identity))
        #expect(action != AskTranscriptInspectionAction(identity: UUID()))
        action()
        #expect(!followed)
    }

    @Test func pageRemainsBoundedWhenGrowingAndClampsAfterHistoryChanges() {
        #expect(AskActivityPage.range(count: 0, page: 0).isEmpty)
        #expect(AskActivityPage.range(count: 1000, page: -2) == 0..<20)
        #expect(AskActivityPage.range(count: 1000, page: 1) == 20..<40)
        #expect(AskActivityPage.range(count: 1001, page: 1) == 20..<40)
        #expect(AskActivityPage.range(count: 21, page: 100) == 20..<21)
        #expect(AskActivityPage.last(count: 1000) == 49)
        let rows = AskActivityDetail.rows([step("one")])
        #expect(rows.map(\.id) == ["one/reasoning", "one/note", "call-one"])
        let plan = AskMessage(id: "plan", role: "assistant", text: "", toolCalls: [
            .init(id: "p", function: .init(name: "update_plan", arguments: "{}"))
        ], createdAt: now)
        #expect(AskActivityDetail.rows([plan]).isEmpty)
    }

    @Test func longTextPreservesSelectionAndCanRestyleWithoutChangingContent() throws {
        let scroll = AskReasoningText.makeScrollView()
        let editor = try #require(scroll.documentView as? AskReasoningText.Editor)
        let text = String(repeating: "a long line of output\n", count: 10_000)
        editor.setContent(text, monospaced: true)
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        editor.setContent(text + "tail", monospaced: true)
        #expect(editor.string == text + "tail")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 7))
        editor.setContent(text + "tail", monospaced: true, isError: true)
        #expect(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
        editor.setContent("replacement")
        #expect(editor.string == "replacement")
    }

    @Test func largeHistoriesPrepareOnceAndOnlyDecodeNewReceipts() {
        for count in [100, 500, 1000] {
            let cache = AskActivityOutputCache()
            var messages = [user("q")] + (0..<count).map { step(String($0)) }
            var results = (0..<count).map { result(String($0)) }
            let start = ContinuousClock.now
            let items = cache.prepare(conversationID: "chat", messages: messages, results: results, changes: [:])
            let cold = start.duration(to: .now)
            #expect(items.count == count * 2 + 2)
            #expect(cache.decodeCount == count)
            let warmStart = ContinuousClock.now
            for _ in 0..<20 {
                _ = cache.prepare(conversationID: "chat", messages: messages, results: results, changes: [:])
            }
            #expect(cache.preparationCount == 1)
            messages.append(step("new")); results.append(result("new"))
            _ = cache.prepare(conversationID: "chat", messages: messages, results: results, changes: [:])
            #expect(cache.decodeCount == count + 1)
            print("ACTIVITY_PERF steps=\(count) cold=\(cold) warm20_and_append=\(warmStart.duration(to: .now))")
        }
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 640))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func expandedThousandStepHistoryHasBoundedLayoutAndResultsStayVisibleWhileActive() {
        _ = NSApplication.shared
        let messages = (0..<1000).map { step(String($0)) }
        let group = AskActivityGroup(id: "g", messages: messages)
        let start = ContinuousClock.now
        let large = height(AskActivityBlock(group: group, results: [], plan: nil, status: .running, startsExpanded: true))
        let small = height(AskActivityBlock(group: .init(id: "g", messages: Array(messages.prefix(100))),
                                            results: [], plan: nil, status: .running, startsExpanded: true))
        #expect(large < 1500)
        #expect(abs(large - small) < 50)
        print("ACTIVITY_LAYOUT steps=1000 height=\(large) two_layouts=\(start.duration(to: .now))")
        let changes = (0..<100).map { AskWorkspaceFileChange(path: "outputs/\($0).txt", kind: .added) }
        let outcome = AskTaskOutcome(id: "outcome-q", messageIDs: ["a"], runIDs: ["run"], changes: changes)
        var outputs = AskRunOutputs(); outputs.sources = [URL(string: "https://example.com")!]
        let active = height(AskTaskOutcomeView(outcome: outcome, outputs: outputs, active: true, actions: .init()))
        let done = height(AskTaskOutcomeView(outcome: outcome, outputs: outputs, active: false, actions: .init()))
        #expect(active > 100)
        #expect(active == done)
        #expect(active < 600)
        #expect(height(AskMonoBlock(title: "Output", text: String(repeating: "line\n", count: 10000))) < 350)
    }
}
