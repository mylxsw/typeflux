import AppKit

/// What the launcher shows under its controls when the text has a local
/// answer: a calculation with other ways to write it, or applications, System
/// Settings panes, files and folders to open, and always the way back to the AI.
/// See `docs/design/launcher-content-search.md` §2.
struct AskQuickResults: Equatable {
    enum Row: Equatable {
        case calculation
        case feature(Int)
        case browser(Int)
        case format(Int)
        case app(Int)
        case pane(Int)
        /// A file or folder in `files`.
        case file(Int)
        /// "Show all N files": opens file mode with the same text.
        case showAllFiles
        case askAI
    }

    /// A kind of result, listed together under one heading.
    enum Group: Equatable, CaseIterable {
        case apps, panes, files, folders
    }

    /// Said above the files while the index cannot answer fully yet.
    enum Notice: Equatable {
        case indexing(found: Int, progress: Double?)
    }

    /// Pure numbers offer conversions alongside search; arithmetic has only calculation rows.
    var calculation: AskCalculation?
    var formats: [AskCalculatorFormat] = []
    var features: [AskLauncherSearchEntry] = []
    var browserEntries: [AskBrowserSearchEntry] = []
    var apps: [AskAppMatch] = []
    var panes: [AskAppMatch] = []
    /// Files first, then folders, each best first.
    var files: [AskFileHit] = []
    /// More files matched than are listed: "Show all" offers them.
    var moreFiles = false
    /// Applications precede files unless file-first mode was explicitly selected.
    var groups: [Group] = []
    /// The clear winner, listed first and taking Return. Without one "Ask AI" takes Return from its fixed footer.
    var best: Row?
    var notice: Notice?
    /// The expression being typed while the last result stays on screen, dimmed.
    var pendingExpression: String?
    var highlighted = 0
    /// The highlight was moved by the user rather than placed by default.
    var chosen = false

    /// A match leads and takes Return (the name is kept from when only applications were listed).
    var appsLead: Bool { best != nil }

    init(calculation: AskCalculation, formats: [AskCalculatorFormat], pendingExpression: String? = nil) {
        self.calculation = calculation
        self.formats = formats
        self.pendingExpression = pendingExpression
        highlighted = calculation.number == nil ? formats.count + 1 : 0
    }

    init(apps: [AskAppMatch], lead: Bool) {
        self.apps = apps
        groups = apps.isEmpty ? [] : [.apps]
        best = lead && !apps.isEmpty ? .app(0) : nil
        highlighted = best == nil ? rows.count - 1 : 0
    }

    init(apps: [AskAppMatch], panes: [AskAppMatch], files: [AskFileHit], moreFiles: Bool, groups: [Group],
         best: Row?, notice: Notice? = nil) {
        self.apps = apps
        self.panes = panes
        self.files = files
        self.moreFiles = moreFiles
        self.groups = groups
        self.best = best
        self.notice = notice
        highlighted = best == nil ? rows.count - 1 : 0
    }

    var rows: [Row] {
        var listed: [Row] = features.indices.map(Row.feature)
        for group in groups {
            switch group {
            case .apps: listed += apps.indices.map(Row.app)
            case .panes: listed += panes.indices.map(Row.pane)
            case .files:
                listed += files.indices.filter { !files[$0].isFolder }.map(Row.file)
                if moreFiles { listed.append(.showAllFiles) }
            case .folders: listed += files.indices.filter { files[$0].isFolder }.map(Row.file)
            }
        }
        listed += browserEntries.indices.map(Row.browser)
        if let best { listed = [best] + listed.filter { $0 != best } }
        let conversions: [Row] = calculation == nil ? [] : [.calculation] + formats.indices.map(Row.format)
        return conversions + listed + [.askAI]
    }

    func identity(of row: Row) -> String {
        switch row {
        case let .browser(index): return "browser:" + browserEntries[index].id
        case let .feature(index): return "feature:" + features[index].id
        case let .app(index): return "app:" + apps[index].entry.id
        case let .pane(index): return "pane:" + panes[index].entry.id
        case let .file(index): return "file:" + files[index].path
        case let .format(index): return "format:\(index)"
        case .calculation: return "calculation"
        case .showAllFiles: return "showAllFiles"
        case .askAI: return "askAI"
        }
    }

    var highlightedRow: Row { rows[min(max(0, highlighted), rows.count - 1)] }
    var stale: Bool { pendingExpression != nil }

