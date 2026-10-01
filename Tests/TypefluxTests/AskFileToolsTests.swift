@testable import Typeflux
import XCTest

final class AskFileToolsTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private var tools: AskFileTools!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-files-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "alpha\nBeta line\ngamma\n".write(to: root.appendingPathComponent("docs/notes.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        tools = AskFileTools(roots: [root.path])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testListReadSearchWriteAndEditInsideTheRoot() throws {
        XCTAssertTrue(try tools.execute(["action": "list", "path": root.path]).contains("docs/"))
        let listing = try tools.list("docs")
        XCTAssertTrue(listing.contains("notes.txt"))
        XCTAssertTrue(try tools.list(root.path + "/docs").contains("bytes"))

        let read = try tools.execute(["action": "read", "path": "docs/notes.txt"])
        XCTAssertTrue(read.contains("1\talpha\n2\tBeta line"))
        XCTAssertTrue(try tools.read("docs/notes.txt", offset: 2, limit: 1).contains("3\tgamma"))
        XCTAssertFalse(try tools.read("docs/notes.txt", offset: 2, limit: 1).contains("alpha"))

        let found = try tools.execute(["action": "search", "path": root.path, "pattern": "beta"])
        XCTAssertTrue(found.hasSuffix("notes.txt:2: Beta line"))
        XCTAssertEqual(try tools.search("docs/notes.txt", pattern: "missing"), "No matches.")

        XCTAssertTrue(try tools.execute(["action": "write", "path": "new/dir/file.md", "content": "hello"]).hasPrefix("Created"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new/dir/file.md")), "hello")
        XCTAssertTrue(try tools.write("new/dir/file.md", content: "hello again").hasPrefix("Replaced"))

        XCTAssertTrue(try tools.execute(["action": "edit", "path": "docs/notes.txt", "old_text": "gamma", "new_text": "delta"]).hasPrefix("Edited"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("docs/notes.txt")).contains("delta"))
    }

    func testPathsOutsideTheRootsAreRefused() throws {
        for path in [outside.appendingPathComponent("secret.txt").path, "../outside/secret.txt", "/etc/hosts", "  "] {
            XCTAssertThrowsError(try tools.read(path, offset: 0, limit: nil), path)
        }
        // A symlink inside the root cannot reach outside it, for reading or for writing a new file.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try tools.read("link/secret.txt", offset: 0, limit: nil))
        XCTAssertThrowsError(try tools.write("link/new/file.txt", content: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertThrowsError(try AskFileTools(roots: []).list("/"))
        // A root's sibling with a shared prefix is not inside it.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: root.path + "-other"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try tools.list(root.path + "-other"))
    }

    func testInvalidRequestsAndLimits() throws {
        try Data([0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("blob.bin"))
        XCTAssertThrowsError(try tools.read("blob.bin", offset: 0, limit: nil))
        try "x x".write(to: root.appendingPathComponent("dup.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try tools.edit("dup.txt", old: "x", new: "y")) { error in
            XCTAssertTrue(error.localizedDescription.contains("2"))
        }
        XCTAssertThrowsError(try tools.edit("dup.txt", old: "z", new: "y"))
        XCTAssertThrowsError(try tools.write("big.txt", content: String(repeating: "a", count: AskFileTools.maximumWriteBytes + 1)))
        for args: [String: Any] in [["action": "search", "path": "."], ["action": "write", "path": "a"], ["action": "edit", "path": "a"], ["action": "drop", "path": "a"]] {
            XCTAssertThrowsError(try tools.execute(args))
        }
        let long = (0 ..< 5000).map { "line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n")
        try long.write(to: root.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try tools.read("long.txt", offset: 0, limit: nil).contains("[truncated at line"))
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0 ..< (AskFileTools.maximumListEntries + 2) {
            FileManager.default.createFile(atPath: many.appendingPathComponent("f\(index)").path, contents: Data("needle".utf8))
        }
        XCTAssertTrue(try tools.list("many").contains("[2 more entries]"))
        XCTAssertTrue(try tools.search("many", pattern: "needle").hasSuffix("[more matches omitted]"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertTrue(try tools.list("empty").hasSuffix("(empty)"))
    }

    func testDefinitionAndRisk() throws {
        XCTAssertNil(AskFileTools.definition(roots: []))
        let definition = try XCTUnwrap(AskFileTools.definition(roots: [root.path]))
        XCTAssertEqual(definition.name, "files")
        XCTAssertTrue(definition.description.contains(root.path))
        XCTAssertEqual(AskFileTools.risk(action: "read"), .read)
        XCTAssertEqual(AskFileTools.risk(action: "search"), .read)
        XCTAssertEqual(AskFileTools.risk(action: "edit"), .write)
    }
}

final class AskCodeSandboxTests: XCTestCase {
    private var base: URL!
    private var sandbox: AskCodeSandbox!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-sandbox-\(UUID().uuidString)")
        sandbox = AskCodeSandbox(baseDirectory: base)
        try XCTSkipUnless(sandbox.isSupported, "sandbox-exec is unavailable")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testShellRunsAndWorkspacePersistsAcrossCalls() async throws {
        let first = try await sandbox.run(.shell, code: "echo hello; echo saved > data.txt; echo oops >&2", conversationId: "Conv-1")
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(first.stdout, "hello")
        XCTAssertEqual(first.stderr, "oops")
        XCTAssertEqual(first.changedFiles.map(\.name), ["data.txt"])
        let second = try await sandbox.run(.shell, code: "cat data.txt; exit 3", conversationId: "Conv-1")
        XCTAssertEqual(second.stdout, "saved")
        XCTAssertEqual(second.exitCode, 3)
        XCTAssertTrue(second.changedFiles.isEmpty)
        let report = AskCodeSandbox.report(first, workspace: "/ws")
        XCTAssertTrue(report.contains("Exit code: 0") && report.contains("--- stdout ---") && report.contains("- data.txt"))
        XCTAssertTrue(AskCodeSandbox.report(.init(exitCode: 0, timedOut: true, stdout: "", stderr: "", changedFiles: [], image: nil), workspace: "/ws")
            .contains("Timed out"))
    }

    func testSandboxBlocksHomeNetworkAndOutsideWrites() async throws {
        let secret = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".typeflux-sandbox-test-\(UUID().uuidString)")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ask-outside-\(UUID().uuidString)")
        let script = """
        cat \(secret.path) && echo READ_HOME
        echo x > \(outside.path) && echo WROTE_OUTSIDE
        /usr/bin/curl -s -m 5 https://example.com >/dev/null && echo NETWORK
        echo done
        """
        let result = try await sandbox.run(.shell, code: script, conversationId: "c2")
        XCTAssertEqual(result.stdout, "done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(result.stdout.contains("top secret"))
    }

    func testTimeoutStopsTheProgram() async throws {
        let started = Date()
        let result = try await sandbox.run(.shell, code: "sleep 30; echo late", conversationId: "c3", timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.stdout.contains("late"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testPythonImageAndOutputLimit() async throws {
        try XCTSkipIf(sandbox.interpreter(for: .python) == nil, "python3 is unavailable")
        // A 1x1 PNG written without third-party packages.
        let code = """
        import base64
        open("dot.png", "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        print("x" * 40000)
        """
        let result = try await sandbox.run(.python, code: code, conversationId: "c4")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertNotNil(result.image)
        XCTAssertTrue(result.stdout.hasSuffix("more bytes omitted]"))
    }

    func testDefinitionProfileAndHousekeeping() async throws {
        let definition = try XCTUnwrap(sandbox.definition())
        XCTAssertEqual(definition.name, "run_code")
        XCTAssertTrue(sandbox.availableLanguages.contains(.shell))
        XCTAssertEqual(sandbox.interpreter(for: .shell)?.path, "/bin/zsh")
        let profile = AskCodeSandbox.profile(workspace: "/w \"q\"", home: "/Users/me", readable: ["/r"])
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(subpath \"/w \\\"q\\\"\")"))
        XCTAssertTrue(profile.contains("(deny file-read* (subpath \"/Users/me\"))"))
        XCTAssertTrue(profile.contains("(subpath \"/r\")"))
        do {
            _ = try await sandbox.run(.shell, code: String(repeating: "a", count: AskCodeSandbox.maximumCodeBytes + 1), conversationId: "x")
            XCTFail("Expected a size error")
        } catch {}
        let unsupported = AskCodeSandbox(baseDirectory: base, environment: ["PATH": "/nonexistent"])
        XCTAssertNotNil(unsupported.interpreter(for: .shell))
        let workspace = try sandbox.workspace(for: "../../escape")
        XCTAssertTrue(workspace.path.hasPrefix(AskCodeSandbox.realPath(base.path)))
        let old = try sandbox.workspace(for: "old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: old.path)
        sandbox.pruneWorkspaces()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        let collector = AskOutputCollector(limit: 3)
        collector.append(Data("abcdef".utf8))
        XCTAssertEqual(collector.text, "abc\n[3 more bytes omitted]")
    }
}
