import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Typeflux

/// A temporary workflows folder with a settings store of its own.
@MainActor
final class AskWorkflowFixture {
    let root: URL
    let home: URL
    let settings: SettingsStore
    let store: AskWorkflowStore
    private let suite = "ask-workflows-\(UUID().uuidString)"

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tf-wf-\(UUID().uuidString)", isDirectory: true)
        root = home.appendingPathComponent("Workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        store = AskWorkflowStore(settings: settings, root: root, home: home.path,
                                 trash: { try FileManager.default.removeItem(at: $0) })
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Writes a workflow folder by hand, as an import or a copy would.
    @discardableResult
    func write(_ id: String, manifest: [String: Any], files: [String: String] = [:], executable: [String] = []) throws -> URL {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("workflow.json"))
        for (name, text) in files {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            if executable.contains(name) { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return folder
    }

    /// A manifest running an inline zsh script.
    static func inline(_ id: String, keyword: String = "wf", script: String, output: String = "text",
                       extra: [String: Any] = [:]) -> [String: Any] {
        var manifest: [String: Any] = ["schema": 1, "id": id, "name": id.capitalized, "keywords": [["keyword": keyword]],
                                       "command": ["runtime": "zsh", "inline": script], "output": output]
        manifest.merge(extra) { $1 }
        return manifest
    }
}

private func request(_ text: String, origin: AskPluginRequest.Origin = .argument, selection: String? = nil,
                     keyword: AskKeyword = AskKeyword(keyword: "wf", pluginID: "workflow.test"),
                     options: [String: String] = [:]) -> AskPluginRequest {
    AskPluginRequest(text: text, origin: origin, keyword: keyword, options: options, interfaceLanguage: .english,
                     selection: selection)
}

@Suite("Ask workflow manifest")
struct AskWorkflowManifestTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-manifest-\(UUID().uuidString)")

    private func manifest(_ json: String) throws -> AskWorkflowManifest {
        try JSONDecoder().decode(AskWorkflowManifest.self, from: Data(json.utf8))
    }