    /// A failed calculation has nothing to copy.
    func isEnabled(_ row: Row) -> Bool {
        row == .calculation ? calculation?.number != nil : true
    }

    /// The text a row copies.
    func value(of row: Row) -> String? {
        switch row {
        case .calculation: calculation?.number?.copyText
        case let .format(index): formats.indices.contains(index) ? formats[index].value : nil
        case .feature, .browser, .app, .pane, .file, .showAllFiles, .askAI: nil
        }
    }

    func app(at row: Row) -> AskAppEntry? {
        switch row {
        case let .app(index): apps.indices.contains(index) ? apps[index].entry : nil
        case let .pane(index): panes.indices.contains(index) ? panes[index].entry : nil
        default: nil
        }
    }

    func match(at row: Row) -> AskAppMatch? {
        switch row {
        case let .app(index): apps.indices.contains(index) ? apps[index] : nil
        case let .pane(index): panes.indices.contains(index) ? panes[index] : nil
        default: nil
        }
    }

    func file(at row: Row) -> AskFileHit? {
        guard case let .file(index) = row, files.indices.contains(index) else { return nil }
        return files[index]
    }

    /// Moves the highlight, wrapping at both ends and passing over rows that cannot run.
    mutating func move(_ delta: Int) {
        let count = rows.count
        var next = highlighted
        for _ in 0 ..< count {
            next = ((next + delta) % count + count) % count
            if isEnabled(rows[next]) { highlighted = next; chosen = true; return }
        }
    }

    /// Highlights a row under the pointer, unless it cannot run.
    mutating func highlight(_ index: Int) {
        guard rows.indices.contains(index), isEnabled(rows[index]) else { return }
        highlighted = index
        chosen = true
    }

    /// What the launcher searches besides the calculator.
    struct Sources {
        var apps: (any AskAppSearching)?
        var files: (any AskFileSearching)?
        var settings = AskLauncherSearchSettings()
        var entries: [AskLauncherSearchEntry] = []
        var browsers: (any AskBrowserSearching)?
        var browserSettings = AskBrowserSearchSettings()
    }

    /// At most this many of each kind in the launcher; files beyond it are behind "Show all".
    static let appLimit = 5
    static let paneLimit = 3
    static let fileLimit = 6
    static let folderLimit = 3
    /// A file needs this much to lead (an exact name, its start, initials or pinyin)…
    static let strongFileScore = 0.88
    /// …and to be this far ahead of the next result, so similar names do not take Return.
    static let fileMargin = 0.05

    /// The results for the launcher's new text. Arithmetic goes to the
    /// calculator; pure numbers also search applications and files.
    /// `previous` keeps the last answer on screen while an expression is
    /// unfinished, and keeps a row the user chose while the text changes.
    static func resolve(text: String, previous: AskQuickResults?, chinese: Bool,
                        calculator: Bool = true, numberConversions: Bool = true, apps: (any AskAppSearching)? = nil) -> AskQuickResults? {
        resolve(text: text, previous: previous, chinese: chinese, calculator: calculator,
                numberConversions: numberConversions, sources: Sources(apps: apps))
    }

    static func resolve(text: String, previous: AskQuickResults?, chinese: Bool, calculator: Bool,
                        numberConversions: Bool = true, sources: Sources) -> AskQuickResults? {
        let reading = AskCalculator.read(text, arithmetic: calculator, numberConversions: numberConversions)
        switch reading {
        case .notExpression:
            guard var results = search(text, sources: sources) else { return nil }
            results.keepChoice(from: previous)
            return results
        case let .incomplete(expression):
            guard let previous, let calculation = previous.calculation, calculation.number != nil,
                  !calculation.isNumericInput || numberConversions else { return nil }
            var kept = AskQuickResults(calculation: calculation, formats: previous.formats, pendingExpression: expression)
            kept.keepChoice(from: previous)
            return kept
        case let .calculation(calculation):
            let formats = calculation.number.map {
                calculation.isNumericInput ? AskNumberConversions.formats(for: $0)
                    : AskCalculatorFormats.formats(for: $0, radix: calculation.radix, chinese: chinese)
            } ?? []
            var results = AskQuickResults(calculation: calculation, formats: formats)
            if calculation.isNumericInput {
                results = addingNumberConversions(results, to: search(text, sources: sources)) ?? results
            }
            results.keepChoice(from: previous)
            return results
        }
    }

