import Foundation
import Testing
@testable import Typeflux

@Suite("Chat run phase")
@MainActor
struct AskRunPhaseTests {
    private func run(_ status: String, steps: Int = 3, recovery: AskRunRecovery? = nil) -> AskRun {
        var value = AskRecoveryFixture.conversation().run!
        value.status = status
        value.steps = steps
        value.recovery = recovery
        return value
    }

    private func recovery(_ run: AskRun?, entries: [AskExecutionEntry] = []) -> AskRecoveryPresentation {
        .init(run: run, entries: entries, deviceId: "device", local: false)
    }

    @Test func noRunHasNoPhase() {
        #expect(AskRunPhase.resolve(run: nil, busy: false, pendingApproval: false, recovery: nil) == nil)
        #expect(AskRunPhase.resolve(run: nil, busy: true, pendingApproval: false, recovery: nil) == .working(step: 1))
    }

    @Test func busyRunWorksWithTheRunsOwnStep() {
        let value = run("running", steps: 7)
        let phase = AskRunPhase.resolve(run: value, busy: true, pendingApproval: false, recovery: recovery(value))
        #expect(phase == .working(step: 7))
        #expect(phase?.isWorking == true)
        #expect(phase?.step == 7)
        #expect(phase?.tone == .running)
        #expect(phase?.summary == L("ask.run.running", 7))
    }

    @Test func unknownOutcomeStopsEveryIndicatorEvenWhileBusy() {
        let value = run("waiting_tool", steps: 7)
        let unknown = AskExecutionEntry(id: "run/call", audit: AskRecoveryFixture.audit(
            AskRecoveryFixture.conversation()), receipt: nil)
        let presentation = recovery(value, entries: [unknown])
        #expect(presentation.unknown)
        for busy in [true, false] {
            let phase = AskRunPhase.resolve(run: value, busy: busy, pendingApproval: true, recovery: presentation)
            #expect(phase == .needsDecision(step: 7))
            #expect(phase?.isWorking == false)
            #expect(phase?.tone == .attention)
            #expect(phase?.summary == L("ask.run.needsDecision"))
            #expect(phase?.step == 7)
        }
    }

    @Test func pausedRunWithoutDriverNeedsDecision() {
        let value = run("waiting_tool", steps: 2)
        let presentation = recovery(value)
        #expect(presentation.canContinue)
        #expect(AskRunPhase.resolve(run: value, busy: false, pendingApproval: false,
                                    recovery: presentation) == .needsDecision(step: 2))
        // While a local operation drives it, the same run is simply working.
        #expect(AskRunPhase.resolve(run: value, busy: true, pendingApproval: false,
                                    recovery: presentation) == .working(step: 2))
    }

    @Test func approvalWaitsForTheUser() {
        let value = run("waiting_tool")
        let phase = AskRunPhase.resolve(run: value, busy: true, pendingApproval: true, recovery: recovery(value))
        #expect(phase == .approval)
        #expect(phase?.tone == .attention)
        #expect(phase?.summary == L("ask.run.attention"))
        #expect(phase?.step == nil)
    }

    @Test func activeRunWithoutRecoveryWorks() {
        let value = run("running", steps: 0)
        #expect(AskRunPhase.resolve(run: value, busy: false, pendingApproval: false, recovery: nil)
            == .working(step: 1))
    }

    @Test func settledRunsMapToTheirStatus() {
        let completed = AskRunPhase.resolve(run: run("completed", steps: 4), busy: false, pendingApproval: false,
                                            recovery: nil)
        #expect(completed == .completed(steps: 4))
        #expect(completed?.tone == .done)
        #expect(completed?.summary == L("ask.run.completed", 4))
        let failed = AskRunPhase.resolve(run: run("failed"), busy: false, pendingApproval: false, recovery: nil)
        #expect(failed == .failed && failed?.tone == .failed && failed?.summary == L("ask.run.failed"))
        let cancelled = AskRunPhase.resolve(run: run("cancelled"), busy: false, pendingApproval: false, recovery: nil)
        #expect(cancelled == .cancelled && cancelled?.tone == .failed
            && cancelled?.summary == L("ask.run.cancelled"))
        #expect(AskRunPhase.resolve(run: run("mystery"), busy: false, pendingApproval: false, recovery: nil)
            == .working(step: 3))
    }

    @Test func stopIsOfferedWhileTheRunIsHeldOpen() {
        #expect(AskRunPhase.working(step: 1).offersStop)
        #expect(AskRunPhase.approval.offersStop)
        for phase in [AskRunPhase.needsDecision(step: 2), .completed(steps: 1), .failed, .cancelled] {
            #expect(!phase.offersStop)
        }
    }

    @Test func stopControlFollowsThePhase() {
        #expect(AskSendControl.resolve(busy: false, hasDraft: false, canSend: false, editingQueued: false)
            == .send(enabled: false))
        #expect(AskSendControl.resolve(busy: true, hasDraft: false, canSend: false, editingQueued: false) == .stop)
    }
}

