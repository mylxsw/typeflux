import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct TerminalLauncherModelTests {
    private func osc(_ text: String) -> String { "\u{1b}]" + text + "\u{7}" }

    @Test func `prompt routes commands plain input and passwords through the PTY`() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let session = try center.create()
        defer { center.terminateAll() }
        let model = TerminalLauncherModel(session: session, settings: .init(), source: nil,
                                          notify: { _, _ in false }, visible: { true })
        #expect(model.prompt == .idle)
        #expect(!model.submit())
        model.fill("read input")
        process.emit(osc("133;A") + osc("133;B"))
        #expect(model.submit())
        #expect(model.text.isEmpty && model.prompt == .running && !model.submit())
        process.emit(osc("133;C") + "Input: ")
        #expect(model.prompt == .input)
        model.synchronizePrompt()
        model.text = "two\nlines"
        #expect(!model.submit())
        model.text = "answer"
        #expect(model.submit() && model.text.isEmpty)
        #expect(process.writes.last == Array("answer\r".utf8))

        process.readsHiddenInput = true
        session.refreshInput()
        model.synchronizePrompt()
        #expect(model.prompt == .secure && model.text.isEmpty)
        model.secret = "expired prompt response"
        process.readsHiddenInput = false
        #expect(!model.submit() && model.secret.isEmpty)
        #expect(process.writes.last == Array("answer\r".utf8))
        process.readsHiddenInput = true
        model.secret = "hidden test response"
        #expect(model.submit() && model.secret.isEmpty)
        #expect(process.writes.last == Array("hidden test response\r".utf8))
        process.readsHiddenInput = false
        process.emit(osc("133;D;0") + osc("133;B"))
        #expect(model.prompt == .idle && history.commands == ["read input"])

        process.exit(0)
        #expect(model.prompt == .ended && !model.submit())
    }

    @Test func riskyPromptStagesOnceAndCancellationLeavesNoHistory() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let settings = TerminalRunSettings(insert: .commandAndOutput)
        let session = try center.create(settings: settings)
        defer { center.terminateAll() }
        let model = TerminalLauncherModel(session: session, settings: settings, source: nil,
                                          notify: { _, _ in false }, visible: { true })
        process.emit(osc("133;B"))
        model.fill("rm -rf sample")
        #expect(!model.submit() && !model.submit())
        #expect(model.pendingRisk == .delete && process.writes.isEmpty && session.blocks.isEmpty)
        #expect(model.cancelRisk() && !model.cancelRisk())
        #expect(model.pendingRisk == nil && model.text.isEmpty)
        let cancelled = try #require(session.blocks.last)
        #expect(cancelled.state == .cancelled && !TerminalLauncherModel.mark(cancelled).isEmpty)
        #expect(history.commands.isEmpty)
        model.insert(cancelled) { _ in Issue.record("Cancelled command was inserted") }

        model.fill("git push --force")
        #expect(!model.submit() && model.pendingRisk == .forcePush)
        model.text = "git status"
        #expect(!model.confirmRisk() && model.pendingRisk == nil)
        model.fill("git reset --hard")
        #expect(!model.submit() && model.confirmRisk() && !model.confirmRisk())
        #expect(process.writes.count == 1 && history.commands == ["git reset --hard"])
        process.emit(osc("133;C") + "test output\r\n" + osc("133;D;0"))
        model.insertSelected { #expect($0 == "git reset --hard\ntest output") }
        model.fill("rm -r sample")
        #expect(!model.submit() && model.pendingRisk == .delete)
        process.exit(0)
        model.synchronizePrompt()
        #expect(model.pendingRisk == nil && !model.confirmRisk())
    }

    @Test func promptCompletionCyclesAndRiskConfirmationCanBeDisabled() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let settings = TerminalRunSettings(confirmsRisky: false)
        let session = try center.create(settings: settings)
        defer { center.terminateAll() }
        let model = TerminalLauncherModel(session: session, settings: settings, source: nil,
                                          notify: { _, _ in false }, visible: { true })
        model.fill("git sta")
        #expect(model.complete() && model.text == "git stash")
        #expect(model.completionCandidates == ["stash", "status"])
        #expect(model.complete() && model.text == "git status")
        #expect(model.resetCompletion() && !model.resetCompletion())
        model.fill("rm -rf sample")
        process.emit(osc("133;B"))
        #expect(model.submit() && model.pendingRisk == nil)
        #expect(process.writes.count == 1 && model.completionCandidates.isEmpty && !model.complete())
    }

    @Test func `background completion respects the ten second threshold`() {
        let start = Date()
        var block = TerminalCommandBlock(command: "git status", cwd: "/tmp", startedAt: start)
        #expect(TerminalLauncherModel.backgroundCompletion(block) == nil)
        block.exitCode = 1
        block.state = .finished
        block.endedAt = start.addingTimeInterval(9)
        #expect(TerminalLauncherModel.backgroundCompletion(block) == nil)
        block.endedAt = start.addingTimeInterval(10)
        #expect(TerminalLauncherModel.backgroundCompletion(block) == "✗ 1 git status · 10.0s")
    }

    @Test func `history preserves the draft and offers the latest prefix match`() {
        var history = TerminalLauncherModel.History()
        let commands = ["git status", "pwd", "git log"]
        #expect(TerminalLauncherModel.History.suggestion(for: "git ", commands: commands) == "git status")
        #expect(TerminalLauncherModel.History.suggestion(for: "pwd", commands: commands) == nil)
        #expect(TerminalLauncherModel.History.suggestion(for: "", commands: commands) == nil)
        #expect(history.move(1, commands: [], current: "draft") == "draft")
        #expect(history.move(1, commands: commands, current: "draft") == "git status")
        #expect(history.move(1, commands: commands, current: "git status") == "pwd")
        #expect(history.move(-1, commands: commands, current: "pwd") == "git status")
        #expect(history.move(-1, commands: commands, current: "git status") == "draft")
    }

    @Test func `block selection supplies insertion output and clear keeps the running block`() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let session = try center.create()
        defer { center.terminateAll() }
        let model = TerminalLauncherModel(session: session, settings: .init(), source: nil,
                                          notify: { _, _ in false }, visible: { true })
        model.select(-1)
        #expect(!model.deselect() && model.actionBlock == nil)
        process.emit(osc("133;A") + osc("133;B"))
        for (command, code) in [("first", 1), ("second", 0)] {
            model.fill(command)
            #expect(model.submit())
            process.emit(osc("133;C") + command + "\r\n" + osc("133;D;\(code)") + osc("133;B"))
        }
        #expect(model.actionBlock?.output.string == "second")
        model.select(-1)
        model.select(-1)
        let selected = try #require(model.actionBlock)
        var inserted: [String] = []
        model.insertSelected { inserted.append($0) }
        #expect(inserted == ["first"])
        #expect(TerminalLauncherModel.mark(selected) == "✗ 1")
        model.toggleCollapsed(selected.id)
        #expect(model.collapsed.contains(selected.id))
        model.toggleCollapsed(selected.id)
        #expect(model.collapsed.isEmpty)
        #expect(model.deselect())
        model.recall(1, commands: history.commands)
        #expect(model.text == "second")
        #expect(model.submit())
        model.clear()
        #expect(session.blocks.count == 1 && session.runningBlock?.command == "second")
        #expect(model.actionBlock == nil && model.selected == nil && process.terminations == 0)
        model.insertSelected { inserted.append($0) }
        #expect(inserted == ["first"])
    }
}
