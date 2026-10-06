import Foundation
import Testing
@testable import Typeflux

private func manifestText(_ object: [String: Any]) -> String {
    AskWorkflowDraft.format(object) ?? "{}"
}

private let pythonManifest: [String: Any] = [
    "schema": 1, "id": "local.fx", "name": "FX", "keywords": [["keyword": "fx", "title": "Rates"]],
    "command": ["runtime": "python3", "script": "main.py"], "output": "text", "x-roots": ["~/Code"]
]

@Suite("Ask workflow draft")
struct AskWorkflowDraftTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-draft-\(UUID().uuidString)")

    @Test func setChangesOneFieldAndKeepsUnknownOnes() {
        var draft = AskWorkflowDraft(
            folder: folder,
            manifestText: manifestText(pythonManifest),
            files: ["main.py": "print(1)"]
        )
        let setScript = draft.set("main2.py", at: ["command", "script"])
        #expect(setScript)
        #expect(draft.value(at: ["command", "script"]) as? String == "main2.py")
        #expect(draft.value(at: ["command", "runtime"]) as? String == "python3")
        #expect(draft.value(at: ["x-roots"]) as? [String] == ["~/Code"])
        let setRun = draft.set(["mode": "onSubmit", "timeoutSeconds": 5], at: ["run"])
        #expect(setRun)
        #expect(draft.manifest?.timeout == 5)
        // Nil removes a key, and an emptied object goes with it.
        draft.set(nil, at: ["run", "mode"])
        draft.set(nil, at: ["run", "timeoutSeconds"])
        #expect(draft.value(at: ["run"]) == nil)
        #expect(draft.isDirty && draft.changedPaths == ["workflow.json"])
    }

    @Test func theFormLeavesInvalidJSONAlone() {
        var draft = AskWorkflowDraft(folder: folder, manifestText: "{ \"id\": ", files: [:])
        #expect(!draft.isFormEditable)
        let changed = draft.set("x", at: ["name"])
        #expect(!changed)
        #expect(draft.manifestText == "{ \"id\": ")
        #expect(draft.formattedManifest() == nil)
        guard case .failure(.syntax) = draft.decoded else { Issue.record("expected a syntax error"); return }
        #expect(draft.problems().first?.field == "workflow.json")
    }

    @Test func aManifestThatIsJSONButNotAManifestNamesTheField() {
        let draft = AskWorkflowDraft(folder: folder, manifestText: #"{"id": "a", "name": "A"}"#, files: [:])
        #expect(draft.isFormEditable)
        guard case let .failure(.decoding(message)) = draft.decoded
        else { Issue.record("expected a decoding error"); return }
        #expect(message.contains("command"))
        #expect(AskWorkflowDraft(folder: folder, manifestText: "", files: [:]).problems().count == 1)
    }

    @Test func aScriptOnlyInTheDraftCountsAsPresent() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var draft = AskWorkflowDraft(folder: folder, manifestText: manifestText(pythonManifest), files: [:])
        #expect(draft.problems().map(\.field) == ["command.script"])
        draft.files["main.py"] = "print(1)"
        #expect(draft.problems().isEmpty)
    }

    @Test func loadReadsTextFilesAndSkipsTheRest() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try Data(manifestText(pythonManifest).utf8).write(to: folder.appendingPathComponent("workflow.json"))
        try Data("print(1)".utf8).write(to: folder.appendingPathComponent("main.py"))
        try Data("x = 1".utf8).write(to: folder.appendingPathComponent("lib/util.py"))
        try Data([0, 1, 2, 0xFF]).write(to: folder.appendingPathComponent("icon.png"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".env"))
        var draft = AskWorkflowDraft.load(folder: folder)
        #expect(draft.files.keys.sorted() == ["lib/util.py", "main.py"])
        #expect(draft.otherFiles == ["icon.png"])
        #expect(draft.paths == ["workflow.json", "lib/util.py", "main.py"])
        #expect(!draft.isDirty && draft.manifest?.id == "local.fx")
        draft.setText("print(2)", of: "main.py")
        draft.files["lib/util.py"] = nil
        #expect(draft.isDirty("main.py") && !draft.isDirty("workflow.json"))
        #expect(draft.changedPaths == ["main.py"] && draft.deletedPaths == ["lib/util.py"])
        #expect(draft.pendingWrites == ["main.py": Data("print(2)".utf8)])
        draft.markSaved()
        #expect(!draft.isDirty && draft.savedPaths == ["main.py"])
        #expect(draft.text(of: "workflow.json") == draft.manifestText && draft.text(of: "nope") == nil)
    }

    @Test func problemsMapToFlowSteps() {
        #expect(AskWorkflowDraft.step(for: "keywords[1]") == .keywords)
        #expect(AskWorkflowDraft.step(for: "input.selection") == .input)
        #expect(AskWorkflowDraft.step(for: "command.script") == .script)
        #expect(AskWorkflowDraft.step(for: "run.mode") == .output)
        #expect(AskWorkflowDraft.step(for: "output") == .output)
        #expect(AskWorkflowDraft.step(for: "env") == .output)
        #expect(AskWorkflowDraft.step(for: "id") == nil)
    }

    @Test func fieldsAreFoundOnTheirLines() {
        let text = """
        {
          "command" : {
            "runtime" : "python3",
            "script" : "main.ts"
          },
          "id" : "a",
          "keywords" : [
            {
              "keyword" : "fx"
            },
            {
              "keyword" : "tr"
            }
          ],
          "output" : "items"
        }
        """
        let draft = AskWorkflowDraft(folder: folder, manifestText: text, files: [:])
        #expect(draft.line(for: "command.script") == 4)
        #expect(draft.line(for: "output") == 15)
        #expect(draft.line(for: "keywords[1]") == 11)
        #expect(draft.line(for: "keywords[0]") == 8)
        #expect(draft.line(for: "keywords") == 7)
        #expect(draft.line(for: "missing") == nil)
        let compact = AskWorkflowDraft(
            folder: folder,
            manifestText: "{\n  \"keywords\": [{\"keyword\": \"a\"}]\n}",
            files: [:]
        )
        #expect(compact.line(for: "keywords[0]") == 2)
    }
}

