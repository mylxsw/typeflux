import SwiftUI

/// The list's layout, kept apart from its views: headings, heights and the hint,
/// and how names, dates and places read.
extension AskQuickResultsView {
    static func section(of row: AskQuickResults.Row, in results: AskQuickResults? = nil) -> Section {
        switch row {
        case .calculation, .format: .calculation
        case .app: .apps
        case .pane: .panes
        case .file: results?.file(at: row)?.isFolder == true ? .folders : .files
        case .showAllFiles: .files
        case .askAI: .ai
        }
    }

    /// The heading shown above the row at `index`: where a new kind of result begins.
    /// The best match, when there is one, has a heading of its own.
    static func sectionStart(at index: Int, in rows: [AskQuickResults.Row], results: AskQuickResults? = nil) -> Section? {
        guard rows.indices.contains(index) else { return nil }
        func section(_ position: Int) -> Section {
            if position == 0, let best = results?.best, rows[0] == best { return .best }
            return Self.section(of: rows[position], in: results)
        }
        return index == 0 || section(index - 1) != section(index) ? section(index) : nil
    }

    static func rowHeight(_ row: AskQuickResults.Row) -> CGFloat {
        switch row {
        case .calculation: calculationHeight
        case .format: formatHeight
        case .app, .pane: appHeight
        case .file: fileHeight
        case .showAllFiles: moreHeight
        case .askAI: askHeight
        }
    }

    /// Everything this list adds to the launcher card, up to `maximumHeight`.
    static func height(for results: AskQuickResults) -> CGFloat {
        min(maximumHeight, contentHeight(for: results))
    }

    static func contentHeight(for results: AskQuickResults) -> CGFloat {
        let rows = results.rows
        let content = rows.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        let sections = CGFloat(rows.indices.filter { sectionStart(at: $0, in: rows, results: results) != nil }.count)
        let notice = results.notice == nil ? 0 : noticeHeight + rowSpacing
        return 1 + listPadding * 2 + content + CGFloat(max(0, rows.count - 1)) * rowSpacing
            + sections * (sectionHeight + rowSpacing) + notice
    }

    /// Return copies a calculation, opens an application or file, or sends to the AI.
    static func hint(for results: AskQuickResults) -> String {
        switch results.highlightedRow {
        case .askAI: L("ask.launcher.hint")
        case .app, .pane: L("ask.quick.hint.app")
        case .file: L("ask.quick.hint.file")
        case .showAllFiles: L("ask.quick.hint.showAll")
        case .calculation, .format: L("ask.quick.hint")
        }
    }

    /// `name` with the characters in `ranges` bold and in the accent color.
    static func marked(_ name: String, _ ranges: [Range<Int>]) -> Text {
        guard !ranges.isEmpty else { return Text(name) }
        let characters = Array(name)
        var parts: [Text] = []
        var position = 0
        for range in ranges where range.lowerBound >= position && range.upperBound <= characters.count {
            if range.lowerBound > position { parts.append(Text(String(characters[position ..< range.lowerBound]))) }
            parts.append(Text(String(characters[range])).bold().foregroundColor(AskTheme.accent))
            position = range.upperBound
        }
        if position < characters.count { parts.append(Text(String(characters[position...]))) }
        return parts.reduce(Text(""), +)
    }

    /// "Today", "Yesterday", "3 days ago": when a file last changed.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return L("ask.quick.file.today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L("ask.quick.file.yesterday")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "/Applications", "~/Applications/Chrome Apps" or "System": where the application is installed.
    static func location(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        if folder.hasPrefix("/System/") { return L("ask.quick.app.system") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
