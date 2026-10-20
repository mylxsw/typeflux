import AppKit
import Testing
@testable import Typeflux

/// Records what the built-in terminal window hands to the rest of the app.
@MainActor
final class TerminalRunnerServiceRecorder {
    var delivered: [String] = []
    var notices: [String] = []
    var notifications: [(String, String)] = []
    var copied: [String] = []
    var deliveryError: Error?
    let dispatcher = TestTerminalDispatcher()

    var services: TerminalRunnerServices {
        TerminalRunnerServices(
            deliverText: { [weak self] text in
                if let error = self?.deliveryError { throw error }
                self?.delivered.append(text)
            },
            notifyUser: { [weak self] title, body in self?.notifications.append((title, body)); return true },
            passiveNotice: { [weak self] in self?.notices.append($0) },
            dispatcher: dispatcher,
            copy: { [weak self] in self?.copied.append($0) }
        )
    }
}

@Suite("Built-in terminal window", .exclusiveUIState)
@MainActor
struct TerminalRunnerWindowTests {
    private func center() -> TerminalRunnerCenter {
        let center = TerminalRunnerCenter()
        // `/bin/sh -c` with the production command script, without the account's startup files.
        center.makeLaunch = { request, settings in
            var launch = TerminalShellLaunch(command: request.command, settings: settings, shell: "/bin/sh",
                                             base: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            launch.arguments = ["/bin/sh", "-c", launch.arguments.last ?? ""]
            return launch
        }
        return center
    }

    private func present(_ command: String, settings: TerminalRunSettings = .init(), in center: TerminalRunnerCenter,
                         recorder: TerminalRunnerServiceRecorder) throws -> TerminalRunnerWindowController {
        center.present(.init(command: command, terminal: .iterm, builtin: settings), services: recorder.services)
        return try #require(center.windows.last)
    }

    private func wait(seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "the terminal window did not reach the expected state in time")
    }