@Suite("Ask workflow store editing")
@MainActor
struct AskWorkflowStoreEditorTests {
    private func readyWorkflow(_ fixture: AskWorkflowFixture, id: String = "local.a") throws -> AskWorkflow {
        try fixture.write(id, manifest: AskWorkflowFixture.inline(id, keyword: "aa", script: "print -r -- hi"))
        fixture.store.reload()
        fixture.store.trust(id)
        return try #require(fixture.store.workflow(id))
    }

    @Test func savingTheUsersOwnEditsKeepsTrust() throws {
        let fixture = try AskWorkflowFixture()
        let workflow = try readyWorkflow(fixture)
        #expect(workflow.status == .ready)
        let outcome = try fixture.store.save(
            workflow.id,
            folder: workflow.folder,
            writes: ["notes.txt": Data("x".utf8)],
            expectedHash: workflow.hash
        )
        guard case let .saved(hash, trusted) = outcome else { Issue.record("expected a save"); return }
        #expect(trusted && hash != workflow.hash)
        #expect(fixture.store.workflow(workflow.id)?.status == .ready)
    }

    @Test func anOutsideChangeIsAConflictAndNothingIsWritten() throws {
        let fixture = try AskWorkflowFixture()
        let workflow = try readyWorkflow(fixture)
        try Data("outside".utf8).write(to: workflow.folder.appendingPathComponent("other.txt"))
        let outcome = try fixture.store.save(
            workflow.id,
            folder: workflow.folder,
            writes: ["notes.txt": Data("x".utf8)],
            expectedHash: workflow.hash
        )
        guard case .conflict = outcome else { Issue.record("expected a conflict"); return }
        #expect(!FileManager.default.fileExists(atPath: workflow.folder.appendingPathComponent("notes.txt").path))
    }

    @Test func keepingMyVersionWritesButNeverTrusts() throws {
        let fixture = try AskWorkflowFixture()
        let workflow = try readyWorkflow(fixture)
        try Data("outside".utf8).write(to: workflow.folder.appendingPathComponent("other.txt"))
        let outcome = try fixture.store.save(
            workflow.id,
            folder: workflow.folder,
            writes: ["notes.txt": Data("x".utf8)],
            expectedHash: nil
        )
        guard case let .saved(_, trusted) = outcome else { Issue.record("expected a save"); return }
        #expect(!trusted)
        #expect(fixture.store.workflow(workflow.id)?.status == .modified)
    }

