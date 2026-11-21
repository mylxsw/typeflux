import AppKit
import Combine
import Testing
@testable import Typeflux

@MainActor
@Suite("Persistent launcher terminal", .exclusiveUIState)
struct TerminalSessionTests {
    private func history() -> TerminalCommandHistory {
        TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private let esc = "\u{1b}"
    private func osc(_ text: String) -> String {
        esc + "]" + text + "\u{7}"
    }

    @Test func `blocks preserve cwd exit and attributes across chunks`() throws {
        let process = FakeTerminalProcess()
        let center = TerminalSessionCenter(history: history(), makeProcess: { process })
        let session = try center.create()
        defer { center.terminateAll() }
        #expect(session.submit("cd /tmp"))
        #expect(process.writes.isEmpty)
        process.emit(osc("133;A") + osc("133;B"))
        #expect(process.writes.first == Array("\u{1b}[200~cd /tmp\u{1b}[201~\r".utf8))
        for byte in (osc("133;C") + esc + "[31mred" + esc + "[0m\r\n" + osc("133;D;0") +
            osc("7;file://localhost/tmp/a%20b") + osc("133;A") + osc("133;B")).utf8 {
            process.onOutput?([byte])
        }
        let first = try #require(session.blocks.first)
        try #require(first.output.string == "red")
        #expect(first.output.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(first.state == .finished && first.exitCode == 0 && first.endedAt != nil)
        #expect(session.submit("false"))
        process.emit(osc("133;C") + osc("133;D;1"))
        #expect(session.blocks.last?.cwd == "/tmp/a b")
        #expect(session.blocks.last?.exitCode == 1)
        #expect(session.blocks.last?.output.string == "")
    }

    @Test func `hosting input and expiry share one process`() throws {
        let process = FakeTerminalProcess()
        let history = history()
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        var activities: [BackgroundActivity] = []
        let observer = center.activitiesPublisher.sink { activities = $0 }
        defer { observer.cancel() }
        let session = try center.create()
        let view = session.terminalView
        process.emit(osc("133;A") + osc("133;B"))
        #expect(!session.submit("a\nb"))
        #expect(session.submit("read password"))
        process.emit(osc("133;C") + "Password: ")
        #expect(session.runningBlock?.state == .waitingForInput)
        process.readsHiddenInput = true
        session.refreshInput()
        #expect(session.readsHiddenInput)
        session.write(Array("private\n".utf8))
        #expect(!session.submit("private"))
        #expect(history.commands == ["read password"])
        process.emit(esc + "[?1049h")
        #expect(session.alternateScreen && session.runningBlock?.state == .alternateScreen)
        process.emit(esc + "[?1049l")
        let window = TerminalSession.Host.window(UUID())
        center.move(session, to: window)
        #expect(session.host == window && view === session.terminalView && process.started.count == 1)
        center.setVisible(false, session: session)
        center.expireIdle(now: .distantFuture)
        #expect(center.sessions.count == 1 && process.terminations == 0)
        session.eof()
        #expect(process.writes.last == [4])
        try center.perform(.stop, on: #require(activities.first?.id))
        #expect(process.writes.last == [3])
        session.interrupt()
        #expect(process.forcedInterrupts == 1 && process.terminations == 0)
        process.emit(osc("133;D;137") + osc("133;A"))
        #expect(session.blocks.last?.state == .interrupted && activities.isEmpty)
        center.expireIdle(now: .distantFuture)
        #expect(center.sessions.isEmpty)
    }

    @Test func `idle timer closes only the hidden idle session`() async throws {
        let idle = FakeTerminalProcess()
        let visible = FakeTerminalProcess()
        var processes = [idle, visible]
        let center = TerminalSessionCenter(history: history(), makeProcess: { processes.removeFirst() })
        defer { center.terminateAll() }
        let hidden = try center.create()
        let other = try center.create()
        center.idleTimeout = 0.05
        center.setVisible(false, session: hidden)
        try await wait { center.sessions.count == 1 }
        #expect(center.sessions.first === other && idle.terminations == 1 && visible.terminations == 0)
        center.close(other)
        #expect(center.sessions.isEmpty && visible.terminations == 1)
    }

    @Test func `second interrupt kills an interrupt ignoring job and preserves shell state`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = TerminalSessionCenter(history: history())
        let session = try center.create(settings: .init(shell: .login, directory: "/"))
        defer { center.close(session) }
        let cwd = folder.resolvingSymlinksInPath().path
        try #require(session.submit("cd '\(cwd)' && export TF_INTERRUPT_PROBE=$$"))
        try await wait { session.runningBlock == nil && session.cwd == cwd }
        try #require(session.submit("/bin/sh -c 'trap \"\" INT; touch ready; exec /bin/sleep 100'"))
        try await wait { FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) }
        session.interrupt()
        session.interrupt()
        try await wait { session.runningBlock == nil }
        #expect(session.blocks.last?.state == .interrupted && session.blocks.last?.exitCode == 137)
        try #require(!session.exited)
        try #require(session.submit("test \"$TF_INTERRUPT_PROBE\" = \"$$\" && test . -ef '\(cwd)' && test -f ready"))
        try await wait { session.runningBlock == nil }
        #expect(session.blocks.last?.exitCode == 0 && session.cwd == cwd)
    }