    /// Conversions lead and take Return by default; search keeps its own ordering below them.
    static func addingNumberConversions(_ number: AskQuickResults?, to search: AskQuickResults?) -> AskQuickResults? {
        guard let number, let calculation = number.calculation else { return search }
        guard var combined = search else { return number }
        combined.calculation = calculation
        combined.formats = number.formats
        combined.highlighted = 0
        return combined
    }

    /// Applications, panes, files and folders for `text`, grouped and with the best one picked.
    static func search(_ text: String, sources: Sources) -> AskQuickResults? {
        let query = AskSearchQuery(text)
        guard query.isSearchable || query.hasFilters else { return nil }
        let matches = !query.hasFilters ? sources.apps?.search(text, limit: appLimit + paneLimit + 4) ?? [] : []
        let hits = sources.files?.search(query, options: .init(limit: 24, fuzzy: sources.settings.fuzzy)) ?? []
        return assemble(text, matches: matches, hits: hits, status: sources.files?.status, settings: sources.settings, entries: sources.entries)
    }

    /// Pure presentation policy shared by synchronous callers and staged search.
    static func assemble(_ text: String, matches: [AskAppMatch], hits: [AskFileHit],
                         status: AskFileIndexStatus?, settings: AskLauncherSearchSettings,
                         entries: [AskLauncherSearchEntry] = []) -> AskQuickResults? {
        let features = AskLauncherSearchEntry.search(entries, text: text)
        let apps = Array(matches.filter { $0.entry.kind == .application }.prefix(appLimit))
        let panes = Array(matches.filter { $0.entry.kind == .settingsPane }.prefix(paneLimit))
        let plain = hits.filter { !$0.isFolder }
        let files = Array(plain.prefix(fileLimit))
        let folders = Array(hits.filter(\.isFolder).prefix(folderLimit))
        let moreFiles = plain.count > fileLimit
        var notice: Notice?
        if let status, case let .building(found, _) = status.phase {
            notice = .indexing(found: found, progress: status.progress)
        }
        if status?.phase == .loading { notice = .indexing(found: 0, progress: nil) }
        // A question does not need the index's progress; a file's name, files found or files first do.
        if notice != nil, files.isEmpty, folders.isEmpty, settings.mode != .filesFirst,
           !AskSearchQuery(text).hasFilters, !looksLikeName(text) {
            notice = nil
        }
        guard !features.isEmpty || !apps.isEmpty || !panes.isEmpty || !files.isEmpty || !folders.isEmpty || notice != nil else { return nil }
        var groups: [(group: Group, top: Double)] = []
        if let top = apps.first?.score { groups.append((.apps, top)) }
        if let top = panes.first?.score { groups.append((.panes, top)) }
        if let top = files.first?.score { groups.append((.files, top)) }
        if let top = folders.first?.score { groups.append((.folders, top)) }
        let order: (Group) -> Int = { group in
            let fileGroup = group == .files || group == .folders
            switch settings.mode {
            case .mixed, .appsFirst:
                return group == .apps ? 0 : (group == .panes ? 1 : (group == .files ? 2 : 3))
            case .filesFirst: return fileGroup ? (group == .files ? 0 : 1) : (group == .apps ? 2 : 3)
            }
        }
        groups.sort { lhs, rhs in
            order(lhs.group) != order(rhs.group) ? order(lhs.group) < order(rhs.group) : lhs.top > rhs.top
        }
        let listed = files + folders
        let best: Row?
        if settings.mode != .filesFirst, !apps.isEmpty || !panes.isEmpty {
            best = bestRow(text, apps: apps, panes: apps.isEmpty ? panes : [], files: [])
        } else {
            best = bestRow(text, apps: apps, panes: panes, files: listed)
        }
        var result = AskQuickResults(apps: apps, panes: panes, files: listed, moreFiles: moreFiles, groups: groups.map(\.group),
                                     best: features.isEmpty ? best : .feature(0), notice: notice)
        result.features = features
        result.highlighted = result.best == nil ? result.rows.count - 1 : 0
        return result
    }