    @Test func savingAnUntrustedWorkflowDoesNotTrustIt() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.u", manifest: AskWorkflowFixture.inline("local.u", script: "print hi"))
        fixture.store.reload()
        let workflow = try #require(fixture.store.workflow("local.u"))
        #expect(workflow.status == .untrusted)
        _ = try fixture.store.save("local.u", folder: workflow.folder, writes: ["a.txt": Data("a".utf8)],
                                   expectedHash: workflow.hash)
        #expect(fixture.store.workflow("local.u")?.status == .untrusted)
    }

    @Test func renamingTheIDMovesTrustAndTheSwitch() throws {
        let fixture = try AskWorkflowFixture()
        let workflow = try readyWorkflow(fixture)
        fixture.store.setEnabled(workflow.id, false)
        let renamed = AskWorkflowFixture.inline("local.b", keyword: "aa", script: "print -r -- hi")
        let data = try JSONSerialization.data(withJSONObject: renamed)
        let reloaded = try #require(fixture.store.workflow(workflow.id))
        _ = try fixture.store.save(workflow.id, folder: workflow.folder, writes: ["workflow.json": data],
                                   expectedHash: reloaded.hash)
        #expect(fixture.settings.askWorkflowTrust["local.a"] == nil)
        #expect(fixture.settings.askWorkflowTrust["local.b"] != nil)
        #expect(fixture.settings.askDisabledWorkflows == ["local.b"])
    }

    @Test func writesStayInsideTheFolderAndKeepPermissions() throws {
        let fixture = try AskWorkflowFixture()
        let folder = fixture.root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in ["../escape.txt", "/etc/x", "~/x"] {
            #expect(throws: AskWorkflowStore.EditorError.pathOutside(path)) {
                try AskWorkflowStore.write([path: Data()], deletes: [], in: folder, fileManager: .default)
            }
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["id": "w", "name": "W",
                                                                   "command": [
                                                                       "runtime": "python3",
                                                                       "script": "main.py"
                                                                   ]])
        try AskWorkflowStore.write(["workflow.json": manifest, "main.py": Data("print(1)".utf8),
                                    "tool.sh": Data("#!/bin/zsh\n".utf8), "lib/data.txt": Data("d".utf8)],
                                   deletes: [], in: folder, fileManager: .default)
        func mode(_ path: String) throws -> Int {
            try #require(FileManager.default
                .attributesOfItem(atPath: folder.appendingPathComponent(path).path)[.posixPermissions] as? Int)
        }
        #expect(try mode("main.py") == 0o755 && mode("tool.sh") == 0o755 && mode("lib/data.txt") == 0o644)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: folder.appendingPathComponent("lib/data.txt").path
        )
        try AskWorkflowStore.write(
            ["lib/data.txt": Data("e".utf8)],
            deletes: ["tool.sh"],
            in: folder,
            fileManager: .default
        )
        #expect(try mode("lib/data.txt") == 0o600)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("tool.sh").path))
    }

    @Test func createUsesTheChosenNameKeywordAndID() throws {
        let fixture = try AskWorkflowFixture()
        let created = try fixture.store.create(
            .pythonText,
            name: "Rates",
            keyword: "fx",
            id: "local.rates",
            builtIn: []
        )
        #expect(created.status == .ready && created.manifest?.name == "Rates" && created.manifest?.keywords.first?
            .keyword == "fx")
        #expect(throws: AskWorkflowStore.EditorError.duplicateID("local.rates")) {
            try fixture.store.create(.nodeText, name: "", keyword: "fx2", id: "local.rates", builtIn: [])
        }
        #expect(throws: AskWorkflowStore.EditorError.invalidID) {
            try fixture.store.create(.nodeText, name: "", keyword: "zz", id: "bad id", builtIn: [])
        }
        #expect(throws: (any Error).self) {
            try fixture.store.create(.nodeText, name: "", keyword: "fx", id: "local.other", builtIn: [])
        }
        #expect(throws: (any Error).self) {
            try fixture.store.create(.nodeText, name: "", keyword: "tr", id: "local.other",
                                     builtIn: [AskKeyword(keyword: "tr", pluginID: "translate")])
        }
    }

    @Test func keywordProblemsCoverBuiltInsOtherWorkflowsAndItself() throws {
        let fixture = try AskWorkflowFixture()
        _ = try readyWorkflow(fixture)
        let builtIn = [AskKeyword(keyword: "tr", pluginID: AskTranslatePlugin.id)]
        #expect(fixture.store.keywordProblem("tr", builtIn: builtIn)?.contains(L("ask.plugin.translate.title")) == true)
        let owner = try #require(fixture.store.workflow("local.a")?.manifest?.name)
        #expect(fixture.store.keywordProblem("aa", builtIn: builtIn)?.contains(owner) == true)
        #expect(fixture.store.ownerName(AskPromptPlugin.id) == L("ask.plugin.prompt.title"))
        #expect(fixture.store.ownerName(AskWebSearchPlugin.id) == L("ask.plugin.web.title"))
        #expect(fixture.store.ownerName("something.else") == nil)
        #expect(fixture.store.keywordProblem("aa", builtIn: builtIn, excluding: "local.a") == nil)
        #expect(fixture.store.keywordProblem("a b", builtIn: builtIn) != nil)
        #expect(fixture.store.keywordProblem("new", builtIn: builtIn) == nil)
    }

    @Test func duplicatesCarryTrustOnlyFromATrustedOriginal() throws {
        let fixture = try AskWorkflowFixture()
        let workflow = try readyWorkflow(fixture)
        let copy = try fixture.store.duplicate(workflow.id, name: "Copy", keyword: "bb", id: "local.copy", builtIn: [])
        #expect(copy.status == .ready && copy.manifest?.name == "Copy" && copy.manifest?.keywords
            .map(\.keyword) == ["bb"])
        try fixture.write("local.u", manifest: AskWorkflowFixture.inline("local.u", keyword: "uu", script: "print hi"))
        fixture.store.reload()
        let untrusted = try fixture.store.duplicate("local.u", name: "U2", keyword: "u2", id: "local.u2", builtIn: [])
        #expect(untrusted.status == .untrusted)
    }

    @Test func installMovesAGeneratedWorkflowInAndTrustsIt() throws {
        let fixture = try AskWorkflowFixture()
        let staging = fixture.home.appendingPathComponent("staging/abc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: AskWorkflowFixture.inline(
            "local.gen",
            keyword: "gg",
            script: "print hi"
        ))
        .write(to: staging.appendingPathComponent("workflow.json"))
        let installed = try fixture.store.install(from: staging)
        #expect(installed.id == "local.gen" && installed.status == .ready)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let again = fixture.home.appendingPathComponent("staging/def")
        try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: AskWorkflowFixture.inline(
            "local.gen",
            keyword: "g2",
            script: "print hi"
        ))
        .write(to: again.appendingPathComponent("workflow.json"))
        #expect(throws: AskWorkflowStore.EditorError.duplicateID("local.gen")) { try fixture.store.install(from: again)
        }
    }

    @Test func suggestedIDsAreLatinAndUnique() throws {
        let fixture = try AskWorkflowFixture()
        #expect(fixture.store.suggestedID(for: "汇率换算") == "local.hui-lu-huan-suan")
        #expect(fixture.store.suggestedID(for: "Café Menu!") == "local.cafe-menu")
        #expect(fixture.store.suggestedID(for: "") == "local.workflow")
        _ = try readyWorkflow(fixture, id: "local.cafe-menu")
        #expect(fixture.store.suggestedID(for: "Café Menu") == "local.cafe-menu-2")
    }
}