@Suite("Chat activity line while paused")
@MainActor
struct AskActivityPausedTests {
    private let group = AskActivityGroup(id: "a", messages: [
        AskMessage(id: "a", role: "assistant", text: "", toolCalls: [
            .init(id: "c", function: .init(name: "web_search", arguments: "{}"))
        ], createdAt: Date())
    ])

    @Test func haltedBlockNeitherSpinsNorReadsDone() {
        let status = AskActivity.status(group, results: [], streamingId: "a", approvalToolId: nil,
                                        live: true, halted: true)
        #expect(status == .paused)
        #expect(AskActivity.status(group, results: [], streamingId: nil, approvalToolId: "c", halted: true)
            == .attention)
        #expect(AskActivity.title(group, status: .paused, plan: nil, results: [])
            == AskActivity.title(group, status: .running, plan: nil, results: []))
    }

    @Test func stepNoteSharesTheRunsStep() {
        #expect(AskActivity.stepNote(group, status: .running) == L("ask.activity.step", 1))
        #expect(AskActivity.stepNote(group, status: .running, runStep: 7) == L("ask.activity.step", 7))
        #expect(AskActivity.stepNote(group, status: .paused, runStep: 7) == L("ask.activity.pausedAt", 7))
        #expect(AskActivity.stepNote(group, status: .paused) == L("ask.activity.pausedAt", 1))
        let empty = AskActivityGroup(id: "e", messages: [])
        #expect(AskActivity.stepNote(empty, status: .running) == nil)
        #expect(AskActivity.stepNote(empty, status: .paused, runStep: 0) == L("ask.activity.pausedAt", 1))
    }
}

@Suite("Chat recovery actions")
@MainActor
struct AskRecoveryActionTests {
    private let value = AskRecoveryFixture.conversation()

    private func presentation(_ entries: [AskExecutionEntry], deviceId: String = "device",
                              status: String? = nil) -> AskRecoveryPresentation {
        var run = value.run
        if let status { run?.status = status }
        return .init(run: run, entries: entries, deviceId: deviceId, local: false)
    }

    private var unknownEntry: AskExecutionEntry {
        .init(id: "run/call", audit: AskRecoveryFixture.audit(value), receipt: nil)
    }

    private var savedEntry: AskExecutionEntry {
        .init(id: "run/call", audit: AskRecoveryFixture.audit(value), receipt: AskRecoveryFixture.receipt(value))
    }

    @Test func unknownOffersCheckStopAndDetails() {
        let unknown = presentation([unknownEntry])
        let actions = unknown.actions(canRetransmit: false, canContinue: false)
        #expect(actions == .init(primary: .checkAndContinue, stop: true, details: true))
        #expect(unknown.options(canRetransmit: false, canContinue: false) == [.checkAndContinue, .selfCheck, .stop])
    }

