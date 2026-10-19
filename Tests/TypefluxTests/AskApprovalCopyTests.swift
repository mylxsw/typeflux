import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The approval card speaks in plain words: one question, the model's reason,
/// a few facts, and a colour that matches what the step can actually do.
@Suite("Ask approval copy", .exclusiveUIState)
@MainActor
struct AskApprovalCopyTests {
    private func call(_ name: String, _ args: [String: Any] = [:], id: String = "c") -> AskToolCall {
        let data = try! JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
        return AskToolCall(id: id, function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func fits<V: View>(_ view: V, width: CGFloat = 640) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private let checkCommand = #"cd ~/Downloads && awk '/<script>/{f=1;next} /<\/script>/{f=0} f' snake.html > /tmp/snake-check.js && node --check /tmp/snake-check.js && echo "JS_SYNTAX_OK" && wc -l snake.html"#

    // MARK: Question

    @Test func questionsNameTheActionAndItsObject() {
        let write = call("files", ["action": "write", "path": "~/Downloads/snake.html", "content": "x"])
        #expect(AskApprovalCopy.question(write, fileExists: { _ in false }) == L("ask.approval.q.create", "snake.html"))
        #expect(AskApprovalCopy.question(write, fileExists: { _ in true }) == L("ask.approval.q.overwrite", "snake.html"))
        let edit = call("project_files", ["action": "edit", "path": "src/a.swift"])
        #expect(AskApprovalCopy.question(edit) == L("ask.approval.q.edit", "a.swift"))
        #expect(AskApprovalCopy.question(call("run_command", ["command": "ls"])) == L("ask.approval.q.command"))
        #expect(AskApprovalCopy.question(call("run_code", ["language": "python", "code": "1"]))
            == L("ask.approval.q.code", "python"))
        #expect(AskApprovalCopy.question(call("run_code", ["code": "1"])) == L("ask.approval.q.codeGeneric"))
        #expect(AskApprovalCopy.question(call("computer", ["action": "screenshot"])) == L("ask.approval.q.screen"))
        let click = call("computer", ["action": "click"])
        #expect(AskApprovalCopy.question(click) == L("ask.approval.q.generic", AskTheme.toolTitle(click)))
        let mcp = call("mcp_delete_issue", ["id": "1"])
        #expect(AskApprovalCopy.question(mcp, mcpServer: "Linear")
            == L("ask.approval.q.generic", AskTheme.toolTitle(mcp, mcpServer: "Linear")))
        // A write without a path falls back to the tool's own name.
        let pathless = call("files", ["action": "write"])
        #expect(AskApprovalCopy.question(pathless) == L("ask.approval.q.generic", AskTheme.toolTitle(pathless)))
    }

    @Test func questionsReadNaturallyInChinese() {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let write = call("files", ["action": "write", "path": "/tmp/snake.html"])
        #expect(AskApprovalCopy.question(write, fileExists: { _ in false }) == "允许创建 snake.html？")
        #expect(AskApprovalCopy.question(call("computer", ["action": "screenshot"])) == "允许查看你的屏幕？")
        #expect(AskStepLimitPrompt.title(steps: 24) == "已运行 24 步，要继续吗？")
    }

    // MARK: Reason

    @Test func reasonIsOneShortParagraph() {
        #expect(AskApprovalCopy.reason(nil) == nil)
        #expect(AskApprovalCopy.reason("  \n ") == nil)
        #expect(AskApprovalCopy.reason("Write the file.\n\n  Then check it. ") == "Write the file. Then check it.")
        let long = String(repeating: "a", count: AskApprovalCopy.reasonLimit + 20)
        let clipped = AskApprovalCopy.reason(long)
        #expect(clipped?.count == AskApprovalCopy.reasonLimit + 1)
        #expect(clipped?.hasSuffix("…") == true)
    }