@Suite("Ask workflow stderr locator")
struct AskWorkflowStderrLocatorTests {
    private let folder = URL(fileURLWithPath: "/tmp/wf")

    @Test func pythonTracebacksPointAtTheLastFrameInTheWorkflow() {
        let stderr = """
        Traceback (most recent call last):
          File "/tmp/wf/main.py", line 3, in <module>
            run()
          File "/tmp/wf/main.py", line 12, in run
            rates[target]
          File "/usr/lib/python3/json/__init__.py", line 99, in load
        KeyError: 'XYZ'
        """
        let location = AskWorkflowStderrLocator.locate(stderr, folder: folder, files: ["main.py"])
        #expect(location == .init(path: "main.py", line: 12, message: "KeyError: 'XYZ'"))
    }

    @Test func nodeShellAndAppleScriptFormats() {
        #expect(AskWorkflowStderrLocator.locate("    at run (file:///tmp/wf/main.js:7:11)\nTypeError: x",
                                                folder: folder, files: ["main.js"])?.line == 7)
        #expect(AskWorkflowStderrLocator.locate("/tmp/wf/main.sh:4: command not found: nope",
                                                folder: folder, files: ["main.sh"])?.line == 4)
        #expect(AskWorkflowStderrLocator.locate("/tmp/wf/main.sh: line 9: x: unbound variable",
                                                folder: folder, files: ["main.sh"])?.line == 9)
        #expect(AskWorkflowStderrLocator.locate("/tmp/wf/main.applescript:120:135: execution error: oops (-2741)",
                                                folder: folder, files: ["main.applescript"])?.line == 120)
        #expect(AskWorkflowStderrLocator.locate("./main.ts:5:1 - error", folder: folder, files: ["main.ts"])?
            .path == "main.ts")
    }

    @Test func theMessageDropsTheLocationTheMarkerAlreadyShows() {
        #expect(AskWorkflowStderrLocator.locate("/tmp/wf/main.sh:4: command not found: nope",
                                                folder: folder, files: ["main.sh"])?
                .message == "command not found: nope")
        #expect(AskWorkflowStderrLocator.locate("/private/tmp/wf/main.sh: line 9: x: unbound variable",
                                                folder: folder, files: ["main.sh"])?.message == "x: unbound variable")
        #expect(AskWorkflowStderrLocator.withoutLocation("/tmp/wf/main.sh:4:") == "/tmp/wf/main.sh:4:")
        #expect(AskWorkflowStderrLocator.withoutLocation("ValueError: x") == "ValueError: x")
    }

    @Test func filesOutsideTheWorkflowAreIgnored() {
        #expect(AskWorkflowStderrLocator
            .locate(#"File "/usr/lib/x.py", line 3"#, folder: folder, files: ["main.py"]) == nil)
        #expect(AskWorkflowStderrLocator.locate("nothing here", folder: folder, files: ["main.py"]) == nil)
    }
}