    @Test func stoppedUnknownCannotBeStoppedAgain() {
        let stopped = presentation([unknownEntry], status: "cancelled")
        #expect(stopped.actions(canRetransmit: false, canContinue: false)
            == .init(primary: .checkAndContinue, stop: false, details: true))
        #expect(stopped.options(canRetransmit: false, canContinue: false) == [.checkAndContinue, .selfCheck])
    }

    @Test func otherDeviceOffersNoAction() {
        let other = presentation([unknownEntry], deviceId: "elsewhere")
        #expect(other.actions(canRetransmit: true, canContinue: true).primary == nil)
        #expect(other.options(canRetransmit: true, canContinue: true).isEmpty)
    }

    @Test func refreshAppearsOnlyWithSavedProgress() {
        let saved = presentation([savedEntry])
        #expect(saved.savedReceipts == 1)
        #expect(saved.actions(canRetransmit: true, canContinue: false).primary == .refresh)
        #expect(saved.actions(canRetransmit: false, canContinue: false).primary == nil)
        #expect(saved.options(canRetransmit: true, canContinue: false) == [.refresh, .stop])
        let none = presentation([])
        #expect(none.savedReceipts == 0)
        #expect(none.actions(canRetransmit: true, canContinue: false).primary != .refresh)
    }

    @Test func pausedRunContinues() {
        let paused = presentation([])
        #expect(paused.actions(canRetransmit: false, canContinue: true)
            == .init(primary: .continueRun, stop: true, details: true))
        #expect(paused.actions(canRetransmit: false, canContinue: false).primary == nil)
        #expect(paused.options(canRetransmit: false, canContinue: true) == [.continueRun, .stop])
    }

    @Test func invisibleNoticeHasNoActions() {
        let done = presentation([], status: "completed")
        #expect(!done.isVisible)
        #expect(done.actions(canRetransmit: false, canContinue: false) == .init(primary: nil, stop: false, details: false))
    }

    @Test func everyActionHasLocalizedCopy() {
        for action in AskRecoveryAction.allCases {
            for key in [action.titleKey, action.optionTitleKey, action.optionBodyKey,
                        action.optionBodyKey(active: false)] {
                #expect(L(key) != key, "Missing \(key)")
            }
            #expect(!AskRecoveryCard.symbol(action).isEmpty)
        }
        #expect(AskRecoveryAction.stop.isDestructive && !AskRecoveryAction.refresh.isDestructive)
        #expect(AskRecoveryAction.selfCheck.optionBodyKey(active: false) == "ask.recovery.followUpBody")
        #expect(AskRecoveryAction.selfCheck.optionBodyKey(active: true) == "ask.recovery.checkBody")
        #expect(AskRecoveryAction.refresh.titleKey == "ask.recovery.retransmit")
    }
}

@Suite("Chat recovery timeline")
@MainActor
struct AskRecoveryTimelineTests {
    @Test func countsStepsWithoutNamingTools() {
        var run = AskRecoveryFixture.conversation().run!
        run.steps = 7
        let timeline = AskRecoveryTimeline(run: run, unknown: true)
        #expect(timeline.items == [
            .init(title: L("ask.recovery.timeline.done", 6), detail: nil, state: .done),
            .init(title: L("ask.activity.step", 7) + " · " + L("ask.recovery.timeline.unknown"), detail: nil,
                  state: .current)
        ])
        #expect(!timeline.items.map(\.title).joined().contains("browser"))
        run.steps = 1
        #expect(AskRecoveryTimeline(run: run, unknown: false).items == [
            .init(title: L("ask.activity.step", 1) + " · " + L("ask.recovery.timeline.paused"), detail: nil,
                  state: .current)
        ])
        #expect(AskRecoveryTimeline(run: nil, unknown: true).items.isEmpty)
    }

    @Test func followsTheRunsPlan() {
        var run = AskRecoveryFixture.conversation().run!
        run.plan = [.init(step: "Draft manifest", status: "completed"),
                    .init(step: "Write main.py", status: "in_progress"),
                    .init(step: "Set keywords", status: "pending")]
        let items = AskRecoveryTimeline(run: run, unknown: false).items
        #expect(items.map(\.state) == [.done, .current, .upcoming])
        #expect(items[1].title == "Write main.py · " + L("ask.recovery.timeline.paused"))
        #expect(items.map(\.detail) == [L("ask.activity.step", 1), L("ask.activity.step", 2), L("ask.activity.step", 3)])
    }
}

