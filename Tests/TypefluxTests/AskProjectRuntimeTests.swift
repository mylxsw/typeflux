import AppKit
import Darwin
@testable import Typeflux
import XCTest

@MainActor
final class AskProjectRuntimeTests: XCTestCase {
    typealias Fixture = AskProjectRuntimeFixture

    func testOfflineProcessUsesPrivateStagedCopyAndPreservesSource() async throws {
        let fixture = try Fixture("print('source')"); defer { fixture.close() }
        let source = try fixture.projects.read(
            fixture.workspace.id,
            path: "main.py",
            scope: fixture.scope,
            authorizedRoots: fixture.roots
        )
        fixture.workspace = try fixture.projects.write(
            fixture.workspace.id,
            path: "main.py",
            expectedVersion: source.version,
            content: "open('new.txt','w').write('result'); print('staged')",
            scope: fixture.scope,
            authorizedRoots: fixture.roots
        )
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.state, .exited)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), "staged\n")
        XCTAssertEqual(try String(contentsOf: fixture.source.appendingPathComponent("main.py")), "print('source')")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("new.txt").path))
        XCTAssertEqual(
            try String(contentsOf: fixture.base.appendingPathComponent("runtime/\(lease.id)/project/new.txt")),
            "result"
        )
    }

    func testPipeInputEOFAndByteCursorsAreLossless() async throws {
        let fixture = try Fixture("import sys; print(sys.stdin.read(), end='')"); defer { fixture.close() }
        let lease = try fixture.launch()
        try fixture.input("hello 🐱\n", lease: lease, eof: true)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        var cursor: Int64 = 0, collected = Data()
        while cursor < status.outputBytes {
            let page = try fixture.runtime.output(lease, scope: fixture.scope, cursor: cursor, maximumBytes: 1)
            XCTAssertEqual(page.offset, cursor); XCTAssertEqual(page.lostBytes, 0)
            collected.append(page.data); cursor = page.nextCursor
        }
        XCTAssertEqual(collected, Data("hello 🐱\n".utf8))
        XCTAssertEqual(try fixture.runtime.output(lease, scope: fixture.scope, cursor: cursor).data, Data())
        XCTAssertThrowsError(try fixture.runtime.output(lease, scope: fixture.scope, cursor: -1))
        XCTAssertThrowsError(try fixture.runtime.output(lease, scope: fixture.scope, cursor: cursor + 1))
        XCTAssertThrowsError(try fixture.runtime.output(lease, scope: fixture.scope, cursor: 0, maximumBytes: 0))
        XCTAssertThrowsError(try fixture.input("late", lease: lease))
    }

    func testPTYProvidesTerminalAndInteractiveInput() async throws {
        let fixture = try Fixture("import os; print(os.isatty(0), os.isatty(1)); print(input().upper())")
        defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.terminal = .pty
        let lease = try fixture.launch(request)
        XCTAssertThrowsError(try fixture.input(String(repeating: "x", count: 256), lease: lease))
        try fixture.input("hello\n", lease: lease)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), "True True\nHELLO\n")
    }

    func testPTYEOF() async throws {
        let fixture = try Fixture("import sys; print(sys.stdin.read())"); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.terminal = .pty
        let lease = try fixture.launch(request)
        try fixture.input("line", lease: lease, eof: true)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), "line\n")
    }

    func testOutputFloodIsBoundedAndReportsEvictedBytes() async throws {
        let fixture = try Fixture("import os; os.write(1, b'a' * 2200000)"); defer { fixture.close() }
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.outputBytes, 2_200_000)
        XCTAssertTrue(status.logTruncated)
        let page = try fixture.runtime.output(lease, scope: fixture.scope, cursor: 0)
        XCTAssertEqual(page.lostBytes, 2_200_000 - Int64(AskTerminalSession.outputLimit))
        XCTAssertEqual(page.data, Data(repeating: 97, count: 65536))
        let log = try Data(contentsOf: fixture.base.appendingPathComponent("runtime/\(lease.id)/output.bin"))
        XCTAssertEqual(log.count, AskTerminalSession.outputLimit)
        XCTAssertFalse(status.persistenceFailed)
    }

    func testSingleProcessPolicyDeniesForkSpawnExecAndOutsideFiles() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let secret = fixture.base.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let script = """
        import os, subprocess, socket
        actions = [lambda: os.fork(), lambda: subprocess.run(['/bin/echo','escaped']),
                   lambda: os.posix_spawn('/bin/echo',['echo','escaped'],{}),
                   lambda: open('\(secret.path)').read(),
                   lambda: open('\(fixture.source.path)/changed','w'),
                   lambda: os.execv('/bin/echo',['echo','escaped'])]
        for action in actions:
            try: action(); print('UNEXPECTED')
            except OSError: print('denied')
        """
        try Data(script.utf8).write(to: fixture.source.appendingPathComponent("main.py"))
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), String(repeating: "denied\n", count: 6))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("changed").path))
    }

    func testRealConnectionsAndWildcardBindAreDenied() async throws {
        let listener = try AskProjectPortLease(requested: 0)
        let fixture = try Fixture("""
        import socket
        for host in ['127.0.0.1', '1.1.1.1']:
            s=socket.socket(); s.settimeout(0.2)
            try: s.connect((host, \(listener.port))); print('UNEXPECTED')
            except PermissionError: print('denied')
        for host in ['0.0.0.0','127.0.0.1']:
            s=socket.socket()
            try: s.bind((host,0)); print('UNEXPECTED')
            except PermissionError: print('denied')
        """)
        defer { fixture.close() }
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), String(repeating: "denied\n", count: 4))
    }

    func testEnvironmentCwdAndArgumentsAreExplicit() async throws {
        let fixture = try Fixture("import os,sys; print(os.getcwd()); print(sys.argv[1:]); print(sorted(os.environ))")
        defer { fixture.close() }
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent("sub"),
            withIntermediateDirectories: false
        )
        var request = AskProjectLaunchRequest(script: "main.py")
        request.cwd = "sub"; request.arguments = ["a b", "$(no shell)"]
        request.environment = ["TERM": "xterm-256color"]
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        let text = try fixture.text(lease)
        XCTAssertTrue(text.contains("/project/sub\n")); XCTAssertTrue(text.contains("['a b', '$(no shell)']"))
        XCTAssertTrue(text.contains("'TERM'")); XCTAssertFalse(text.contains("'SSH_AUTH_SOCK'"))
        XCTAssertFalse(text.contains("'CODEX_HOME'"))
    }

    func testTimeoutKillsSignalIgnoringProcessWithClosedOutput() async throws {
        let fixture = try Fixture("""
        import os,signal,time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print('started'); os.close(1); os.close(2); time.sleep(30)
        """)
        defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.timeout = 0.3
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.state, .timedOut)
        XCTAssertEqual(kill(status.pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }

    func testStopCancelShutdownAndWorkspaceDeletionReapProcesses() throws {
        for reason in ["stop", "cancel", "shutdown", "delete"] {
            let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
            let lease = try fixture.launch()
            switch reason {
            case "stop": try fixture.runtime.stop(lease, scope: fixture.scope)
            case "cancel": fixture.runtime.cancel(scope: fixture.scope)
            case "shutdown": fixture.runtime.shutdown()
            default: fixture.runtime.workspaceDeleted(lease.workspace, scope: fixture.scope)
            }
            let status = try fixture.runtime.status(lease, scope: fixture.scope)
            XCTAssertEqual(kill(status.pid, 0), -1); XCTAssertEqual(errno, ESRCH)
            XCTAssertFalse([.starting, .running, .ready].contains(status.state))
            try fixture.runtime.stop(lease, scope: fixture.scope)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("main.py").path))
        }
    }

    func testRevocationAndSourceRootDeletionStopRunningLease() throws {
        for remove in [false, true] {
            let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
            let lease = try fixture.launch()
            if remove {
                try FileManager.default.removeItem(at: fixture.source)
            } else {
                fixture.roots = []
            }
            fixture.runtime.reconcileAuthorization()
            let status = try fixture.runtime.status(lease, scope: fixture.scope)
            XCTAssertEqual(status.state, .revoked)
            XCTAssertEqual(kill(status.pid, 0), -1)
        }
    }

    func testDifferentOwnerRunAndForgedHandleCannotAccessLease() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        let lease = try fixture.launch()
        var scope = fixture.scope; scope.runId = "another"
        XCTAssertThrowsError(try fixture.runtime.stop(lease, scope: scope))
        XCTAssertThrowsError(try fixture.runtime.output(lease, scope: scope, cursor: 0))
        XCTAssertThrowsError(try fixture.runtime.serviceAddress(lease, scope: scope))
        fixture.runtime.cancel(scope: scope)
        fixture.runtime.workspaceDeleted(lease.workspace, scope: scope)
        XCTAssertEqual(try fixture.runtime.status(lease, scope: fixture.scope).state, .running)
        scope = fixture.scope; scope.ownerId = "other"
        XCTAssertThrowsError(try fixture.runtime.status(lease, scope: scope))
        let forged = AskProjectRuntimeLease(id: lease.id, sessionId: "other", workspace: lease.workspace,
                                            root: lease.root, createdAt: lease.createdAt, port: nil)
        XCTAssertThrowsError(try fixture.runtime.stop(forged, scope: fixture.scope))
    }
}

