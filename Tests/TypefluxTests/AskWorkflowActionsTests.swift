import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Records what a workflow's actions asked for, as the launcher or the test panel would do it.
@MainActor
final class RecordingActionHost: AskWorkflowActionHost {
    var calls: [String] = []
    var notificationsAllowed = true
    var opens = true

    func copy(_ text: String) {
        calls.append("copy:" + text)
    }

    func writeBack(_ text: String) {
        calls.append("writeBack:" + text)
    }

    func notify(title: String, body: String) async -> Bool {
        calls.append("notify:\(title)|\(body)")
        return notificationsAllowed
    }

    func hud(_ text: String) {
        calls.append("hud:" + text)
    }

    func open(_ target: AskWorkflowOpenTarget) -> Bool {
        calls.append("open:\(target)")
        return opens
    }

    func reveal(_ url: URL) -> Bool {
        calls.append("reveal:" + url.lastPathComponent)
        return true
    }

    func speak(_ text: String, language: String?) {
        calls.append("speak:\(text)|\(language ?? "-")")
    }

    func askAI(_ prompt: String) {
        calls.append("askAI:" + prompt)
    }
}

@Suite("Ask workflow output")
struct AskWorkflowOutputTests {
    private func decode(_ json: String) throws -> AskWorkflowManifest.Output {
        try JSONDecoder().decode(AskWorkflowManifest.Output.self, from: Data(json.utf8))
    }