    @Test func aMinimalManifestGetsTheDefaults() throws {
        let manifest = try manifest(#"{"id": "a.b", "name": "A", "command": {"runtime": "python3", "script": "main.py"}}"#)
        #expect(manifest.schema == 1 && manifest.keywords.isEmpty && manifest.output == .auto)
        #expect(manifest.input == .init(argument: .optional, selection: .ifEmpty))
        #expect(manifest.run.mode == .onSubmit && manifest.timeout == 30)
        #expect(manifest.argumentTemplate == ["{query}"])
        let full = try self.manifest(#"""
        {"id": "x", "name": "X", "keywords": [{"keyword": "x", "title": "T", "options": {"a": "1"}}],
         "input": {"argument": "required", "selection": "always"}, "run": {"mode": "onSubmit", "timeoutSeconds": 999},
         "command": {"runtime": "zsh", "inline": "echo", "args": ["{query}", "--sel={selection}"]}, "output": "none",
         "env": {"K": "V"}, "icon": "sf:star", "version": "1", "author": "me", "description": "d"}
        """#)
        #expect(full.timeout == 300, "kept to five minutes")
        #expect(full.keywords.first?.options == ["a": "1"] && full.env == ["K": "V"])
        var short = full
        short.run.timeoutSeconds = 0.1
        #expect(short.timeout == 1)
    }

    @Test func argumentsAreFilledInOnePassAndStayWhole() {
        let template = ["{query}", "--sel={selection}", "{option:mode}-{option:none}", "{unknown}", "{unclosed"]
        let filled = AskWorkflowManifest.arguments(template, query: "a b; $(rm -rf ~) {selection}", selection: "picked",
                                                   options: ["mode": "fast"])
        #expect(filled == ["a b; $(rm -rf ~) {selection}", "--sel=picked", "fast-", "{unknown}", "{unclosed"])
        #expect(AskWorkflowManifest.arguments(["{selection}"], query: "", selection: nil, options: [:]) == [""])
    }

    @Test func problemsNameTheirFields() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("print(1)".utf8).write(to: folder.appendingPathComponent("main.py"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("tool"))
        func check(_ change: (inout AskWorkflowManifest) -> Void) -> [String] {
            var manifest = AskWorkflowManifest(id: "a.b", name: "A", keywords: [.init(keyword: "ab")],
                                               command: .init(runtime: .python3, script: "main.py"))
            change(&manifest)
            return manifest.problems(in: folder).map(\.field)
        }
        #expect(check { _ in }.isEmpty)
        #expect(check { $0.schema = 2 } == ["schema"])
        #expect(check { $0.id = "../x" } == ["id"])
        #expect(check { $0.id = "中文" } == ["id"])
        #expect(check { $0.name = " " } == ["name"])
        #expect(check { $0.keywords = [] } == ["keywords"])
        #expect(check { $0.keywords = [.init(keyword: "ab"), .init(keyword: "AB"), .init(keyword: "a b")] }
            == ["keywords[1]", "keywords[2]"])
        #expect(check { $0.output = .items } == ["output"])
        #expect(check { $0.run.mode = .live } == ["run.mode"])
        #expect(check { $0.command.script = nil } == ["command.script"])
        #expect(check { $0.command.inline = "echo" } == ["command.inline"])
        #expect(check { $0.command.script = nil; $0.command.inline = "echo" } == ["command.inline"])
        #expect(check { $0.command = .init(runtime: .zsh, inline: "echo") }.isEmpty)
        #expect(check { $0.command.script = "../main.py" } == ["command.script"])
        #expect(check { $0.command.script = "/etc/hosts" } == ["command.script"])
        #expect(check { $0.command.script = "missing.py" }.isEmpty == false)
        var missing = AskWorkflowManifest(id: "a", name: "A", keywords: [.init(keyword: "a")],
                                          command: .init(runtime: .python3, script: "src/missing.py"))
        #expect(missing.problems(in: folder).map(\.message) == [L("ask.workflow.problem.scriptMissing", "src/missing.py")])
        // A link inside the folder that points outside it is refused.
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.py"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        missing.command.script = "escape.py"
        #expect(missing.problems(in: folder).map(\.message) == [L("ask.workflow.problem.scriptOutside")])
        #expect(AskWorkflowManifest.scriptURL("a/../../x", in: folder) == nil)
        #expect(check { $0.command = .init(runtime: .exec, script: "tool") } == ["command.script"], "not executable")
        #expect(AskWorkflowManifest.isValidID("com.me.jira_2-x") && !AskWorkflowManifest.isValidID(".hidden"))
        #expect(!AskWorkflowManifest.isValidID(""))
    }
}

@Suite("Ask workflow runtimes")
struct AskWorkflowRuntimeTests {
    private let script = URL(fileURLWithPath: "/w/main.py")

    private func resolver(_ names: Set<String>) -> (String) -> URL? {
        { names.contains($0) ? URL(fileURLWithPath: "/bin/" + $0) : nil }
    }

    @Test func eachRuntimeStartsItsInterpreter() throws {
        let all = resolver(["python3", "node", "zsh", "bash", "osascript", "bun", "deno", "npx", "custom"])
        let python = try AskWorkflowRuntime.python3.launch(script: script, inline: nil, arguments: ["q"], interpreter: nil,
                                                           name: "w", resolve: all)
        #expect(python == .init(executable: URL(fileURLWithPath: "/bin/python3"), arguments: ["/w/main.py", "q"]))
        let venv = try AskWorkflowRuntime.python3.launch(script: script, inline: nil, arguments: [], interpreter: "custom",
                                                         name: "w", resolve: all)
        #expect(venv.executable.path == "/bin/custom")
        let inline = try AskWorkflowRuntime.zsh.launch(script: nil, inline: "echo $1", arguments: ["a b"], interpreter: nil,
                                                       name: "w", resolve: all)
        #expect(inline.arguments == ["-c", "echo $1", "zsh", "a b"])
        let bun = try AskWorkflowRuntime.typescript.launch(script: script, inline: nil, arguments: [], interpreter: nil,
                                                           name: "w", resolve: all)
        #expect(bun.executable.path == "/bin/bun")
        let deno = try AskWorkflowRuntime.typescript.launch(script: script, inline: nil, arguments: [], interpreter: nil,
                                                            name: "w", resolve: resolver(["deno"]))
        #expect(deno.arguments == ["run", "-A", "/w/main.py"])
        let tsx = try AskWorkflowRuntime.typescript.launch(script: script, inline: nil, arguments: [], interpreter: nil,
                                                           name: "w", resolve: resolver(["npx"]))
        #expect(tsx.arguments == ["--yes", "tsx", "/w/main.py"])
        let jxa = try AskWorkflowRuntime.osascript.launch(script: URL(fileURLWithPath: "/w/a.js"), inline: nil, arguments: [],
                                                          interpreter: nil, name: "w", resolve: resolver([]))
        #expect(jxa == .init(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-l", "JavaScript", "/w/a.js"]))
        let program = try AskWorkflowRuntime.exec.launch(script: script, inline: nil, arguments: ["x"], interpreter: "ignored",
                                                         name: "w", resolve: all)
        #expect(program == .init(executable: script, arguments: ["x"]))
        for runtime in AskWorkflowRuntime.allCases { #expect(!runtime.title.isEmpty) }
    }

    @Test func missingProgramsAreNamed() {
        let none: (String) -> URL? = { _ in nil }
        #expect(throws: AskWorkflowRuntime.LaunchError.missing("node")) {
            try AskWorkflowRuntime.node.launch(script: script, inline: nil, arguments: [], interpreter: nil, name: "w", resolve: none)
        }
        #expect(throws: AskWorkflowRuntime.LaunchError.missing("bun")) {
            try AskWorkflowRuntime.typescript.launch(script: script, inline: nil, arguments: [], interpreter: nil, name: "w",
                                                     resolve: none)
        }
        #expect(throws: AskWorkflowRuntime.LaunchError.missing("~/venv/python")) {
            try AskWorkflowRuntime.python3.launch(script: script, inline: nil, arguments: [], interpreter: "~/venv/python",
                                                  name: "w", resolve: none)
        }
        #expect(throws: AskWorkflowRuntime.LaunchError.missing("w")) {
            try AskWorkflowRuntime.exec.launch(script: nil, inline: nil, arguments: [], interpreter: nil, name: "w", resolve: none)
        }
    }

    @Test func thePathGainsTheUsualDirectories() {
        let path = AskWorkflowPath.combine("/usr/bin:/custom", home: "/Users/me")
        #expect(path.hasPrefix("/usr/bin:/custom:"))
        #expect(path.contains("/opt/homebrew/bin") && path.contains("/Users/me/.deno/bin"))
        #expect(path.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count == 1)
        #expect(AskWorkflowPath.resolve("sh", searchPath: "/nowhere:/bin")?.path == "/bin/sh")
    }

    @Test func theLoginShellPathIsReadWithoutHanging() async throws {
        #expect(await AskWorkflowPath.loginShellPath(shell: "/bin/zsh")?.isEmpty == false)
        #expect(await AskWorkflowPath.loginShellPath(shell: "/nonexistent/shell") == nil)
        #expect(await AskWorkflowPath.loginShellPath(shell: "/usr/bin/false") == nil)
        let path = await AskWorkflowPath.searchPath()
        #expect(!path.isEmpty)
        #expect(await AskWorkflowPath.searchPath() == path, "read once")
        // A "shell" that leaves a child holding stdout open still answers within the timeout.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = folder.appendingPathComponent("stuck.sh")
        try Data("#!/bin/sh\nsleep 30 &\nprintf /stuck/bin\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        // The first launch of a new script waits for macOS to scan it; run it once with room for that.
        // Without the runner the background sleep would hold the output open for 30 seconds.
        let direct = AskWorkflowInvocation(launch: .init(executable: shell, arguments: []), environment: [:],
                                           directory: folder, stdin: Data(), timeout: 20)
        for try await event in AskWorkflowRunner().run(direct) {
            if case let .finished(result) = event {
                #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/stuck/bin" && result.duration < 15,
                        "\(result)")
            }
        }
        let started = Date()
        #expect(await AskWorkflowPath.loginShellPath(shell: shell.path) == "/stuck/bin")
        #expect(Date().timeIntervalSince(started) < 3)
        let hung = folder.appendingPathComponent("hung.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: hung)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)
        #expect(await AskWorkflowPath.loginShellPath(shell: hung.path) == nil)
    }
}

@Suite("Ask workflow runner", .serialized)
struct AskWorkflowRunnerTests {
    private func invocation(_ program: String, _ arguments: [String] = [], environment: [String: String] = ["PATH": "/usr/bin:/bin"],
                            stdin: String = "", timeout: Double = 10, stdoutLimit: Int = 1_000_000) -> AskWorkflowInvocation {
        AskWorkflowInvocation(launch: .init(executable: URL(fileURLWithPath: program), arguments: arguments),
                              environment: environment, directory: FileManager.default.temporaryDirectory,
                              stdin: Data(stdin.utf8), timeout: timeout, stdoutLimit: stdoutLimit)
    }

    private func collect(_ invocation: AskWorkflowInvocation, runner: AskWorkflowRunner = AskWorkflowRunner())
        async throws -> (outputs: [String], result: AskWorkflowRunResult?) {
        var outputs: [String] = [], result: AskWorkflowRunResult?
        for try await event in runner.run(invocation) {
            switch event {
            case let .output(text): outputs.append(text)
            case let .finished(finished): result = finished
            }
        }
        return (outputs, result)
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func argumentsArriveWholeAndNothingIsInterpreted() async throws {
        let tricky = ["a b", "\"quoted\"", "$(touch /tmp/tf-injected)", "x; rm -rf ~", "`id`", "中文"]
        let (_, result) = try await collect(invocation("/bin/sh", ["-c", "for a in \"$@\"; do printf '%s\\n' \"$a\"; done", "sh"]
                                                       + tricky))
        #expect(result?.stdout == tricky.joined(separator: "\n") + "\n")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/tf-injected"))
    }

    @Test func theEnvironmentIsExactlyTheOneGiven() async throws {
        setenv("TYPEFLUX_PARENT_SECRET", "leak", 1)
        defer { unsetenv("TYPEFLUX_PARENT_SECRET") }
        let (_, result) = try await collect(invocation("/usr/bin/env", environment: ["ONLY": "this", "PATH": "/bin"]))
        #expect(result?.stdout.split(separator: "\n").sorted() == ["ONLY=this", "PATH=/bin"])
    }

    @Test func stdinReachesTheScriptAndOutputStreamsByLine() async throws {
        let (_, echoed) = try await collect(invocation("/bin/cat", stdin: "{\"query\":\"x\"}\n"))
        #expect(echoed?.stdout == "{\"query\":\"x\"}\n" && echoed?.exitCode == 0)
        let (outputs, result) = try await collect(invocation("/bin/sh", ["-c", "echo one; sleep 0.4; printf two; sleep 0.2; echo"]))
        #expect(outputs.first == "one\n")
        #expect(outputs.last == "one\ntwo\n")
        #expect(result?.stdout == "one\ntwo\n" && (result?.duration ?? 0) >= 0.5)
        // A script that never reads a large stdin does not take the app down.
        let ignored = try await collect(invocation("/usr/bin/true", stdin: String(repeating: "x", count: 2_000_000)))
        #expect(ignored.result?.exitCode == 0)
    }

    @Test func failuresKeepTheirExitCodeAndStderr() async throws {
        let (_, result) = try await collect(invocation("/bin/sh", ["-c", "echo out; echo broke >&2; exit 3"]))
        #expect(result?.exitCode == 3 && result?.stderr == "broke\n" && result?.stdout == "out\n")
        let (_, killed) = try await collect(invocation("/bin/sh", ["-c", "kill -9 $$"]))
        #expect(killed?.exitCode == 137)
        await #expect(throws: AskWorkflowRunError.spawnFailed(ENOENT)) {
            _ = try await collect(invocation("/nonexistent/program"))
        }
    }

    @Test func aTimeoutEndsTheWholeProcessGroup() async throws {
        let runner = AskWorkflowRunner()
        runner.killGrace = 0.3
        let (outputs, result) = try await collect(invocation("/bin/sh", ["-c", "sleep 30 & echo $!; wait"], timeout: 0.6),
                                                  runner: runner)
        #expect(result?.timedOut == true)
        #expect((result?.duration ?? 99) < 5)
        let child = try #require(outputs.first.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isAlive(child), "the background sleep went with its script")
    }

    @Test func leftoversAreEndedWhenTheScriptExits() async throws {
        let (outputs, result) = try await collect(invocation("/bin/sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]))
        #expect(result?.exitCode == 0)
        let child = try #require(outputs.first.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isAlive(child))
    }

    @Test func cancellingStopsTheRun() async throws {
        let runner = AskWorkflowRunner()
        runner.killGrace = 0.3
        var child: pid_t?
        let started = Date()
        for try await event in runner.run(invocation("/bin/sh", ["-c", "sleep 30 & echo $!; wait"])) {
            if case let .output(text) = event { child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)); break }
        }
        let pid = try #require(child)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!isAlive(pid))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func outputPastItsLimitIsCutAndStopped() async throws {
        let (_, result) = try await collect(invocation("/usr/bin/yes", stdoutLimit: 1000))
        #expect(result?.truncated == true && result?.stdout.utf8.count == 1000)
    }
}

@Suite("Ask workflow store", .serialized)
@MainActor
struct AskWorkflowStoreTests {
    @Test func statusFollowsTrustEditsAndSwitches() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("imported", manifest: AskWorkflowFixture.inline("imported", script: "echo hi"))
        fixture.store.reload()
        var workflow = try #require(fixture.store.workflow("imported"))
        #expect(workflow.status == .untrusted && workflow.blockedReason == L("ask.workflow.blocked.untrusted"))
        fixture.store.trust("imported")
        workflow = try #require(fixture.store.workflow("imported"))
        #expect(workflow.status == .ready && workflow.blockedReason == nil)
        // Finder's droppings do not count as a change; a new file does.
        try Data("x".utf8).write(to: workflow.folder.appendingPathComponent(".DS_Store"))
        fixture.store.reload()
        #expect(fixture.store.workflow("imported")?.status == .ready)
        try Data("payload".utf8).write(to: workflow.folder.appendingPathComponent("extra.sh"))
        fixture.store.reload()
        #expect(fixture.store.workflow("imported")?.status == .modified)
        #expect(fixture.store.workflow("imported")?.blockedReason == L("ask.workflow.blocked.modified"))
        fixture.store.trust("imported")
        fixture.store.setEnabled("imported", false)
        #expect(fixture.store.workflow("imported")?.status == .disabled && !fixture.store.isEnabled("imported"))
        #expect(fixture.store.plugins { (nil, nil) }.isEmpty, "a switched-off workflow is not offered")
        fixture.store.setEnabled("imported", true)
        #expect(fixture.store.workflow("imported")?.status == .ready)
        try fixture.store.delete("imported")
        #expect(fixture.store.workflows.isEmpty && fixture.settings.askWorkflowTrust.isEmpty)
        fixture.store.trust("gone")
        try fixture.store.delete("gone")
    }

    @Test func brokenFoldersExplainThemselves() throws {
        let fixture = try AskWorkflowFixture()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let bad = fixture.root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: bad.appendingPathComponent("workflow.json"))
        try fixture.write("nokw", manifest: ["id": "nokw", "name": "N", "command": ["runtime": "zsh", "inline": "true"]])
        try fixture.write("typed", manifest: ["id": "typed", "name": 3, "command": ["runtime": "zsh"]])
        try fixture.write("nocmd", manifest: ["id": "nocmd", "name": "N"])
        try fixture.write("dup1", manifest: AskWorkflowFixture.inline("same", script: "true"))
        try fixture.write("dup2", manifest: AskWorkflowFixture.inline("same", keyword: "other", script: "true"))
        try Data().write(to: fixture.root.appendingPathComponent("stray.txt"))
        fixture.store.reload()
        func problem(_ id: String) -> String? {
            if case let .invalid(problems) = fixture.store.workflows.first(where: { $0.id == id })?.status { problems.first?.message } else { nil }
        }
        #expect(problem("empty") == L("ask.workflow.problem.noManifest"))
        #expect(problem("bad") == L("ask.workflow.problem.json"))
        #expect(problem("nokw") == L("ask.workflow.problem.noKeywords"))
        #expect(problem("typed") == L("ask.workflow.problem.wrongValue", "name"))
        #expect(problem("nocmd") == L("ask.workflow.problem.missingField", "command"))
        #expect(fixture.store.workflows.filter { $0.id == "same" }.count == 2)
        let duplicates = fixture.store.workflows.filter { $0.id == "same" }.map(\.status)
        #expect(duplicates.contains(.invalid([.init(field: "id", message: L("ask.workflow.problem.duplicateID"))])))
        #expect(fixture.store.workflows.count == 7, "files beside the folders are ignored")
        let symbols = Set(fixture.store.workflows.map(\.symbol))
        #expect(symbols.contains("terminal"))
    }

    @Test func templatesAreTrustedAndKeepTheirKeywordsApart() async throws {
        let fixture = try AskWorkflowFixture()
        let taken = [AskKeyword(keyword: "wf", pluginID: "translate")]
        let first = try fixture.store.create(.shellText, takenKeywords: taken)
        #expect(first.status == .ready && first.manifest?.keywords.first?.keyword == "wf2")
        let second = try fixture.store.create(.shellText, takenKeywords: taken)
        #expect(second.id == "local.shell-2" && second.manifest?.keywords.first?.keyword == "wf3")
        for template in AskWorkflowTemplate.allCases where template != .shellText {
            let made = try fixture.store.create(template, takenKeywords: [])
            #expect(made.status == .ready, "\(template)")
            #expect(made.manifest?.command.runtime == template.runtime && !template.title.isEmpty)
            let script = try #require(made.manifest?.command.script)
            #expect(FileManager.default.isExecutableFile(atPath: made.folder.appendingPathComponent(script).path))
        }
        #expect(fixture.store.workflow("local.action")?.manifest?.output == AskWorkflowManifest.Output.none)
        // The launcher's view of them: plugins, keywords, clashes.
        let plugins = fixture.store.plugins { (nil, nil) }
        #expect(plugins.count == 5)
        let (keywords, conflicts) = AskWorkflowStore.keywords(of: plugins, excluding: [AskKeyword(keyword: "act", pluginID: "x")])
        #expect(conflicts.map(\.keyword) == ["act"])
        #expect(keywords.map(\.keyword).sorted() == ["wf", "wf2", "wf3", "wf4"])
        await fixture.store.refresh()
        #expect(fixture.store.workflows.count == 5)
        // An empty or missing root is fine.
        try FileManager.default.removeItem(at: fixture.root)
        fixture.store.reload()
        #expect(fixture.store.workflows.isEmpty)
    }

    @Test func theLogKeepsTheLastRuns() {
        let log = AskWorkflowLog()
        for index in 0 ..< 25 {
            log.add(.init(workflowID: "a", keyword: "k", date: Date(), duration: Double(index), exitCode: 0, timedOut: false,
                          stderr: ""))
        }
        #expect(log.entries["a"]?.count == AskWorkflowLog.limit && log.last(for: "a")?.duration == 24)
        log.clear("a")
        #expect(log.last(for: "a") == nil)
    }
}

@Suite("Ask workflow plugin", .serialized)
@MainActor
struct AskWorkflowPluginTests {
    private func plugin(_ fixture: AskWorkflowFixture, _ id: String) throws -> AskWorkflowPlugin {
        fixture.store.reload()
        fixture.store.trust(id)
        var plugin = try #require(fixture.store.plugins { ("Notes", "com.apple.Notes") }.first { $0.workflow.id == id })
        plugin.searchPath = { "/usr/bin:/bin" }
        return plugin
    }

    /// Runs a request; failures are compared without the editor actions they carry
    /// (those are covered in `AskWorkflowLauncherActionTests`).
    private func run(_ plugin: AskWorkflowPlugin, _ request: AskPluginRequest) async throws -> AskPluginOutput {
        do {
            return try await plugin.run(request, plan: await plugin.plan(request))
        } catch var failure as AskPluginFailure {
            #expect(failure.action(for: .commandE) != nil)
            failure.actions = []
            throw failure
        }
    }

    @Test func textOutputBecomesACardWithTheSharedActions() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("rev", manifest: AskWorkflowFixture.inline("rev", script: "print -r -- \"$1\" | rev",
                                                                     extra: ["keywords": [["keyword": "rv", "title": "Reverse"]]]))
        let plugin = try plugin(fixture, "rev")
        #expect(plugin.id == "workflow.rev" && plugin.title == "Rev" && plugin.runsWithoutInput)
        #expect(plugin.defaultKeywords == [AskKeyword(keyword: "rv", pluginID: "workflow.rev", options: ["title": "Reverse"])])
        #expect(plugin.chipDetail(for: plugin.defaultKeywords[0], language: .english) == "Reverse")
        let typed = request("hello")
        let plan = await plugin.plan(typed)
        // Other suites switch the interface language while this one awaits: check the parts, not the sentence.
        #expect(plan.mode == .onSubmit && plan.title.contains("Rev") && plan.title.contains("hello"))
        #expect(plan.meta.map(\.text) == ["zsh"])
        let recorder = AskProgressRecorder()
        let output = try await plugin.run(typed, plan: plan, progress: recorder.progress)
        #expect(output.body == "olleh" && recorder.bodies == ["olleh\n"])
        #expect(output.action(for: .enter)?.kind == .copy("olleh"))
        #expect(output.action(for: .optionEnter)?.title == L("ask.plugin.action.insert"))
        #expect(output.action(for: .commandR)?.kind == .rerun([:]) && !output.dismisses)
        #expect(output.source.hasPrefix("zsh · "))
        let selected = try await run(plugin, request("Picked", origin: .selection, selection: "Picked"))
        #expect(selected.body == "" || selected.dismisses, "the query is empty when only the selection is there")
    }

    @Test func theSelectionFollowsTheManifest() async throws {
        let fixture = try AskWorkflowFixture()
        let echoSelection = "print -r -- \"q=$1 s=$TYPEFLUX_SELECTION\""
        try fixture.write("ifempty", manifest: AskWorkflowFixture.inline("ifempty", keyword: "a", script: echoSelection,
                                                                         extra: ["command": ["runtime": "zsh", "inline": echoSelection,
                                                                                             "args": ["{query}"]]]))
        try fixture.write("never", manifest: AskWorkflowFixture.inline("never", keyword: "b", script: echoSelection,
                                                                       extra: ["input": ["selection": "never"]]))
        try fixture.write("always", manifest: AskWorkflowFixture.inline("always", keyword: "c", script: echoSelection,
                                                                        extra: ["input": ["selection": "always"]]))
        let ifEmpty = try plugin(fixture, "ifempty"), never = try plugin(fixture, "never"), always = try plugin(fixture, "always")
        #expect(try await run(ifEmpty, request("Sel", origin: .selection, selection: "Sel")).body == "q= s=Sel")
        #expect(try await run(ifEmpty, request("typed", selection: "Sel")).body == "q=typed s=")
        #expect(try await run(never, request("Sel", origin: .selection, selection: "Sel")).body == "q= s=")
        #expect(try await run(always, request("typed", selection: "Sel")).body == "q=typed s=Sel")
        let plan = await ifEmpty.plan(request("a\nb", origin: .selection, selection: "a\nb"))
        #expect(plan.title == L("ask.workflow.plan.selection", "Ifempty", 2))
        #expect(await ifEmpty.plan(request("")).title == L("ask.workflow.plan.run", "Ifempty"))
        #expect(ifEmpty.placeholder(selectionLines: 3) == L("ask.workflow.placeholder.selection", 3))
        #expect(never.placeholder(selectionLines: 3) == L("ask.workflow.placeholder"))
    }

    @Test func failuresTimeoutsAndBlocksAreExplained() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("fail", manifest: AskWorkflowFixture.inline("fail", keyword: "f", script: "echo boom >&2; exit 3"))
        try fixture.write("said", manifest: AskWorkflowFixture.inline("said", keyword: "s",
                                                                      script: "echo '{\"error\": \"Token expired\"}'; exit 1"))
        try fixture.write("slow", manifest: AskWorkflowFixture.inline("slow", keyword: "w", script: "sleep 5",
                                                                      extra: ["run": ["timeoutSeconds": 1]]))
        try fixture.write("need", manifest: AskWorkflowFixture.inline("need", keyword: "n", script: "true",
                                                                      extra: ["input": ["argument": "required"]]))
        try fixture.write("nopython", manifest: ["id": "nopython", "name": "P", "keywords": [["keyword": "p"]],
                                                 "command": ["runtime": "python3", "script": "main.py", "interpreter": "nonexistent-py"]],
                          files: ["main.py": "print(1)"])
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.failed", 3) + "\nboom")) {
            try await run(try plugin(fixture, "fail"), request("x"))
        }
        await #expect(throws: AskPluginFailure(message: "Token expired")) { try await run(try plugin(fixture, "said"), request("x")) }
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.timedOut", 1))) {
            try await run(try plugin(fixture, "slow"), request("x"))
        }
        let need = try plugin(fixture, "need")
        #expect(!need.runsWithoutInput)
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.needsInput"), retry: false)) { try await run(need, request("")) }
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.missingRuntime", "nonexistent-py"), retry: false)) {
            try await run(try plugin(fixture, "nopython"), request("x"))
        }
        // Not trusted: nothing runs.
        try fixture.write("new", manifest: AskWorkflowFixture.inline("new", keyword: "z", script: "touch ran"))
        fixture.store.reload()
        let untrusted = try #require(fixture.store.plugins { (nil, nil) }.first { $0.workflow.id == "new" })
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.blocked.untrusted"), retry: false)) {
            try await run(untrusted, request("x"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new/ran").path))
        // Trusted when the launcher opened, changed before Return: nothing runs either.
        let trusted = try plugin(fixture, "new")
        try Data("touch ran2".utf8).write(to: fixture.root.appendingPathComponent("new/extra.sh"))
        await #expect(throws: AskPluginFailure(message: L("ask.workflow.blocked.modified"), retry: false)) {
            try await run(trusted, request("x"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new/ran").path))
        #expect(AskWorkflowPlugin.tail("a\n\nb\nc", lines: 2) == "\nb\nc" && AskWorkflowPlugin.tail("") == "")
        #expect(AskWorkflowPlugin.errorMessage(in: "x\n{\"error\": \"\"}") == nil)
        #expect(AskWorkflowPlugin.errorMessage(in: "") == nil)
    }

    @Test func actionsWithoutOutputCloseTheLauncherAndRunsAreLogged() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("act", manifest: AskWorkflowFixture.inline("act", keyword: "a", script: "echo ignored", output: "none"))
        try fixture.write("quiet", manifest: AskWorkflowFixture.inline("quiet", keyword: "q", script: "true"))
        try fixture.write("big", manifest: AskWorkflowFixture.inline("big", keyword: "b", script: "yes | head -c 2000000"))
        let recorder = AskProgressRecorder()
        let act = try plugin(fixture, "act")
        let done = try await act.run(request("x"), plan: await act.plan(request("x")), progress: recorder.progress)
        #expect(done.dismisses && recorder.bodies.isEmpty, "nothing is shown for a workflow that only acts")
        #expect(try await run(try plugin(fixture, "quiet"), request("x")).dismisses)
        let big = try await run(try plugin(fixture, "big"), request("x"))
        #expect(big.note == L("ask.workflow.truncated") && big.body.utf8.count <= 1_000_000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(AskWorkflowLog.shared.last(for: "act")?.exitCode == 0)
    }

    @Test func theScriptGetsACleanEnvironmentAndTheRequest() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("env", manifest: AskWorkflowFixture.inline(
            "env", keyword: "e", script: "env | sort; cat",
            extra: ["env": ["SERVICE_URL": "https://x", "PATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                            "TYPEFLUX_QUERY": "spoof", "bad name": "x"]]))
        setenv("TYPEFLUX_PARENT_SECRET", "leak", 1)
        defer { unsetenv("TYPEFLUX_PARENT_SECRET") }
        let plugin = try plugin(fixture, "env")
        let output = try await run(plugin, request("hi there", keyword: AskKeyword(keyword: "e", pluginID: "workflow.env"),
                                                   options: ["mode": "fast", "title": "T", "my-opt": "1"]))
        let lines = output.body.split(separator: "\n").map(String.init)
        #expect(lines.contains("TYPEFLUX_QUERY=hi there"))
        #expect(lines.contains("TYPEFLUX_KEYWORD=e") && lines.contains("TYPEFLUX_LANGUAGE=en"))
        #expect(lines.contains("TYPEFLUX_OPTION_MODE=fast") && lines.contains("TYPEFLUX_OPTION_MY_OPT=1"))
        #expect(!lines.contains { $0.hasPrefix("TYPEFLUX_OPTION_TITLE") })
        #expect(lines.contains("TYPEFLUX_SOURCE_APP=Notes") && lines.contains("TYPEFLUX_SOURCE_BUNDLE_ID=com.apple.Notes"))
        #expect(lines.contains("SERVICE_URL=https://x") && lines.contains("PATH=/usr/bin:/bin"))
        #expect(!lines.contains { $0.hasPrefix("DYLD_") || $0.contains("leak") || $0.hasPrefix("bad name") })
        #expect(lines.contains { $0.hasPrefix("TYPEFLUX_WORKFLOW_DIR=/") && $0.hasSuffix("/Workflows/env") })
        let json = try #require(lines.last { $0.hasPrefix("{") })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["query"] as? String == "hi there" && object["typeflux"] as? Int == 1)
        #expect(object["selection"] is NSNull && (object["options"] as? [String: String])?["title"] == nil)
        #expect((object["source"] as? [String: Any])?["app"] as? String == "Notes")
        #expect(AskWorkflowPlugin.variableName("a-b.c") == "A_B_C")
        #expect(!AskWorkflowPlugin.isAllowedVariable("HOME") && AskWorkflowPlugin.isAllowedVariable("API_URL"))
    }
}

@Suite("Ask workflow settings")
@MainActor
struct AskWorkflowSettingsTests {
    @Test func summariesSayWhatStateAWorkflowIsIn() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("one", manifest: AskWorkflowFixture.inline("one", keyword: "fy", script: "echo",
                                                                     extra: ["description": "Says hi"]))
        try fixture.write("broken", manifest: ["id": "broken", "name": "B", "keywords": [["keyword": "b"]],
                                               "command": ["runtime": "python3", "script": "gone.py"]])
        fixture.store.reload()
        let one = try #require(fixture.store.workflow("one"))
        var summary = AskWorkflowSummary(one)
        #expect(summary.status == L("ask.workflow.status.untrusted") && summary.needsTrust && summary.level == .attention)
        #expect(summary.subtitle == "Says hi" && summary.keywords == ["fy"] && summary.runtime == "zsh")
        let conflicts = AskWorkflowStore.keywords(of: fixture.store.plugins { (nil, nil) }, excluding: AskTranslatePlugin.keywords)
            .conflicts
        summary = AskWorkflowSummary(one, conflicts: conflicts,
                                     lastRun: .init(workflowID: "one", keyword: "fy", date: Date(), duration: 1.25, exitCode: 2,
                                                    timedOut: false, stderr: ""))
        #expect(summary.subtitle.contains(L("ask.workflow.conflicts", "fy")))
        #expect(summary.subtitle.contains(L("ask.workflow.lastRun", 2, 1.25)))
        let timedOut = AskWorkflowSummary(one, lastRun: .init(workflowID: "one", keyword: "fy", date: Date(), duration: 30,
                                                              exitCode: 143, timedOut: true, stderr: ""))
        #expect(timedOut.subtitle.contains(L("ask.workflow.lastRun.timedOut", 30.0)))
        let broken = AskWorkflowSummary(try #require(fixture.store.workflow("broken")))
        #expect(broken.status == L("ask.workflow.status.invalid") && broken.subtitle.hasPrefix("command.script: "))
        fixture.store.trust("one")
        #expect(AskWorkflowSummary(try #require(fixture.store.workflow("one"))).level == .ready)
        fixture.store.setEnabled("one", false)
        #expect(AskWorkflowSummary(try #require(fixture.store.workflow("one"))).level == .off)
        try Data("x".utf8).write(to: one.folder.appendingPathComponent("new"))
        fixture.store.setEnabled("one", true)
        #expect(AskWorkflowSummary(try #require(fixture.store.workflow("one"))).status == L("ask.workflow.status.modified"))
    }

    @Test func theTrustSheetShowsTheCommandFilesAndCode() throws {
        let fixture = try AskWorkflowFixture()
        let script = (1 ... 60).map { "line \($0)" }.joined(separator: "\n")
        try fixture.write("py", manifest: ["id": "py", "name": "Py", "keywords": [["keyword": "py"], ["keyword": "p2"]],
                                           "input": ["selection": "never"], "run": ["timeoutSeconds": 20],
                                           "command": ["runtime": "python3", "script": "main.py"]],
                          files: ["main.py": script])
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("py/lib"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("py/lib/util.py"))
        try fixture.write("sh", manifest: AskWorkflowFixture.inline("sh", script: "echo inline", extra: ["input": ["selection": "always"]]))
        fixture.store.reload()
        let py = AskWorkflowTrustSummary(try #require(fixture.store.workflow("py")))
        #expect(py.keywords == ["py", "p2"])
        #expect(py.command == "python3 main.py {query} · " + L("ask.workflow.trust.timeout", 20))
        #expect(py.selection == L("ask.workflow.trust.selection.never"))
        #expect(py.files == ["lib/util.py", "main.py", "workflow.json"])
        #expect(py.preview.split(separator: "\n").count == AskWorkflowTrustSummary.previewLines)
        let sh = AskWorkflowTrustSummary(try #require(fixture.store.workflow("sh")))
        #expect(sh.preview == "echo inline" && sh.command.hasPrefix("zsh " + L("ask.workflow.trust.inline")))
        #expect(sh.selection == L("ask.workflow.trust.selection.always"))
        try fixture.write("ifempty", manifest: AskWorkflowFixture.inline("ifempty", keyword: "ie", script: "echo"))
        fixture.store.reload()
        #expect(AskWorkflowTrustSummary(try #require(fixture.store.workflow("ifempty"))).selection
            == L("ask.workflow.trust.selection.ifEmpty"))
        let empty = fixture.root.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        fixture.store.reload()
        let none = AskWorkflowTrustSummary(try #require(fixture.store.workflow("nothing")))
        #expect(none.command.isEmpty && none.keywords.isEmpty && none.preview.isEmpty)
    }
}

/// Draws the settings list and the trust sheet; writes PNGs when TYPEFLUX_ASK_SNAPSHOTS is set.
@Suite("Ask workflow settings rendering", .serialized)
@MainActor
struct AskWorkflowRenderTests {
    private func render<V: View>(_ view: V, size: NSSize, name: String) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(white: 0.12)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test func settingsListAndTrustSheet() async throws {
        _ = NSApplication.shared
        // Screenshots are in Chinese; plain runs keep the language, which other suites read while they wait.
        let previous = AppLocalization.shared.language
        let snapshots = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil
        if snapshots { AppLocalization.shared.setLanguage(.simplifiedChinese) }
        defer { if snapshots { AppLocalization.shared.setLanguage(previous) } }
        let fixture = try AskWorkflowFixture()
        try fixture.write("com.me.jira", manifest: ["id": "com.me.jira", "name": "Jira", "description": "搜索 Jira 问题",
                                                    "icon": "sf:ticket", "keywords": [["keyword": "jira"], ["keyword": "jm"]],
                                                    "command": ["runtime": "python3", "script": "main.py"]],
                          files: ["main.py": "import json, os, sys\n\nquery = sys.argv[1] if len(sys.argv) > 1 else \"\"\nprint(query)\n"])
        try fixture.write("md", manifest: AskWorkflowFixture.inline("md", keyword: "md", script: "pandoc -f markdown -t html",
                                                                    extra: ["name": "Markdown 转 HTML", "description": "pandoc · 用选中的文字"]))
        try fixture.write("broken", manifest: ["id": "broken", "name": "打开项目", "keywords": [["keyword": "code"]],
                                               "command": ["runtime": "typescript", "script": "main.ts"]])
        fixture.store.reload()
        fixture.store.trust("md")
        fixture.store.trust("com.me.jira")
        try Data("# changed".utf8).write(to: fixture.root.appendingPathComponent("com.me.jira/notes.md"))
        fixture.store.reload()
        let log = AskWorkflowLog()
        log.add(.init(workflowID: "md", keyword: "md", date: Date(), duration: 0.4, exitCode: 0, timedOut: false, stderr: ""))
        try await render(AskWorkflowSettingsView(store: fixture.store, log: log, settings: fixture.settings),
                         size: NSSize(width: 760, height: 420), name: "workflow-settings.png")
        let jira = try #require(fixture.store.workflow("com.me.jira"))
        try await render(AskWorkflowTrustSheet(workflow: jira, summary: AskWorkflowTrustSummary(jira),
                                               onTrust: {}, onReveal: {}, onCancel: {}),
                         size: NSSize(width: 600, height: 520), name: "workflow-trust.png")
    }
}
