import AppKit
import SwiftTerm

extension TerminalRunnerTerminalView {
    func blockSnapshot(limit: Int = 5000) -> NSAttributedString {
        guard limit > 0 else { return NSAttributedString(string: "") }
        let terminal = getTerminal()
        let data = terminal.getBufferAsData()
        let rows = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let text = NSMutableAttributedString(string: "")
        var styles: [Attribute: [NSAttributedString.Key: Any]] = [:]
        let palette = TerminalRunnerPalette.forAppearance(effectiveAppearance)
        guard let end = rows.lastIndex(where: { !$0.isEmpty }) else { return text }
        for row in max(0, end + 1 - limit) ... end {
            var cells: [(Character, Attribute)] = []
            var col = 0
            while col < terminal.cols {
                let cell = terminal.buffer.getChar(atBufferRelative: Position(col: col, row: row))
                col += max(1, Int(cell.width))
                let char = terminal.getCharacter(for: cell)
                cells.append((char == "\0" ? " " : char, cell.attribute))
            }
            while cells.last?.0 == " " {
                cells.removeLast()
            }
            var run = ""
            var previous: Attribute?
            for (char, attr) in cells {
                if previous != attr, let previous {
                    text.append(NSAttributedString(string: run, attributes: styles[previous]))
                    run.removeAll(keepingCapacity: true)
                }
                previous = attr
                if styles[attr] == nil {
                    var style: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: Self.fontSize,
                            weight: attr.style.contains(.bold) ? .bold : .regular
                        )
                    ]
                    style[.foregroundColor] = Self.color(attr.fg, palette: palette)
                    style[.backgroundColor] = Self.color(attr.bg, palette: palette)
                    styles[attr] = style
                }
                run.append(char)
            }
            if let previous {
                text.append(NSAttributedString(string: run, attributes: styles[previous]))
            }
            if row < end {
                text.append(NSAttributedString(string: "\n"))
            }
        }
        return text
    }

    private static func color(_ value: Attribute.Color, palette: TerminalRunnerPalette) -> NSColor? {
        switch value {
        case .defaultColor, .defaultInvertedColor: return nil
        case let .trueColor(r, g, b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case let .ansi256(code):
            let index = Int(code)
            if index < 16 {
                return palette.ansi[index]
            }
            if index >= 232 {
                return NSColor(white: CGFloat(8 + 10 * (index - 232)) / 255, alpha: 1)
            }
            let n = index - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: levels[n / 36] / 255,
                green: levels[n / 6 % 6] / 255,
                blue: levels[n % 6] / 255,
                alpha: 1
            )
        }
    }
}
