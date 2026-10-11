import AppKit
import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite("System monitor in the launcher")
@MainActor
struct SystemMonitorLauncherModelTests {
    typealias F = SystemMonitorFixtures

    /// A model whose clock the test moves and whose terminations are recorded.
    final class Recorder {
        var now = Date(timeIntervalSince1970: 1000)
        var signals: [(Int32, Int32)] = []
        var result: Int32 = 0
    }

    private func makeModel(_ recorder: Recorder = Recorder()) -> SystemMonitorLauncherModel {
        let model = SystemMonitorLauncherModel()
        model.now = { recorder.now }
        model.terminator = SystemProcessTerminator(currentUID: 501, ownPID: 3301, application: { _ in nil },
                                                   signal: { pid, signal in
                                                       recorder.signals.append((pid, signal))
                                                       return recorder.result
                                                   })
        return model
    }

    private var snapshot: SystemSnapshot { F.snapshot(processes: F.processes) }

    @Test func rowsFilterAndSortThenHoldStillWhileFrozen() {
        let recorder = Recorder()
        let model = makeModel(recorder)
        #expect(model.rows(nil, filter: "").isEmpty)
        #expect(model.rows(snapshot, filter: "").map(\.pid) == [4821, 912, 1288, 344, 511])
        #expect(model.rows(snapshot, filter: "chrome").map(\.pid) == [912])

        _ = model.rows(snapshot, filter: "")
        model.hoveringList = true
        var busier = F.processes
        busier[4].cpu = 99
        let held = F.snapshot(processes: busier)
        #expect(model.isFrozen)
        #expect(model.rows(held, filter: "").map(\.pid) == [4821, 912, 1288, 344, 511])
        // Values still change while the order holds.
        #expect(model.rows(held, filter: "").last?.cpu == 99)
        model.hoveringList = false
        #expect(model.rows(held, filter: "").first?.pid == 511)
    }

    @Test func arrowsChooseAndFreezeForAMoment() {
        let recorder = Recorder()
        let model = makeModel(recorder)
        let rows = model.rows(snapshot, filter: "")
        #expect(model.handle(.down, rows: rows) == .handled)
        #expect(model.selection == 4821)
        #expect(model.isFrozen)
        _ = model.handle(.down, rows: rows)
        _ = model.handle(.down, rows: rows)
        #expect(model.selection == 1288)
        _ = model.handle(.up, rows: rows)
        #expect(model.selection == 912)
        recorder.now = recorder.now.addingTimeInterval(SystemMonitorLauncherModel.freezeDuration + 0.1)
        #expect(!model.isFrozen)

        // Up from nothing chosen starts at the bottom; the ends hold.
        let fresh = makeModel()
        _ = fresh.handle(.up, rows: rows)
        #expect(fresh.selection == 511)
        _ = fresh.handle(.down, rows: rows)
        #expect(fresh.selection == 511)
        #expect(fresh.handle(.down, rows: []) == .handled)
        #expect(fresh.selected(in: []) == nil)
    }

    @Test func cardsFocusWithTabNumbersAndClicks() {
        let model = makeModel()
        _ = model.handle(.tab, rows: [])
        #expect(model.focus == .cpu && model.sort == .cpu)
        _ = model.handle(.tab, rows: [])
        #expect(model.focus == .memory && model.sort == .memory)
        _ = model.handle(.tab, rows: [])
        _ = model.handle(.tab, rows: [])
        #expect(model.focus == .network && model.sort == .disk)
        _ = model.handle(.tab, rows: [])
        #expect(model.focus == nil)
        _ = model.handle(.shiftTab, rows: [])
        #expect(model.focus == .network)
        #expect(model.handle(.number(3), rows: []) == .handled)
        #expect(model.focus == .disk)
        _ = model.handle(.number(3), rows: [])
        #expect(model.focus == nil)
        #expect(model.handle(.number(9), rows: []) == .handled)
        #expect(model.focus == nil)
        model.toggleFocus(.memory)
        #expect(model.focus == .memory)
    }

    @Test func returnSwitchesAndCopyTakesThePID() {
        let model = makeModel()
        let rows = model.rows(snapshot, filter: "")
        #expect(model.handle(.enter, rows: rows) == .handled)
        #expect(model.handle(.copy, rows: rows) == .unhandled)
        model.select(912)
        #expect(model.handle(.enter, rows: rows) == .activate(rows[1]))
        #expect(model.handle(.copy, rows: rows) == .copy("912"))
        #expect(model.handle(.popOut, rows: rows) == .popOut)
        // A chosen process that went away is no longer chosen.
        #expect(model.handle(.enter, rows: [rows[0]]) == .handled)
    }

