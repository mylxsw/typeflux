import Darwin
import Foundation
import Testing
@testable import Typeflux

/// Collects a PTY process's callbacks, which arrive on a private serial queue in these tests.
final class TerminalPTYRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var code: Int32?

    var text: String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }

    var byteCount: Int {
        lock.withLock { bytes.count }
    }

    var exitCode: Int32? {
        lock.withLock { code }
    }

    func attach(to process: TerminalPTYProcess) {
        process.onOutput = { [self] chunk in lock.withLock { bytes += chunk } }
        process.onExit = { [self] value in lock.withLock { code = value } }
    }
}

@Suite("Built-in terminal pseudo-terminal process", .serialized)
struct TerminalPTYProcessTests {
    private let callbacks = DispatchQueue(label: "ai.typeflux.tests.terminal-pty")

    /// `/bin/sh -c` with the production command script, without reading any startup files.
    private func launch(_ command: String, directory: String = NSTemporaryDirectory()) -> TerminalShellLaunch {
        var launch = TerminalShellLaunch(command: command, settings: .init(shell: .login, directory: directory),
                                         shell: "/bin/sh", base: ProcessInfo.processInfo.environment,
                                         home: NSHomeDirectory())
        launch.arguments = ["/bin/sh", "-c", launch.arguments.last ?? ""]
        return launch
    }

    private func run(_ command: String, size: TerminalSize = .standard,
                     during: (TerminalPTYProcess) async throws -> Void = { _ in }) async throws
        -> TerminalPTYRecorder {
        let process = TerminalPTYProcess(callbackQueue: callbacks)
        let recorder = TerminalPTYRecorder()
        recorder.attach(to: process)
        try process.start(launch(command), size: size)
        try await during(process)
        try await wait(seconds: 10) { recorder.exitCode != nil }
        return recorder
    }