@Suite("Chat workflow draft presentation")
@MainActor
struct AskWorkflowChecklistTests {
    private func manifest(keywords: [String] = ["weather"], description: String? = "Current weather",
                          script: String? = "main.py") throws -> AskWorkflowManifest {
        var object: [String: Any] = ["schema": 1, "id": "local.weather", "name": "Weather",
                                     "keywords": keywords.map { ["keyword": $0] },
                                     "command": script.map { ["runtime": "python3", "script": $0] }
                                         ?? ["runtime": "zsh", "inline": "echo hi"]]
        if let description { object["description"] = description }
        return try JSONDecoder().decode(AskWorkflowManifest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func completeDraftSummarizesEachItem() throws {
        let checklist = AskWorkflowChecklist(manifest: try manifest(keywords: ["weather", "tq"]), problems: [])
        #expect(checklist.isComplete && checklist.missing == 0 && checklist.completed == 3)
        #expect(checklist.rows.map(\.item) == [.details, .script, .keywords])
        #expect(checklist.rows[0].detail == "Weather · Current weather")
        #expect(checklist.rows[1].detail == "main.py")
        #expect(checklist.rows[2].detail == "weather" + L("ask.workflow.chat.check.separator") + "tq")
        let inline = AskWorkflowChecklist(manifest: try manifest(description: nil, script: nil), problems: [])
        #expect(inline.rows[0].detail == "Weather")
        #expect(inline.rows[1].detail == L("ask.workflow.chat.check.inlineScript"))
        #expect(AskWorkflowChecklist(manifest: nil, problems: []).rows.allSatisfy { $0.detail.isEmpty })
    }

    @Test func problemsLandOnTheirItem() throws {
        let problems: [AskWorkflowManifest.Problem] = [
            .init(field: "keywords", message: "Needs a keyword"),
            .init(field: "command.script", message: "main.py is missing"),
            .init(field: "output.mode", message: "Bad output"),
            .init(field: "id", message: "Keep the ID"),
            .init(field: "workflow.json", message: "Not JSON"),
            .init(field: "keywords[0]", message: "Taken")
        ]
        let checklist = AskWorkflowChecklist(manifest: try manifest(keywords: []), problems: problems)
        #expect(checklist.missing == 3 && !checklist.isComplete)
        #expect(checklist.rows[0].problems == ["Keep the ID", "Not JSON"])
        #expect(checklist.rows[1].problems == ["main.py is missing", "Bad output"])
        #expect(checklist.rows[2].problems == ["Needs a keyword", "Taken"])
        #expect(checklist.rows[2].detail == "Needs a keyword")
        let request = checklist.completionRequest
        #expect(request.hasPrefix(L("ask.workflow.chat.completePrompt")))
        #expect(request.contains("main.py is missing; Bad output"))
        #expect(request.contains(L("ask.workflow.chat.check.keywords") + ": Needs a keyword; Taken"))
    }

    @Test func fieldsMapToItems() {
        #expect(AskWorkflowChecklist.item(for: "keywords[2].script") == .keywords)
        #expect(AskWorkflowChecklist.item(for: "input.selection") == .script)
        #expect(AskWorkflowChecklist.item(for: "run.mode") == .script)
        #expect(AskWorkflowChecklist.item(for: "env") == .script)
        #expect(AskWorkflowChecklist.item(for: "name") == .details)
        #expect(AskWorkflowChecklist.item(for: "schema") == .details)
    }

    @Test func statusReflectsTheDraft() throws {
        let incomplete = AskWorkflowChecklist(manifest: try manifest(keywords: []),
                                              problems: [.init(field: "keywords", message: "x"),
                                                         .init(field: "command.script", message: "y")])
        let complete = AskWorkflowChecklist(manifest: try manifest(), problems: [])
        let missing = AskWorkflowDraftStatus.resolve(checklist: incomplete, isDirty: true)
        #expect(missing == .incomplete(missing: 2))
        #expect(missing.cardLabel == L("ask.workflow.chat.status.missing", 2))
        #expect(missing.badge == L("ask.workflow.chat.status.incomplete"))
        let draft = AskWorkflowDraftStatus.resolve(checklist: complete, isDirty: true)
        #expect(draft == .draft && draft.cardLabel == L("ask.workflow.chat.status.unsaved")
            && draft.badge == L("ask.workflow.chat.status.draft"))
        let saved = AskWorkflowDraftStatus.resolve(checklist: complete, isDirty: false)
        #expect(saved == .saved && saved.cardLabel == L("ask.workflow.chat.saved")
            && saved.badge == L("ask.workflow.chat.status.saved"))
    }