    @Test func endingAProcessAsksFirst() {
        let recorder = Recorder()
        let model = makeModel(recorder)
        let rows = model.rows(snapshot, filter: "")
        #expect(model.handle(.terminate(force: false), rows: rows) == .unhandled)
        model.select(4821)
        #expect(model.handle(.terminate(force: true), rows: rows) == .handled)
        #expect(model.confirming == .init(pid: 4821, force: true))
        #expect(model.isFrozen)
        // Other keys wait for the answer.
        #expect(model.handle(.down, rows: rows) == .handled)
        #expect(model.selection == 4821)
        #expect(model.handle(.escape, rows: rows) == .handled)
        #expect(model.confirming == nil && recorder.signals.isEmpty)

        _ = model.handle(.terminate(force: false), rows: rows)
        #expect(model.handle(.enter, rows: rows) == .terminated(rows[0], success: true))
        #expect(recorder.signals.count == 1 && recorder.signals[0].0 == 4821 && recorder.signals[0].1 == SIGTERM)
        #expect(model.selection == nil && model.confirming == nil)

        recorder.result = -1
        model.select(912)
        _ = model.handle(.terminate(force: true), rows: rows)
        #expect(model.handle(.enter, rows: rows) == .terminated(rows[1], success: false))
        #expect(recorder.signals.last?.1 == SIGKILL)
        #expect(model.selection == 912)

        _ = model.handle(.terminate(force: false), rows: rows)
        #expect(model.handle(.popOut, rows: rows) == .popOut)
        #expect(model.confirming == nil)

        // The process ended on its own before the answer.
        _ = model.handle(.terminate(force: false), rows: rows)
        #expect(model.handle(.enter, rows: []) == .handled)
        model.cancelConfirmation()
    }

    @Test func systemProcessesAreRefused() {
        let model = makeModel()
        let rows = model.rows(snapshot, filter: "")
        model.select(344)
        #expect(model.handle(.terminate(force: false), rows: rows) == .refused(rows[3], .system))
        #expect(model.confirming == nil)
    }

    @Test func escapeStepsBackOneLayerAtATime() {
        let model = makeModel()
        let rows = model.rows(snapshot, filter: "")
        model.setFocus(.cpu)
        model.select(912)
        #expect(model.handle(.escape, rows: rows) == .handled)
        #expect(model.selection == nil && model.focus == .cpu)
        #expect(model.handle(.escape, rows: rows) == .handled)
        #expect(model.focus == nil)
        #expect(model.handle(.escape, rows: rows) == .unhandled)
    }

    @Test func resetStartsOver() {
        let model = makeModel()
        model.setFocus(.memory)
        model.select(1)
        model.hoveringList = true
        model.sort = .disk
        model.reset()
        #expect(model.focus == nil && model.sort == .cpu && model.selection == nil && !model.isFrozen)
    }
}

@Suite("Ending processes from the monitor")
@MainActor
struct SystemProcessTerminatorTests {
    typealias F = SystemMonitorFixtures

    @Test func onlyTheUsersOwnProcesses() {
        let terminator = SystemProcessTerminator(currentUID: 501, ownPID: 3301)
        #expect(terminator.eligibility(of: F.systemProcess(912, "Chrome", cpu: 1)) == .allowed)
        #expect(terminator.eligibility(of: F.systemProcess(3301, "Typeflux", cpu: 1)) == .typeflux)
        #expect(terminator.eligibility(of: F.systemProcess(0, "kernel_task", cpu: 1, uid: 0)) == .system)
        #expect(terminator.eligibility(of: F.systemProcess(1, "launchd", cpu: 1, uid: 501)) == .system)
        #expect(terminator.eligibility(of: F.systemProcess(344, "WindowServer", cpu: 1, uid: 88)) == .system)
        #expect(terminator.eligibility(of: F.systemProcess(500, "root", cpu: 1, uid: 0)) == .system)
    }

    @Test func signalsOrRefuses() {
        var sent: [(Int32, Int32)] = []
        var terminator = SystemProcessTerminator(currentUID: 501, ownPID: 3301, application: { _ in nil },
                                                 signal: { sent.append(($0, $1)); return 0 })
        #expect(terminator.terminate(F.systemProcess(912, "Chrome", cpu: 1), force: false))
        #expect(terminator.terminate(F.systemProcess(913, "x", cpu: 1), force: true))
        #expect(!terminator.terminate(F.systemProcess(3301, "Typeflux", cpu: 1), force: true))
        #expect(sent.map(\.0) == [912, 913] && sent.map(\.1) == [SIGTERM, SIGKILL])
        terminator.signal = { _, _ in -1 }
        #expect(!terminator.terminate(F.systemProcess(912, "Chrome", cpu: 1), force: false))
    }

    @Test func endsARealChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let process = F.systemProcess(child.processIdentifier, "sleep", cpu: 0, uid: getuid())
        #expect(SystemProcessTerminator().terminate(process, force: false))
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
        #expect(SystemProcessActions.executablePath(child.processIdentifier) == nil)
        #expect(SystemProcessActions.executablePath(getpid())?.isEmpty == false)
        #expect(!SystemProcessActions.activate(child.processIdentifier))
    }
}
