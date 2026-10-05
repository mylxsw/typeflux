import AppKit

/// What the launcher shows under its controls when the text has a local
/// answer: the calculation, other ways to write it, and the way back to the AI.
/// Later sources (apps, documents, conversations) join here.
struct AskQuickResults: Equatable {
    enum Row: Equatable {
        case calculation
        case format(Int)
        case askAI
    }

    var calculation: AskCalculation
    var formats: [AskCalculatorFormat]
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

    var rows: [Row] { [.calculation] + formats.indices.map(Row.format) + [.askAI] }
    var highlightedRow: Row { rows[min(max(0, highlighted), rows.count - 1)] }
    var stale: Bool { pendingExpression != nil }

    /// A failed calculation has nothing to copy.
    func isEnabled(_ row: Row) -> Bool {
        row == .calculation ? calculation.number != nil : true
    }

    /// The text a row copies.
    func value(of row: Row) -> String? {
        switch row {
        case .calculation: calculation.number?.copyText
        case let .format(index): formats.indices.contains(index) ? formats[index].value : nil
        case .askAI: nil
        }
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

    /// The results for the launcher's new text. `previous` keeps the last
    /// answer on screen while an expression is unfinished, so the panel does
    /// not jump with every keystroke.
    static func resolve(text: String, previous: AskQuickResults?, chinese: Bool) -> AskQuickResults? {
        switch AskCalculator.read(text) {
        case .notExpression:
            return nil
        case let .incomplete(expression):
            guard var kept = previous, kept.calculation.number != nil else { return nil }
            kept.pendingExpression = expression
            return kept
        case let .calculation(calculation):
            let formats = calculation.number.map {
                AskCalculatorFormats.formats(for: $0, radix: calculation.radix, chinese: chinese)
            } ?? []
            var results = AskQuickResults(calculation: calculation, formats: formats)
            // Keep a row the user chose while the value changes under it.
            if let previous, previous.chosen {
                switch previous.highlightedRow {
                case .askAI: results.highlighted = results.rows.count - 1
                case let .format(index) where index < formats.count: results.highlighted = index + 1
                case .calculation where calculation.number != nil: results.highlighted = 0
                default: break
                }
                results.chosen = results.highlightedRow == previous.highlightedRow
            }
            return results
        }
    }

    /// Where results are copied. Tests point it at a private pasteboard.
    @MainActor static var pasteboard = NSPasteboard.general

    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard? = nil) {
        let target = pasteboard ?? Self.pasteboard
        target.clearContents()
        target.setString(text, forType: .string)
    }
}