    @Test func saveHintExplainsTheButton() {
        let passing = AskWorkflowTestResult(input: .init(query: "x"), exitCode: 0, stdout: "", stderr: "", duration: 1)
        let bad = AskWorkflowTestResult(input: .init(query: "x"), exitCode: 2, stdout: "", stderr: "", duration: 1)
        let complete = AskWorkflowSaveHint.resolve(status: .incomplete(missing: 2), isRunning: false,
                                                   lastResult: passing, keyword: "w")
        #expect(complete == .completeFirst(missing: 2) && !complete.allowsSave && !complete.isPositive)
        #expect(complete.text == L("ask.workflow.chat.hint.complete", 2))
        let running = AskWorkflowSaveHint.resolve(status: .draft, isRunning: true, lastResult: nil, keyword: nil)
        #expect(running == .running && !running.allowsSave && running.text == L("ask.workflow.chat.hint.running"))
        let untested = AskWorkflowSaveHint.resolve(status: .draft, isRunning: false, lastResult: nil, keyword: nil)
        #expect(untested == .testFirst && untested.allowsSave && !untested.isPositive)
        #expect(untested.text == L("ask.workflow.chat.hint.testFirst"))
        let tested = AskWorkflowSaveHint.resolve(status: .draft, isRunning: false, lastResult: passing, keyword: nil)
        #expect(tested == .tested && tested.allowsSave && tested.isPositive)
        #expect(tested.text == L("ask.workflow.chat.hint.tested"))
        let failed = AskWorkflowSaveHint.resolve(status: .draft, isRunning: false, lastResult: bad, keyword: nil)
        #expect(failed == .testFailed && failed.allowsSave && !failed.isPositive)
        #expect(failed.text == L("ask.workflow.chat.hint.testFailed"))
        let saved = AskWorkflowSaveHint.resolve(status: .saved, isRunning: false, lastResult: nil, keyword: "weather")
        #expect(saved == .saved(keyword: "weather") && !saved.allowsSave && saved.isPositive)
        #expect(saved.text == L("ask.workflow.chat.hint.savedKeyword", "weather"))
        let unnamed = AskWorkflowSaveHint.resolve(status: .saved, isRunning: false, lastResult: nil, keyword: "")
        #expect(unnamed == .saved(keyword: nil) && unnamed.text == L("ask.workflow.chat.saved"))
    }

    @Test func runLogAndLineCount() {
        var result = AskWorkflowTestResult(input: .init(query: "x"), exitCode: 0, stdout: "", stderr: " \n",
                                           duration: 1)
        #expect(AskWorkflowAuthoringPanel.log(result) == "$ run\n" + L("ask.workflow.chat.logEmpty"))
        result.arguments = ["python3", "main.py", "Hangzhou"]
        result.failure = "No interpreter"
        result.stderr = "trace\n"
        #expect(AskWorkflowAuthoringPanel.log(result) == "$ python3 main.py Hangzhou\nNo interpreter\ntrace")
        #expect(AskWorkflowAuthoringPanel.lineCount(nil) == 0)
        #expect(AskWorkflowAuthoringPanel.lineCount("") == 0)
        #expect(AskWorkflowAuthoringPanel.lineCount("a") == 1)
        #expect(AskWorkflowAuthoringPanel.lineCount("a\nb\n") == 2)
        #expect(AskWorkflowAuthoringPanel.lineCount("a\n\nb") == 3)
    }
}

