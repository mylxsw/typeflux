import Foundation
import Testing
@testable import Typeflux

/// A terminal process the test drives by hand.
final class FakeTerminalProcess: TerminalProcess {
    var onOutput: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?
    var started: [(TerminalShellLaunch, TerminalSize)] = []
    var writes: [[UInt8]] = []
    var sizes: [TerminalSize] = []
    var terminations = 0
    var readsHiddenInput = false
    var startError: Error?

    func start(_ launch: TerminalShellLaunch, size: TerminalSize) throws {
        if let startError { throw startError }
        started.append((launch, size))
    }

    func write(_ bytes: [UInt8]) {
        writes.append(bytes)
    }

    func resize(_ size: TerminalSize) {
        sizes.append(size)
    }

    func terminate() {
        terminations += 1
    }

    func emit(_ text: String) {
        onOutput?(Array(text.utf8))
    }

    func exit(_ code: Int32) {
        onExit?(code)
    }
}

final class TerminalTestClock {
    var now = Date(timeIntervalSince1970: 1000)
}

@Suite("Built-in terminal run model")
@MainActor
struct TerminalRunModelTests {
    private func model(_ settings: TerminalRunSettings = .init(), command: String = "ls -la",
                       processes: [FakeTerminalProcess], clock: TerminalTestClock = .init()) -> TerminalRunModel {
        var queue = processes
        let request = TerminalCommandRequest(command: command, terminal: .iterm, builtin: settings)
        let launch = TerminalShellLaunch(command: command, settings: settings, shell: "/bin/zsh", base: [:],
                                         home: "/Users/tester")
        let model = TerminalRunModel(request: request, settings: settings, launch: launch, targetAppName: "Notes",
                                     makeProcess: { queue.removeFirst() }, now: { clock.now })
        var screen = ""
        model.output = { screen += String(decoding: $0, as: UTF8.self) }
        model.visibleText = { screen.trimmingCharacters(in: .whitespacesAndNewlines) }
        model.clearScreen = { screen = "" }
        return model
    }

    @Test func `start runs the prepared launch and exposes the request`() {
        let process = FakeTerminalProcess()
        let model = model(processes: [process])
        model.start()
        #expect(model.isRunning && process.started.count == 1)
        #expect(process.started[0].0.environment[TerminalShellLaunch.commandVariable] == "ls -la")
        #expect(process.started[0].1 == .standard)
        #expect(model.command == "ls -la" && model.externalTerminal == .iterm && model.targetAppName == "Notes")
        #expect(model.directoryLabel == "~")
        model.terminate()
        #expect(process.terminations == 1)
    }

    @Test func `output before the view attaches is kept in order`() {
        let process = FakeTerminalProcess()
        let model = model(processes: [process])
        var received: [String] = []
        model.output = nil
        model.start()
        process.emit("one ")
        process.emit("two")
        model.output = { received.append(String(decoding: $0, as: UTF8.self)) }
        process.emit(" three")
        #expect(received == ["one ", "two", " three"])
    }