    static func addingBrowsers(_ entries: [AskBrowserSearchEntry], to base: AskQuickResults?) -> AskQuickResults? {
        guard !entries.isEmpty else { return base }
        var result = base ?? AskQuickResults(apps: [], lead: false)
        let previous = result
        result.browserEntries = entries
        result.highlighted = result.calculation?.isNumericInput == true || result.best != nil ? 0 : result.rows.count - 1
        result.keepChoice(from: previous)
        return result
    }

    /// Whether `text` reads like the name of a file rather than a question: short,
    /// a few words, no sentence punctuation, and no run of Chinese, Japanese or
    /// Korean longer than a short name.
    static func looksLikeName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, trimmed.split(whereSeparator: \.isWhitespace).count <= 3,
              !trimmed.contains(where: { "?？。，,!！:：;；".contains($0) }) else { return false }
        var run = 0
        for scalar in trimmed.unicodeScalars {
            run = scalar.properties.isIdeographic || (0xAC00 ... 0xD7AF).contains(scalar.value)
                || (0x3040 ... 0x30FF).contains(scalar.value) ? run + 1 : 0
            if run > 6 { return false }
        }
        return true
    }

    /// The result that clearly answers a short query, if one does. Applications
    /// keep the rule they always had; a file must also stand out from the rest.
    static func bestRow(_ text: String, apps: [AskAppMatch], panes: [AskAppMatch], files: [AskFileHit]) -> Row? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.split(separator: " ").count <= 3,
              !trimmed.contains(where: { "?？。，,!！:：;；".contains($0) }) else { return nil }
        var candidates: [(row: Row, score: Double, app: Bool)] = []
        if let app = apps.first { candidates.append((.app(0), app.score, true)) }
        if let pane = panes.first { candidates.append((.pane(0), pane.score, true)) }
        for (index, file) in files.enumerated() { candidates.append((.file(index), file.score, false)) }
        // Applications win a tie; then the order they came in.
        candidates.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.app && !rhs.app }
        guard let first = candidates.first else { return nil }
        if first.app { return first.score >= AskAppMatcher.strongScore ? first.row : nil }
        // The file's own match, without what recency and use added.
        guard case let .file(index) = first.row, files[index].match >= strongFileScore else { return nil }
        let second = candidates.dropFirst().first?.score ?? 0
        return first.score - second >= fileMargin ? first.row : nil
    }

    /// Highlights the row the user chose in `previous`, if it is still here:
    /// the same spelling, application, file, or "Ask AI".
    mutating func keepChoice(from previous: AskQuickResults?) {
        guard let previous, previous.chosen else { return }
        let target: Row?
        switch previous.highlightedRow {
        case let .feature(index):
            let id = previous.features.indices.contains(index) ? previous.features[index].id : nil
            target = features.firstIndex { $0.id == id }.map(Row.feature)
        case let .browser(index):
            let id = previous.browserEntries.indices.contains(index) ? previous.browserEntries[index].id : nil
            target = browserEntries.firstIndex { $0.id == id }.map(Row.browser)
        case .askAI: target = .askAI
        case .showAllFiles: target = moreFiles ? .showAllFiles : nil
        case let .format(index): target = index < formats.count ? .format(index) : nil
        case .calculation: target = calculation?.number != nil ? .calculation : nil
        case .app:
            let id = previous.app(at: previous.highlightedRow)?.id
            target = apps.firstIndex { $0.entry.id == id }.map(Row.app)
        case .pane:
            let id = previous.app(at: previous.highlightedRow)?.id
            target = panes.firstIndex { $0.entry.id == id }.map(Row.pane)
        case .file:
            let path = previous.file(at: previous.highlightedRow)?.path
            target = files.firstIndex { $0.path == path }.map(Row.file)
        }
        guard let target, let index = rows.firstIndex(of: target) else { return }
        highlighted = index
        chosen = true
    }

    /// Where results are copied. Tests point it at a private pasteboard.
    @MainActor static var pasteboard = NSPasteboard.general

    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard? = nil) {
        let target = pasteboard ?? Self.pasteboard
        target.clearContents()
        target.setString(text, forType: .string)
    }

    /// Puts the image at `url` on the pasteboard as one item: the image itself, for
    /// apps that paste pictures, and the file, for Finder. False when it is not an image.
    @MainActor @discardableResult
    static func copyImage(_ url: URL, to pasteboard: NSPasteboard? = nil) -> Bool {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return false }
        let target = pasteboard ?? Self.pasteboard
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        target.clearContents()
        target.writeObjects([item])
        return true
    }
}