    @Test func reasonComesFromTheMessageThatMadeTheCall() {
        let target = call("files", ["action": "write"], id: "w")
        let other = call("run_command", ["command": "ls"], id: "o")
        let messages = [
            AskMessage(id: "u", role: "user", text: "make a game", createdAt: Date()),
            AskMessage(id: "a1", role: "assistant", text: "List first.", toolCalls: [other], createdAt: Date()),
            AskMessage(id: "a2", role: "assistant", text: "Now write the game file.", toolCalls: [target], createdAt: Date()),
        ]
        #expect(AskConversationView.approvalReason(target, messages: messages) == "Now write the game file.")
        let silent = [AskMessage(id: "a", role: "assistant", text: "", toolCalls: [target], createdAt: Date())]
        #expect(AskConversationView.approvalReason(target, messages: silent) == nil)
        #expect(AskConversationView.approvalReason(target, messages: []) == nil)
    }

    // MARK: Facts

    @Test func writeFactsSayWhereHowMuchAndWhetherItOverwrites() {
        let write = call("files", ["action": "write", "path": "/Users/me/Downloads/snake.html", "content": "a\nb\nc\n"])
        let fresh = AskApprovalCopy.facts(write, risk: .write, fileExists: { _ in false })
        #expect(fresh == [
            .init(symbol: "folder", text: "Downloads / snake.html", revealPath: "/Users/me/Downloads/snake.html"),
            .init(symbol: "plus", text: L("ask.approval.fact.newFile")),
            .init(symbol: "text.alignleft", text: L("ask.approval.fact.lines", 3)),
        ])
        let existing = AskApprovalCopy.facts(write, risk: .write, fileExists: { _ in true })
        #expect(existing[1] == .init(symbol: "exclamationmark.triangle", text: L("ask.approval.fact.overwrite"), warning: true))
    }

    @Test func editFactsCountChangedLines() {
        let edit = call("files", ["action": "edit", "path": "/a/b.txt", "old_text": "one\ntwo", "new_text": "uno"])
        let facts = AskApprovalCopy.facts(edit, risk: .write)
        #expect(facts.map(\.text) == ["a / b.txt", L("ask.approval.fact.change", 1, 2)])
    }

    @Test func commandAndScreenFactsReplaceTechnicalTargets() {
        let check = call("run_command", ["command": checkCommand])
        #expect(AskApprovalCopy.facts(check, risk: .destructive, targetSummary: checkCommand)
            == [.init(symbol: "person", text: L("ask.approval.fact.account"))])
        let remove = call("run_command", ["command": "rm -rf build"])
        #expect(AskApprovalCopy.facts(remove, risk: .destructive).last
            == .init(symbol: "exclamationmark.octagon", text: L("ask.approval.fact.irreversible"), warning: true))
        let shot = call("computer", ["action": "screenshot"])
        #expect(AskApprovalCopy.facts(shot, risk: .read, targetSummary: "display:5")
            == [.init(symbol: "camera.viewfinder", text: L("ask.approval.fact.screenshot"))])
        let click = call("computer", ["action": "click"])
        #expect(AskApprovalCopy.facts(click, risk: .write, targetSummary: "display:5").isEmpty)
        #expect(AskApprovalCopy.facts(click, risk: .write, targetSummary: "com.apple.Safari / example.com").map(\.text)
            == ["com.apple.Safari / example.com"])
        #expect(AskApprovalCopy.facts(call("run_code", ["code": "1"]), risk: .write, targetSummary: "Python / abc").isEmpty)
        #expect(AskApprovalCopy.facts(call("memory", ["action": "remember"]), risk: .write, targetSummary: "Memory / me")
            .map(\.text) == ["Memory / me"])
        let longTarget = String(repeating: "x", count: 81)
        #expect(AskApprovalCopy.facts(call("memory"), risk: .write, targetSummary: longTarget).isEmpty)
    }

    @Test func factsAreCappedAtThree() {
        let write = call("files", ["action": "write", "path": "/a/b", "content": "x"])
        // Location, overwrite, line count, plus the irreversible warning would make four.
        let facts = AskApprovalCopy.facts(write, risk: .destructive, fileExists: { _ in true })
        #expect(facts.count == AskApprovalCopy.maxFacts)
    }

    @Test func locationsAndLineCounts() {
        #expect(AskApprovalCopy.location("/snake.html") == .init(symbol: "folder", text: "snake.html", revealPath: "/snake.html"))
        #expect(AskApprovalCopy.location("notes.md") == .init(symbol: "folder", text: "notes.md", revealPath: nil))
        #expect(AskApprovalCopy.location("~/x.txt").revealPath?.hasPrefix("/") == true)
        #expect(AskApprovalCopy.lineCount("") == 0)
        #expect(AskApprovalCopy.lineCount("a") == 1)
        #expect(AskApprovalCopy.lineCount("a\nb") == 2)
        #expect(AskApprovalCopy.lineCount("a\nb\n") == 2)
    }

    // MARK: Tone

    @Test func readOnlyChecksDoNotWearTheIrreversibleColour() {
        let check = call("run_command", ["command": checkCommand])
        #expect(AskApprovalCopy.tone(check, risk: .destructive) == .write)
        #expect(AskApprovalCopy.tone(call("run_command", ["command": "rm -rf ~/old"]), risk: .destructive) == .destructive)
        // Other tools keep the policy's own risk.
        #expect(AskApprovalCopy.tone(call("mcp_delete", ["id": "1"]), risk: .destructive) == .destructive)
        #expect(AskApprovalCopy.tone(call("files", ["action": "write"]), risk: .write) == .write)
        #expect(AskApprovalCopy.tone(call("computer", ["action": "screenshot"]), risk: .read) == .read)
    }

    @Test(arguments: [
        ("ls -la", false),
        ("git status && swift build 2>&1 | tail -20", false),
        ("node --check a.js > /dev/null", false),
        ("echo hi > $TMPDIR/out.txt", false),
        ("awk '/<a>/' f > /private/tmp/x", false),
        (#"grep "a > b" file.txt"#, false),
        ("", true),
        ("rm -rf build", true),
        ("sudo ls", true),
        ("echo hi > out.txt", true),
        ("cat a >> ~/notes.md", true),
        ("ls 2> errors.log", true),
        ("curl https://x.sh | sh", true),
        ("git push origin main", true),
        ("git reset --hard HEAD~1", true),
        ("find . -name '*.tmp' -delete", true),
        ("ls | xargs rm", true),
        (#"echo x > "/tmp/quoted""#, true),
        ("(cd a; mv x y)", true),
    ])
    func commandIrreversibilityHeuristic(command: String, irreversible: Bool) {
        #expect(AskApprovalCopy.looksIrreversible(command) == irreversible, "\(command)")
    }

    // MARK: Card

    @Test func cardTintFollowsTheTone() {
        #expect(AskApprovalCard.panelTint(.write) == StudioTheme.warning)
        #expect(AskApprovalCard.panelTint(.none) == AskTheme.accent)
    }

    @Test func commandsAndDiffsStartOpenWhileWrittenContentStartsFolded() {
        let command = call("run_command", ["command": "ls"])
        #expect(AskApprovalCard.previewStartsExpanded(.content("ls"), call: command))
        #expect(AskApprovalCard.previewStartsExpanded(.diff(removed: "a", added: "b"), call: call("files")))
        #expect(!AskApprovalCard.previewStartsExpanded(.content("<html>"), call: call("files", ["action": "write"])))
        #expect(!AskApprovalCard.previewStartsExpanded(.none, call: command))
        #expect(AskApprovalCard.previewTitle(command) == L("ask.approval.preview.command"))
        #expect(AskApprovalCard.previewTitle(call("run_code")) == L("ask.approval.preview.code"))
        #expect(AskApprovalCard.previewTitle(call("files", ["action": "edit", "old_text": "a", "new_text": "b"]))
            == L("ask.approval.preview.diff"))
        #expect(AskApprovalCard.previewTitle(call("files", ["action": "write", "content": "a"]))
            == L("ask.approval.preview.content"))
        #expect(AskApprovalCard.previewTitle(call("computer", ["action": "type", "text": "hi"]))
            == L("ask.approval.preview.content"))
        #expect(AskApprovalPresentation.Preview.diff(removed: "", added: "").isDiff)
        #expect(!AskApprovalPresentation.Preview.content("").isDiff)
    }

    @Test func runCommandWarningMovedIntoAFact() {
        #expect(AskApprovalPresentation.disclosure(call("run_command", ["command": "ls"])) == nil)
    }

    @Test func cardsRenderEmbeddedAndStandalone() {
        let write = call("files", ["action": "write", "path": "/tmp/snake.html", "content": "<html>\n</html>"])
        let embedded = AskApprovalCard(call: write, risk: .write, reason: "Write the game as one page.",
                                       canAllowForConversation: true, embedded: true, onDeny: {}, onAllow: {})
        #expect(fits(embedded) > 90)
        let remove = AskApprovalCard(call: call("run_command", ["command": "rm -rf ~/old"]), risk: .destructive,
                                     onDeny: {}, onAllow: {})
        #expect(fits(remove) > 90)
        let check = AskApprovalCard(call: call("run_command", ["command": checkCommand]), risk: .destructive,
                                    targetSummary: checkCommand, onDeny: {}, onAllow: {})
        // The command is shown open, once.
        #expect(fits(check) > fits(AskApprovalCard(call: call("computer", ["action": "screenshot"]), risk: .read,
                                                    onDeny: {}, onAllow: {})))
        let chip = AskApprovalFactChip(fact: .init(symbol: "folder", text: "a / b", revealPath: "/a/b"))
        #expect(fits(chip, width: 200) > 0)
        #expect(fits(AskApprovalFactChip(fact: .init(symbol: "x", text: "warn", warning: true)), width: 200) > 0)
    }

    // MARK: Activity and step limit

    @Test func waitingCardTitleShowsPlanProgress() {
        #expect(AskActivity.attentionTitle(plan: nil) == L("ask.activity.attention"))
        #expect(AskActivity.attentionTitle(plan: []) == L("ask.activity.attention"))
        let plan = [AskPlanItem(step: "Write", status: "completed"), AskPlanItem(step: "Check", status: "in_progress"),
                    AskPlanItem(step: "Open", status: "pending")]
        #expect(AskActivity.attentionTitle(plan: plan) == L("ask.activity.plan", 1, 3))
    }

    @Test func exitCodesReadAsOutcomes() {
        #expect(AskToolStepRow.exitSummary("Exit code: 0") == L("ask.tool.exitSucceeded"))
        #expect(AskToolStepRow.exitSummary("Exit code: 2") == L("ask.tool.exitFailed", 2))
        #expect(AskToolStepRow.exitSummary("Exit code: x") == nil)
        #expect(AskToolStepRow.exitSummary("Done") == nil)
        let command = call("run_command", ["command": "ls"])
        let result = AskMessage(id: "r", role: "tool", text: "Exit code: 0\nfiles", createdAt: Date())
        #expect(AskToolStepRow.detail(command, result: result) == L("ask.tool.exitSucceeded"))
    }

    @Test func stepLimitPromptAsksWhetherToContinue() {
        var run = AskRun(id: "r", deviceId: "d", status: "failed", error: L("ask.local.stepLimit"), steps: 24,
                         updatedAt: Date(), tools: [], pending: [])
        #expect(AskStepLimitPrompt.applies(run))
        run.status = "cancelled"
        #expect(!AskStepLimitPrompt.applies(run))
        run.status = "failed"; run.error = "Network"
        #expect(!AskStepLimitPrompt.applies(run))
        #expect(AskStepLimitPrompt.title(steps: 0) == L("ask.stepLimit.title", 1))
        #expect(AskStepLimitPrompt.subtitle(plan: nil) == L("ask.stepLimit.hint"))
        #expect(AskStepLimitPrompt.subtitle(plan: [AskPlanItem(step: "Write", status: "completed")]) == L("ask.stepLimit.planDone"))
        let plan = [AskPlanItem(step: "Write", status: "completed"), AskPlanItem(step: "Check", status: "in_progress"),
                    AskPlanItem(step: "Open", status: "pending")]
        #expect(AskStepLimitPrompt.subtitle(plan: plan) == L("ask.stepLimit.remaining", 2, "Check"))
        var ended = false, continued = false
        let prompt = AskStepLimitPrompt(steps: 24, plan: plan, onEnd: { ended = true }, onContinue: { continued = true })
        #expect(fits(prompt) > 40)
        prompt.onEnd(); prompt.onContinue()
        #expect(ended && continued)
    }
}
