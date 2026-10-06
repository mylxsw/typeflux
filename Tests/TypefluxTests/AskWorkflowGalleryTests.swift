import Foundation
import Testing
@testable import Typeflux

/// A gallery folder of its own: one example, `ex`, whose version and files a test can change.
private final class GalleryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tf-gallery-\(UUID().uuidString)")

    func write(version: String, script: String = "print('first')", extra: [String: String] = [:],
               keywords: [[String: Any]] = [["keyword": "ex", "title": "@L:fx.keyword.fx"]]) throws
        -> AskWorkflowGallery {
        let folder = root.appendingPathComponent("ex", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index: [String: Any] = ["schema": 1, "items": [[
            "id": "ex", "category": "text", "order": 1,
            "usage": [["example": "ex 1", "text": "fx.usage.1"]],
            "preview": ["keyword": "ex", "query": "1", "output": "one"]
        ]]]
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("gallery.json"))
        let keywordsJSON = try String(bytes: JSONSerialization.data(withJSONObject: keywords), encoding: .utf8) ?? "[]"
        let manifest = """
        {
          "schema": 1,
          "id": "local.ex",
          "name": "@L:fx.name",
          "version": "\(version)",
          "keywords": \(keywordsJSON),
          "command": { "runtime": "python3", "script": "main.py" },
          "output": "text"
        }
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("workflow.json"))
        try Data(script.utf8).write(to: folder.appendingPathComponent("main.py"))
        for (path, text) in extra {
            try Data(text.utf8).write(to: folder.appendingPathComponent(path))
        }
        return AskWorkflowGallery.load(root: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("Ask workflow gallery index")
struct AskWorkflowGalleryIndexTests {
    @Test func `the bundled examples are valid and keep their keywords apart`() throws {
        let gallery = AskWorkflowGallery.bundled
        #expect(gallery.items.map(\.id) == ["fx", "ts", "json", "codec", "uuid", "wc"])
        var keywords = Set<String>()
        for item in gallery.items {
            #expect(
                item.manifest.problems(in: item.folder).isEmpty,
                "\(item.id): \(item.manifest.problems(in: item.folder))"
            )
            #expect(!item.name.hasPrefix(AskWorkflowGallery.localizedPrefix) && !item.summary.isEmpty)
            #expect(!item.demonstrates.isEmpty && item.preview != nil && !item.usage.isEmpty)
            #expect(item.manifest.keywords.allSatisfy { !($0.title ?? "").hasPrefix("@L:") })
            #expect(item.files()["README.md"] != nil, "\(item.id) explains itself")
            #expect(item.entryScript.flatMap { item.files()[$0] } != nil)
            for keyword in item.keywords {
                #expect(AskKeywordMatcher.problem(with: keyword, among: []) == nil, "\(keyword) is a valid keyword")
                #expect(keywords.insert(keyword.lowercased()).inserted, "\(keyword) is used once in the gallery")
            }
            // Every file a manifest names is shipped, and only the bundled text is localized.
            let rendered = AskWorkflowGallery.render(item, id: "local.x", keywords: item.keywords)
            let manifest = try JSONDecoder().decode(AskWorkflowManifest.self,
                                                    from: #require(rendered[AskWorkflowManifest.fileName]))
            #expect(manifest.id == "local.x" && manifest.origin == .init(gallery: item.id, version: item.version))
            let text = try String(bytes: #require(rendered[AskWorkflowManifest.fileName]), encoding: .utf8)
            #expect(text?.contains("@L:") == false)
        }
        #expect(gallery.item("fx")?.hosts == ["open.er-api.com"])
        #expect(gallery.item("fx")?.manifest.keywords[1].script == "table.py")
        #expect(gallery.items.filter { !$0.hosts.isEmpty }.map(\.id) == ["fx"])
    }

    @Test func `categories and search narrow the cards`() {
        let gallery = AskWorkflowGallery.bundled
        #expect(gallery.categoryCounts.map(\.category) == [.text, .dev, .network])
        #expect(gallery.categoryCounts.map(\.count) == [1, 4, 1])
        #expect(gallery.filtered(category: .dev, query: "").map(\.id) == ["ts", "json", "codec", "uuid"])
        #expect(gallery.filtered(category: nil, query: "B64").map(\.id) == ["codec"])
        #expect(gallery.filtered(category: .text, query: "json").isEmpty)
        #expect(gallery.item("nope") == nil)
        #expect(!AskWorkflowGallery.Category.dev.title.hasPrefix("ask."))
    }

    @Test func `versions hosts and broken galleries`() throws {
        #expect(AskWorkflowGallery.isOlder("1.0.0", than: "1.0.1") && AskWorkflowGallery.isOlder("1.2", than: "1.10"))
        #expect(!AskWorkflowGallery.isOlder("1.0", than: "1.0.0") && !AskWorkflowGallery.isOlder("2.0", than: "1.9.9"))
        #expect(AskWorkflowGallery.hosts(in: "a https://API.x.com/v1 and http://b.org, https://api.x.com/again")
            == ["api.x.com", "b.org"])
        #expect(AskWorkflowGallery.load(root: nil).items.isEmpty)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("tf-none-\(UUID().uuidString)")
        #expect(AskWorkflowGallery.load(root: missing).items.isEmpty)
        // An index entry whose folder is gone is left out.
        let fixture = GalleryFixture()
        _ = try fixture.write(version: "1.0.0")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ex"))
        #expect(AskWorkflowGallery.load(root: fixture.root).items.isEmpty)
        #expect(AskWorkflowGallery.localizedManifest("not json") == nil)
    }
}

@Suite("Ask workflow gallery store", .serialized)
@MainActor
struct AskWorkflowGalleryStoreTests {
    @Test func `adding copies trusts and renames what clashes`() throws {
        let fixture = try AskWorkflowFixture()
        let exchange = try #require(AskWorkflowGallery.bundled.item("fx"))
        #expect(fixture.store.installed(exchange) == nil && !fixture.store.hasUpdate(exchange))
        let first = try fixture.store.add(exchange, builtIn: [])
        #expect(first.workflow.id == "local.fx" && first.renamed.isEmpty)
        #expect(first.workflow.status == .ready, "added examples are trusted")
        let manifest = try #require(first.workflow.manifest)
        #expect(manifest.origin == .init(gallery: "fx", version: "1.0.0"))
        #expect(manifest.name == exchange.name && manifest.keywords.map(\.keyword) == ["fx", "rate"])
        #expect(manifest.keywords[1].script == "table.py" && manifest.output.onSuccess.count == 2)
        #expect(fixture.store.installed(exchange)?.id == "local.fx" && !fixture.store.hasUpdate(exchange))
        let folder = first.workflow.folder
        for script in ["main.py", "table.py"] {
            #expect(FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent(script).path))
        }
        #expect(!FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("rates.py").path))
        #expect(fixture.settings.askWorkflowGalleryBaseline["local.fx"]?.keys.sorted()
            == ["README.md", "main.py", "rates.py", "table.py", "workflow.json"])

        // Again: a new id, and both keywords are taken by the first copy.
        let second = try fixture.store.add(exchange, builtIn: [])
        #expect(second.workflow.id == "local.fx-2" && second.renamed == ["fx": "fx2", "rate": "rate2"])
        #expect(second.workflow.status == .ready)

        // A built-in keyword is avoided too.
        let timestamps = try #require(AskWorkflowGallery.bundled.item("ts"))
        let translate = AskKeyword(keyword: "ts", pluginID: AskTranslatePlugin.id)
        let third = try fixture.store.add(timestamps, builtIn: [translate])
        let note = AskWorkflowGallerySheet.addedNote(timestamps, third)
        #expect(note.contains("ts → ts2") && note.contains(timestamps.name))
        #expect(AskWorkflowGallerySheet.addedNote(exchange, first).contains(exchange.name))
        #expect(AskWorkflowGallerySheet.missingRuntimes([.python3, .node, .exec], searchPath: "/nonexistent")
            == [.python3, .node])
        #expect(AskWorkflowGallerySheet.missingRuntimes([.zsh, .exec], searchPath: "/bin:/usr/bin").isEmpty)
        #expect(third.renamed == ["ts": "ts2"] && third.workflow.manifest?.keywords.first?.keyword == "ts2")

        // A duplicate is the user's own: it is not the added example.
        let copy = try fixture.store.duplicate("local.fx", name: "Mine", keyword: "mine", id: "local.mine", builtIn: [])
        #expect(copy.manifest?.origin == nil && fixture.store.installed(exchange)?.id == "local.fx")
        try fixture.store.delete("local.mine")

        // Deleting forgets the baseline; the gallery offers it again.
        try fixture.store.delete("local.fx")
        try fixture.store.delete("local.fx-2")
        #expect(fixture.settings.askWorkflowGalleryBaseline["local.fx"] == nil)
        #expect(fixture.store.installed(exchange) == nil)
    }

    @Test func `a taken ID gets A suffix`() throws {
        let fixture = try AskWorkflowFixture()
        let gallery = GalleryFixture()
        let item = try #require(try gallery.write(version: "1.0.0").item("ex"))
        // Something else already sits at `local.ex`.
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("local.ex"))
        let added = try fixture.store.add(item, builtIn: [])
        #expect(added.workflow.id == "local.ex-2" && added.workflow.status == .ready)
    }

    @Test func `updates show the differences and overwrite only when asked`() throws {
        let fixture = try AskWorkflowFixture()
        let gallery = GalleryFixture()
        let first = try #require(try gallery.write(version: "1.0.0", extra: ["old.py": "x = 1\n"]).item("ex"))
        let added = try fixture.store.add(first, builtIn: [])
        let id = added.workflow.id
        #expect(fixture.store.galleryUpdate(first)?.current.text(of: "main.py") == "print('first')")
        // The user renames the keyword, changes the script and adds a file of their own.
        let folder = added.workflow.folder
        var draft = AskWorkflowDraft.load(folder: folder)
        draft.set([["keyword": "mine", "title": "Mine"]], at: ["keywords"])
        draft.setText("print('mine')", of: "main.py")
        draft.setText("notes", of: "notes.txt")
        _ = try fixture.store.save(id, folder: folder, writes: draft.pendingWrites, expectedHash: added.workflow.hash)
        #expect(fixture.store.workflow(id)?.status == .ready)

        let second = try #require(try gallery.write(version: "1.1.0", script: "print('second')").item("ex"))
        #expect(fixture.store.hasUpdate(second) && !fixture.store.hasUpdate(first))
        let update = try #require(fixture.store.galleryUpdate(second))
        #expect(update.workflowID == id)
        #expect(update.userModified == ["main.py", "workflow.json"])
        #expect(update.current.text(of: "main.py") == "print('mine')" && update.updated
            .text(of: "main.py") == "print('second')")
        #expect(update.updated.files["old.py"] == nil && update.updated.files["notes.txt"] == "notes")
        let updatedManifest = try #require(update.updated.manifest)
        #expect(updatedManifest.keywords.map(\.keyword) == ["mine"], "the user's keyword carries over")
        #expect(updatedManifest.origin?.version == "1.1.0" && updatedManifest.id == id)
        // Looking changed nothing.
        #expect(try String(contentsOf: folder.appendingPathComponent("main.py"), encoding: .utf8) == "print('mine')")

        let workflow = try #require(try fixture.store.applyUpdate(second))
        #expect(workflow.status == .ready && workflow.manifest?.origin?.version == "1.1.0")
        #expect(try String(contentsOf: folder.appendingPathComponent("main.py"), encoding: .utf8) == "print('second')")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("old.py").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        #expect(!fixture.store.hasUpdate(second) && fixture.store.galleryUpdate(second)?.userModified == [])

        // Renaming the workflow keeps it tied to its baseline.
        var renamed = AskWorkflowDraft.load(folder: folder)
        renamed.set("local.renamed", at: ["id"])
        _ = try fixture.store.save(id, folder: folder, writes: renamed.pendingWrites, expectedHash: workflow.hash)
        #expect(fixture.settings.askWorkflowGalleryBaseline[id] == nil)
        #expect(fixture.settings.askWorkflowGalleryBaseline["local.renamed"] != nil)
    }

    @Test func `a changed keyword count falls back to the examples keywords`() throws {
        let fixture = try AskWorkflowFixture()
        let gallery = GalleryFixture()
        let first = try #require(try gallery.write(version: "1").item("ex"))
        try fixture.store.add(first, builtIn: [])
        let second = try #require(try gallery.write(version: "2", keywords: [["keyword": "ex"], ["keyword": "ey"]])
            .item("ex"))
        #expect(fixture.store.galleryUpdate(second)?.updated.manifest?.keywords.map(\.keyword) == ["ex", "ey"])
        #expect(try fixture.store.galleryUpdate(#require(AskWorkflowGallery.bundled.item("wc"))) == nil)
        #expect(try fixture.store.applyUpdate(#require(AskWorkflowGallery.bundled.item("wc"))) == nil)
    }
}

/// Runs each example the way the launcher would. Examples whose runtime this Mac lacks are skipped.
@Suite("Ask workflow gallery examples", .serialized)
@MainActor
struct AskWorkflowGalleryExampleTests {
    private func run(_ fixture: AskWorkflowFixture, _ id: String, keyword: String? = nil, query: String,
                     selection: String? = nil) async throws -> AskWorkflowTestResult? {
        let item = try #require(AskWorkflowGallery.bundled.item(id))
        let path = await AskWorkflowPath.searchPath()
        guard let interpreter = item.runtime.interpreterName,
              AskWorkflowPath.resolve(interpreter, searchPath: path) != nil
        else { return nil }
        let workflow = try fixture.store.installed(item) ?? fixture.store.add(item, builtIn: []).workflow
        let tester = AskWorkflowTester(home: fixture.home.path)
        return await tester.run(
            workflow,
            input: AskWorkflowTestInput(query: query, selection: selection, keyword: keyword)
        )
    }

    private func lines(_ result: AskWorkflowTestResult?) -> [String] {
        (result?.stdout ?? "").split(separator: "\n").map(String.init)
    }

    @Test func `exchange rates use both entries and the cache`() async throws {
        let fixture = try AskWorkflowFixture()
        // Seed the rates cache so the run stays offline.
        let cache = AskWorkflow.cacheDirectory(for: "local.fx", home: fixture.home.path)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["USD": 1, "JPY": 150, "EUR": 0.9])
            .write(to: cache.appendingPathComponent("rates-USD.json"))
        guard let converted = try await run(fixture, "fx", keyword: "fx", query: "100 usd jpy") else { return }
        #expect(converted.succeeded, "\(converted.stderr)")
        #expect(lines(converted) == ["100 USD = 15,000.00 JPY", "1 USD = 150.000 JPY"])
        #expect(converted.actionSteps.count == 2)
        let table = try #require(try await run(fixture, "fx", keyword: "rate", query: ""))
        #expect(table.succeeded && lines(table) == ["1 USD = 0.9000 EUR", "1 USD = 150.0000 JPY"])
        #expect(table.arguments.first?.hasSuffix("/table.py") == true, "rate runs its own entry")
        let unknown = try #require(try await run(fixture, "fx", keyword: "fx", query: "5 usd xyz"))
        #expect(unknown.exitCode == 1 && unknown.stdout.contains("Unknown currency: XYZ"))
        let wrong = try #require(try await run(fixture, "fx", keyword: "fx", query: "lots of money"))
        #expect(wrong.exitCode == 1 && wrong.stdout.contains("Try: 100 usd jpy"))
    }

    @Test func `timestamps go both ways`() async throws {
        let fixture = try AskWorkflowFixture()
        guard let seconds = try await run(fixture, "ts", query: "1700000000") else { return }
        #expect(seconds.succeeded && lines(seconds).first == "2023-11-14 22:13:20 UTC")
        let millis = try #require(try await run(fixture, "ts", query: "1700000000000"))
        #expect(lines(millis).first == "2023-11-14 22:13:20 UTC" && millis.stdout.contains("milliseconds"))
        let date = try #require(try await run(fixture, "ts", query: "", selection: "2024-05-01 12:00"))
        #expect(date.succeeded && Int(lines(date).first ?? "") != nil, "the selection is used without an argument")
        let now = try #require(try await run(fixture, "ts", query: ""))
        #expect(now.succeeded && lines(now).count == 3)
        let bad = try #require(try await run(fixture, "ts", query: "yesterday"))
        #expect(bad.exitCode == 1 && bad.stdout.contains("Not a timestamp"))
    }

    @Test func `json is formatted or compacted and written back`() async throws {
        let fixture = try AskWorkflowFixture()
        guard let pretty = try await run(fixture, "json", query: "", selection: #"{"a":1,"b":[true,null]}"#)
        else { return }
        #expect(pretty.succeeded && pretty.stdout == "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null\n  ]\n}\n")
        #expect(pretty.actionSteps.map(\.action.action) == ["writeBack"])
        let compact = try #require(try await run(fixture, "json", query: "min", selection: "{ \"a\" : [1, 2] }"))
        #expect(compact.stdout == "{\"a\":[1,2]}\n")
        let typed = try #require(try await run(fixture, "json", query: "[1,2]"))
        #expect(typed.stdout == "[\n  1,\n  2\n]\n")
        let broken = try #require(try await run(fixture, "json", query: "", selection: "{nope"))
        #expect(broken.exitCode == 1 && broken.stdout.contains("Not valid JSON"))
    }

    @Test func `url and base 64 share one script`() async throws {
        let fixture = try AskWorkflowFixture()
        guard let encoded = try await run(fixture, "codec", keyword: "url", query: "a b&c=d") else { return }
        #expect(encoded.succeeded && encoded.stdout == "a%20b%26c%3Dd\n", "\(encoded.stderr)")
        #expect(try await run(fixture, "codec", keyword: "url", query: "a%20b%26c")?.stdout == "a b&c\n")
        #expect(try await run(fixture, "codec", keyword: "url", query: "-e 100%")?.stdout == "100%25\n")
        #expect(try await run(fixture, "codec", keyword: "b64", query: "hello")?.stdout == "aGVsbG8=\n")
        #expect(try await run(fixture, "codec", keyword: "b64", query: "aGVsbG8=")?.stdout == "hello\n")
        #expect(try await run(fixture, "codec", keyword: "b64", query: "test")?.stdout == "dGVzdA==\n",
                "text that only looks like Base64 is encoded")
        #expect(try await run(fixture, "codec", keyword: "b64", query: "-e aGVsbG8=")?.stdout == "YUdWc2JHOD0=\n")
        #expect(try await run(fixture, "codec", keyword: "b64", query: "", selection: "hi")?.stdout == "aGk=\n")
        let bad = try #require(try await run(fixture, "codec", keyword: "url", query: "-d %E0%A4%A"))
        #expect(bad.exitCode == 1 && bad.stdout.contains("Cannot decode"))
    }

    @Test func `uuid and passwords are copied not shown`() async throws {
        let fixture = try AskWorkflowFixture()
        guard let uuid = try await run(fixture, "uuid", keyword: "uuid", query: "") else { return }
        let value = uuid.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(uuid.succeeded && UUID(uuidString: value) != nil && value == value.lowercased())
        #expect(uuid.actionSteps.map(\.action.action) == ["copy", "hud"])
        let password = try #require(try await run(fixture, "uuid", keyword: "pwd", query: "12"))
        let text = password.stdout.trimmingCharacters(in: .newlines)
        #expect(text.count == 12 && text.allSatisfy { $0.isASCII && !$0.isWhitespace })
        #expect(try await run(fixture, "uuid", keyword: "pwd", query: "")?.stdout.trimmingCharacters(in: .newlines)
            .count == 20)
        let short = try #require(try await run(fixture, "uuid", keyword: "pwd", query: "4"))
        #expect(short.exitCode == 1 && short.stdout.contains("Length"))
    }

    @Test func `word count counts CJK as words`() async throws {
        let fixture = try AskWorkflowFixture()
        guard let latin = try await run(fixture, "wc", query: "", selection: "Hello world") else { return }
        #expect(lines(latin) == ["11 characters · 10 without spaces", "2 words · 1 line"])
        let mixed = try #require(try await run(fixture, "wc", query: "你好 world\nok"))
        #expect(lines(mixed) == ["11 characters · 9 without spaces", "4 words · 2 lines"])
    }
}

@Suite("Ask workflow keyword entries")
struct AskWorkflowKeywordEntryTests {
    private func folder(_ files: [String: String], executable: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tf-entry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
            if executable.contains(path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return folder
    }

    private func manifest(script: String? = "main.py", inline: String? = nil, runtime: AskWorkflowRuntime = .python3,
                          entries: [String?]) -> AskWorkflowManifest {
        AskWorkflowManifest(id: "a.b", name: "A", keywords: entries.enumerated().map { index, script in
            .init(keyword: "k\(index)", script: script)
        }, command: .init(runtime: runtime, script: script, inline: inline, args: nil, interpreter: nil))
    }

    @Test func `each keyword finds its entry`() throws {
        let manifest = manifest(entries: [nil, "table.py", "main.py"])
        #expect(manifest.script(forKeyword: "k0") == "main.py" && manifest.script(forKeyword: "K1") == "table.py")
        #expect(manifest.script(forKeyword: "other") == "main.py")
        #expect(manifest.entryScripts == ["main.py", "table.py"])
        let decoded = try JSONDecoder().decode(AskWorkflowManifest.self, from: Data(#"""
        {"id": "x", "name": "X", "keywords": [{"keyword": "r", "script": "t.py"}],
         "command": {"runtime": "python3", "script": "m.py"}, "origin": {"gallery": "fx", "version": "1.0.0"}}
        """#.utf8))
        #expect(decoded.keywords[0].script == "t.py" && decoded.origin == .init(gallery: "fx", version: "1.0.0"))
        let encoded = try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(manifest.keywords[0])) as? [String: Any]
        #expect(encoded?["script"] == nil, "a keyword without an entry writes none")
    }

    @Test func `entries are checked like the script`() throws {
        let folder = try folder(["main.py": "", "table.py": "", "tool": "#!/bin/sh\n"], executable: ["tool"])
        /// Fields, and the file named in the message: other suites switch the interface language meanwhile.
        func problems(_ manifest: AskWorkflowManifest) -> [String] {
            manifest.problems(in: folder).map(\.field)
        }
        #expect(problems(manifest(entries: [nil, "table.py"])).isEmpty)
        #expect(problems(manifest(entries: [nil, "gone.py"])) == ["keywords[1].script"])
        #expect(manifest(entries: [nil, "gone.py"]).problems(in: folder).first?.message.contains("gone.py") == true)
        #expect(problems(manifest(entries: ["../x.py"])) == ["keywords[0].script"])
        #expect(problems(manifest(entries: ["workflow.json"])) == ["keywords[0].script"])
        #expect(problems(manifest(script: nil, inline: "echo", runtime: .zsh, entries: ["main.py"]))
            == ["keywords[0].script"])
        #expect(problems(manifest(script: "tool", runtime: .exec, entries: ["table.py"])) == ["keywords[0].script"])
        #expect(problems(manifest(script: "tool", runtime: .exec, entries: ["tool"])).isEmpty)
        #expect(AskWorkflowDraft.step(for: "keywords[1].script") == .keywords)
    }

    @Test func `a draft counts entries it has not saved yet`() throws {
        let folder = try folder(["main.py": ""])
        var draft = AskWorkflowDraft(folder: folder, manifestText: "", files: ["main.py": ""])
        draft.manifestText = #"""
        {"schema": 1, "id": "a.b", "name": "A", "keywords": [{"keyword": "a"}, {"keyword": "b", "script": "table.py"}],
         "command": {"runtime": "python3", "script": "main.py"}}
        """#
        #expect(draft.problems().map(\.field) == ["keywords[1].script"])
        draft.files["table.py"] = "print(1)"
        #expect(draft.problems().isEmpty)
        let manifest = try #require(draft.manifest)
        #expect(AskWorkflowDraft.entryScript(of: "keywords[1].script", in: manifest) == "table.py")
        #expect(AskWorkflowDraft.entryScript(of: "keywords[0].script", in: manifest) == nil)
        #expect(AskWorkflowDraft.entryScript(of: "keywords[9].script", in: manifest) == nil)
        #expect(AskWorkflowDraft.entryScript(of: "command.script", in: manifest) == "main.py")
        #expect(AskWorkflowDraft.entryScript(of: "keywords[x].script", in: manifest) == nil)
        // Saving makes every entry executable, not only the default one.
        try AskWorkflowStore.write(draft.pendingWrites, deletes: [], in: folder, fileManager: .default)
        #expect(FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("table.py").path))
    }

    @Test func `errors are located in every file`() throws {
        let folder = try folder(["main.py": "", "lib/helper.py": "", "workflow.json": "{}", ".hidden": "",
                                 "__pycache__/x.pyc": ""])
        #expect(AskWorkflowStderrLocator.files(in: folder) == ["main.py", "lib/helper.py"])
        let stderr = """
        Traceback (most recent call last):
          File "\(folder.path)/main.py", line 3, in <module>
          File "\(folder.path)/lib/helper.py", line 7, in boom
        ValueError: nope
        """
        let location = AskWorkflowStderrLocator.locate(
            stderr,
            folder: folder,
            files: AskWorkflowStderrLocator.files(in: folder)
        )
        #expect(location == .init(path: "lib/helper.py", line: 7, message: "ValueError: nope"))
    }
}

@Suite("Ask workflow keyword entries at run time", .serialized)
@MainActor
struct AskWorkflowKeywordEntryRunTests {
    @Test func `the launcher runs the keywords entry and points at A helper`() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("multi", manifest: [
            "schema": 1, "id": "multi", "name": "Multi",
            "keywords": [["keyword": "one"], ["keyword": "two", "script": "two.sh"]],
            "command": ["runtime": "zsh", "script": "one.sh"]
        ], files: [
            "one.sh": "print one",
            "two.sh": "source ./lib.sh\nfail_here",
            "lib.sh": "fail_here() {\n  print -u2 \"$TYPEFLUX_WORKFLOW_DIR/lib.sh:2: boom\"\n  exit 4\n}"
        ])
        fixture.store.reload()
        fixture.store.trust("multi")
        var plugin = try #require(fixture.store.plugins { (nil, nil) }.first)
        plugin.searchPath = { "/usr/bin:/bin" }
        let one = AskPluginRequest(text: "", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:],
                                   interfaceLanguage: .english, selection: nil)
        #expect(try await plugin.run(one, plan: plugin.plan(one)).body == "one")
        let two = AskPluginRequest(text: "", origin: .argument, keyword: plugin.defaultKeywords[1], options: [:],
                                   interfaceLanguage: .english, selection: nil)
        let invocation = try plugin.invocation(
            for: two,
            input: plugin.input(for: two),
            manifest: #require(plugin.manifest),
            source: (nil, nil),
            path: "/usr/bin:/bin"
        )
        #expect(invocation.launch.arguments.first?.hasSuffix("/two.sh") == true)
        do {
            _ = try await plugin.run(two, plan: plugin.plan(two))
            Issue.record("two fails")
        } catch let failure as AskPluginFailure {
            // The marked line is in lib.sh, which no keyword runs.
            guard case let .editWorkflow(id, path, line) = failure.action(for: .commandE)?.kind else {
                Issue.record("no edit action"); return
            }
            #expect(id == "multi" && path == "lib.sh" && line == 2)
        }
        // Without stderr nothing is scanned.
        guard case let .editWorkflow(_, path, _) = plugin.editActions()[0].kind else { return }
        #expect(path == nil)
    }

    @Test func `the trust sheet says which keyword runs what`() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("multi", manifest: [
            "schema": 1, "id": "multi", "name": "Multi",
            "keywords": [["keyword": "one"], ["keyword": "two", "script": "two.sh"]],
            "command": ["runtime": "zsh", "script": "one.sh"]
        ], files: ["one.sh": "", "two.sh": ""])
        fixture.store.reload()
        #expect(try AskWorkflowTrustSummary(#require(fixture.store.workflow("multi"))).keywords == [
            "one",
            "two → two.sh"
        ])
    }
}

@Suite("Ask workflow file references")
struct AskWorkflowFileReferencesTests {
    @Test func `imports requires and sources are found`() {
        let files = [
            "main.py": "import json\nfrom rates import fetch\nimport helpers.text\n",
            "table.py": "  import rates\n",
            "rates.py": "", "helpers/text.py": "", "README.md": "",
            "main.js": "const h = require('./helper')\nimport x from \"./util.mjs\"\n",
            "helper.js": "", "util.mjs": "",
            "main.sh": "source ./lib.sh\n. \"$TYPEFLUX_WORKFLOW_DIR/env.sh\"\n",
            "lib.sh": "", "env.sh": ""
        ]
        let references = AskWorkflowFileReferences.references(in: files)
        #expect(references["rates.py"] == [.init(from: "main.py", statement: "from rates import …"),
                                           .init(from: "table.py", statement: "import rates")])
        #expect(references["helpers/text.py"] == [.init(from: "main.py", statement: "import helpers.text")])
        #expect(references["helper.js"] == [.init(from: "main.js", statement: "require('./helper')")])
        #expect(references["util.mjs"] == [.init(from: "main.js", statement: "require('./util.mjs')")])
        #expect(references["lib.sh"] == [.init(from: "main.sh", statement: "source ./lib.sh")])
        #expect(references["env.sh"] == [.init(from: "main.sh", statement: "source ./env.sh")])
        #expect(references["json.py"] == nil && references["README.md"] == nil)
    }

    @Test func `rows put entries first`() {
        let manifest = AskWorkflowManifest(id: "a", name: "A", keywords: [
            .init(keyword: "fx"), .init(keyword: "rate", script: "table.py"), .init(keyword: "fy")
        ], command: .init(runtime: .python3, script: "main.py", inline: nil, args: nil, interpreter: nil))
        let rows = AskWorkflowFileReferences.rows(manifest: manifest, files: [
            "README.md": "", "rates.py": "", "table.py": "import rates", "main.py": "import rates"
        ])
        #expect(rows.map(\.path) == ["main.py", "table.py", "README.md", "rates.py"])
        #expect(rows[0].isDefault && rows[0].keywords == ["fx", "fy"] && rows[0].isEntry)
        #expect(!rows[1].isDefault && rows[1].keywords == ["rate"])
        #expect(!rows[2].isEntry && rows[3].references.map(\.from) == ["main.py", "table.py"])
        #expect(!AskWorkflowFilesCard.note(for: rows[0]).isEmpty, "the default entry says so")
        #expect(AskWorkflowFilesCard.note(for: rows[1]).isEmpty)
        #expect(!AskWorkflowFilesCard.note(for: rows[2]).isEmpty, "a README says what it is")
        let note = AskWorkflowFilesCard.note(for: rows[3])
        #expect(note.contains("main.py") && note.contains("table.py") && note.contains("import rates"))
        #expect(AskWorkflowFileReferences.rows(manifest: nil, files: ["a.py": ""]).map(\.isEntry) == [false])
    }
}
