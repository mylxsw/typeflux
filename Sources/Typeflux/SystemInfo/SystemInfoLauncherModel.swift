import AppKit
import Foundation

/// The keys `sys` answers to in the launcher.
enum SystemInfoKey: Equatable {
    // swiftlint:disable:next identifier_name
    case up, down, enter, tab, shiftTab, escape
    /// ⌘1…⌘8: a section.
    case number(Int)
    /// ⌘C: the chosen row's value.
    case copy
    /// ⇧⌘C: the whole configuration as Markdown.
    case copyReport
}

/// What a key or click asks of the launcher beyond changing the view's own state.
enum SystemInfoEffect: Equatable {
    /// The view changed (or deliberately ignored the key); nothing else to do.
    case handled
    /// Not the view's key: the launcher handles it as usual.
    case unhandled
    case copy(String)
    case copyReport(String)
    /// The System Information app, for what `sys` leaves out.
    case openApp
    /// A section was picked while searching: the filter goes and the section shows.
    case showSection(SystemInfoSection)
}

/// The state of `sys` in the launcher: the section, the chosen row and which hidden
/// values the user chose to see.
@MainActor
final class SystemInfoLauncherModel: ObservableObject {
    @Published private(set) var section: SystemInfoSection = .overview
    @Published private(set) var selection: String?
    @Published private(set) var revealed: Set<String> = []

    /// Back to how `sys` opens: the overview, nothing chosen, everything hidden again.
    func reset() {
        section = .overview
        selection = nil
        revealed = []
    }

    func show(_ section: SystemInfoSection) {
        self.section = section
        selection = nil
    }

    func select(_ id: String?) {
        selection = id
    }

    func isRevealed(_ field: SystemInfoField) -> Bool {
        !field.sensitive || revealed.contains(field.id)
    }

    func toggleReveal(_ id: String) {
        if revealed.contains(id) {
            revealed.remove(id)
        } else {
            revealed.insert(id)
        }
    }

    /// The rows on screen: everything matching the filter, or the section's rows.
    func rows(_ snapshot: SystemInfoSnapshot?, filter: String) -> [SystemInfoField] {
        guard let snapshot else { return [] }
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            return SystemInfoSearch.filter(snapshot.fields, query: filter, revealed: revealed)
        }
        return section == .overview ? [] : snapshot.fields(in: section)
    }

    /// The chosen row, if it is still on screen.
    func selected(in rows: [SystemInfoField]) -> SystemInfoField? {
        selection.flatMap { id in rows.first { $0.id == id } }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ key: SystemInfoKey, snapshot: SystemInfoSnapshot?, filter: String) -> SystemInfoEffect {
        let rows = rows(snapshot, filter: filter)
        let chosen = selected(in: rows)
        let searching = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        switch key {
        case .up, .down:
            move(key == .down ? 1 : -1, rows: rows, from: chosen)
            return .handled
        case .tab, .shiftTab:
            guard let sections = snapshot?.sections, !searching else { return .handled }
            let index = sections.firstIndex(of: section) ?? 0
            let step = key == .tab ? 1 : sections.count - 1
            show(sections[(index + step) % sections.count])
            return .handled
        case let .number(number):
            guard let sections = snapshot?.sections, sections.indices.contains(number - 1) else { return .handled }
            show(sections[number - 1])
            return .handled
        case .enter:
            // Return copies the chosen row, or the first match while searching.
            guard let field = chosen ?? (searching ? rows.first : nil) else { return .handled }
            selection = field.id
            return .copy(field.value)
        case .copy:
            return chosen.map { .copy($0.value) } ?? .unhandled
        case .copyReport:
            guard let snapshot else { return .handled }
            return .copyReport(SystemInfoReport.markdown(snapshot))
        case .escape:
            if selection != nil {
                selection = nil
                return .handled
            }
            // The launcher clears a filter first; without one the section steps back to the overview.
            if !searching, section != .overview {
                show(.overview)
                return .handled
            }
            return .unhandled
        }
    }

    private func move(_ step: Int, rows: [SystemInfoField], from chosen: SystemInfoField?) {
        guard !rows.isEmpty else { return }
        guard let chosen, let index = rows.firstIndex(of: chosen) else {
            selection = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        selection = rows[max(0, min(rows.count - 1, index + step))].id
    }
}

/// The System Information app, for what `sys` leaves out.
enum SystemInformationApp {
    static let bundleIdentifier = "com.apple.SystemProfiler"

    static func url(workspace: NSWorkspace = .shared) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
