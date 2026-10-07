// swiftlint:disable file_length
import AppKit
import Foundation
import Testing
@testable import Typeflux

/// A PNG of `width` × `height` pixels, for image results.
func askWorkflowTestPNG(width: Int = 40, height: Int = 20) throws -> Data {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(rep.representation(using: .png, properties: [:]))
}

@Suite("Ask workflow script actions")
struct AskWorkflowScriptOutputTests {
    @Test func `the envelope gives the text and the actions`() throws {
        let script = try #require(AskWorkflowScriptOutput.parse(#"""
          {"text": "100 USD = 14,912.30 JPY",
           "actions": [{"action": "open", "target": "https://www.xe.com/"}, {"action": "copy", "value": 42},
                       {"value": "no name"}, "not an object", {"action": "teleport"}]}
        """#))
        #expect(script.text == "100 USD = 14,912.30 JPY")
        #expect(script.actions == [AskWorkflowAction(action: "open", target: "https://www.xe.com/"),
                                   AskWorkflowAction(action: "copy", value: "42"),
                                   AskWorkflowAction(action: "teleport")])
        let bare = try #require(AskWorkflowScriptOutput.parse(#"{"actions": []}"#))
        #expect(bare.text.isEmpty && bare.actions.isEmpty)
    }

    @Test func `other JSON is not an envelope`() {
        #expect(AskWorkflowScriptOutput.parse("plain text") == nil)
        #expect(AskWorkflowScriptOutput.parse(#"{"text": "x"}"#) == nil, "no actions")
        #expect(AskWorkflowScriptOutput.parse(#"{"items": [], "actions": []}"#) == nil, "a list")
        #expect(AskWorkflowScriptOutput.parse(#"{"name": "doc", "actions": [{"action": "copy"}]}"#) == nil,
                "a document that only has an actions key")
        #expect(AskWorkflowScriptOutput.parse(#"{"text": 3, "actions": []}"#) == nil)
        #expect(AskWorkflowScriptOutput.parse(#"{"actions": "copy"}"#) == nil)
        #expect(AskWorkflowScriptOutput.parse(#"{"actions": [ broken"#) == nil)
    }

    @Test func `at most eight actions are kept`() throws {
        let many = (0 ..< 12).map { #"{"action": "hud", "text": "\#($0)"}"# }.joined(separator: ",")
        let script = try #require(AskWorkflowScriptOutput.parse(#"{"actions": [\#(many)]}"#))
        #expect(script.actions.count == AskWorkflowManifest.Output.maximumActions)
        #expect(script.actions.last?.text == "7")
    }

    @Test func `the launcher shows the envelopes text`() {
        let stdout = ##"{"text": "# Title", "actions": [{"action": "hud", "text": "x"}]}"##
        #expect(AskWorkflowDecodedOutput.decode(stdout, display: .text) == .text("# Title", note: nil))
        #expect(AskWorkflowDecodedOutput.decode(stdout, display: .auto) == .text("# Title", note: nil))
        #expect(AskWorkflowDecodedOutput.decode(stdout, display: .markdown) == .markdown("# Title"))
        #expect(AskWorkflowDecodedOutput.decode(stdout, display: .items) == .text("# Title", note: nil))
        #expect(AskWorkflowDecodedOutput
            .decode(#"{"text": "a.png", "actions": []}"#, display: .image) == .image("a.png"))
        #expect(!AskWorkflowDecodedOutput.streams("{\"text\"", display: .text), "it may be an envelope")
        #expect(!AskWorkflowDecodedOutput.streams("a.png", display: .image))
    }

    @Test func `json placeholders read the whole envelope`() {
        let stdout = #"{"text": "shown", "actions": [{"action": "hud", "text": "x"}]}"#
        let values = AskWorkflowPlaceholders(output: "shown", json: stdout)
        #expect(values.expand("{output} {json.actions.0.text}") == "shown x")
        #expect(values.missingJSON(in: "{json.text} {json.nope}") == ["{json.nope}"])
        #expect(AskWorkflowPlaceholders(output: #"{"a": 1}"#).expand("{json.a}") == "1", "without one, output is read")
    }

    @Test func `known hosts come from the manifest and the code`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"""
        {"id": "a", "name": "A", "command": {"runtime": "zsh", "script": "main.py"},
         "output": {"onSuccess": [{"action": "open", "target": "https://docs.example.com/{query}"}]}}
        """#.utf8).write(to: folder.appendingPathComponent("workflow.json"))
        try Data("import urllib\nurl = 'https://open.er-api.com/v6/latest'\n# https://comment.example.org\n".utf8)
            .write(to: folder.appendingPathComponent("main.py"))
        try Data(repeating: 0x61, count: AskWorkflowScriptOutput.maximumScannedFile + 1)
            .write(to: folder.appendingPathComponent("big.txt"))
        #expect(AskWorkflowScriptOutput.knownHosts(in: folder) == ["docs.example.com", "open.er-api.com"])
        #expect(try AskWorkflowScriptOutput.host(of: #require(URL(string: "https://WWW.XE.com/a"))) == "www.xe.com")
        #expect(try AskWorkflowScriptOutput.host(of: #require(URL(string: "file:///tmp"))) == nil)
    }
}

@Suite("Ask workflow script steps and runKeyword")
@MainActor
struct AskWorkflowScriptStepTests {
    private let folder = URL(fileURLWithPath: "/tmp/tf-script-steps")

    private func steps(_ actions: [AskWorkflowAction], allowed: Bool = true, known: Set<String> = [],
                       chain: [String] = []) -> [AskWorkflowActionStep] {
        AskWorkflowActionRunner.scriptSteps(actions, allowed: allowed, folder: folder, name: "FX", home: "/Users/me",
                                            chain: chain, knownHosts: { known })
    }

    @Test func `script actions are used as written and marked`() {
        let listed = steps([.init(action: "copy", value: "{query} {output}"), .init(action: "teleport")])
        #expect(listed.map(\.effect) == [.copy("{query} {output}"), nil], "no placeholders in what a script printed")
        #expect(listed.allSatisfy(\.fromScript) && listed.allSatisfy { $0.notRun == nil })
        #expect(
            listed[1].problem == L("ask.workflow.problem.action.unknown", "teleport"),
            "the allowed list still holds"
        )
        let many = steps(Array(repeating: .init(action: "hud", text: "x"), count: 10))
        #expect(many.count == AskWorkflowManifest.Output.maximumActions)
    }

    @Test func `without the switch they are only listed`() async {
        let listed = steps([.init(action: "copy", value: "x"), .init(action: "teleport")], allowed: false)
        #expect(listed.allSatisfy { $0.notRun == L("ask.workflow.action.scriptNotAllowed") })
        let host = RecordingActionHost()
        let outcomes = await AskWorkflowActionRunner.run(listed, host: host)
        #expect(outcomes.map(\.status) == Array(
            repeating: .skipped(L("ask.workflow.action.scriptNotAllowed")),
            count: 2
        ))
        #expect(host.calls.isEmpty)
        let preview = await AskWorkflowActionRunner.run(listed, host: host, perform: false)
        #expect(preview.first?.status == .skipped(L("ask.workflow.action.scriptNotAllowed")), "not even as a preview")
        #expect(AskWorkflowActionRunner.summary(outcomes).isEmpty)
    }

    @Test func `links to hosts the workflow does not name are asked about`() {
        var reads = 0
        let actions: [AskWorkflowAction] = [
            .init(action: "open", target: "https://www.xe.com/convert"),
            .init(action: "open", target: "https://api.example.com/x"),
            .init(action: "open", target: "https://example.com"),
            .init(action: "open", target: "app:Notes"),
            .init(action: "copy", value: "https://evil.example.net")
        ]
        let listed = AskWorkflowActionRunner.scriptSteps(actions, allowed: true, folder: folder, name: "FX",
                                                         knownHosts: { reads += 1; return ["example.com"] })
        #expect(listed.map(\.confirmHost) == ["www.xe.com", nil, nil, nil, nil])
        #expect(reads == 1, "the folder is read once, and only for links")
        _ = AskWorkflowActionRunner.scriptSteps([.init(action: "copy", value: "x")], allowed: true, folder: folder,
                                                name: "FX", knownHosts: { reads += 1; return [] })
        #expect(reads == 1)
        #expect(AskWorkflowActionRunner.isKnown("a.b.example.com", in: ["example.com"]))
        #expect(!AskWorkflowActionRunner.isKnown("badexample.com", in: ["example.com"]))
    }

    @Test func `the launcher asks before opening an unknown host`() async {
        let listed = steps([.init(action: "open", target: "https://www.xe.com/a"),
                            .init(action: "open", target: "https://ok.example.com/b")], known: ["ok.example.com"])
        let host = RecordingActionHost()
        var outcomes = await AskWorkflowActionRunner.run(listed, host: host)
        #expect(outcomes.map(\.status) == [.skipped(L("ask.workflow.action.hostDeclined", "www.xe.com")), .done])
        #expect(host.calls == ["approve:www.xe.com", "open:link(https://ok.example.com/b)"])
        host.calls = []
        host.allowedHosts = ["www.xe.com"]
        outcomes = await AskWorkflowActionRunner.run(listed, host: host)
        #expect(outcomes.map(\.status) == [.done, .done])
        host.calls = []
        _ = await AskWorkflowActionRunner.run(listed, host: host) { _ in true }
        #expect(!host.calls.contains { $0.hasPrefix("approve:") }, "a test run's own question covers it")
        host.calls = []
        _ = await AskWorkflowActionRunner.run(listed, host: host, perform: false)
        #expect(host.calls.isEmpty, "previews ask nothing")
    }
}

@Suite("Ask workflow runKeyword")
@MainActor
struct AskWorkflowRunKeywordTests {
    private let folder = URL(fileURLWithPath: "/tmp/tf-run-keyword")

    private func step(_ action: AskWorkflowAction, chain: [String] = ["fx"],
                      output: String = "100 usd") -> AskWorkflowActionStep {
        AskWorkflowActionRunner.step(for: action, placeholders: AskWorkflowPlaceholders(output: output, query: "q"),
                                     folder: folder, name: "FX", chain: chain)
    }

    @Test func `the kind has its fields and template`() {
        let kind = AskWorkflowAction.Kind.runKeyword
        #expect(kind.fields == [.keyword, .argument] && kind.requiredField == .keyword)
        #expect(kind.template == AskWorkflowAction(action: "runKeyword", keyword: "", argument: "{output}"))
        #expect(AskWorkflowAction.Kind.groups.last?.last == .runKeyword)
        #expect(!kind.title.hasPrefix("ask.") && !kind.symbol.isEmpty)
        var action = AskWorkflowAction(action: "runKeyword")
        action[.keyword] = "tr"
        action[.argument] = "{output}"
        #expect(action.keyword == "tr" && action[.argument] == "{output}")
        #expect(action.jsonObject as NSDictionary == ["action": "runKeyword", "keyword": "tr", "argument": "{output}"])
    }

    @Test func `it fills in the argument and carries the chain`() {
        let run = step(.init(action: "runKeyword", keyword: "tr", argument: "{output} {query}"))
        #expect(run.effect == .runKeyword("tr", argument: "100 usd q", chain: ["fx"]) && run.problem == nil)
        #expect(run.detail == "tr 100 usd q")
        #expect(step(.init(action: "runKeyword", keyword: "tr")).detail == "tr")
        #expect(step(.init(action: "runKeyword", keyword: "{output}"), output: "ip").effect
            == .runKeyword("ip", argument: "", chain: ["fx"]), "the keyword itself may come from the output")
        #expect(AskWorkflowEffect.runKeyword("a", argument: "", chain: []).needsConfirmationInTest)
        #expect(!AskWorkflowEffect.runKeyword("a", argument: "", chain: []).closesLauncher)
    }

    @Test func `loops and long chains are refused`() {
        let back = step(.init(action: "runKeyword", keyword: "FX"), chain: ["fx"])
        #expect(back.effect == nil && back.problem == L("ask.workflow.action.loop", "fx → FX"))
        let around = step(.init(action: "runKeyword", keyword: "a"), chain: ["a", "b", "c"])
        #expect(around.problem == L("ask.workflow.action.loop", "a → b → c → a"))
        #expect(step(.init(action: "runKeyword", keyword: "d"), chain: ["a", "b", "c"]).problem == nil,
                "the third run started this way is allowed")
        let deep = step(.init(action: "runKeyword", keyword: "e"), chain: ["a", "b", "c", "d"])
        #expect(deep.problem == L("ask.workflow.action.tooDeep", AskWorkflowAction.maximumChain))
        #expect(step(.init(action: "runKeyword", keyword: "{output}"), output: "two words").problem
            == L("ask.workflow.problem.action.keyword"))
        #expect(step(.init(action: "runKeyword", keyword: "{nope}"))
            .problem == L("ask.workflow.problem.action.keyword"))
        #expect(step(.init(action: "runKeyword", keyword: " ")).problem == L("ask.workflow.action.empty"))
    }

    @Test func `validation wants one word`() {
        func problem(_ keyword: String?) -> String? {
            AskWorkflowAction(action: "runKeyword", keyword: keyword).problem(folder: folder, failure: false)
        }
        #expect(problem("tr") == nil && problem("{output.line1}") == nil)
        #expect(problem("tr x") == L("ask.workflow.problem.action.keyword"))
        #expect(problem("tr:") == L("ask.workflow.problem.action.keyword"))
        #expect(problem(nil) == L("ask.workflow.problem.action.missing", AskWorkflowAction.Field.keyword.title))
        #expect(AskWorkflowAction(action: "runKeyword", keyword: "a", argument: "{error}")
            .problem(folder: folder, failure: false) == L("ask.workflow.problem.action.error"))
    }

    @Test func `the runner hands it to the host`() async {
        let host = RecordingActionHost()
        let steps = [step(.init(action: "runKeyword", keyword: "tr", argument: "{output}")),
                     step(.init(action: "runKeyword", keyword: "zz")),
                     step(.init(action: "runKeyword", keyword: "fx"))]
        let outcomes = await AskWorkflowActionRunner.run(steps, host: host)
        #expect(host.calls == ["runKeyword:tr|100 usd|fx", "runKeyword:zz||fx"])
        #expect(outcomes.map(\.status) == [.done, .failed(L("ask.workflow.action.noKeyword", "zz")),
                                           .failed(L("ask.workflow.action.loop", "fx → fx"))])
        #expect(AskWorkflowActionRunner.summary(Array(outcomes.prefix(1)))
            == "✓ " + L("ask.workflow.action.done.runKeyword", "tr 100 usd"))
        var declined = 0
        let tested = await AskWorkflowActionRunner
            .run(Array(steps.prefix(1)), host: host) { _ in declined += 1; return false }
        #expect(declined == 1 && tested.first?.status == .skipped(L("ask.workflow.action.declined")))
    }
}

@Suite("Ask workflow images")
struct AskWorkflowImageTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("out"),
            withIntermediateDirectories: true
        )
        return folder
    }

    @Test func `paths are read from the folder home or anywhere`() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try askWorkflowTestPNG(width: 40, height: 20).write(to: folder.appendingPathComponent("out/qr.png"))
        let cache = folder.appendingPathComponent("cache")
        let relative = try AskWorkflowImage.resolve(
            "out/qr.png\nignored",
            folder: folder,
            cache: cache,
            home: "/nowhere"
        ).get()
        #expect(relative.url.lastPathComponent == "qr.png" && relative.width == 40 && relative.height == 20)
        let absolute = try AskWorkflowImage.resolve(folder.path + "/out/qr.png", folder: URL(fileURLWithPath: "/"),
                                                    cache: cache, home: "/nowhere").get()
        #expect(absolute.url.path.hasSuffix("out/qr.png"))
        #expect((try? AskWorkflowImage.resolve("~/out/qr.png", folder: cache, cache: cache, home: folder.path).get()) !=
            nil)
        #expect((try? AskWorkflowImage.resolve(URL(fileURLWithPath: folder.path + "/out/qr.png").absoluteString,
                                               folder: cache, cache: cache, home: "/").get()) != nil)
        #expect(AskWorkflowImage.resolve("missing.png", folder: folder, cache: cache, home: "/")
            == .failure(.notFound("missing.png")))
        #expect(AskWorkflowImage.resolve("", folder: folder, cache: cache, home: "/") == .failure(.notFound("")))
        #expect(AskWorkflowImage.resolve("../escape.png", folder: folder, cache: cache, home: "/")
            == .failure(.notFound("../escape.png")), "relative paths stay in the folder")
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("out/fake.png"))
        #expect(AskWorkflowImage
            .resolve("out/fake.png", folder: folder, cache: cache, home: "/") == .failure(.notImage))
    }

    @Test func `data UR ls are saved once to the cache`() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let url = try "data:image/png;base64," + askWorkflowTestPNG(width: 8, height: 6).base64EncodedString()
        let first = try AskWorkflowImage.resolve(url, folder: folder, cache: cache, home: "/").get()
        #expect(first.url.deletingLastPathComponent().lastPathComponent == "images")
        #expect(first.url.pathExtension == "png" && first.width == 8 && first.height == 6)
        let second = try AskWorkflowImage.resolve("  " + url + "\n", folder: folder, cache: cache, home: "/").get()
        #expect(second == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.url.deletingLastPathComponent().path)
            .count == 1)
        #expect(AskWorkflowImage.resolve("data:text/plain;base64,aGk=", folder: folder, cache: cache, home: "/")
            == .failure(.notImage))
        #expect(AskWorkflowImage.resolve("data:image/png;base64,aGk=", folder: folder, cache: cache, home: "/")
            == .failure(.notImage), "base64 that is no image")
        #expect(AskWorkflowImage.dataURL("data:image/png,raw") == nil && AskWorkflowImage
            .dataURL("data:image/png") == nil)
        #expect(AskWorkflowImage.dataURL("DATA:IMAGE/PNG;BASE64,aG k=") == Data("hi".utf8), "case and spaces")
    }

    @Test func `the card scales images down never up`() {
        let width = Double(AskPluginResultsView.textWidth)
        let small = AskPluginResultsView.imageSize(AskPluginImage(
            url: URL(fileURLWithPath: "/a"),
            width: 60,
            height: 30
        ))
        #expect(small == CGSize(width: 60, height: 30))
        let wide = AskPluginResultsView.imageSize(AskPluginImage(url: URL(fileURLWithPath: "/a"), width: width * 2,
                                                                 height: 100))
        #expect(wide == CGSize(width: width.rounded(), height: 50))
        let tall = AskPluginResultsView.imageSize(AskPluginImage(
            url: URL(fileURLWithPath: "/a"),
            width: 100,
            height: 960
        ))
        #expect(tall.height == AskPluginResultsView.maximumImageHeight && tall.width == 25)
        var output = AskPluginOutput(body: "a.png", original: "", meta: [], source: "", actions: [])
        let text = AskPluginResultsView.cardHeight(output: output, failure: nil, comparing: false)
        output.image = AskPluginImage(url: URL(fileURLWithPath: "/a"), width: 60, height: 200)
        let image = AskPluginResultsView.cardHeight(output: output, failure: nil, comparing: false)
        #expect(image - text == 200 - AskPluginResultsView.bodyHeight("a.png"))
    }

    @Test @MainActor func `copying an image puts the image and the file on the pasteboard`() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.png")
        try askWorkflowTestPNG().write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wf-image-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(AskQuickResults.copyImage(file, to: pasteboard))
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.data(forType: .png) != nil && pasteboard.data(forType: .tiff) != nil)
        #expect(pasteboard.string(forType: .fileURL) == file.absoluteString)
        #expect(!AskQuickResults.copyImage(folder.appendingPathComponent("none.png"), to: pasteboard))
        #expect(AskPluginResultsView.loadImage(file) != nil && AskPluginResultsView.loadImage(file) != nil)
        #expect(AskPluginResultsView.loadImage(folder.appendingPathComponent("none.png")) == nil)
    }
}

@Suite("Ask workflow O4 in the plugin")
@MainActor
struct AskWorkflowO4PluginTests {
    private func run(_ script: String, output: [String: Any], files: [String: String] = [:], chain: [String] = [],
                     prepare: (URL) throws -> Void = { _ in })
        async throws -> (Result<AskPluginOutput, AskPluginFailure>, AskWorkflowFixture) {
        let fixture = try AskWorkflowFixture()
        let folder = try fixture.write("local.a", manifest: AskWorkflowFixture.inline(
            "local.a", keyword: "a", script: script, extra: ["output": output]
        ), files: files)
        try prepare(folder)
        fixture.store.reload()
        fixture.store.trust("local.a")
        let workflow = try #require(fixture.store.workflow("local.a"))
        let plugin = AskWorkflowPlugin(workflow: workflow, home: fixture.home.path)
        var request = AskPluginRequest(text: "in", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:],
                                       interfaceLanguage: .english)
        request.chain = chain
        let plan = await plugin.plan(request)
        do {
            return try await (.success(plugin.run(request, plan: plan) { _ in }), fixture)
        } catch let failure as AskPluginFailure {
            return (.failure(failure), fixture)
        }
    }

    @Test func `an image card copies the image and shows it in finder`() async throws {
        let (result, _) = try await run("print -r -- out.png", output: ["display": "image"]) { folder in
            try askWorkflowTestPNG(width: 30, height: 10).write(to: folder.appendingPathComponent("out.png"))
        }
        let output = try result.get()
        let image = try #require(output.image)
        #expect(image.url.lastPathComponent == "out.png" && image.width == 30)
        #expect(output.body == "out.png" && output.note == nil)
        #expect(output.action(for: .enter)?.kind == .copyImage(image.url))
        #expect(output.action(for: .optionEnter)?.kind == .reveal(image.url))
        #expect(output.actions.contains { $0.kind == .rerun([:]) } && !output.actions.contains { $0.kind == .compare })
    }

    @Test func `a data URL image lands in the cache`() async throws {
        let png = try askWorkflowTestPNG(width: 4, height: 4).base64EncodedString()
        let (result, fixture) = try await run(
            "print -r -- 'data:image/png;base64,\(png)'",
            output: ["display": "image"]
        )
        let image = try #require(try result.get().image)
        #expect(image.url.path.hasPrefix(AskWorkflow.cacheDirectory(for: "local.a", home: fixture.home.path).path))
    }

    @Test func `what is not an image says why`() async throws {
        let (missing, _) = try await run("print -r -- nope.png", output: ["display": "image"])
        let card = try missing.get()
        #expect(card.image == nil && card.note == L("ask.workflow.image.notFound", "nope.png"))
        #expect(card.action(for: .enter)?.kind == .copy("nope.png"))
        let (data, _) = try await run("print -r -- 'data:image/png;base64,aGVsbG8='", output: ["display": "image"])
        let broken = try data.get()
        #expect(broken.note == L("ask.workflow.image.invalid") && broken.body.count <= 61)
    }

    @Test func `script actions follow the configured ones when allowed`() async throws {
        let printed = #"{"text": "shown", "actions": [{"action": "copy", "value": "from script"}, "#
            + #"{"action": "open", "target": "https://new.example.org/x"}]}"#
        // Encoded, so the host is not named in the code: the script makes it up at run time.
        let (result, _) = try await run(Self.printing(printed), output: [
            "display": "text", "scriptActions": true,
            "onSuccess": [["action": "hud", "text": "{output}|{json.actions.0.value}"]]
        ], files: ["notes.sh": "curl https://api.example.org/v1"])
        let output = try result.get()
        #expect(output.body == "shown")
        let steps = try #require(output.followUp?.steps)
        #expect(try steps.map(\.effect) == [.hud("shown|from script"), .copy("from script"),
                                            .open(.link(#require(URL(string: "https://new.example.org/x"))))])
        #expect(steps.map(\.fromScript) == [false, true, true])
        #expect(steps.last?.confirmHost == "new.example.org", "the workflow names api.example.org, not this host")
    }

    /// A zsh line that prints `text` without naming anything in it.
    static func printing(_ text: String) -> String {
        "print -r -- \(Data(text.utf8).base64EncodedString()) | base64 -d"
    }

    @Test func `hosts named in an inline script are known`() async throws {
        let (result, _) = try await run(
            #"print -r -- '{"actions": [{"action": "open", "target": "https://www.xe.com/"}]}'"#,
            output: ["display": "text", "scriptActions": true]
        )
        #expect(try result.get().followUp?.steps.first?.confirmHost == nil)
    }

    @Test func `script actions are only listed when not allowed`() async throws {
        let printed = #"{"text": "", "actions": [{"action": "copy", "value": "x"}]}"#
        let (result, _) = try await run("print -r -- '\(printed)'", output: ["display": "text"])
        let output = try result.get()
        #expect(output.dismisses, "nothing to show")
        #expect(output.followUp?.steps.map(\.notRun) == [L("ask.workflow.action.scriptNotAllowed")])
    }

    @Test func `run keyword knows the chain so far`() async throws {
        let (result, _) = try await run("print -r -- next", output: [
            "display": "text", "onSuccess": [["action": "runKeyword", "keyword": "b", "argument": "{output}"],
                                             ["action": "runKeyword", "keyword": "x"]]
        ], chain: ["x"])
        let steps = try #require(try result.get().followUp?.steps)
        #expect(steps.first?.effect == .runKeyword("b", argument: "next", chain: ["x", "a"]))
        #expect(steps.last?.problem == L("ask.workflow.action.loop", "x → a → x"))
    }

    @Test func `the trust sheet says the script may add actions`() {
        #expect(AskWorkflowTrustSummary.actions(.init(scriptActions: true)) == [L("ask.workflow.trust.scriptActions")])
        #expect(AskWorkflowTrustSummary.actions(.init()).isEmpty)
    }

    @Test func `approvals are forgotten with the workflow and follow A rename`() throws {
        let fixture = try AskWorkflowFixture()
        let folder = try fixture.write("local.a", manifest: AskWorkflowFixture.inline("local.a", script: "echo"))
        fixture.store.reload()
        fixture.settings.askWorkflowAllowedHosts = ["local.a": ["www.xe.com"], "other": ["x.com"]]
        var manifest = AskWorkflowFixture.inline("local.b", script: "echo")
        manifest["name"] = "B"
        let data = try JSONSerialization.data(withJSONObject: manifest)
        _ = try fixture.store.save("local.a", folder: folder, writes: ["workflow.json": data], expectedHash: nil)
        #expect(fixture.settings.askWorkflowAllowedHosts == ["local.b": ["www.xe.com"], "other": ["x.com"]])
        try fixture.store.delete("local.b")
        #expect(fixture.settings.askWorkflowAllowedHosts == ["other": ["x.com"]])
    }
}

@Suite("Ask workflow O4 in the test panel")
@MainActor
struct AskWorkflowO4TesterTests {
    @Test func `a test run lists the scripts actions`() async throws {
        let fixture = try AskWorkflowFixture()
        let printed = #"{"text": "t", "actions": [{"action": "open", "target": "https://www.xe.com/"}]}"#
        for allowed in [false, true] {
            try fixture.write("local.t", manifest: AskWorkflowFixture.inline("local.t", keyword: "t",
                                                                             script: AskWorkflowO4PluginTests
                                                                                 .printing(printed), extra: [
                                                                                     "output": [
                                                                                         "display": "text",
                                                                                         "scriptActions": allowed,
                                                                                         "onSuccess": [[
                                                                                             "action": "copy",
                                                                                             "value": "{output}"
                                                                                         ]]
                                                                                     ]
                                                                                 ]))
            fixture.store.reload()
            fixture.store.trust("local.t")
            let tester = AskWorkflowTester(home: fixture.home.path)
            let result = try await tester.run(#require(fixture.store.workflow("local.t")),
                                              input: AskWorkflowTestInput(query: "q"))
            #expect(result.actionSteps.map(\.fromScript) == [false, true])
            #expect(result.actionSteps.first?.effect == .copy("t"), "{output} is the envelope's text")
            #expect(result.actionSteps.last?.notRun == (allowed ? nil : L("ask.workflow.action.scriptNotAllowed")))
            #expect(result.actionSteps.last?.confirmHost == (allowed ? "www.xe.com" : nil))
            let status = try AskWorkflowTestActions.status(#require(result.actionSteps.last), nil).0
            #expect(status == (allowed ? L("ask.workflow.editor.test.actionPreview")
                    : L("ask.workflow.action.scriptNotAllowed")))
        }
        let failed = AskWorkflowTestResult(input: .init(query: ""), exitCode: 1,
                                           stdout: #"{"actions": [{"action": "copy", "value": "x"}]}"#, stderr: "",
                                           duration: 0)
        #expect(failed.takesFailureActions)
        let unknown = AskWorkflowActionStep(action: .init(action: "teleport"), problem: "bad", detail: "",
                                            notRun: "not allowed")
        #expect(AskWorkflowTestActions.status(unknown, nil).0 == "not allowed", "not run wins over a problem")
    }

    @Test func `the editor host types the keyword into the launcher`() async throws {
        let fixture = try AskWorkflowFixture()
        let defaults = try #require(UserDefaults(suiteName: "wf-o4-host-\(UUID().uuidString)"))
        let model = AskWorkflowEditorModel(
            store: fixture.store, settings: fixture.settings,
            assistant: AskWorkflowAssistant(dependencies: .init(
                api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
                modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
            ))
        )
        let host = AskWorkflowEditorActionHost(model: model)
        var typed: [String] = []
        host.openInLauncher = { typed.append($0); return true }
        #expect(host.runKeyword("tr", argument: "hello", chain: ["fx"]))
        #expect(host.runKeyword("ip", argument: "", chain: []))
        #expect(typed == ["tr hello", "ip "])
        #expect(await host.approve(host: "x.com"))
        let previous = AskWorkflowEditorWindowController.shared.openInLauncher
        defer { AskWorkflowEditorWindowController.shared.openInLauncher = previous }
        AskWorkflowEditorWindowController.shared.openInLauncher = nil
        #expect(!AskWorkflowEditorActionHost(model: model).runKeyword("tr", argument: "", chain: []))
    }
}
