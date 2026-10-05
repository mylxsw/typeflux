import Foundation
import SwiftUI
import UIKit

/// A small block parser keeps the transcript readable while a response streams.
/// Inline emphasis and links are delegated to Foundation's Markdown parser.
enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case listItem(marker: String, text: String, depth: Int)
        case quote(String)
        case code(language: String, text: String)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    private struct Fence {
        let character: Character
        let count: Int
        let language: String
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = []
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if let fence = fence(trimmed) {
                flush()
                blocks.append(readCode(lines, index: &index, fence: fence))
            } else if let headers = tableHeader(lines, index: index) {
                flush()
                blocks.append(readTable(lines, index: &index, headers: headers))
                continue
            } else if isDivider(trimmed) {
                flush(); blocks.append(.divider)
            } else if let heading = heading(trimmed) {
                flush(); blocks.append(.heading(heading.level, heading.text))
            } else if let item = listItem(line) {
                flush(); blocks.append(item)
            } else if trimmed.hasPrefix(">") {
                flush()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let last = blocks.last, case let .quote(previous) = last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func readCode(_ lines: [String], index: inout Int, fence: Fence) -> Block {
        var code: [String] = []
        index += 1
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate.allSatisfy({ $0 == fence.character }), candidate.count >= fence.count {
                break
            }
            code.append(lines[index]); index += 1
        }
        return .code(language: fence.language, text: code.joined(separator: "\n"))
    }

    private static func tableHeader(_ lines: [String], index: Int) -> [String]? {
        guard index + 1 < lines.count, let headers = tableCells(lines[index]),
              let separators = tableCells(lines[index + 1]), headers.count == separators.count,
              separators.allSatisfy(isTableSeparator) else { return nil }
        return headers
    }

    private static func readTable(_ lines: [String], index: inout Int, headers: [String]) -> Block {
        var rows: [[String]] = []
        index += 2
        while index < lines.count, let cells = tableCells(lines[index]) {
            // Preserve unexpected extra cells rather than silently losing content.
            if cells.count > headers.count {
                break
            }
            rows.append(cells + Array(repeating: "", count: headers.count - cells.count))
            index += 1
        }
        return .table(headers: headers, rows: rows)
    }

    private static func fence(_ line: String) -> Fence? {
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        let count = line.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        return Fence(character: character, count: count,
                     language: String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return (count, String(line.dropFirst(count + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let depth = min(6, line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
        if ["- ", "+ ", "* "].contains(where: { trimmed.hasPrefix($0) }) {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), depth: depth)
        }
        let number = trimmed.prefix(while: { $0.isNumber })
        let rest = trimmed.dropFirst(number.count)
        guard !number.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .listItem(marker: String(number) + ".", text: String(rest.dropFirst(2)), depth: depth)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let text = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return text.count >= 3 && text.allSatisfy { $0 == "-" }
    }

    /// Ignore escaped pipes and pipes inside inline code. Outer pipes are optional.
    static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var codeDelimiter = 0
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                if character != "|" {
                    cell.append("\\")
                }
                cell.append(character); escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                let count = characters[index...].prefix(while: { $0 == "`" }).count
                if codeDelimiter == 0 {
                    codeDelimiter = count
                } else if codeDelimiter == count {
                    codeDelimiter = 0
                }
                cell += String(repeating: "`", count: count)
                index += count - 1
            } else if character == "|", codeDelimiter == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        if escaped {
            cell.append("\\")
        }
        guard !cells.isEmpty else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return trimOuterCells(cells, text: text)
    }

    private static func trimOuterCells(_ source: [String], text: String) -> [String]? {
        var cells = source
        if text.hasPrefix("|"), cells.first == "" {
            cells.removeFirst()
        }
        if text.hasSuffix("|"), cells.last == "" {
            cells.removeLast()
        }
        return cells.isEmpty ? nil : cells
    }
}

struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatSelectableContent.groups(ChatMarkdown.parse(text)).enumerated()),
                    id: \.offset) { _, blocks in
                if blocks.count == 1, case let .code(language, text) = blocks[0] {
                    ChatCodeBlock(language: language, text: text)
                } else if blocks.count == 1, case let .table(headers, rows) = blocks[0] {
                    table(headers: headers, rows: rows)
                } else {
                    ChatSelectableText(blocks: blocks)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        ChatHorizontalScroll(accessibilityLabel: "Table, scroll horizontally") {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in tableRow(cells, header: false) }
            }
            .background(ChatTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ChatTheme.border, lineWidth: 0.5))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell).font(.system(size: header ? 12.5 : 13.5, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? ChatTheme.secondary : Color.primary)
                    .lineSpacing(2)
                    .frame(minWidth: 90, maxWidth: 240, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(header ? ChatTheme.fill : .clear)
                    .overlay(alignment: .top) {
                        if !header {
                            Rectangle().fill(ChatTheme.separator).frame(height: 0.5)
                        }
                    }
            }
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? NSLocalizedString("Code", comment: "Code block") : language)
                    .font(.system(size: 12))
                Spacer()
                Button {
                    UIPasteboard.general.string = text; copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        .frame(width: 36, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? ChatTheme.accent : ChatTheme.textSecondary)
                .accessibilityLabel(NSLocalizedString(copied ? "Copied" : "Copy code", comment: "Code action"))
            }
            .foregroundStyle(ChatTheme.textSecondary)
            .padding(.leading, 12).padding(.trailing, 4)
            Rectangle().fill(ChatTheme.separator).frame(height: 0.5)
            ChatHorizontalScroll(accessibilityLabel: "Code", hintPadding: 12) {
                Text(text).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false).padding(12)
            }
        }
        .background(ChatTheme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatTheme.border, lineWidth: 0.5))
        .onChange(of: text) { _, _ in copied = false }
    }
}

/// Keep the full table or code intact while making offscreen content discoverable.
private struct ChatHorizontalScroll<Content: View>: View {
    let accessibilityLabel: String
    var hintPadding: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                content.background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                            contentWidth = width
                        }
                    }
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        viewportWidth = width
                    }
                }
            }
            .accessibilityLabel(NSLocalizedString(accessibilityLabel, comment: "Scrollable Markdown content"))
            if ChatPresentation.hasHorizontalOverflow(contentWidth: contentWidth, viewportWidth: viewportWidth) {
                Label("Swipe horizontally to see more", systemImage: "arrow.left.and.right")
                    .font(.system(size: 12)).foregroundStyle(ChatTheme.textSecondary)
                    .padding(.horizontal, hintPadding).padding(.bottom, hintPadding)
                    .accessibilityIdentifier("chat.horizontalHint")
            }
        }
    }
}
