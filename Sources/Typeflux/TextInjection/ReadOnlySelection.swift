import Foundation

/// One budget shared by tree traversal and AX requests. A slow request can exceed
/// the deadline only by its own AX messaging timeout, not once per remaining node.
final class ReadOnlySelectionBudget {
    private var remaining: Int
    private let deadline: TimeInterval
    private let now: () -> TimeInterval

    init(operations: Int = 96, seconds: TimeInterval = 0.35,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        remaining = operations
        self.now = now
        deadline = now() + seconds
    }

    func take() -> Bool {
        guard remaining > 0, now() < deadline else { return false }
        remaining -= 1
        return true
    }
}

enum ReadOnlySelection {
    static func capture(
        readAX: () -> String?, copy: () -> String?, targetMatches: () -> Bool,
        checkCancellation: () throws -> Void
    ) throws -> (text: String?, source: String) {
        try checkCancellation()
        let selectedText = readAX()
        try checkCancellation()
        guard targetMatches() else { return (nil, "target-changed") }
        if let selectedText { return (selectedText, "accessibility-context") }
        let copiedText = copy()
        try checkCancellation()
        guard targetMatches() else { return (nil, "target-changed") }
        return (copiedText, copiedText == nil ? "none" : "clipboard-copy")
    }

    static func text(
        selectedText: () -> String?, ranges: () -> [CFRange],
        stringForRange: (CFRange) -> String?, value: () -> String?
    ) -> String? {
        if let direct = selectedText(), !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return direct
        }
        let ranges = ranges()
        guard !ranges.isEmpty, ranges.count <= 16 else { return nil }
        var fragments: [String] = []
        var cachedValue: String?
        var didReadValue = false
        for range in ranges {
            guard range.location >= 0, range.length > 0,
                  range.location <= Int.max - range.length else { return nil }
            if let text = stringForRange(range), text.utf16.count == range.length {
                fragments.append(text)
            } else {
                if !didReadValue { cachedValue = value(); didReadValue = true }
                guard let text = cachedValue else { return nil }
                let units = text.utf16
                guard range.location <= units.count, range.length <= units.count - range.location else { return nil }
                let start = units.index(units.startIndex, offsetBy: range.location)
                let end = units.index(start, offsetBy: range.length)
                // String slicing can round an interior UTF-16 index to a character
                // boundary. Require exact representable boundaries before slicing.
                guard let lower = String.Index(start, within: text),
                      let upper = String.Index(end, within: text) else { return nil }
                fragments.append(String(text[lower..<upper]))
            }
        }
        let text = fragments.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Read the focused target first, then search only the source window. Never
    /// infer a selection from a label, full value, or editability alone.
    static func find<Node>(
        roots: [Node], budget: ReadOnlySelectionBudget,
        read: (Node) -> String?, children: (Node) -> [Node], matches: (Node, Node) -> Bool
    ) -> (node: Node, text: String)? {
        var pending = Array(roots.prefix(2))
        var seen: [Node] = []
        var index = 0
        while index < pending.count, budget.take() {
            let node = pending[index]
            index += 1
            guard !seen.contains(where: { matches($0, node) }) else { continue }
            seen.append(node)
            if let text = read(node), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (node, text)
            }
            // Bound both the requests and the in-memory queue for wide/cyclic trees.
            if pending.count < 96 {
                pending.append(contentsOf: children(node).prefix(96 - pending.count))
            }
        }
        return nil
    }
}

extension TextSelectionSnapshot {
    func readOnlyContext() -> TextSelectionSnapshot {
        var snapshot = self
        snapshot.replacementSafety = hasSelection ? .resultOnly : SelectionReplacementSafety.none
        snapshot.replacementContextID = nil
        snapshot.nativeTarget = nil
        return snapshot
    }
}
