import AppKit
import SwiftUI

/// Keeps the ordinary transcript renderer for every message without a complete
/// Mermaid fence. A streaming fence remains source text until the turn ends.
struct AskMermaidTranscript: View {
    let text: String
    let isStreaming: Bool
    let onAsk: ((String, String) -> Void)?
    let onSaveNote: ((String) -> Void)?

    var body: some View {
        let parts = isStreaming ? [] : AskMermaidFences.split(text)
        if parts.contains(where: { if case .diagram = $0 { return true }; return false }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parts.indices, id: \.self) { index in
                    switch parts[index] {
                    case let .markdown(markdown):
                        AskTranscriptText(text: markdown, onAsk: onAsk, onSaveNote: onSaveNote)
                    case let .diagram(source):
                        AskMermaidDiagram(source: source)
                            .id(source)
                    }
                }
            }
        } else {
            AskTranscriptText(text: text, onAsk: onAsk, onSaveNote: onSaveNote)
        }
    }
}

enum AskMermaidFences {
    enum Part: Equatable {
        case markdown(String)
        case diagram(String)
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let language: String
    }

    static func split(_ text: String) -> [Part] {
        let lines = AskMarkdownFences.normalize(text).components(separatedBy: "\n")
        var parts: [Part] = []
        var sectionStart = 0
        var index = 0
        var diagramCount = 0
        while index < lines.count {
            guard let open = openingFence(lines[index]) else { index += 1; continue }
            guard let close = ((index + 1) ..< lines.count).first(where: { closes(lines[$0], open) }) else { break }
            if open.language == "mermaid", diagramCount < 8 {
                let source = lines[(index + 1) ..< close].joined(separator: "\n")
                if !source.isEmpty, source.utf8.count <= 20_000 {
                    appendMarkdown(lines[sectionStart ..< index], to: &parts)
                    parts.append(.diagram(source))
                    sectionStart = close + 1
                    diagramCount += 1
                }
            }
            index = close + 1
        }
        appendMarkdown(lines[sectionStart ..< lines.count], to: &parts)
        return parts
    }

    private static func appendMarkdown(_ lines: ArraySlice<String>, to parts: inout [Part]) {
        let value = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !value.isEmpty { parts.append(.markdown(value)) }
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = content.dropFirst(count)
        guard marker != "`" || !info.contains("`") else { return nil }
        let language = info.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return Fence(marker: marker, count: count, language: language)
    }

    private static func closes(_ line: String, _ open: Fence) -> Bool {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let content = line.dropFirst(indentation)
        let count = content.prefix(while: { $0 == open.marker }).count
        return count >= open.count && content.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
