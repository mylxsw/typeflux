import Foundation

/// Writes word book entries out for other tools: a spreadsheet, notes, or Anki cards.
enum AskWordBookExporter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv, markdown, anki

        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .markdown: "md"
            case .anki: "tsv"
            }
        }

        var title: String {
            switch self {
            case .csv: L("ask.wordBook.export.csv")
            case .markdown: L("ask.wordBook.export.markdown")
            case .anki: L("ask.wordBook.export.anki")
            }
        }
    }

    static func export(_ entries: [AskWordBookEntry], as format: Format) -> String {
        switch format {
        case .csv: csv(entries)
        case .markdown: markdown(entries)
        case .anki: anki(entries)
        }
    }

    /// One row per word: `headword,phonetic,meanings,source,target,count,starred_at`.
    static func csv(_ entries: [AskWordBookEntry]) -> String {
        let iso = ISO8601DateFormatter()
        let header = "headword,phonetic,meanings,source,target,count,starred_at"
        let rows = entries.map { entry in
            [entry.headword, entry.lookup.card?.phonetics.first?.text ?? "", entry.lookup.summary,
             entry.lookup.source ?? "", entry.lookup.target, String(entry.lookupCount),
             entry.starredAt.map(iso.string(from:)) ?? ""].map(csvField).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    /// Quotes a field when it holds a comma, quote or line break.
    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Each word as the launcher copies a card (⇧⌘C), or its translation.
    static func markdown(_ entries: [AskWordBookEntry]) -> String {
        entries.map { entry in
            entry.lookup.card?.markdown ?? "**\(entry.headword)**\n\(entry.lookup.translation ?? "")"
        }.joined(separator: "\n\n---\n\n") + "\n"
    }

    /// Anki's text import: the word and its phonetic in front, meanings and examples behind.
    static func anki(_ entries: [AskWordBookEntry]) -> String {
        entries.map { entry in
            var front = entry.headword
            if let phonetic = entry.lookup.card?.phonetics.first?.text { front += " " + phonetic }
            var back = [entry.lookup.summary]
            back += entry.lookup.card?.examples.map { example in
                [AskWordCardView.plain(example.source), example.target].filter { !$0.isEmpty }.joined(separator: " — ")
            } ?? []
            return [front, back.filter { !$0.isEmpty }.joined(separator: "<br>")].map(ankiField).joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// Tabs and line breaks would split the card.
    static func ankiField(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
