// swiftlint:disable file_length
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask workflow output editing", .exclusiveUIState)
@MainActor
struct AskWorkflowOutputEditorTests {
    private func model(_ fixture: AskWorkflowFixture) -> AskWorkflowEditorModel {
        let defaults = UserDefaults(suiteName: "wf-output-\(UUID().uuidString)")!
        let assistant = AskWorkflowAssistant(dependencies: .init(
            api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
        ))
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        return model
    }

    private func open(_ fixture: AskWorkflowFixture, output: Any = "text",
                      script: String = "print -r -- \"$1 = 42\"\nprint -r -- last") throws -> AskWorkflowEditorModel {
        try fixture.write("local.fx", manifest: AskWorkflowFixture.inline("local.fx", keyword: "fx", script: script,
                                                                          extra: ["output": output, "name": "FX"]))
        fixture.store.reload()
        fixture.store.trust("local.fx")
        let model = model(fixture)
        model.open("local.fx")
        return model
    }

    @Test func menusOpenInPopoversThatOnlyCloseThemselves() {
        var menu: AskWorkflowOutputMenu?
        let binding = Binding(get: { menu }, set: { menu = $0 })
        let add = AskWorkflowOutputMenu.presented(.add(.onSuccess), in: binding)
        let token = AskWorkflowOutputMenu.presented(.placeholder(.onSuccess, index: 0, field: .value), in: binding)
        #expect(!add.wrappedValue && !token.wrappedValue)
        add.wrappedValue = true
        #expect(menu == .add(.onSuccess) && add.wrappedValue && !token.wrappedValue)
        token.wrappedValue = false
        #expect(menu == .add(.onSuccess), "closing another menu's popover leaves this one open")
        token.wrappedValue = true
        #expect(menu == .placeholder(.onSuccess, index: 0, field: .value) && !add.wrappedValue)
        add.wrappedValue = false
        #expect(menu == .placeholder(.onSuccess, index: 0, field: .value))
        token.wrappedValue = false
        #expect(menu == nil)
    }

