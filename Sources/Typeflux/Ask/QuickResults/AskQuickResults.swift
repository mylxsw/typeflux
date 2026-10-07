import AppKit

/// What the launcher shows under its controls when the text has a local
/// answer: a calculation with other ways to write it, or applications to open,
/// and always the way back to the AI. Later sources (documents, conversations) join here.
struct AskQuickResults: Equatable {
    enum Row: Equatable {
        case calculation
        case format(Int)
        case app(Int)
        case askAI
    }

    /// Set for arithmetic; then `apps` is empty.
    var calculation: AskCalculation?
    var formats: [AskCalculatorFormat] = []
    var apps: [AskAppMatch] = []
    /// The top application clearly matches, so it leads and takes Return;
    /// otherwise "Ask AI" leads and the applications follow it.
    var appsLead = false
    /// The expression being typed while the last result stays on screen, dimmed.
    var pendingExpression: String?
    var highlighted = 0
    /// The highlight was moved by the user rather than placed by default.
    var chosen = false

    init(calculation: AskCalculation, formats: [AskCalculatorFormat], pendingExpression: String? = nil) {
        self.calculation = calculation
        self.formats = formats
        self.pendingExpression = pendingExpression
        highlighted = calculation.number == nil ? formats.count + 1 : 0
    }

    init(apps: [AskAppMatch], lead: Bool) {
        self.apps = apps
        appsLead = lead
    }

    var rows: [Row] {
        if calculation != nil { return [.calculation] + formats.indices.map(Row.format) + [.askAI] }
        let appRows = apps.indices.map(Row.app)
        return appsLead ? appRows + [.askAI] : [.askAI] + appRows
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
        case .app, .askAI: nil
        }
    }

    func app(at row: Row) -> AskAppEntry? {
        guard case let .app(index) = row, apps.indices.contains(index) else { return nil }
        return apps[index].entry
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

    /// The results for the launcher's new text. Arithmetic goes to the
    /// calculator; other text is matched against applications when `apps` is given.
    /// `previous` keeps the last answer on screen while an expression is
    /// unfinished, and keeps a row the user chose while the text changes.
    static func resolve(text: String, previous: AskQuickResults?, chinese: Bool,
                        calculator: Bool = true, apps: (any AskAppSearching)? = nil) -> AskQuickResults? {
        let reading = calculator ? AskCalculator.read(text) : .notExpression
        switch reading {
        case .notExpression:
            guard let apps else { return nil }
            let matches = apps.search(text, limit: 5)
            guard !matches.isEmpty else { return nil }
            var results = AskQuickResults(apps: matches, lead: AskAppMatcher.isStrong(matches.first, query: text))
            results.keepChoice(from: previous)
            return results
        case let .incomplete(expression):
            guard var kept = previous, kept.calculation?.number != nil else { return nil }
            kept.pendingExpression = expression
            return kept
        case let .calculation(calculation):
            let formats = calculation.number.map {
                AskCalculatorFormats.formats(for: $0, radix: calculation.radix, chinese: chinese)
            } ?? []
            var results = AskQuickResults(calculation: calculation, formats: formats)
            results.keepChoice(from: previous)
            return results
        }
    }

    /// Highlights the row the user chose in `previous`, if it is still here:
    /// the same spelling, the same application, or "Ask AI".
    private mutating func keepChoice(from previous: AskQuickResults?) {
        guard let previous, previous.chosen else { return }
        let target: Row?
        switch previous.highlightedRow {
        case .askAI: target = .askAI
        case let .format(index): target = index < formats.count ? .format(index) : nil
        case .calculation: target = calculation?.number != nil ? .calculation : nil
        case .app:
            let id = previous.app(at: previous.highlightedRow)?.id
            target = apps.firstIndex { $0.entry.id == id }.map(Row.app)
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