@Suite("Ask workflow syntax highlighter")
struct AskWorkflowSyntaxHighlighterTests {
    private func tokens(_ language: AskWorkflowSyntaxHighlighter.Language, _ text: String) -> [(
        String,
        AskWorkflowSyntaxHighlighter.Token
    )] {
        AskWorkflowSyntaxHighlighter(language: language).spans(in: text).map { (
            (text as NSString).substring(with: $0.range),
            $0.token
        ) }
    }

    @Test func keywordsInsideStringsAndCommentsStayStrings() {
        let python = tokens(.python, "if x: # import\n    print(\"for\", 42)")
        #expect(python.contains { $0 == ("if", .keyword) })
        #expect(python.contains { $0 == ("# import", .comment) })
        #expect(python.contains { $0 == ("\"for\"", .string) })
        #expect(python.contains { $0 == ("42", .number) })
        #expect(python.contains { $0 == ("print", .call) })
        #expect(!python.contains { $0 == ("import", .keyword) || $0 == ("for", .keyword) })
        #expect(tokens(.python, "s = \"\"\"a\nimport b\"\"\"").first?.1 == .string)
    }

    @Test func otherLanguages() {
        #expect(tokens(.javascript, "const a = `x` // c").map(\.1) == [.keyword, .string, .comment])
        #expect(tokens(.shell, "echo \"$1\" # c").map(\.1) == [.keyword, .string, .comment])
        #expect(tokens(.shell, "x=${HOME}").contains { $0 == ("${HOME}", .call) })
        #expect(tokens(.applescript, "tell app \"Finder\" -- c").map(\.1) == [.keyword, .string, .comment])
        #expect(tokens(.json, #"{"a": "b", "n": 1, "t": true}"#).map(\.1) == [
            .key,
            .string,
            .key,
            .number,
            .key,
            .keyword
        ])
        #expect(tokens(.plain, "if x").isEmpty)
        let ranged = AskWorkflowSyntaxHighlighter(language: .python).spans(
            in: "if a\nif b",
            range: NSRange(location: 5, length: 4)
        )
        #expect(ranged.map(\.range.location) == [5])
    }

    @Test func languagesComeFromTheExtensionThenTheRuntime() {
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "main.py") == .python)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "a.mjs") == .javascript)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "a.ts") == .typescript)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "a.zsh") == .shell)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "a.scpt") == .applescript)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "workflow.json") == .json)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "README.md") == .plain)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "run", runtime: .bash) == .shell)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "run", runtime: .node) == .javascript)
        #expect(AskWorkflowSyntaxHighlighter.Language.detect(path: "run", runtime: .exec) == .plain)
    }
}