    @Test func theShortFormStaysUntilSomethingElseIsSet() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture)
        #expect(model.outputObject["display"] as? String == "text")
        model.setDisplay(.none)
        #expect(model.draft?.value(at: ["output"]) as? String == "none", "only the display: still a string")
        model.addAction(.copy, to: .onSuccess)
        let object = try #require(model.draft?.value(at: ["output"]) as? [String: Any])
        #expect(object["display"] as? String == "none")
        #expect(model.actions(.onSuccess).first?["action"] as? String == "copy")
        #expect(model.draft?.manifest?.output.onSuccess == [AskWorkflowAction(action: "copy", value: "{output}")])
        model.removeAction(at: 0, from: .onSuccess)
        #expect(model.draft?.value(at: ["output"]) is [String: Any], "an object stays an object")
        #expect(model.outputObject["onSuccess"] == nil, "an empty list is left out")
        model.setOutputFlag("close", true)
        #expect(model.draft?.manifest?.output.close == true)
        model.setOutputFlag("close", false)
        #expect(model.outputObject["close"] == nil)
        model.setOutputFlag("scriptActions", true)
        #expect(model.draft?.manifest?.output.scriptActions == true)
    }

    @Test func aMissingOutputGainsTheShortFormFirst() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture)
        model.set(nil, at: ["output"])
        #expect(model.outputObject.isEmpty)
        model.setDisplay(.text)
        #expect(model.draft?.value(at: ["output"]) as? String == "text")
    }

    @Test func actionsAreEditedMovedAndCapped() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture)
        model.addAction(.copy, to: .onSuccess)
        model.addAction(.notify, to: .onSuccess)
        model.addAction(.speak, to: .onFailure)
        model.setActionField(.value, to: "{output.line1}", at: 0, in: .onSuccess)
        model.setActionField(.title, to: "FX", at: 1, in: .onSuccess)
        model.setActionField(.language, to: "", at: 0, in: .onFailure)
        model.setActionField(.value, to: "ignored", at: 9, in: .onSuccess)
        let output = try #require(model.draft?.manifest?.output)
        #expect(output.onSuccess == [.init(action: "copy", value: "{output.line1}"),
                                     .init(action: "notify", title: "FX", body: "{output}")])
        #expect(output.onFailure == [.init(action: "speak", text: "{output}")], "an empty language is left out")
        model.moveAction(from: 1, to: 0, in: .onSuccess)
        #expect(model.draft?.manifest?.output.onSuccess.map(\.action) == ["notify", "copy"])
        model.moveAction(from: 0, to: 5, in: .onSuccess)
        model.removeAction(at: 7, from: .onSuccess)
        #expect(model.draft?.manifest?.output.onSuccess.count == 2)
        for _ in 0 ..< 10 {
            model.addAction(.hud, to: .onSuccess)
        }
        #expect(model.actions(.onSuccess).count == AskWorkflowManifest.Output.maximumActions)
        #expect(AskWorkflowEditorModel.outputSummary(model.draft?.manifest?.output ?? .init())
            == L("ask.workflow.editor.outputShort.text") + " · " + L("ask.workflow.editor.actionsCount", 9))
        #expect(AskWorkflowEditorModel
            .outputSummary(.init(display: .none)) == L("ask.workflow.editor.outputShort.none"))
    }

    @Test func unknownFieldsOfAnActionSurviveEdits() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, output: ["display": "text", "onSuccess": [["action": "copy", "value": "a",
                                                                                 "future": 1]]])
        model.setActionField(.value, to: "b", at: 0, in: .onSuccess)
        #expect(model.actions(.onSuccess).first?["future"] as? Int == 1)
    }

    @Test func thePreviewUsesTheSampleThenTheLastRun() async throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, output: ["display": "text", "onSuccess": [
            ["action": "copy", "value": "{output.line1}"], ["action": "open", "target": "missing.txt"]
        ]])
        #expect(model.problems.isEmpty, "a file that is not there yet is checked when it runs")
        let sample = model.successPreview
        #expect(sample.first?.detail == L("ask.workflow.editor.preview.sample").components(separatedBy: "\n").first)
        #expect(sample.last?.problem != nil)
        #expect(model.placeholderValues.keyword == "fx" && model.placeholderValues.query == "100 usd jpy")
        model.testQuery = "rate"
        model.runTest()
        #expect(model.isTesting, "\(model.message ?? "")")
        for _ in 0 ..< 1000 where model.isTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = try #require(model.results.last)
        #expect(result.succeeded && !result.takesFailureActions)
        #expect(result.actionSteps.map(\.detail) == ["rate = 42", "missing.txt"])
        #expect(result.actionOutcomes.map(\.status)
            == [.skipped(nil), .failed(L("ask.workflow.action.cannotOpen", "missing.txt"))],
            "previewed only, by default")
        #expect(model.successPreview.first?.detail == "rate = 42")
        #expect(model.placeholderValues.output == "rate = 42\nlast" && model.placeholderValues.query == "rate")
        #expect(model.lastRun == result)
    }

    @Test func anInvalidActionStopsTheWorkflowFromRunning() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, output: ["onSuccess": [["action": "open", "target": "ssh://host"]]])
        #expect(model.problems(for: .output).map(\.field) == ["output.onSuccess[0]"])
        model.runTest()
        #expect(!model.isTesting && model.message != nil)
        #expect(fixture.store.workflow("local.fx")?.status != .ready)
    }

    @Test func aFailedTestRunListsTheFailureActions() async throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(
            fixture,
            output: ["display": "text", "onFailure": [["action": "notify", "body": "{error}"]],
                     "onSuccess": [["action": "copy", "value": "{output}"]]],
            script: "print -u2 broken; exit 2"
        )
        model.runTest()
        for _ in 0 ..< 1000 where model.isTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = try #require(model.results.last)
        #expect(result.takesFailureActions && result.actionSteps.count == 1)
        let body = try #require(result.actionSteps.first?.detail)
        #expect(body.contains(L("ask.workflow.failed", 2)) && body.contains("broken"))
        #expect(result.errorText(timeout: 30, folder: nil)?.contains("broken") == true)
        var timedOut = result
        timedOut.timedOut = true
        #expect(timedOut.errorText(timeout: 5, folder: nil)?.hasPrefix(L("ask.workflow.timedOut", 5)) == true)
        var cut = result
        cut.exitCode = 0
        cut.truncated = true
        #expect(cut.errorText(timeout: 5, folder: nil)?.hasPrefix(L("ask.workflow.truncated")) == true)
        cut.truncated = false
        #expect(cut.errorText(timeout: 5, folder: nil) == nil)
    }

    @Test func placeholderMenuRowsUseTheValues() {
        let values = AskWorkflowPlaceholders(output: #"{"amount": 3}"#, query: "q", keyword: "fx",
                                             options: ["to": "usd"], error: "boom")
        let rows = AskWorkflowPlaceholderMenu.rows(values: values, failure: false)
        #expect(rows.map(\.token) == ["{output}", "{output.line1}", "{output.lastLine}", "{json.amount}", "{query}",
                                      "{selection}", "{keyword}", "{option:to}"])
        #expect(rows.first { $0.token == "{json.amount}" }?.value == "3")
        #expect(rows.allSatisfy { !$0.title.hasPrefix("ask.workflow") })
        let failure = AskWorkflowPlaceholderMenu.rows(values: AskWorkflowPlaceholders(output: "x", error: "boom"),
                                                      failure: true)
        #expect(failure.last?.token == "{error}" && failure.last?.value == "boom")
        #expect(failure.contains { $0.token == "{json.field}" } && failure.contains { $0.token == "{option:name}" })
        #expect(AskWorkflowPlaceholderMenu.firstJSONKey(in: "[1]") == nil)
    }

    @Test func placeholderTextSplitsIntoTags() {
        #expect(AskWorkflowPlaceholderText.segments("Copied {output.line1}!") == [
            .init(text: "Copied ", isToken: false), .init(text: "{output.line1}", isToken: true),
            .init(text: "!", isToken: false)
        ])
        #expect(AskWorkflowPlaceholderText.segments("{a}{b") == [.init(text: "{a}", isToken: true),
                                                                 .init(text: "{b", isToken: false)])
        #expect(AskWorkflowPlaceholderText.segments("").isEmpty)
    }

    @Test func displayChoicesOfferEveryDisplay() {
        let choices = AskWorkflowOutputForm.displayChoices
        #expect(choices.map(\.value) == [.text, .none, .auto, .items, .markdown, .image])
        #expect(choices.allSatisfy { !$0.title.hasPrefix("ask.workflow") })
    }
}

