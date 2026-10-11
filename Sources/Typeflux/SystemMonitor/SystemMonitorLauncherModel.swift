import AppKit
import Foundation

/// The keys the monitor answers to in the launcher.
enum SystemMonitorKey: Equatable {
    case up, down, enter, tab, shiftTab, escape
    /// ⌘1...⌘4: focus a card.
    case number(Int)
    /// ⌘C: copy the chosen process's PID.
    case copy
    /// ⌘O: move the monitor into its own window.
    case popOut
    /// ⌘⌫, with ⌥ to force.
    case terminate(force: Bool)
}

/// What a key asks of the launcher beyond changing the monitor's own state.
enum SystemMonitorEffect: Equatable {
    /// The monitor changed (or deliberately ignored the key); nothing else to do.
    case handled
    /// The key is not the monitor's: the launcher handles it as usual.
    case unhandled
    /// Switch to the app, or show the program in Finder.
    case activate(SystemProcess)
    case copy(String)
    case popOut
    case terminated(SystemProcess, success: Bool)
    /// The process may not be ended here.
    case refused(SystemProcess, SystemProcessTerminator.Eligibility)
}

/// The monitor's state in the launcher: what is focused, how processes sort,
/// which one is chosen and whether ending it waits for confirmation.
@MainActor
final class SystemMonitorLauncherModel: ObservableObject {
    struct Confirmation: Equatable {
        var pid: Int32
        var force: Bool
    }

    /// How long rows stay put after the arrows move, so the next press hits what the user saw.
    static let freezeDuration: TimeInterval = 3

    @Published private(set) var focus: SystemMonitorMetric?
    @Published var sort: SystemMonitorSort = .cpu {
        didSet { if sort != oldValue { frozen = [] } }
    }
    @Published private(set) var selection: Int32?
    @Published private(set) var confirming: Confirmation?
    /// The pointer is over the list: rows stop moving.
    @Published var hoveringList = false

    var terminator = SystemProcessTerminator()
    var now: () -> Date = Date.init
    private var frozen: [Int32] = []
    private var freezeUntil = Date.distantPast

    /// Rows hold their places while pointed at, chosen with the arrows a moment ago, or confirming.
    var isFrozen: Bool { hoveringList || confirming != nil || now() < freezeUntil }

    /// Back to how the monitor opens.
    func reset() {
        focus = nil
        sort = .cpu
        selection = nil
        confirming = nil
        hoveringList = false
        frozen = []
        freezeUntil = .distantPast
    }

    /// The rows to show: filtered and sorted, or in the order they had while frozen.
    func rows(_ snapshot: SystemSnapshot?, filter: String) -> [SystemProcess] {
        let filtered = SystemMonitorProcessList.filter(snapshot?.processes ?? [], query: filter)
        let sorted = SystemMonitorProcessList.sorted(filtered, by: sort)
        if isFrozen, !frozen.isEmpty { return SystemMonitorProcessList.holding(sorted, in: frozen) }
        frozen = sorted.map(\.pid)
        return sorted
    }

    /// A click on a card, or ⌘1...⌘4: focus it, or unfocus it when it already is.
    func toggleFocus(_ metric: SystemMonitorMetric) {
        setFocus(focus == metric ? nil : metric)
    }

    func setFocus(_ metric: SystemMonitorMetric?) {
        focus = metric
        if let metric, let sort = SystemMonitorSort(focus: metric) { self.sort = sort }
    }

    /// ⇥ goes CPU → memory → disk → network → none; ⇧⇥ the other way.
    func cycleFocus(_ step: Int) {
        let cycle: [SystemMonitorMetric?] = [nil] + SystemMonitorMetric.allCases
        let index = cycle.firstIndex(of: focus) ?? 0
        setFocus(cycle[((index + step) % cycle.count + cycle.count) % cycle.count])
    }

    /// A click on a row.
    func select(_ pid: Int32?) {
        selection = pid
        confirming = nil
        freeze()
    }

    func cancelConfirmation() { confirming = nil }

    private func freeze() { freezeUntil = now().addingTimeInterval(Self.freezeDuration) }

    /// The chosen process, if it is still on screen.
    func selected(in rows: [SystemProcess]) -> SystemProcess? {
        selection.flatMap { pid in rows.first { $0.pid == pid } }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ key: SystemMonitorKey, rows: [SystemProcess]) -> SystemMonitorEffect {
        let chosen = selected(in: rows)
        if let confirming {
            switch key {
            case .enter:
                self.confirming = nil
                guard let process = rows.first(where: { $0.pid == confirming.pid }) else { return .handled }
                let success = terminator.terminate(process, force: confirming.force)
                if success { selection = nil }
                return .terminated(process, success: success)
            case .escape:
                self.confirming = nil
                return .handled
            case .popOut:
                self.confirming = nil
                return .popOut
            default:
                // Nothing else happens until the question is answered.
                return .handled
            }
        }
        switch key {
        case .up, .down:
            move(key == .down ? 1 : -1, rows: rows, from: chosen)
            return .handled
        case .tab:
            cycleFocus(1)
            return .handled
        case .shiftTab:
            cycleFocus(-1)
            return .handled
        case let .number(number):
            guard let metric = SystemMonitorMetric(number: number) else { return .handled }
            toggleFocus(metric)
            return .handled
        case .enter:
            return chosen.map(SystemMonitorEffect.activate) ?? .handled
        case .copy:
            return chosen.map { .copy(String($0.pid)) } ?? .unhandled
        case .popOut:
            return .popOut
        case let .terminate(force):
            guard let chosen else { return .unhandled }
            let eligibility = terminator.eligibility(of: chosen)
            guard eligibility == .allowed else { return .refused(chosen, eligibility) }
            confirming = Confirmation(pid: chosen.pid, force: force)
            return .handled
        case .escape:
            if selection != nil {
                selection = nil
                return .handled
            }
            if focus != nil {
                setFocus(nil)
                return .handled
            }
            return .unhandled
        }
    }

    private func move(_ step: Int, rows: [SystemProcess], from chosen: SystemProcess?) {
        guard !rows.isEmpty else { return }
        freeze()
        guard let chosen, let index = rows.firstIndex(of: chosen) else {
            selection = (step > 0 ? rows.first : rows.last)?.pid
            return
        }
        selection = rows[max(0, min(rows.count - 1, index + step))].pid
    }
}

/// Switching to a process: apps come to the front, other programs show in Finder.
enum SystemProcessActions {
    /// False when the process is gone or its program cannot be found.
    @MainActor
    @discardableResult
    static func activate(_ pid: Int32, workspace: NSWorkspace = .shared) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app.activate(options: [])
        }
        guard let path = executablePath(pid) else { return false }
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