    private func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func snapshot(_ controller: TerminalRunnerWindowController, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_SNAPSHOTS"],
              let view = controller.window.contentView?.superview ?? controller.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("terminal-runner-\(name).png"))
    }

    @Test func `a silent success closes itself with a notice`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("true", in: center, recorder: recorder)
        #expect(controller.window.isVisible && controller.window.level == .floating)
        try await wait { center.windows.isEmpty }
        #expect(!controller.window.isVisible)
        #expect(recorder.notices.count == 1 && recorder.notices[0].hasPrefix("✓ true · "))
        #expect(recorder.notifications.isEmpty)
    }

    @Test func `output stays on screen and can be copied and inserted`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("printf '\\033[32mhello\\033[0m\\nworld\\n'", in: center, recorder: recorder)
        try await wait { controller.model.phase == .finished(exitCode: 0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.window.isVisible && recorder.notices.isEmpty)
        #expect(controller.model.visibleText() == "hello\nworld")
        try snapshot(controller, name: "done")
        controller.window.sendEvent(try key(8, "c", [.command, .shift], in: controller.window))
        #expect(recorder.copied == ["hello\nworld"])
        controller.window.sendEvent(try key(36, "\r", .command, in: controller.window))
        #expect(!controller.window.isVisible && center.windows.isEmpty)
        try await wait { recorder.delivered == ["hello\nworld"] }
    }

    @Test func `insert falls back to copying when delivery fails`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        recorder.deliveryError = TextDeliveryError.noInput
        let controller = try present("echo fallback", in: center, recorder: recorder)
        try await wait { !controller.model.isRunning }
        controller.insertOutput()
        try await wait { recorder.copied == ["fallback"] }
        #expect(recorder.notices == [L("ask.plugin.writeBack.failed")])
    }

    @Test func `a failure stays open and escape closes it`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("exit 4", settings: .init(finish: .close), in: center, recorder: recorder)
        try await wait { controller.model.phase == .finished(exitCode: 4) }
        try snapshot(controller, name: "failed")
        #expect(controller.window.isVisible && recorder.notices.isEmpty)
        controller.window.sendEvent(try key(53, "\u{1B}", in: controller.window))
        #expect(!controller.window.isVisible && center.windows.isEmpty)
    }

    @Test func `closing a running command asks first and then ends it`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("sleep 30", in: center, recorder: recorder)
        try snapshot(controller, name: "running")
        // Keys go to the terminal while the command runs, except the window's own ⌘W.
        #expect(!controller.handleKey(try key(53, "\u{1B}", in: controller.window)))
        controller.window.performClose(nil)
        try await wait { controller.window.attachedSheet != nil }
        #expect(controller.window.isVisible && controller.model.isRunning)
        let sheet = try #require(controller.window.attachedSheet)
        controller.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.window.isVisible && controller.model.isRunning)
        controller.window.sendEvent(try key(13, "w", .command, in: controller.window))
        try await wait { controller.window.attachedSheet != nil }
        let again = try #require(controller.window.attachedSheet)
        controller.window.endSheet(again, returnCode: .alertFirstButtonReturn)
        try await wait { !controller.window.isVisible }
        try await wait { controller.model.phase == .finished(exitCode: 128 + SIGHUP) }
        #expect(center.windows.isEmpty && recorder.notices.isEmpty)
    }

    @Test func `stop interrupts then the run can start again`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("sleep 30", settings: .init(finish: .keep, pinned: false), in: center,
                                     recorder: recorder)
        #expect(controller.window.level == .normal && !controller.pinned)
        controller.setPinned(true)
        #expect(controller.window.level == .floating && controller.pinned)
        try await Task.sleep(for: .milliseconds(200))
        controller.model.stop()
        try await wait { !controller.model.isRunning }
        #expect(controller.model.phase == .finished(exitCode: 128 + SIGINT))
        controller.window.sendEvent(try key(15, "r", .command, in: controller.window))
        #expect(controller.model.isRunning)
        controller.model.stop()
        try await wait { !controller.model.isRunning }
        controller.window.close()
        #expect(center.windows.isEmpty)
    }

    @Test func `a full-screen program enlarges the window until it exits`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("printf '\\033[?1049h'; sleep 0.5; printf '\\033[?1049l'; echo back",
                                     in: center, recorder: recorder)
        let original = controller.window.frame
        try await wait { controller.model.alternateScreen }
        try await wait {
            controller.window.frame.width >= TerminalRunnerWindowController.fullScreenSize.width - 1
        }
        try await wait { !controller.model.isRunning }
        try await wait { controller.window.frame.size == original.size }
        #expect(controller.model.visibleText() == "back")
        controller.window.close()
    }

    @Test func `the external terminal runs the finished command again`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("echo again", in: center, recorder: recorder)
        try await wait { !controller.model.isRunning }
        controller.openExternally()
        try await wait { !recorder.dispatcher.requests.isEmpty }
        #expect(recorder.dispatcher.authorizations == [.iterm])
        #expect(recorder.dispatcher.requests == [.init(command: "echo again", terminal: .iterm)])
        try await wait { center.windows.isEmpty }
    }

    @Test func `an external failure is shown and the window stays`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        recorder.dispatcher.authorizationError = .permissionDenied
        let controller = try present("echo denied", in: center, recorder: recorder)
        try await wait { !controller.model.isRunning }
        controller.openExternally()
        try await wait { controller.window.attachedSheet != nil }
        #expect(recorder.dispatcher.requests.isEmpty && controller.window.isVisible)
        if let sheet = controller.window.attachedSheet { controller.window.endSheet(sheet) }
        controller.window.close()
    }

    @Test func `a missing directory is explained in the window`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let controller = try present("pwd", settings: .init(directory: "/nonexistent/gul431"), in: center,
                                     recorder: recorder)
        guard case let .failedToStart(message) = controller.model.phase else {
            Issue.record("Expected a start failure")
            return
        }
        #expect(message.contains("/nonexistent/gul431"))
        try snapshot(controller, name: "not-started")
        controller.window.close()
        #expect(center.windows.isEmpty)
    }

    @Test func `windows cascade and quitting ends every command`() async throws {
        let center = center(), recorder = TerminalRunnerServiceRecorder()
        let first = try present("sleep 30", in: center, recorder: recorder)
        let second = try present("sleep 30", in: center, recorder: recorder)
        #expect(second.window.frame.minX - first.window.frame.minX == TerminalRunnerCenter.cascadeOffset)
        center.terminateAll()
        try await wait { !first.model.isRunning && !second.model.isRunning }
        first.window.close()
        second.window.close()
        #expect(center.windows.isEmpty)
    }

    @Test func `screen text trims trailing blanks and the palette follows the appearance`() {
        #expect(TerminalRunnerTerminalView.trimmed("\n\na  \nb\n\n   \n") == "a\nb")
        #expect(TerminalRunnerTerminalView.trimmed("   ") == "")
        let dark = TerminalRunnerPalette.forAppearance(NSAppearance(named: .darkAqua)!)
        let light = TerminalRunnerPalette.forAppearance(NSAppearance(named: .aqua)!)
        #expect(dark.ansi.count == 16 && light.ansi.count == 16)
        #expect(dark.background != light.background)
    }
}
