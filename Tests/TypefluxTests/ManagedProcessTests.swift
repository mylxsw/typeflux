import Darwin
import Foundation
@testable import Typeflux
import XCTest

final class ManagedProcessTests: XCTestCase {
    private var root: URL!
    private var directory: AskSecureDirectory!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-process-\(UUID().uuidString)")
        directory = try AskSecureDirectory.openRoot(root)
    }

    override func tearDownWithError() throws {
        directory = nil
        try FileManager.default.removeItem(at: root)
    }

    private func request(_ code: String, timeout: Double = 2, limit: Int = 1000) -> ManagedProcess.Request {
        .init(executable: "/bin/sh", arguments: ["-c", code], environment: ["PATH": "/usr/bin:/bin"],
              directoryDescriptor: directory.descriptor, timeout: timeout, outputLimit: limit)
    }

    private func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        // Orphan zombies can briefly await launchd's reap, but cannot run or hold FDs.
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        XCTAssertTrue(size == 0 || info.pbi_status == SZOMB, "Process \(pid) is still alive", file: file, line: line)
    }

    func testExitOutputEnvironmentAndWorkingDirectory() async throws {
        let result = try await ManagedProcess()
            .run(request("echo hello; echo error >&2; echo ok > file; test -z \"$GUL167_FAKE_SECRET\"; exit 7"))
        XCTAssertEqual(result.termination, .exited(7))
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "error")
        XCTAssertFalse(result.outputTruncated)
        XCTAssertEqual(try directory.readFile("file", limit: 10), Data("ok\n".utf8))
    }

    func testTimeoutKillsGroupIgnoringTermWithinCleanupBudget() async throws {
        let start = Date()
        let result = try await ManagedProcess().run(request(
            "trap '' TERM; echo $$; /bin/sh -c 'trap \"\" TERM; echo $$; while :; do sleep 10; done' & wait",
            timeout: 0.2
        ))
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.2)
        let pids = result.stdout.split(separator: "\n").compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        pids.forEach { assertGone($0) }
    }

    func testParentExitWithPipeHoldingChildIsCleanedUp() async throws {
        let start = Date()
        let result = try await ManagedProcess()
            .run(request("/bin/sh -c 'trap \"\" TERM; echo $$; while :; do sleep 10; done' & sleep 0.05; exit 3"))
        XCTAssertEqual(result.termination, .exited(3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try assertGone(XCTUnwrap(Int32(result.stdout)))
    }

    func testParentExitDoesNotDisarmPipeDrainDeadline() async throws {
        let result = try await ManagedProcess().run(request(
            "/bin/sh -c 'trap \"\" TERM; echo $$; while :; do sleep 10; done' & sleep 0.025; exit 0",
            timeout: 0.1
        ))
        XCTAssertEqual(result.termination, .timedOut)
        try assertGone(XCTUnwrap(Int32(result.stdout)))
    }

    func testFloodBothStreamsIsBoundedAndDoesNotStarveDeadline() async throws {
        let result = try await ManagedProcess().run(request(
            "while :; do printf '012345678901234567890123456789'; printf 'abcdefghijklmnopqrstuvwxyz' >&2; done",
            timeout: 0.15,
            limit: 127
        ))
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertLessThan(result.stdout.utf8.count, 200)
        XCTAssertLessThan(result.stderr.utf8.count, 200)
        XCTAssertTrue(result.stdout.contains("more bytes omitted"))
        XCTAssertTrue(result.stderr.contains("more bytes omitted"))
    }

    func testCancellationWaitsForGroupCleanup() async throws {
        let request = request("trap '' TERM; echo $$ > pid; while :; do sleep 10; done", timeout: 20)
        let task = Task { try await ManagedProcess().run(request) }
        // Wait for an observable start, not an assumed scheduler delay.
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("pid").path) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.termination, .cancelled)
        let pid =
            try XCTUnwrap(Int32(String(decoding: directory.readFile("pid", limit: 32), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        assertGone(pid)
    }

    func testCancelTimeoutRaceAlwaysReaps() async throws {
        for _ in 0 ..< 5 {
            let request = request("echo $$; sleep 10", timeout: 0.025)
            let task = Task { try await ManagedProcess().run(request) }
            try await Task.sleep(for: .milliseconds(25))
            task.cancel()
            let result = try await task.value
            XCTAssertTrue(result.termination == .cancelled || result.termination == .timedOut)
            try assertGone(XCTUnwrap(Int32(result.stdout)))
        }
    }

    func testPrecancelAndLaunchFailureAndInvalidRequest() async throws {
        let request = request("echo should-not-run > launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ManagedProcess().run(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
        var missing = request
        missing.executable = "/missing/gul167"
        do { _ = try await ManagedProcess().run(missing); XCTFail("Expected launch failure") } catch {}
        var invalid = request
        invalid.timeout = .nan
        do { _ = try await ManagedProcess().run(invalid); XCTFail("Expected validation failure") } catch {}
        invalid = request
        invalid.environment = ["BAD=KEY": "value"]
        do { _ = try await ManagedProcess().run(invalid); XCTFail("Expected validation failure") } catch {}
    }

    func testUnspecifiedHostDescriptorsAreNotInherited() async throws {
        let descriptor = open(root.appendingPathComponent("host-only").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        // Deliberately leave CLOEXEC unset to exercise the spawn contract.
        let result = try await ManagedProcess()
            .run(request("if test -e /dev/fd/\(descriptor); then echo LEAK; fi; read value || echo stdin-closed"))
        XCTAssertEqual(result.stdout, "stdin-closed")
    }

    func testSignalStatusAndZeroOutputLimit() async throws {
        let result = try await ManagedProcess().run(request("echo hi; kill -KILL $$", limit: 0))
        XCTAssertEqual(result.termination, .signalled(SIGKILL))
        XCTAssertEqual(result.exitCode, 128 + SIGKILL)
        XCTAssertTrue(result.outputTruncated)
    }
}
