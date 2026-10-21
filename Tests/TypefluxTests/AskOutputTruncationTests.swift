import Darwin
import Foundation
@testable import Typeflux
import XCTest

/// Real children write a marker only after exceeding the display cap.
private enum TruncationFixture {
    static func assertRecovery(_ output: AskLocalToolOutput, ambiguous: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        let conversation = AskConversation(id: "c", title: "", revision: 0, updatedAt: .now, messages: [])
        let run = AskRun(id: "r", deviceId: "d", status: "waiting_tool", steps: 1, updatedAt: .now,
                         tools: [], pending: [])
        let identity = AskExecutionIdentity(owner: "owner", conversation: conversation, run: run,
                                            callId: "call", kind: "tool")
        let receipt = AskToolResultRequest(runId: run.id, deviceId: run.deviceId, toolCallId: "call",
                                           content: output.content, isError: output.isError,
                                           harness: .init(version: 1, outcome: output.outcome))
        let entry = AskExecutionEntry(id: identity.key,
                                      audit: .init(identity: identity, toolVersion: "1", argumentsHash: "test"),
                                      receipt: .tool(receipt))
        // These are the journal gates used by automatic recovery, not output text heuristics.
        XCTAssertEqual(entry.unknown, ambiguous, file: file, line: line)
        XCTAssertEqual(entry.needsInspection(run: run), ambiguous, file: file, line: line)
    }

    static func flood(stdout: Bool = true, stderr: Bool = true) -> String {
        let output = "printf '%31001s' x | tr ' ' x"
        return [stdout ? output : nil, stderr ? output + " >&2" : nil].compactMap(\.self).joined(separator: "; ")
    }
}

final class AskHostOutputTruncationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("host-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFiniteFloodPreservesExitAndCompletesSideEffectsOnEachStream() async throws {
        for (stdout, stderr) in [(true, false), (false, true), (true, true)] {
            for code in [0, 7] {
                let result = try await AskHostCommand().run(
                    command: TruncationFixture
                        .flood(stdout: stdout, stderr: stderr) + "; printf done > marker; exit \(code)",
                    timeout: 5, workingDirectory: root
                )
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "done")
                try FileManager.default.removeItem(at: root.appendingPathComponent("marker"))
                XCTAssertEqual(result.outcome?.safeStatus, code == 0 ? .ok : .failed)
                XCTAssertEqual(result.isError, code != 0)
                TruncationFixture.assertRecovery(result, ambiguous: false)
                let expected = "Exit code: \(code)\n" + (stdout ? "--- stdout ---\n" + String(
                    repeating: "x",
                    count: 30000
                ) + "\n" : "")
                    + (stderr ? "--- stderr ---\n" + String(repeating: "x", count: 30000) + "\n" : "")
                    + "[output truncated; only part of the output is shown]"
                XCTAssertEqual(result.content, expected)
                XCTAssertFalse(result.content.contains("stopped"))
            }
        }
    }

    func testExactLimitAndSmallWhitespaceOutputRemainCompatible() async throws {
        let exact = try await AskHostCommand().run(command: "head -c 30000 /dev/zero | tr '\\000' x", timeout: 5)
        XCTAssertEqual(exact.content, "Exit code: 0\n--- stdout ---\n" + String(repeating: "x", count: 30000))
        XCTAssertEqual(exact.outcome?.safeStatus, .ok)
        let small = try await AskHostCommand().run(command: "printf '  hi \\n'; printf ' err \\n' >&2", timeout: 5)
        XCTAssertEqual(small.content, "Exit code: 0\n--- stdout ---\n  hi \n\n--- stderr ---\n err \n")
        XCTAssertFalse(small.isError)
    }

    func testTimeoutAndSignalAfterFloodRemainAmbiguous() async throws {
        let timed = try await AskHostCommand().run(
            command: TruncationFixture.flood() + "; printf done > marker; while :; do :; done", timeout: 1,
            workingDirectory: root
        )
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "done")
        XCTAssertEqual(timed.outcome?.safeStatus, .timeout)
        TruncationFixture.assertRecovery(timed, ambiguous: true)
        XCTAssertTrue(timed.content.contains("may have made changes"))
        XCTAssertTrue(timed.content.contains("output truncated"))
        let signalled = try await AskHostCommand().run(
            command: TruncationFixture.flood() + "; kill -KILL $$",
            timeout: 5
        )
        XCTAssertEqual(signalled.outcome?.safeStatus, .unknown)
        TruncationFixture.assertRecovery(signalled, ambiguous: true)
        XCTAssertTrue(signalled.content.contains("Exit code: \(128 + SIGKILL)"))
    }

    func testCancellationAfterFloodPropagatesAndCleansUpGroup() async throws {
        let fifo = root.appendingPathComponent("ready")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let descriptor = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let ready = expectation(description: "child exceeded cap and wrote PID")
        ready.assertForOverFulfill = false
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor)
        source.setEventHandler {
            var byte: UInt8 = 0
            if read(descriptor, &byte, 1) == 1 {
                ready.fulfill()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        defer { source.cancel() }
        let directory = try XCTUnwrap(root)
        let task = Task {
            try await AskHostCommand().run(
                command: TruncationFixture.flood() + "; echo $$ > pid; printf r > ready; while :; do :; done",
                timeout: 10, workingDirectory: directory
            )
        }
        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {}
        let pid =
            try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("pid"))
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        XCTAssertTrue(size == 0 || info.pbi_status == SZOMB)
    }
}

