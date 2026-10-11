import AppKit
import Foundation
import Testing
@testable import Typeflux

/// The system monitor (`top`) in the real launcher, driven by key presses.
extension AskQuickResultsInteractionTests {
    /// A store already holding figures, and a window that is not the app's.
    @MainActor final class Monitor {
        let defaults = UserDefaults(suiteName: "system-monitor-launcher-" + UUID().uuidString)!
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(), runningApps: { [] })
        lazy var window = SystemMonitorWindowController(defaults: defaults, store: store)

        init() {
            let counters = SystemMonitorFixtures.processes.map {
                SystemMonitorFixtures.process($0.pid, $0.name, memory: $0.memory, uid: getuid())
            }
            store.receive(SystemMonitorFixtures.raw(time: 0, processes: counters))
            let busier = counters.map { process in
                var process = process
                process.cpuTime = UInt64(process.pid) * 100_000
                return process
            }
            store.receive(SystemMonitorFixtures.raw(time: 1, processes: busier))
        }

        func install(in model: AskConversationModel) {
            model.systemMonitorWindow = window
        }
    }

    private func typeMonitor(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test func topOpensTheMonitorAndItsKeysWork() async throws {
        try await withPasteboard { pasteboard in
            let monitor = Monitor()
            let launcher = try await Launcher(text: "", prepare: monitor.install)
            defer {
                monitor.window.close()
                launcher.close()
            }
            let model = launcher.fixture.model
            try await typeMonitor("top", into: launcher)
            try await launcher.press(Self.returnKey)
            #expect(model.showsSystemMonitor)
            #expect(launcher.heights.contains { $0 >= SystemMonitorLauncherView.height })

            // The editor filters; the busiest process by PID order in the fixture comes first.
            let rows = model.systemMonitor.rows(monitor.store.snapshot, filter: "")
            #expect(rows.first?.pid == 4821)
            try await launcher.press(Self.down)
            #expect(model.systemMonitor.selection == 4821)
            try await launcher.press(8, .command)
            #expect(pasteboard.string(forType: .string) == "4821")

            // ⌘⌫ asks before ending; esc takes the question back.
            try await launcher.press(Self.backspace, .command)
            #expect(model.systemMonitor.confirming?.pid == 4821)
            try await launcher.press(Self.escape)
            #expect(model.systemMonitor.confirming == nil && model.systemMonitor.selection == 4821)

            try await launcher.press(Self.tab)
            #expect(model.systemMonitor.focus == .cpu)
            try await launcher.press(19, .command)
            #expect(model.systemMonitor.focus == .memory && model.systemMonitor.sort == .memory)

            // Esc steps back: the chosen row, the card, then out of the keyword.
            try await launcher.press(Self.escape)
            #expect(model.systemMonitor.selection == nil)
            try await launcher.press(Self.escape)
            #expect(model.systemMonitor.focus == nil)
            try await typeMonitor("chr", into: launcher)
            #expect(model.systemMonitor.rows(monitor.store.snapshot, filter: model.launcherDraft.text).map(\.pid) == [912])
            try await launcher.press(Self.escape)
            #expect(model.launcherDraft.text.isEmpty && model.showsSystemMonitor)
            try await launcher.press(Self.escape)
            #expect(!model.showsSystemMonitor)
            #expect(launcher.dismissed == 0)
        }
    }

    @Test func commandOMovesTheMonitorIntoItsWindow() async throws {
        try await withPasteboard { _ in
            let monitor = Monitor()
            let launcher = try await Launcher(text: "", prepare: monitor.install)
            defer {
                monitor.window.close()
                launcher.close()
            }
            let model = launcher.fixture.model
            try await typeMonitor("top ", into: launcher)
            #expect(model.showsSystemMonitor)
            try await launcher.press(Self.tab)
            try await launcher.press(Self.tab)
            try await launcher.press(31, .command)
            #expect(monitor.window.isOpen)
            #expect(monitor.window.settings.sort == .memory)
            #expect(launcher.dismissed == 1)
            #expect(!model.showsSystemMonitor)
        }
    }
}