    private func encode(_ output: AskWorkflowManifest.Output) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(output), encoding: .utf8))
    }

    @Test func theStringFormStillReads() throws {
        for display in AskWorkflowManifest.Output.Display.allCases {
            let output = try decode("\"\(display.rawValue)\"")
            #expect(output == .init(display: display) && output.isPlain)
        }
        #expect(throws: DecodingError.self) { try decode("\"cards\"") }
    }

    @Test func theObjectFormReadsEveryField() throws {
        let output = try decode(#"""
        {"display": "none", "onSuccess": [{"action": "copy", "value": "{output.line1}"},
         {"action": "notify", "title": "FX", "body": "{output}"}],
         "onFailure": [{"action": "notify", "body": "{error}"}], "close": true, "scriptActions": true}
        """#)
        #expect(output.display == .none && output.close && output.scriptActions && output.closes)
        #expect(output.onSuccess == [AskWorkflowAction(action: "copy", value: "{output.line1}"),
                                     AskWorkflowAction(action: "notify", title: "FX", body: "{output}")])
        #expect(output.onFailure.first?.kind == .notify)
        let defaults = try decode("{}")
        #expect(defaults == .init() && defaults.display == .auto && !defaults.closes)
        #expect(try decode(#"{"display": "text", "close": true}"#).closes)
        #expect(AskWorkflowManifest.Output(display: .none).closes, "showing nothing always closes")
    }

    @Test func unknownActionsStillDecode() throws {
        let output = try decode(#"{"onSuccess": [{"action": "runKeyword", "keyword": "tr"}]}"#)
        #expect(output.onSuccess.first?.action == "runKeyword" && output.onSuccess.first?.kind == nil)
    }

    @Test func aPlainOutputIsWrittenInTheShortForm() throws {
        #expect(try encode(.init(display: .text)) == "\"text\"")
        let full = AskWorkflowManifest.Output(display: .text, onSuccess: [.init(action: "copy", value: "{output}")],
                                              onFailure: [], close: true)
        let text = try encode(full)
        #expect(text == #"{"close":true,"display":"text","onSuccess":[{"action":"copy","value":"{output}"}]}"#)
        #expect(try decode(text) == full)
        #expect(try encode(.init(display: .none, scriptActions: true)) == #"{"display":"none","scriptActions":true}"#)
        #expect(try encode(.init(display: .auto, onFailure: [.init(action: "hud", text: "x")]))
            == #"{"display":"auto","onFailure":[{"action":"hud","text":"x"}]}"#)
    }

    @Test func aManifestWithActionsRoundTrips() throws {
        let json = #"""
        {"id": "a", "name": "A", "keywords": [{"keyword": "a"}], "command": {"runtime": "zsh", "inline": "echo"},
         "output": {"display": "text", "onSuccess": [{"action": "copy", "value": "{output}"}]}}
        """#
        let manifest = try JSONDecoder().decode(AskWorkflowManifest.self, from: Data(json.utf8))
        #expect(manifest.output.onSuccess.count == 1)
        let again = try JSONDecoder().decode(AskWorkflowManifest.self, from: JSONEncoder().encode(manifest))
        #expect(again == manifest)
    }

    @Test func problemsNameTheDisplayAndEachRow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fields(_ output: AskWorkflowManifest.Output) -> [String] {
            output.problems(folder: folder).map(\.field)
        }
        #expect(fields(.init(display: .text)).isEmpty && fields(.init(display: .none)).isEmpty)
        #expect(fields(.init(display: .items)).isEmpty && fields(.init(display: .markdown)).isEmpty)
        #expect(fields(.init(display: .image)) == ["output"])
        #expect(AskWorkflowManifest.Output(display: .image).problems(folder: folder).first?.message
            == L("ask.workflow.problem.display", "image"))
        let copy = AskWorkflowAction(action: "copy", value: "{output}")
        #expect(fields(.init(onSuccess: Array(repeating: copy, count: 9))) == ["output.onSuccess"])
        #expect(fields(.init(onSuccess: Array(repeating: copy, count: 8))).isEmpty)
        let bad: [AskWorkflowAction] = [
            copy,
            .init(action: "teleport"),
            .init(action: "copy", value: "  "),
            .init(action: "copy", value: "{error}"),
            .init(action: "open", target: "javascript:alert(1)"),
            .init(action: "reveal", path: "/etc/hosts"),
            .init(action: "reveal", path: "../x")
        ]
        #expect(fields(.init(onSuccess: bad)) == (1 ... 6).map { "output.onSuccess[\($0)]" })
        #expect(fields(.init(onFailure: [.init(action: "notify", body: "{error}")])).isEmpty, "{error} fits failures")
        let messages = AskWorkflowManifest.Output(onSuccess: bad).problems(folder: folder).map(\.message)
        #expect(messages == [
            L("ask.workflow.problem.action.unknown", "teleport"),
            L("ask.workflow.problem.action.missing", AskWorkflowAction.Field.value.title),
            L("ask.workflow.problem.action.error"),
            L("ask.workflow.problem.action.open"),
            L("ask.workflow.problem.action.reveal"),
            L("ask.workflow.problem.action.reveal")
        ])
        var manifest = AskWorkflowManifest(id: "a", name: "A", keywords: [.init(keyword: "a")],
                                           command: .init(runtime: .zsh, inline: "echo"))
        manifest.output.onFailure = [.init(action: "nope")]
        #expect(manifest.problems(in: folder).map(\.field) == ["output.onFailure[0]"])
        #expect(AskWorkflowDraft.step(for: "output.onFailure[0]") == .output)
    }

    @Test func openAndRevealTemplatesAreCheckedForWhatTheyFix() {
        let folder = URL(fileURLWithPath: "/tmp/wf")
        for target in ["https://x.com/?q={query}", "http://localhost:8080", "app:Notes", "{output}", "notes.txt",
                       "~/Desktop", "/Applications/Notes.app", "file:///tmp/a"] {
            #expect(AskWorkflowAction.isOpenable(template: target), "\(target)")
        }
        for target in ["javascript:alert(1)", "ssh://host", "vscode://open"] {
            #expect(!AskWorkflowAction.isOpenable(template: target), "\(target)")
        }
        #expect(AskWorkflowAction.isRevealable(template: "{output.line1}", folder: folder))
        #expect(AskWorkflowAction.isRevealable(template: "~/Downloads/a.png", folder: folder))
        #expect(AskWorkflowAction.isRevealable(template: "out/a.png", folder: folder))
        #expect(!AskWorkflowAction.isRevealable(template: "/tmp/a", folder: folder))
        #expect(AskWorkflowAction.scheme(of: "HTTPS://x") == "https" && AskWorkflowAction.scheme(of: "a b:c") == nil)
        #expect(AskWorkflowAction.scheme(of: "c:/x") == nil && AskWorkflowAction.scheme(of: "plain") == nil)
    }

    @Test func eachKindHasFieldsATemplateAndAJSONForm() {
        for kind in AskWorkflowAction.Kind.allCases {
            let template = kind.template
            #expect(template.kind == kind && kind.fields.contains(kind.requiredField))
            #expect(!kind.title.hasPrefix("ask.workflow") && !kind.symbol.isEmpty)
            #expect(template.jsonObject["action"] as? String == kind.rawValue)
        }
        #expect(AskWorkflowAction.Kind.groups.flatMap { $0 }.sorted { $0.rawValue < $1.rawValue }
            == AskWorkflowAction.Kind.allCases.sorted { $0.rawValue < $1.rawValue })
        var action = AskWorkflowAction(action: "speak")
        for field in AskWorkflowAction.Field.allCases {
            action[field] = field.rawValue
            #expect(action[field] == field.rawValue && !field.title.hasPrefix("ask.workflow"))
        }
        #expect(action.jsonObject.count == AskWorkflowAction.Field.allCases.count + 1)
    }
}

@Suite("Ask workflow placeholders")
struct AskWorkflowPlaceholdersTests {
    private let values = AskWorkflowPlaceholders(
        output: "\n 100 USD = 14,912.30 JPY\n1 USD = 149.123 JPY \n", query: "100 usd jpy", selection: "picked",
        keyword: "fx", options: ["to": "usd,eur"], error: nil
    )

    @Test func everyPlaceholderIsReplaced() {
        #expect(values.output == "100 USD = 14,912.30 JPY\n1 USD = 149.123 JPY")
        #expect(values.expand("{output.line1}") == "100 USD = 14,912.30 JPY")
        #expect(values.expand("{output.lastLine}") == "1 USD = 149.123 JPY")
        #expect(values.expand("{query}|{selection}|{keyword}|{option:to}|{option:none}|{error}")
            == "100 usd jpy|picked|fx|usd,eur||")
        #expect(values.expand("{unknown} {output.line1") == "{unknown} {output.line1", "unknown names stay")
        let empty = AskWorkflowPlaceholders(output: "  ")
        #expect(empty.expand("[{output.line1}][{output.lastLine}][{selection}]") == "[][][]")
    }

    @Test func replacementHappensOnce() {
        let tricky = AskWorkflowPlaceholders(output: "{query}", query: "$(rm -rf ~) {selection}", selection: "s")
        #expect(tricky.expand("{output}/{query}") == "{query}/$(rm -rf ~) {selection}")
    }

    @Test func jsonPathsReadObjectsAndArrays() {
        let json = AskWorkflowPlaceholders(output: #"""
        {"amount": 14912.3, "ok": true, "none": null, "name": "JPY", "items": [{"title": "a"}, {"title": "b"}],
         "rates": {"usd": 1}}
        """#)
        #expect(json.expand("{json.amount}") == "14912.3")
        #expect(json.expand("{json.ok}|{json.none}|{json.name}") == "true||JPY")
        #expect(json.expand("{json.items.1.title}") == "b")
        #expect(json.expand("{json.rates}") == #"{"usd":1}"#)
        #expect(json.expand("[{json.missing}][{json.items.9.title}][{json.name.x}]") == "[][][]")
        #expect(json.missingJSON(in: "{json.amount} {json.missing} {json.items.5}") == [
            "{json.missing}",
            "{json.items.5}"
        ])
        #expect(AskWorkflowPlaceholders(output: "not json").expand("[{json.a}]") == "[]")
        #expect(AskWorkflowPlaceholders(output: "[1,2]").expand("{json.1}") == "2")
        #expect(AskWorkflowPlaceholders.json(at: "", in: "{}") == nil)
    }

    @Test func linksEncodeOnlyTheInsertedValues() {
        let target = "https://www.xe.com/convert/?Amount={query}&to={option:to}"
        #expect(values
            .expand(target, urlEncoded: true) == "https://www.xe.com/convert/?Amount=100%20usd%20jpy&to=usd%2Ceur")
        #expect(values.expand(target) == "https://www.xe.com/convert/?Amount=100 usd jpy&to=usd,eur")
        let link = AskWorkflowPlaceholders(output: "https://example.com/a?b=c")
        #expect(
            link.expand("{output}", urlEncoded: true) == "https://example.com/a?b=c",
            "the whole target is not encoded"
        )
        #expect(values.expand("app:{query}", urlEncoded: true) == "app:100 usd jpy", "only web links are encoded")
        #expect(AskWorkflowPlaceholders.percentEncoded("a/b?c&d=e é") == "a%2Fb%3Fc%26d%3De%20%C3%A9")
    }

    @Test func namesInATemplateAreListed() {
        #expect(AskWorkflowPlaceholders.names(in: "a {x} b {json.y} {") == ["x", "json.y"])
    }
}

@Suite("Ask workflow action runner")
@MainActor
struct AskWorkflowActionRunnerTests {
    private let folder: URL
    private let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tf-actions-\(UUID().uuidString)")
        folder = home.appendingPathComponent("wf")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("out"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: folder.appendingPathComponent("out/a.png"))
        try Data("x".utf8).write(to: home.appendingPathComponent("note.txt"))
    }

    private func steps(_ actions: [AskWorkflowAction], output: String = "line one\nline two",
                       error: String? = nil) -> [AskWorkflowActionStep] {
        AskWorkflowActionRunner.steps(
            for: actions, placeholders: AskWorkflowPlaceholders(
                output: output,
                query: "q x",
                keyword: "fx",
                error: error
            ),
            folder: folder, name: "FX", home: home.path
        )
    }

    @Test func stepsAreFilledInWithTheirEffects() throws {
        let all = steps([
            .init(action: "copy", value: "{output.line1}"),
            .init(action: "writeBack", value: "{output}"),
            .init(action: "notify", body: "{output.lastLine}"),
            .init(action: "notify", title: "T {keyword}", body: "b"),
            .init(action: "hud", text: "Copied {output.line1}"),
            .init(action: "open", target: "https://x.com/?q={query}"),
            .init(action: "open", target: "app:Notes"),
            .init(action: "open", target: "~/note.txt")
        ]) + steps([
            .init(action: "reveal", path: "out/a.png"),
            .init(action: "speak", text: "{output.line1}", language: "en"),
            .init(action: "speak", text: "hi"),
            .init(action: "askAI", prompt: "Explain {output}")
        ])
        let effects = all.map(\.effect)
        #expect(try Array(effects[0 ..< 7]) == [
            .copy("line one"), .writeBack("line one\nline two"), .notify(title: "FX", body: "line two"),
            .notify(title: "T fx", body: "b"), .hud("Copied line one"),
            .open(.link(#require(URL(string: "https://x.com/?q=q%20x")))), .open(.application("Notes"))
        ])
        guard case let .open(.file(note)) = effects[7], case let .reveal(image) = effects[8] else {
            Issue.record("a file and a folder item: \(effects[7] as Any) \(effects[8] as Any)")
            return
        }
        #expect(note.standardizedFileURL.path == home.appendingPathComponent("note.txt").standardizedFileURL.path)
        #expect(image.standardizedFileURL.path == folder.appendingPathComponent("out/a.png").standardizedFileURL.path)
        #expect(Array(effects[9...]) == [.speak("line one", language: "en"), .speak("hi", language: nil),
                                         .askAI("Explain line one\nline two")])
        #expect(all.allSatisfy { $0.problem == nil })
        #expect(all[2].detail == "FX · line two" && all[0].title == AskWorkflowAction.Kind.copy.title)
    }

    @Test func stepsThatCannotRunSayWhy() {
        let bad = steps([
            .init(action: "teleport"),
            .init(action: "copy", value: "{selection}"),
            .init(action: "open", target: "ssh://host"),
            .init(action: "open", target: "https://"),
            .init(action: "open", target: "missing.txt"),
            .init(action: "open", target: "app:"),
            .init(action: "open", target: "file:///nope/nothing"),
            .init(action: "reveal", path: "nothing.png")
        ], output: "plain")
        #expect(bad.allSatisfy { $0.effect == nil && $0.problem != nil })
        #expect(bad[0].problem == L("ask.workflow.problem.action.unknown", "teleport") && bad[0]
            .symbol == "questionmark.circle")
        #expect(bad[1].problem == L("ask.workflow.action.empty"))
        #expect(bad[2].problem == L("ask.workflow.action.cannotOpen", "ssh://host"))
        let missing = steps([.init(action: "copy", value: "{json.amount}")], output: "plain")
        #expect(missing.first?.missing == ["{json.amount}"] && missing.first?.problem == L("ask.workflow.action.empty"))
        #expect(steps(Array(repeating: .init(action: "copy", value: "x"), count: 12)).count == 8, "at most eight")
    }

    @Test func errorFillsFailureActions() {
        let step = steps([.init(action: "notify", body: "{error}")], error: "exit 1\nboom")
        #expect(step.first?.effect == .notify(title: "FX", body: "exit 1\nboom"))
    }

    @Test func actionsRunInOrderAndAFailureDoesNotStopTheRest() async {
        let host = RecordingActionHost()
        host.opens = false
        let outcomes = await AskWorkflowActionRunner.run(steps([
            .init(action: "copy", value: "{output.line1}"),
            .init(action: "teleport"),
            .init(action: "open", target: "app:Nope"),
            .init(action: "reveal", path: "out/a.png"),
            .init(action: "hud", text: "done"),
            .init(action: "speak", text: "hi"),
            .init(action: "writeBack", value: "w"),
            .init(action: "askAI", prompt: "p")
        ]), host: host)
        #expect(host.calls == ["copy:line one", "open:application(\"Nope\")", "reveal:a.png", "hud:done", "speak:hi|-",
                               "writeBack:w", "askAI:p"])
        #expect(outcomes.map(\.succeeded) == [true, false, false, true, true, true, true, true])
        #expect(outcomes[2].status == .failed(L("ask.workflow.action.cannotOpen", "app:Nope")))
    }

    @Test func deniedNotificationsFallBackToTheBar() async {
        let host = RecordingActionHost()
        host.notificationsAllowed = false
        let outcomes = await AskWorkflowActionRunner.run(steps([.init(action: "notify", title: "T", body: "B"),
                                                                .init(action: "copy", value: "c")]), host: host)
        #expect(host.calls == ["notify:T|B", "hud:T · B", "copy:c"])
        #expect(outcomes.first?.status == .fellBack(L("ask.workflow.action.notifyDenied")))
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(
            AskWorkflowActionRunner.summary(outcomes)
                .hasPrefix("✓ T · B (" + L("ask.workflow.action.notifyDenied") + ")"),
            "the bar says what it showed, not that a notification went out"
        )
    }

    @Test func previewRunsNothing() async {
        let host = RecordingActionHost()
        let outcomes = await AskWorkflowActionRunner.run(steps([.init(action: "copy", value: "c"),
                                                                .init(action: "nope")]), host: host, perform: false)
        #expect(host.calls.isEmpty)
        #expect(outcomes.map(\.status) == [.skipped(nil), .failed(L("ask.workflow.problem.action.unknown", "nope"))])
        #expect(AskWorkflowActionRunner.summary(outcomes).hasPrefix("✕ "))
    }

    @Test func runsAskBeforeWritingBackOrOpeningAndSkipTheAI() async {
        let host = RecordingActionHost()
        var asked: [String] = []
        let outcomes = await AskWorkflowActionRunner.run(steps([
            .init(action: "writeBack", value: "w"),
            .init(action: "open", target: "https://x.com"),
            .init(action: "copy", value: "c"),
            .init(action: "askAI", prompt: "p")
        ]), host: host) { step in
            asked.append(step.action.action)
            return step.action.action == "open"
        }
        #expect(asked == ["writeBack", "open"])
        #expect(host.calls == ["open:link(https://x.com)", "copy:c"])
        #expect(outcomes.map(\.status) == [.skipped(L("ask.workflow.action.declined")), .done, .done,
                                           .skipped(L("ask.workflow.action.notInTest"))])
    }

    @Test func theSummaryNamesWhatHappened() async {
        let host = RecordingActionHost()
        let outcomes = await AskWorkflowActionRunner.run(steps([
            .init(action: "copy", value: "100 USD = 14,912.30 JPY"),
            .init(action: "notify", body: "b"),
            .init(action: "hud", text: "Saved"),
            .init(action: "nope")
        ]), host: host)
        #expect(AskWorkflowActionRunner.summary(outcomes) == [
            "✓ " + L("ask.workflow.action.done.copy", "100 USD = 14,912.30 JPY"),
            "✓ " + L("ask.workflow.action.done.notify"), "✓ Saved",
            "✕ nope: " + L("ask.workflow.problem.action.unknown", "nope")
        ].joined(separator: " · "))
        for kind in AskWorkflowAction.Kind.allCases where kind != .hud {
            let text = AskWorkflowActionRunner.doneText(.init(action: kind.template, detail: "d"))
            #expect(!text.hasPrefix("ask.workflow"))
        }
        #expect(AskWorkflowActionRunner.doneText(.init(action: .init(action: "x"), detail: "")) == "x")
    }

    @Test func clippingKeepsOneShortLine() {
        #expect(AskWorkflowActionRunner.clipped("short") == "short")
        #expect(AskWorkflowActionRunner.clipped("a\nb") == "a…")
        #expect(AskWorkflowActionRunner.clipped(String(repeating: "x", count: 50), limit: 10) == "xxxxxxxxxx…")
        #expect(AskWorkflowActionRunner.clipped("") == "")
    }

    @Test func effectsKnowWhetherTheyLeaveTheLauncher() {
        #expect(AskWorkflowEffect.writeBack("x").closesLauncher && AskWorkflowEffect.askAI("x").closesLauncher)
        #expect(!AskWorkflowEffect.copy("x").closesLauncher && !AskWorkflowEffect.hud("x").needsConfirmationInTest)
        #expect(AskWorkflowEffect.open(.application("A")).needsConfirmationInTest)
    }

    @Test func filesResolveUnderHomeOrTheFolder() {
        #expect(AskWorkflowActionRunner.file("~", folder: folder, home: "/Users/me")?.path == "/Users/me")
        #expect(AskWorkflowActionRunner.file("~/a", folder: folder, home: "/Users/me")?.path == "/Users/me/a")
        #expect(AskWorkflowActionRunner.file("/etc/hosts", folder: folder, home: "/Users/me")?.path == "/etc/hosts")
        #expect(AskWorkflowActionRunner.file("../x", folder: folder, home: "/Users/me") == nil)
    }
}