@Suite("Ask workflow actions in the plugin, risks and trust", .exclusiveUIState)
@MainActor
struct AskWorkflowActionPluginTests {
    private func run(_ script: String,
                     output: [String: Any]) async throws -> Result<AskPluginOutput, AskPluginFailure> {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.a", manifest: AskWorkflowFixture.inline("local.a", keyword: "a", script: script,
                                                                         extra: ["output": output]))
        fixture.store.reload()
        fixture.store.trust("local.a")
        let workflow = try #require(fixture.store.workflow("local.a"))
        let plugin = AskWorkflowPlugin(workflow: workflow, home: fixture.home.path)
        let request = AskPluginRequest(text: "in", origin: .argument, keyword: plugin.defaultKeywords[0],
                                       options: ["to": "jpy"], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        do {
            return try await .success(plugin.run(request, plan: plan) { _ in })
        } catch let failure as AskPluginFailure {
            return .failure(failure)
        }
    }

    @Test func successCarriesTheFilledInActions() async throws {
        let result = try await run("print -r -- \"$1 out\"", output: [
            "display": "text", "close": true,
            "onSuccess": [["action": "copy", "value": "{output} {option:to} {keyword}"]],
            "onFailure": [["action": "hud", "text": "no"]]
        ])
        let output = try result.get()
        let followUp = try #require(output.followUp)
        #expect(followUp.closes && followUp.steps.map(\.effect) == [.copy("in out jpy a")])
        #expect(!output.dismisses)
    }

    @Test func showingNothingClosesAfterTheActions() async throws {
        let output = try await run("print -r -- x", output: ["display": "none",
                                                             "onSuccess": [["action": "hud", "text": "{output}"]]])
            .get()
        #expect(output.dismisses && output.followUp?.closes == true && output.followUp?.steps.first?
            .effect == .hud("x"))
        let plain = try await run("print -r -- x", output: ["display": "text"]).get()
        #expect(plain.followUp == nil)
    }

    @Test func failuresCarryTheFailureActions() async throws {
        let failed = try await run("print -u2 bad; exit 4", output: [
            "display": "text", "onFailure": [["action": "notify", "body": "{error}"]]
        ])
        guard case let .failure(failure) = failed else { Issue.record("it failed"); return }
        let followUp = try #require(failure.followUp)
        #expect(!followUp.closes, "the error card stays")
        guard case let .notify(_, body) = followUp.steps.first?.effect else { Issue.record("a notification"); return }
        #expect(body.contains(L("ask.workflow.failed", 4)) && body.contains("bad"))
        let quiet = try await run("exit 1", output: ["display": "none", "onFailure": [["action": "hud", "text": "x"]]])
        guard case let .failure(closing) = quiet else { Issue.record("it failed"); return }
        #expect(closing.followUp?.closes == true, "showing nothing closes instead of the card")
        let none = try await run("exit 1", output: ["display": "text"])
        guard case let .failure(plain) = none else { Issue.record("it failed"); return }
        #expect(plain.followUp == nil)
    }

    @Test func risksIncludeTheActions() {
        let manifest = #"""
        {"id": "a", "name": "A", "keywords": [{"keyword": "a"}], "command": {"runtime": "zsh", "inline": "echo"},
         "output": {"onSuccess": [{"action": "open", "target": "https://www.XE.com/?a={query}"},
                                  {"action": "open", "target": "{output}"},
                                  {"action": "writeBack", "value": "{output}"}],
                    "onFailure": [{"action": "open", "target": "https://status.example.com"}]}}
        """#
        let risks = AskWorkflowRiskScanner.scan([AskWorkflowManifest.fileName: manifest])
        #expect(risks == [AskWorkflowRisk(kind: .network, detail: "www.xe.com"),
                          AskWorkflowRisk(kind: .network, detail: "status.example.com"),
                          AskWorkflowRisk(kind: .writesApps, detail: "")])
        #expect(AskWorkflowRisk(kind: .writesApps, detail: "").title == L("ask.workflow.risk.writesApps"))
        #expect(!AskWorkflowRisk.Kind.writesApps.isHigh)
        #expect(AskWorkflowRiskScanner.scanActions(manifest: "not json").isEmpty)
        var draft = AskWorkflowDraft(folder: URL(fileURLWithPath: "/tmp/wf"), manifestText: manifest,
                                     files: ["main.sh": "echo"])
        #expect(draft.scannedFiles.keys.sorted() == ["main.sh", "workflow.json"])
        draft.manifestText = "{}"
        #expect(draft.scannedFiles["workflow.json"] == "{}")
    }

    @Test func theTrustSheetListsTheActions() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.t", manifest: AskWorkflowFixture.inline("local.t", script: "echo", extra: ["output": [
            "onSuccess": [["action": "copy", "value": "{output}"], ["action": "teleport"]],
            "onFailure": [["action": "hud", "text": ""]]
        ]]))
        fixture.store.reload()
        let summary = try AskWorkflowTrustSummary(#require(fixture.store.workflow("local.t")))
        #expect(summary.actions == [
            AskWorkflowAction.Kind.copy.title + ": {output}", "teleport",
            L("ask.workflow.trust.onFailure", AskWorkflowAction.Kind.hud.title)
        ])
        #expect(AskWorkflowTrustSummary.actions(nil).isEmpty)
    }

    @Test func clipboardSnapshotsRestoreEveryType() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wf-snap-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("text", forType: .string)
        item.setString("<b>text</b>", forType: .html)
        pasteboard.writeObjects([item])
        let snapshot = AskClipboardSnapshot.take(pasteboard)
        AskQuickResults.copy("other", to: pasteboard)
        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "text" && pasteboard.string(forType: .html) == "<b>text</b>")
        pasteboard.clearContents()
        AskClipboardSnapshot.take(pasteboard).restore(to: pasteboard)
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func applicationsAreFoundByName() {
        #expect(AskWorkflowLauncherActionHost.applicationURL(named: "Finder")?.path.hasSuffix("Finder.app") == true
            || AskWorkflowLauncherActionHost.applicationURL(named: "Safari") != nil)
        #expect(AskWorkflowLauncherActionHost.applicationURL(named: "No Such App \(UUID().uuidString)") == nil)
        #expect(!AskWorkflowLauncherActionHost.language(of: "Bonjour tout le monde, comment allez-vous ?").isEmpty)
    }

    @Test func theSummaryViewTextsFollowTheOutcomes() {
        let step = AskWorkflowActionStep(action: .init(action: "copy", value: "x"), detail: "x")
        #expect(AskWorkflowActionsSummaryView.text(for: .init(step: step, status: .done))
            == "✓ " + L("ask.workflow.action.done.copy", "x"))
        #expect(AskWorkflowActionsSummaryView.text(for: .init(step: step, status: .skipped(nil))) == nil)
        let state = AskWorkflowActionsState(id: UUID(), outcomes: [.init(step: step, status: .failed("no"))])
        #expect(state.failed && !state.canUndo && state.summary == "✕ " + step.title + ": no")
    }
}

@Suite("Ask workflow action hosts", .exclusiveUIState)
@MainActor
struct AskWorkflowActionHostTests {
    @Test func theLauncherHostClosesOnceAndNotesAfterThat() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var log: [String] = []
        var dismissed = 0
        model.openURL = { log.append("url:" + $0.lastPathComponent) }
        model.openApplicationNamed = { name in log.append("app:" + name); return name == "Notes" }
        model.revealFile = { log.append("reveal:" + $0.lastPathComponent) }
        model.speak = { text, language in log.append("speak:\(text)|\(language)") }
        model.passiveNotice = { log.append("notice:" + $0) }
        model.notifyUser = { title, _ in log.append("notify:" + title); return true }
        let host = AskWorkflowLauncherActionHost(model: model) { dismissed += 1 }
        host.hud("while open")
        #expect(log.isEmpty, "the bar's summary carries the note while the launcher is open")
        #expect(await host.notify(title: "T", body: "B"))
        #expect(host.reveal(URL(fileURLWithPath: "/tmp/a.png")))
        host.speak("hello", language: "en")
        #expect(!host.open(.application("Nope")) && !host.closed, "nothing opened, nothing closed")
        #expect(host.open(.application("Notes")) && host.closed && dismissed == 1)
        #expect(host.open(.link(URL(string: "https://example.com/page")!)) && dismissed == 1, "closes once")
        host.hud("after")
        #expect(log == ["notify:T", "reveal:a.png", "speak:hello|en", "app:Nope", "app:Notes", "url:page",
                        "notice:after"])
        host.close()
        #expect(dismissed == 1)
    }

    @Test func theLauncherHostWritesBackAndHandsToTheAIAfterClosing() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var delivered: [String] = []
        var dismissed = 0
        model.deliverText = { delivered.append($0) }
        let writer = AskWorkflowLauncherActionHost(model: model) { dismissed += 1 }
        writer.writeBack("typed")
        #expect(writer.closed && dismissed == 1)
        for _ in 0 ..< 200 where delivered.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(delivered == ["typed"])
        let asker = AskWorkflowLauncherActionHost(model: model) { dismissed += 1 }
        asker.askAI("explain")
        #expect(asker.closed && dismissed == 2)
        var spoken: [String] = []
        model.speak = { _, language in spoken.append(language) }
        asker.speak("Bonjour tout le monde, comment allez-vous aujourd'hui ?", language: nil)
        #expect(spoken.count == 1 && !spoken[0].isEmpty, "a language is picked from the text")
    }

    @Test func theEditorHostUsesTheSystemOnlyThroughItsHooks() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.fx", manifest: AskWorkflowFixture.inline("local.fx", keyword: "fx", script: "echo"))
        fixture.store.reload()
        let defaults = try #require(UserDefaults(suiteName: "wf-host-\(UUID().uuidString)"))
        let model = AskWorkflowEditorModel(
            store: fixture.store, settings: fixture.settings,
            assistant: AskWorkflowAssistant(dependencies: .init(
                api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
                modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
            ))
        )
        let host = AskWorkflowEditorActionHost(model: model)
        var log: [String] = []
        host.openURL = { log.append("url:" + $0.lastPathComponent); return true }
        host.openApplication = { log.append("app:" + $0); return false }
        host.revealFile = { log.append("reveal:" + $0.lastPathComponent) }
        host.speakText = { log.append("speak:\($0)|\($1)") }
        host.notifyUser = { title, _ in log.append("notify:" + title); return false }
        #expect(host.open(.link(URL(string: "https://example.com/a")!)))
        #expect(host.open(.file(URL(fileURLWithPath: "/tmp/b.txt"))))
        #expect(!host.open(.application("Nope")))
        #expect(host.reveal(URL(fileURLWithPath: "/tmp/c.png")))
        host.speak("hi", language: "en")
        #expect(await host.notify(title: "T", body: "B") == false)
        #expect(log == ["url:a", "url:b.txt", "app:Nope", "reveal:c.png", "speak:hi|en", "notify:T"])
        // A denied notification falls back to a note, which the test panel lists rather than shows as a warning.
        let outcomes = await AskWorkflowActionRunner.run(
            [AskWorkflowActionStep(action: .init(action: "notify", body: "B"), effect: .notify(title: "T", body: "B"),
                                   detail: "T · B")],
            host: host
        )
        #expect(outcomes.first?.status == .fellBack(L("ask.workflow.action.notifyDenied")) && model.message == nil)
    }

    @Test func theNoticePanelShowsANoteForAMoment() async throws {
        _ = NSApplication.shared
        let panel = AskWorkflowNoticePanel()
        panel.duration = .milliseconds(50)
        #expect(!panel.isVisible)
        panel.show("Saved")
        #expect(panel.isVisible)
        panel.show("Saved again")
        for _ in 0 ..< 200 where panel.isVisible {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!panel.isVisible)
        let view = NSHostingView(rootView: AskWorkflowNoticeView(text: String(repeating: "long ", count: 40)))
        #expect(view.fittingSize.width > 0)
    }
}