@MainActor
extension AskProjectRuntimeTests {
    func testGrantCannotBeReplayedOrChangedOrRevoked() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        let request = AskProjectLaunchRequest(script: "main.py"), call = "call"
        let grant = try fixture.grant(request, call: call)
        func launch(_ req: AskProjectLaunchRequest) throws -> AskProjectRuntimeLease {
            try fixture.runtime.start(req, workspace: fixture.workspace, scope: fixture.scope,
                                      authorizedRoots: { fixture.roots }, callId: call, grantId: grant,
                                      approvals: fixture.approvals)
        }
        var changed = request; changed.arguments = ["changed"]
        XCTAssertThrowsError(try launch(changed))
        _ = try launch(request)
        XCTAssertThrowsError(try launch(request))
        fixture.approvals.revoke(conversation: fixture.scope.conversationId)
        XCTAssertThrowsError(try launch(request))
    }

    func testInputRequiresExactFreshApprovalAndBoundsQueue() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        let lease = try fixture.launch(), data = Data("approved".utf8)
        let approval = try fixture.runtime.inputApproval(
            lease,
            scope: fixture.scope,
            data: data,
            eof: false,
            callId: "input"
        )
        let grant = try XCTUnwrap(fixture.approvals.issue(approval))
        XCTAssertThrowsError(try fixture.runtime.send(Data("changed".utf8), lease: lease, scope: fixture.scope,
                                                      callId: "input", grantId: grant, approvals: fixture.approvals))
        try fixture.runtime.send(
            data,
            lease: lease,
            scope: fixture.scope,
            callId: "input",
            grantId: grant,
            approvals: fixture.approvals
        )
        XCTAssertThrowsError(try fixture.runtime.send(data, lease: lease, scope: fixture.scope,
                                                      callId: "input", grantId: grant, approvals: fixture.approvals))
        XCTAssertThrowsError(try fixture.input(String(repeating: "x", count: 65537), lease: lease))
        fixture.roots = []
        XCTAssertThrowsError(try fixture.input("revoked", lease: lease))
    }

    func testDisabledAndUnsupportedNetworkOrEnvironmentFailClosed() throws {
        let fixture = try Fixture(enabled: false); defer { fixture.close() }
        XCTAssertThrowsError(try fixture.launch())
        var request = AskProjectLaunchRequest(script: "main.py")
        request.network = .dependencyInstallation
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request)) { error in
            XCTAssertEqual(error as? AskProjectRuntimeError, .installationUnavailable)
        }
        request.network = .offline; request.environment = ["PYTHONPATH": "/tmp"]
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request))
        request.environment = [:]; request.timeout = .infinity
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request))
        request.timeout = 1; request.script = "../outside"
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request))
        request.script = "main.py"; request.servicePort = 80
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request))
        request.servicePort = nil; request.arguments = ["nul\0"]
        XCTAssertThrowsError(try AskProjectRuntimePolicy.validate(request))
    }

    func testRestartInvalidatesJournalAndDoesNotReplayOrSignalPID() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        let lease = try fixture.launch()
        fixture.runtime.shutdown(); fixture.runtime = nil
        fixture.runtime = try AskProjectRuntime(storageURL: fixture.base.appendingPathComponent("runtime"),
                                                projects: fixture.projects, enabled: true)
        XCTAssertEqual(fixture.runtime.invalidatedLeases, [lease])
        XCTAssertThrowsError(try fixture.runtime.stop(lease, scope: fixture.scope))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: fixture.base.appendingPathComponent("runtime/\(lease.id)/invalidated").path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: fixture.base.appendingPathComponent("runtime/\(lease.id)/result.json").path))
        XCTAssertThrowsError(try AskProjectRuntime(
            storageURL: fixture.base.appendingPathComponent("runtime"),
            projects: fixture.projects
        ))
    }

    func testApplicationTerminationNotificationStopsLease() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        let lease = try fixture.launch()
        fixture.notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(try fixture.runtime.status(lease, scope: fixture.scope).state, .appExit)
        XCTAssertThrowsError(try fixture.launch())
    }

    func testCopiedLocalModulesAndPreinstalledStdlibAreAvailable() async throws {
        let fixture = try Fixture("import helper,json; print(json.dumps(helper.value))"); defer { fixture.close() }
        try Data("value = {'answer': 42}".utf8).write(to: fixture.source.appendingPathComponent("helper.py"))
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), "{\"answer\": 42}\n")
    }

    func testCapacityIsBoundedAndStopAllowsNewProcess() throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        var leases: [AskProjectRuntimeLease] = []
        for _ in 0 ..< 4 {
            try leases.append(fixture.launch())
        }
        XCTAssertThrowsError(try fixture.launch()) { XCTAssertEqual($0 as? AskProjectRuntimeError, .capacity) }
        try fixture.runtime.stop(leases[0], scope: fixture.scope)
        _ = try fixture.launch()
    }

    func testExpiredGrantAndRevocationDuringCopyNeverStartProcess() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        XCTAssertThrowsError(try fixture.launch(mutation: {
            fixture.approvals.now = { Date().addingTimeInterval(301) }
        }))
        fixture.approvals.now = { Date() }
        XCTAssertThrowsError(try fixture.launch(mutation: {
            fixture.approvals.revoke(conversation: fixture.scope.conversationId)
        }))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
            []
        )
    }

    func testNonzeroExitAndSignalExitRemainDistinct() async throws {
        for code in ["raise SystemExit(23)", "import os,signal; os.kill(os.getpid(),signal.SIGKILL)"] {
            let fixture = try Fixture(code); defer { fixture.close() }
            let lease = try fixture.launch()
            let status = try await fixture.wait(lease)
            if code.hasPrefix("raise") {
                XCTAssertEqual(status.state, .exited); XCTAssertEqual(status.exitCode, 23)
            } else {
                XCTAssertEqual(status.state, .signalled); XCTAssertEqual(status.exitCode, 137)
            }
        }
    }

    func testSourceAndHostDescriptorsAreNotInherited() async throws {
        let fixture = try Fixture("""
        import os
        opened=[]
        for descriptor in range(1024):
            try: os.fstat(descriptor); opened.append(descriptor)
            except OSError: pass
        print(opened)
        """)
        defer { fixture.close() }
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(try fixture.text(lease), "[0, 1, 2]\n")
    }

    func testCancelledHostTaskCannotLaunch() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let task = Task { try fixture.launch() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled task launched a process")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
            []
        )
    }
}