    @Test(arguments: [
        (TerminalFinishPolicy.auto, "", Int32(0), true), (.auto, "result", 0, false), (.auto, "", 1, false),
        (.keep, "", 0, false), (.close, "result", 0, true), (.close, "boom", 2, false)
    ])
    func `finishing reports whether the window closes`(policy: TerminalFinishPolicy, output: String, code: Int32,
                                                        closes: Bool) {
        let process = FakeTerminalProcess()
        let clock = TerminalTestClock()
        let model = model(.init(finish: policy), processes: [process], clock: clock)
        var finished: [(Int32, Bool)] = []
        model.onFinish = { finished.append(($0, $1)) }
        model.start()
        process.emit(output)
        clock.now += 1.25
        process.exit(code)
        #expect(model.phase == .finished(exitCode: code) && !model.isRunning)
        #expect(finished.count == 1 && finished[0].0 == code && finished[0].1 == closes)
        #expect(model.duration == 1.25)
        #expect(model.hasOutput == !output.isEmpty)
        #expect(model.completionNotice == (code == 0 ? "✓" : "✗") + " ls -la · 1.2s"
            || model.completionNotice == (code == 0 ? "✓" : "✗") + " ls -la · 1.3s")
    }

    @Test func `stop interrupts first and hangs up second`() {
        let process = FakeTerminalProcess()
        let model = model(processes: [process])
        model.start()
        model.stop()
        #expect(process.writes == [[TerminalRunModel.interruptByte]] && model.interruptSent)
        #expect(process.terminations == 0)
        model.stop()
        #expect(process.terminations == 1)
        process.exit(130)
        model.stop()
        model.send([0x61])
        #expect(process.terminations == 1 && process.writes.count == 1)
    }

    @Test func `input and resizes go to the running process only`() {
        let process = FakeTerminalProcess()
        let model = model(processes: [process])
        model.start()
        model.send([0x6C, 0x73])
        model.resize(TerminalSize(columns: 100, rows: 30))
        model.resize(TerminalSize(columns: 100, rows: 30))
        model.resize(TerminalSize(columns: 0, rows: 30))
        #expect(process.writes == [[0x6C, 0x73]])
        #expect(process.sizes == [TerminalSize(columns: 100, rows: 30)])
    }

    @Test func `rerun clears the screen and ignores the previous process`() {
        let first = FakeTerminalProcess(), second = FakeTerminalProcess()
        let model = model(processes: [first, second])
        var finished = 0
        model.onFinish = { _, _ in finished += 1 }
        model.start()
        model.rerun()
        #expect(second.started.isEmpty, "a running command is not started twice")
        first.emit("old")
        model.resize(TerminalSize(columns: 120, rows: 40))
        first.exit(1)
        model.stop()
        #expect(model.interruptSent == false)
        model.rerun()
        #expect(model.visibleText().isEmpty && model.isRunning && !model.interruptSent)
        #expect(second.started.first?.1 == TerminalSize(columns: 120, rows: 40))
        first.emit("stale")
        first.exit(9)
        #expect(model.isRunning && model.visibleText().isEmpty && finished == 1)
        second.emit("new")
        second.exit(0)
        #expect(model.visibleText() == "new" && finished == 2)
    }

    @Test func `a process that cannot start is reported in the window`() {
        let process = FakeTerminalProcess()
        process.startError = TerminalProcessError.directoryMissing("/gone")
        let model = model(processes: [process])
        model.start()
        guard case let .failedToStart(message) = model.phase else {
            Issue.record("Expected a start failure")
            return
        }
        #expect(message.contains("/gone") && !model.isRunning)
        model.stop()
        model.terminate()
        #expect(process.terminations == 0)
    }

    @Test func `long commands notify when enabled`() {
        let clock = TerminalTestClock()
        let process = FakeTerminalProcess()
        let quiet = model(.init(notifies: false), processes: [process], clock: clock)
        quiet.start()
        clock.now += 60
        process.exit(0)
        #expect(!quiet.shouldNotify)
        let other = FakeTerminalProcess()
        let loud = model(processes: [other], clock: clock)
        loud.start()
        clock.now += TerminalRunModel.notificationThreshold - 1
        #expect(!loud.shouldNotify)
        clock.now += 1
        other.exit(0)
        #expect(loud.shouldNotify)
    }

    @Test func `hidden input is polled while the command runs`() async throws {
        let process = FakeTerminalProcess()
        let model = model(processes: [process])
        model.start()
        process.readsHiddenInput = true
        try await AskQuickSearchSessionTests.wait { model.readsHiddenInput }
        model.alternateScreen = true
        try await AskQuickSearchSessionTests.wait { !model.readsHiddenInput }
        model.alternateScreen = false
        try await AskQuickSearchSessionTests.wait { model.readsHiddenInput }
        process.exit(0)
        #expect(!model.readsHiddenInput && !model.alternateScreen)
    }
}