    private func wait(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "the terminal process did not reach the expected state in time")
    }

    @Test func `output arrives before a successful exit`() async throws {
        let result = try await run("printf 'hello\\n'; printf 'world'")
        #expect(result.exitCode == 0)
        #expect(result.text == "hello\r\nworld")
    }

    @Test func `exit codes and signals are reported like a shell`() async throws {
        #expect(try await run("exit 3").exitCode == 3)
        #expect(try await run("kill -TERM $$").exitCode == 128 + SIGTERM)
        #expect(try await run("definitely-not-a-command-gul431").exitCode == 127)
    }

    @Test func `the command sees a terminal, the marker and no command variable`() async throws {
        let result = try await run(
            "test -t 0 && test -t 1 && printf 'tty;'; printf '%s;%s;%s' \"$TYPEFLUX_TERMINAL\" \"${TYPEFLUX_COMMAND-unset}\" \"$TERM\""
        )
        #expect(result.text == "tty;1;unset;xterm-256color")
    }

    @Test func `the command starts in the chosen directory`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gul431-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = TerminalPTYProcess(callbackQueue: callbacks)
        let recorder = TerminalPTYRecorder()
        recorder.attach(to: process)
        try process.start(launch("pwd -P", directory: directory.path), size: .standard)
        try await wait(seconds: 10) { recorder.exitCode != nil }
        // `realpath`, like `pwd -P`, keeps `/private`; Foundation's symlink resolution drops it.
        let resolved = try #require(realpath(directory.path, nil))
        defer { free(resolved) }
        #expect(recorder.text.trimmingCharacters(in: .whitespacesAndNewlines) == String(cString: resolved))
    }

    @Test func `a missing directory is reported before anything starts`() throws {
        let process = TerminalPTYProcess(callbackQueue: callbacks)
        #expect(throws: TerminalProcessError.directoryMissing("/nonexistent/gul431")) {
            try process.start(launch("pwd", directory: "/nonexistent/gul431"), size: .standard)
        }
        #expect(!TerminalProcessError.directoryMissing("/x").localizedDescription.isEmpty)
        #expect(!TerminalProcessError.spawnFailed(EAGAIN).localizedDescription.isEmpty)
    }

    @Test func `typed input reaches the command`() async throws {
        let result = try await run("read line; printf 'got:%s' \"$line\"") { process in
            try await Task.sleep(for: .milliseconds(200))
            process.write(Array("abc\r".utf8))
        }
        #expect(result.exitCode == 0)
        #expect(result.text.contains("got:abc"))
    }

    @Test func `hidden input is detected while echo is off`() async throws {
        let process = TerminalPTYProcess(callbackQueue: callbacks)
        let recorder = TerminalPTYRecorder()
        recorder.attach(to: process)
        #expect(!process.readsHiddenInput)
        try process.start(launch("stty -echo; read secret; stty echo; printf 'len:%s' \"${#secret}\""), size: .standard)
        try await wait(seconds: 5) { process.readsHiddenInput }
        process.write(Array("hunter2\r".utf8))
        try await wait(seconds: 5) { recorder.exitCode != nil }
        #expect(recorder.text.contains("len:7") && !recorder.text.contains("hunter2"))
        #expect(!process.readsHiddenInput)
    }

    @Test func `window size reaches the command and follows resizes`() async throws {
        let result = try await run("sleep 0.4; stty size", size: TerminalSize(columns: 90, rows: 30)) { process in
            process.resize(TerminalSize(columns: 101, rows: 41))
        }
        #expect(result.text.contains("41 101"))
    }

    @Test func `terminate hangs up a running command and its children`() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("gul431-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = try await run("(sleep 30; touch '\(marker.path)') & sleep 30") { process in
            try await Task.sleep(for: .milliseconds(300))
            process.terminate()
            process.terminate()
        }
        #expect(result.exitCode == 128 + SIGHUP)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func `a command ignoring hangups is killed and reaped after its window is gone`() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("gul431-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        do {
            let process = TerminalPTYProcess(callbackQueue: callbacks)
            try process.start(launch("trap '' HUP TERM; echo $$ > '\(pidFile.path)'; sleep 30"), size: .standard)
            try await wait(seconds: 5) { FileManager.default.fileExists(atPath: pidFile.path) }
            try await Task.sleep(for: .milliseconds(100))
            process.terminate()
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // SIGHUP and SIGTERM are ignored; SIGKILL follows, and the zombie is reaped.
        try await wait(seconds: 8) { kill(pid, 0) != 0 && errno == ESRCH }
    }

    @Test func `the app's open descriptors and ignored signals do not reach the command`() async throws {
        var pipeEnds: [Int32] = [0, 0]
        #expect(pipe(&pipeEnds) == 0)
        defer { close(pipeEnds[0]); close(pipeEnds[1]) }
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let result = try await run(
            "if [ -e /dev/fd/\(pipeEnds[1]) ]; then printf leak; else printf clean; fi; yes | head -n 1 >/dev/null"
        )
        #expect(result.text == "clean")
        #expect(result.exitCode == 0)
    }

    @Test func `fast output is delivered completely under backpressure`() async throws {
        let result = try await run("yes 0123456789 | head -n 200000")
        #expect(result.exitCode == 0)
        // Each line is 11 bytes plus the terminal's CR before LF.
        #expect(result.byteCount == 200_000 * 12)
    }

    @Test func `writes after exit and before start are ignored`() async throws {
        let process = TerminalPTYProcess(callbackQueue: callbacks)
        process.write(Array("x".utf8))
        process.resize(.standard)
        process.terminate()
        let recorder = TerminalPTYRecorder()
        recorder.attach(to: process)
        try process.start(launch("true"), size: .standard)
        try await wait(seconds: 5) { recorder.exitCode != nil }
        process.write(Array("late".utf8))
        process.resize(TerminalSize(columns: 10, rows: 10))
        process.terminate()
        #expect(recorder.exitCode == 0 && recorder.text.isEmpty)
    }
}