@Suite("Chat redesign copy")
@MainActor
struct AskChatRedesignCopyTests {
    static let keys = [
        "ask.run.needsDecision", "ask.usage.conversationSpent", "ask.usage.conversationSpentHelp",
        "ask.recovery.checkAndContinue", "ask.recovery.details", "ask.recovery.recommended",
        "ask.recovery.checkPrompt", "ask.recovery.option.check", "ask.recovery.option.checkBody",
        "ask.recovery.option.refresh", "ask.recovery.option.refreshBody", "ask.recovery.option.continue",
        "ask.recovery.option.self", "ask.recovery.option.stop", "ask.recovery.timeline.unknown",
        "ask.recovery.timeline.paused", "ask.workflow.chat.view", "ask.workflow.chat.openedBeside",
        "ask.workflow.chat.keywordNone", "ask.workflow.chat.tab.test", "ask.workflow.chat.tab.code",
        "ask.workflow.chat.openEditor", "ask.workflow.chat.discardMenu", "ask.workflow.chat.check.title",
        "ask.workflow.chat.check.subtitle", "ask.workflow.chat.check.details", "ask.workflow.chat.check.script",
        "ask.workflow.chat.check.keywords", "ask.workflow.chat.check.inlineScript",
        "ask.workflow.chat.check.separator", "ask.workflow.chat.check.addManually", "ask.workflow.chat.complete",
        "ask.workflow.chat.completeHint", "ask.workflow.chat.completing", "ask.workflow.chat.completeBlocked", "ask.workflow.chat.completePrompt",
        "ask.workflow.chat.afterComplete", "ask.workflow.chat.inputPlaceholder", "ask.workflow.chat.inputLocked",
        "ask.workflow.chat.result", "ask.workflow.chat.running", "ask.workflow.chat.emptyLocked",
        "ask.workflow.chat.resultOK", "ask.workflow.chat.resultFailed", "ask.workflow.chat.launcherPreview",
        "ask.workflow.chat.log", "ask.workflow.chat.logEmpty", "ask.workflow.chat.files",
        "ask.workflow.chat.readOnly", "ask.workflow.chat.status.incomplete", "ask.workflow.chat.status.draft",
        "ask.workflow.chat.status.saved", "ask.workflow.chat.status.unsaved", "ask.workflow.chat.hint.running",
        "ask.workflow.chat.hint.testFirst", "ask.workflow.chat.hint.tested", "ask.workflow.chat.hint.testFailed"
    ]
    static let integerKeys = [
        "ask.activity.pausedAt", "ask.recovery.timeline.done", "ask.workflow.chat.check.remaining",
        "ask.workflow.chat.exitCode", "ask.workflow.chat.lines", "ask.workflow.chat.status.missing",
        "ask.workflow.chat.hint.complete"
    ]
    static let stringKeys = ["ask.workflow.chat.keywordLine", "ask.workflow.chat.hint.savedKeyword"]

    @Test func everyLanguageHasTheNewCopyAndFormats() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
            for key in Self.keys + Self.integerKeys + Self.stringKeys {
                #expect(text(key) != key && !text(key).isEmpty, "Missing \(key) in \(language.rawValue)")
            }
            for key in Self.integerKeys {
                #expect(text(key).components(separatedBy: "%d").count == 2, "\(key) in \(language.rawValue)")
            }
            for key in Self.stringKeys {
                #expect(text(key).components(separatedBy: "%@").count == 2, "\(key) in \(language.rawValue)")
            }
            #expect(text("ask.workflow.chat.details") == "ask.workflow.chat.details")
        }
    }

    @Test func renamedRecoveryButtonsInChinese() throws {
        let path = try #require(Bundle.module.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
        #expect(text("ask.recovery.retransmit") == "刷新进度")
        #expect(text("ask.recovery.checkAndContinue") == "检查并继续")
        #expect(text("ask.recovery.end") == "停止任务")
        #expect(text("ask.recovery.details") == "了解详情")
        #expect(text("ask.usage.conversationSpent") == "本对话已用")
        #expect(text("ask.run.needsDecision") == "需要你确认")
        #expect(text("ask.recovery.savedBody").contains("刷新进度"))
    }
}