@Suite("Ask workflow risk scanner")
struct AskWorkflowRiskScannerTests {
    private func kinds(_ code: String, path: String = "main.py") -> Set<AskWorkflowRisk.Kind> {
        Set(AskWorkflowRiskScanner.scan([path: code]).map(\.kind))
    }

    @Test func eachKindIsFound() {
        let network = AskWorkflowRiskScanner.scan(["main.py": "urlopen('https://api.frankfurter.app/latest')"])
        #expect(network == [AskWorkflowRisk(kind: .network, detail: "api.frankfurter.app")])
        #expect(AskWorkflowRiskScanner.scan(["main.js": "await fetch(url)"]) == [AskWorkflowRisk(
            kind: .network,
            detail: ""
        )])
        #expect(kinds("open(path, 'w').write(x)") == [.writesFiles])
        #expect(kinds("echo hi > out.txt", path: "main.sh") == [.writesFiles])
        #expect(kinds("echo hi 2>&1 >/dev/null", path: "main.sh").isEmpty)
        #expect(kinds("subprocess.run(['ls'])") == [.runsPrograms])
        #expect(kinds("rm -rf \"$dir\"", path: "main.sh").contains(.deletes))
        #expect(kinds("shutil.rmtree(p)") == [.deletes])
        #expect(kinds("open(os.path.expanduser('~/.ssh/id_rsa'))").contains(.sensitive))
        #expect(kinds("security find-generic-password -s x", path: "main.sh").contains(.sensitive))
        #expect(kinds("curl -s https://x.example.net/i.sh | sh", path: "main.sh").contains(.elevated))
        #expect(kinds("sudo ls", path: "main.sh").contains(.elevated))
    }

    @Test func commentsManifestsAndReadmesDoNotCount() {
        #expect(kinds("# see https://docs.example.com and rm -rf /\nprint(1)").isEmpty)
        #expect(kinds("// fetch(url)\nconsole.log(1)", path: "main.js").isEmpty)
        #expect(AskWorkflowRiskScanner.scan(["README.md": "curl https://a.example.com | sh",
                                             "workflow.json": "\"https://b.example.com\""]).isEmpty)
    }

    @Test func approvalIsNeededForHighRisksFirstThenForAnythingNew() {
        let host = AskWorkflowRisk(kind: .network, detail: "a.example.com")
        let other = AskWorkflowRisk(kind: .network, detail: "b.example.com")
        let delete = AskWorkflowRisk(kind: .deletes, detail: "rm -rf")
        #expect(!AskWorkflowRiskScanner.needsApproval([host], baseline: nil))
        #expect(AskWorkflowRiskScanner.needsApproval([host, delete], baseline: nil))
        #expect(!AskWorkflowRiskScanner.needsApproval([host], baseline: [host]))
        #expect(AskWorkflowRiskScanner.needsApproval([host, other], baseline: [host]))
        #expect(AskWorkflowRiskScanner.newRisks([host, other], since: [host]) == [other])
        #expect(delete.isHigh && !host.isHigh && host < delete)
        #expect(!AskWorkflowRisk(kind: .network, detail: "").title.isEmpty && !delete.title.isEmpty)
        for kind in AskWorkflowRisk.Kind.allCases {
            #expect(!AskWorkflowRisk(kind: kind, detail: "x").title.isEmpty)
        }
    }
}