    @Test func `leading space commands stay out of persisted history`() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let key = "terminal.session.commandHistory"
        defaults.set([" previous private command", "pwd"], forKey: key)
        let history = TerminalCommandHistory(defaults: defaults)
        #expect(history.commands == ["pwd"] && defaults.stringArray(forKey: key) == ["pwd"])
        history.record(" new private command")
        history.record("echo public")
        #expect(TerminalCommandHistory(defaults: defaults).commands == ["echo public", "pwd"])
    }

    @Test func `fallback keeps one block and history is bounded`() async throws {
        let process = FakeTerminalProcess()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set((0 ..< 1000).map(String.init), forKey: "terminal.session.commandHistory")
        let history = TerminalCommandHistory(defaults: defaults)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let session = try center.create()
        #expect(session.submit("echo fallback"))
        try await wait { !process.writes.isEmpty }
        #expect(process.writes.first == Array("echo fallback\r".utf8))
        process.emit("fallback")
        session.write(Array("second\r".utf8))
        process.exit(0)
        #expect(session.blocks.count == 1 && session.blocks.first?.output.string == "fallback")
        history.record("17")
        let restored = TerminalCommandHistory(defaults: defaults)
        #expect(restored.commands.count == 1000 && restored.commands.prefix(2) == ["17", "echo fallback"])
        #expect(!restored.commands.contains("999"))
        center.terminateAll()
    }

    @Test func `snapshot keeps last lines and stream preserves other controls`() throws {
        let process = FakeTerminalProcess()
        let center = TerminalSessionCenter(history: history(), makeProcess: { process })
        let session = try center.create()
        defer { center.terminateAll() }
        process.emit("one\r\ntwo\r\nthree")
        #expect(session.terminalView.blockSnapshot(limit: 2).string == "two\nthree")
        var parser = TerminalMarkerStream()
        #expect(parser.read(Array((esc + "]7;file://localhost/a%20b" + esc).utf8)).isEmpty)
        #expect(parser.read([92]) == [.directory("/a b")])
        let oversized = Array((esc + "]2;" + String(repeating: "x", count: 9000) + "\u{7}").utf8)
        #expect(parser.read(oversized + Array(osc("133;B").utf8)) == [.bytes(oversized), .input])
        let unknown = Array(osc("2;window title").utf8)
        #expect(parser.read(unknown) == [.bytes(unknown)])
    }

    @Test func `git status reports clean and untracked files`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ProcessCommandRunner()
        _ = try await runner.run(executablePath: "/usr/bin/git", arguments: ["init", "-b", "session-test"],
                                 currentDirectoryURL: folder)
        #expect(await TerminalGitStatus.read(folder.path) == TerminalGitStatus(branch: "session-test", dirty: false))
        try Data().write(to: folder.appendingPathComponent("new-file"))
        #expect(await TerminalGitStatus.read(folder.path) == TerminalGitStatus(branch: "session-test", dirty: true))
    }

    @Test func `real zsh maintains directory and startup profile`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try "export PROFILE_TEST=login".write(
            to: home.appendingPathComponent(".zprofile"),
            atomically: true,
            encoding: .utf8
        )
        try "export PROFILE_TEST=interactive".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
        for profile in [TerminalShellProfile.login, .interactive] {
            let settings = TerminalRunSettings(shell: profile, directory: "/")
            let process = TerminalPTYProcess()
            let shim = try TerminalSessionShell(settings: settings)
            var events: [TerminalMarkerStream.Event] = []
            var parser = TerminalMarkerStream()
            process.onOutput = { events += parser.read($0) }
            try process.start(
                shim.launch(settings: settings, base: ["HOME": home.path], home: home.path),
                size: .standard
            )
            defer { process.terminate(); withExtendedLifetime(shim) {} }
            try await wait { events.contains(.input) }
            func run(_ command: String) {
                events = []
                process.write(Array(("\u{1b}[200~" + command + "\u{1b}[201~\r").utf8))
            }
            run("cd /private/tmp")
            try await wait { events.contains(.complete(0)) && events.contains(.input) }
            #expect(events.contains(.directory("/private/tmp")))
            run("printf '%s|%s' \"$PWD\" \"$PROFILE_TEST\"; false")
            try await wait { events.contains(.complete(1)) }
            let bytes = events.flatMap { event -> [UInt8] in
                if case let .bytes(bytes) = event {
                    return bytes
                }
                return []
            }
            #expect(String(decoding: bytes, as: UTF8.self).contains("/private/tmp|" + profile.rawValue))
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