@MainActor
final class AskApprovedOutputTruncationTests: XCTestCase {
    func testApprovedDispatchPreservesKnownTruncatedHostAndSandboxResultsWithoutReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("approved-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let sandbox = AskCodeSandbox(baseDirectory: root, allowProcessGroupExecution: true)
        XCTAssertTrue(sandbox.isSupported, "The sandbox-exec fixture must run, not silently skip")
        let settings = SettingsStore(defaults: defaults)
        settings.askCodeExecutionEnabled = true
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
                                  settings: settings, sandbox: sandbox)
        for tool in ["run_command", "run_code"] {
            for code in [0, 9] {
                let session = "\(tool)-\(code)"
                let workspace = try sandbox.workspace(for: session)
                let marker = workspace.appendingPathComponent("marker")
                let script = TruncationFixture.flood() + "; printf x >> '\(marker.path)'; exit \(code)"
                let args = tool == "run_command" ? ["command": script] : ["language": "shell", "code": script]
                let data = try JSONSerialization.data(withJSONObject: args)
                let call = try AskToolCall(
                    id: session,
                    function: .init(name: tool, arguments: XCTUnwrap(String(data: data, encoding: .utf8)))
                )
                let binding = try await tools.approvalBinding(for: call, conversationId: session)
                var authorizations = 0
                let result = try await tools.executeApproved(
                    call,
                    conversationId: session,
                    binding: binding,
                    authorize: { authorizations += 1 }
                )
                XCTAssertGreaterThan(authorizations, 0)
                XCTAssertEqual(result.outcome?.safeStatus, code == 0 ? .ok : .failed)
                XCTAssertEqual(result.isError, code != 0)
                TruncationFixture.assertRecovery(result, ambiguous: false)
                XCTAssertTrue(result.content.contains("Exit code: \(code)"))
                XCTAssertTrue(["--- stdout ---", "--- stderr ---"].allSatisfy(result.content.contains))
                XCTAssertLessThan(result.content.utf8.count, 61000)
                XCTAssertTrue(result.content
                    .contains(tool == "run_command" ? "output truncated" : "more bytes omitted"))
                XCTAssertEqual(
                    result.content.components(separatedBy: "more bytes omitted").count - 1,
                    tool == "run_code" ? 2 : 0
                )
                XCTAssertEqual(
                    try String(contentsOf: marker),
                    "x",
                    "The command must finish once without automatic replay"
                )
            }
        }
    }
}