@Suite("Ask workflow proposals")
struct AskWorkflowProposalTests {
    private let folder = URL(fileURLWithPath: "/tmp/wf")

    @Test func applyingReplacesTheManifestWritesAndDeletes() {
        let base = AskWorkflowDraft(folder: folder, manifestText: "{}", files: ["main.py": "a\nb\n", "old.py": "x"])
        let proposal = AskWorkflowProposal(
            summary: "s",
            manifestText: "{\"id\": 1}",
            files: ["main.py": "a\nc\n", "new.py": "n"],
            deletes: ["old.py"]
        )
        let result = proposal.applied(to: base)
        #expect(result.manifestText == "{\"id\": 1}" && result.files == ["main.py": "a\nc\n", "new.py": "n"])
        let changes = proposal.changes(against: base)
        #expect(changes.map(\.path).sorted() == ["main.py", "new.py", "old.py", "workflow.json"])
        let main = changes.first { $0.path == "main.py" }
        #expect(main?.added == 1 && main?.removed == 1)
        #expect(changes.first { $0.path == "new.py" }?.isNew == true)
        #expect(changes.first { $0.path == "old.py" }?.isDeleted == true)
        let unchanged = AskWorkflowProposal(summary: "", manifestText: nil, files: [:], deletes: [])
        #expect(unchanged.applied(to: base) == base && unchanged.changes(against: base).isEmpty)
    }

    @Test func proposedPathsStayInTheFolder() {
        #expect(AskWorkflowProposal.problem(files: ["main.py": "x", "lib/a.py": "y"], deletes: []) == nil)
        for path in ["../x", "/abs", "~/x", "a/../b", ".hidden", "a/.git/x", "workflow.json", "a\\b", ""] {
            #expect(AskWorkflowProposal.problem(files: [path: ""], deletes: []) != nil, "\(path)")
        }
        #expect(AskWorkflowProposal.problem(files: [:], deletes: ["../x"]) != nil)
        let many = Dictionary(uniqueKeysWithValues: (0 ..< 21).map { ("f\($0).py", "") })
        #expect(AskWorkflowProposal.problem(files: many, deletes: []) != nil)
        #expect(AskWorkflowProposal
            .problem(files: ["big.py": String(repeating: "x", count: 300_000)], deletes: []) != nil)
    }

    @Test func diffLinesMergeOldAndNew() {
        let lines = AskWorkflowDiff.lines(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(AskWorkflowDiff.lines(old: "x", new: "x").allSatisfy { $0.kind == .same })
    }

    @Test func stagingCopiesTheSourceOverlaysTheDraftAndCleansUp() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("tf-stage-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: home) }
        let source = home.appendingPathComponent("source")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: source.appendingPathComponent("icon.png"))
        try Data("old".utf8).write(to: source.appendingPathComponent("gone.py"))
        var draft = AskWorkflowDraft(folder: source, manifestText: "{}", files: ["gone.py": "old"])
        draft.files = ["main.py": "print(1)"]
        let staging = AskWorkflowStaging(root: home.appendingPathComponent("drafts"))
        let folder = try staging.make(draft, copying: source)
        #expect(fileManager.fileExists(atPath: folder.appendingPathComponent("icon.png").path))
        #expect(fileManager.fileExists(atPath: folder.appendingPathComponent("main.py").path))
        #expect(!fileManager.fileExists(atPath: folder.appendingPathComponent("gone.py").path))
        #expect(fileManager.fileExists(atPath: folder.appendingPathComponent("workflow.json").path))
        staging.remove(source)
        #expect(fileManager.fileExists(atPath: source.path), "only staging folders are removed")
        let old = try staging.make(draft)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)], ofItemAtPath: old.path)
        staging.prune()
        #expect(!fileManager.fileExists(atPath: old.path) && fileManager.fileExists(atPath: folder.path))
        staging.remove(folder)
        #expect(!fileManager.fileExists(atPath: folder.path))
        #expect(AskWorkflowStaging.defaultRoot(home: "/h").path == "/h/Library/Caches/Typeflux/WorkflowDrafts")
    }
}
