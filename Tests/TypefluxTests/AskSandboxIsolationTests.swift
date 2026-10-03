import Darwin
import Foundation
@testable import Typeflux
import XCTest

final class AskSandboxIsolationTests: XCTestCase {
    private var root: URL!
    private var sandbox: AskCodeSandbox!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-isolation-\(UUID().uuidString)")
        sandbox = AskCodeSandbox(
            baseDirectory: root,
            environment: ["GUL167_FAKE_SECRET": "do-not-inherit", "PYTHONPATH": "/tmp", "PATH": "/tmp"],
            allowProcessGroupExecution: true
        )
        XCTAssertTrue(sandbox.isSupported, "Seatbelt is required for this acceptance suite; do not silently skip.")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testProductionGateFailsClosedAndDoesNotAdvertiseTool() async throws {
        let production = AskCodeSandbox(baseDirectory: root)
        XCTAssertFalse(production.isSupported)
        XCTAssertNil(production.definition())
        XCTAssertTrue(production.availableLanguages.isEmpty)
        do {
            _ = try await production.run(.shell, code: "echo unsafe", conversationId: "c")
            XCTFail("Unvalidated containment must remain disabled")
        } catch { XCTAssertTrue(error.localizedDescription.contains("containment")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(sandbox.interpreter(for: .javascript))
    }

    func testEnvironmentSiblingSessionsAndOutsideTemporaryFilesAreUnreadable() async throws {
        let sibling = try sandbox.workspace(for: "sibling")
        try "sibling-secret".write(to: sibling.appendingPathComponent("sentinel"), atomically: true, encoding: .utf8)
        let external = root.appendingPathComponent("external")
        try "external-secret".write(to: external, atomically: true, encoding: .utf8)
        let result = try await sandbox.run(.shell, code: """
        test -z "$GUL167_FAKE_SECRET" && echo clean-env
        test -z "$PYTHONPATH" && echo clean-python
        cat '\(sibling.path)/sentinel' && echo LEAK
        cat '\(external.path)' && echo LEAK
        echo finished
        """, conversationId: "current")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "clean-env\nclean-python\nfinished")
    }

    func testOldRunSymlinksCannotRedirectHostScriptWrite() async throws {
        let workspace = try sandbox.workspace(for: "c")
        let marker = root.appendingPathComponent("marker")
        try "sentinel".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".run"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent(".run/main.sh"),
            withDestinationURL: marker
        )
        let result = try await sandbox.run(.shell, code: "echo safe", conversationId: "c")
        XCTAssertEqual(result.stdout, "safe")
        XCTAssertEqual(try String(contentsOf: marker), "sentinel")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scripts").path)
            .isEmpty)
    }

    func testTemporaryDirectorySymlinkIsRejectedBeforeAnyScriptRuns() async throws {
        let workspace = try sandbox.workspace(for: "c")
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".tmp"))
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent(".tmp"),
            withDestinationURL: root
        )
        do {
            _ = try await sandbox
                .run(.shell, code: "echo unsafe", conversationId: "c"); XCTFail("Expected no-follow rejection")
        } catch {}
    }

    func testWorkspaceAndControlDirectoryCannotBeReplacedByProgram() async throws {
        let workspace = try sandbox.workspace(for: "c")
        let result = try await sandbox.run(.shell, code: """
        mv '\(workspace.path)' '\(workspace.path).moved' && echo MOVED
        echo changed > "$0" && echo MODIFIED_SCRIPT
        echo hello > file
        cat file
        """, conversationId: "c")
        XCTAssertEqual(result.stdout, "hello", result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path + ".moved"))
    }

    func testPythonStandardLibraryAndNetworkDenial() async throws {
        XCTAssertNotNil(sandbox.interpreter(for: .python), "CLT Python is required by this acceptance fixture.")
        let result = try await sandbox.run(.python, code: """
        import os, json, sqlite3, hashlib, socket, math
        assert os.environ.get('GUL167_FAKE_SECRET') is None
        assert math.sqrt(9) == 3
        assert sqlite3.connect(':memory:').execute('select 7').fetchone()[0] == 7
        print(hashlib.sha256(b'ok').hexdigest()[:2])
        try:
            socket.create_connection(('127.0.0.1', 9), 0.2)
        except PermissionError:
            print('network-denied')
        else:
            raise AssertionError('network was allowed')
        """, conversationId: "python")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "26\nnetwork-denied")
    }

    func testReadableSkillsRootIsExplicitAndCannotCoverOtherSessions() async throws {
        let skills = root.appendingPathComponent("../skills-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: skills) }
        try "skill-data".write(to: skills.appendingPathComponent("helper.txt"), atomically: true, encoding: .utf8)
        sandbox.readableDirectories = [skills]
        let result = try await sandbox.run(
            .shell,
            code: "echo modified > '\(skills.path)/helper.txt'; cat '\(skills.path)/helper.txt'",
            conversationId: "c"
        )
        XCTAssertEqual(result.stdout, "skill-data", result.stderr)
        sandbox.readableDirectories = [root]
        do {
            _ = try await sandbox
                .run(.shell, code: "echo unsafe", conversationId: "c"); XCTFail("Expected overlap rejection")
        } catch {}
    }

    func testCancellationRemovesControlFilesAndReleasesWorkspaceLock() async throws {
        let current = try XCTUnwrap(sandbox)
        let task = Task { try await current.run(.shell, code: "echo ready > ready; sleep 30", conversationId: "cancel")
        }
        let workspace = try sandbox.workspace(for: "cancel")
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scripts").path)
            .isEmpty)
        let next = try await sandbox.run(.shell, code: "echo next", conversationId: "cancel")
        XCTAssertEqual(next.stdout, "next")
    }

    func testConcurrentSessionUseFailsAndPrunePreservesActiveWorkspace() async throws {
        let workspace = try sandbox.workspace(for: "active")
        let pinned = try AskSecureDirectory.openRoot(workspace)
        try pinned.lock()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: workspace.path
        )
        do {
            _ = try await sandbox
                .run(.shell, code: "echo unsafe", conversationId: "active"); XCTFail("Expected lock rejection")
        } catch {}
        sandbox.pruneWorkspaces()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        withExtendedLifetime(pinned) {}
    }

    func testDaemonEscapeIsAnExplicitUnsupportedModel() async throws {
        // This finite fixture proves why the production gate is necessary without
        // leaving a daemon behind. setsid escapes the group, but not Seatbelt.
        let result = try await sandbox.run(.python, code: """
        import os
        child = os.fork()
        if child == 0:
            os.setsid()
            os.write(1, b'session-escaped\\n')
            os._exit(0)
        os.waitpid(child, 0)
        """, conversationId: "escape")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "session-escaped")
        XCTAssertFalse(AskCodeSandbox().isSupported)
    }
}
