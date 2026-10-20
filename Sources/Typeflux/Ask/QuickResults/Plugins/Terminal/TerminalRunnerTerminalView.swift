import AppKit
import SwiftTerm

/// SwiftTerm's emulator, connected to a `TerminalRunModel` instead of its own process,
/// with Typeflux's colors for the current appearance.
final class TerminalRunnerTerminalView: TerminalView, TerminalViewDelegate {
    static let scrollback = 10000
    static let fontSize: CGFloat = 12

    private weak var model: TerminalRunModel?

    init(model: TerminalRunModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 260),
                   font: .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular))
        terminalDelegate = self
        getTerminal().changeHistorySize(Self.scrollback)
        optionAsMetaKey = false
        applyPalette()
        model.output = { [weak self] bytes in self?.feed(byteArray: bytes[...]) }
        model.visibleText = { [weak self] in self?.normalScreenText() ?? "" }
        model.clearScreen = { [weak self] in
            self?.getTerminal().resetToInitialState()
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The normal screen and its scrollback, without trailing blank lines: what Copy and Insert take.
    func normalScreenText() -> String {
        let data = getTerminal().getBufferAsData(kind: .normal)
        let text = String(decoding: data, as: UTF8.self)
        return TerminalRunnerTerminalView.trimmed(text)
    }

    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// Dragging selects text; it never moves the window.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        let alternate = source.isCurrentBufferAlternate
        DispatchQueue.main.async { [weak self] in self?.model?.alternateScreen = alternate }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    private func applyPalette() {
        let palette = TerminalRunnerPalette.forAppearance(effectiveAppearance)
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.foreground
        caretColor = palette.caret
        selectedTextBackgroundColor = palette.selection
        installColors(palette.ansi.map { color in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535), green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
        needsDisplay = true
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
        model?.resize(TerminalSize(columns: newCols, rows: newRows))
    }

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        model?.send(Array(data))
    }

    /// OSC 52: programs such as tmux or vim copying to the clipboard, as terminal apps allow.
    func clipboardCopy(source _: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func setTerminalTitle(source _: TerminalView, title _: String) {}
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
    func scrolled(source _: TerminalView, position _: Double) {}
    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

/// The terminal's colors: the app's surfaces plus a 16-color ANSI palette per appearance.
struct TerminalRunnerPalette {
    var background: NSColor
    var foreground: NSColor
    var caret: NSColor
    var selection: NSColor
    /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright variants.
    var ansi: [NSColor]

    /// The header and footer around the terminal.
    static let chrome = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x202022) : hex(0xFCFCFD)
    }

    static func forAppearance(_ appearance: NSAppearance) -> Self {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    static let dark = TerminalRunnerPalette(
        background: hex(0x161618), foreground: hex(0xE6E6E6), caret: hex(0xE6E6E6),
        selection: hex(0x178CFF, alpha: 0.35),
        ansi: [0x1D1D1F, 0xFF6B6B, 0x4FD18B, 0xE8C46A, 0x5FA8FF, 0xD78CF0, 0x5FD4E0, 0xD0D0D0,
               0x6E6E73, 0xFF8A8A, 0x7BE0A8, 0xF2D68C, 0x8CC0FF, 0xE5ADF5, 0x8AE3EC, 0xFFFFFF].map { hex($0) }
    )

    static let light = TerminalRunnerPalette(
        background: hex(0xFFFFFF), foreground: hex(0x1D1D1F), caret: hex(0x1D1D1F),
        selection: hex(0x2563EB, alpha: 0.22),
        ansi: [0x1D1D1F, 0xC62828, 0x11813C, 0x9A6B00, 0x1F5FD1, 0x8E3BB0, 0x0A7F8C, 0x86868B,
               0x515154, 0xDC2626, 0x16A34A, 0xB45309, 0x2563EB, 0xA855F7, 0x0891B2, 0xD1D1D6].map { hex($0) }
    )

    static func hex(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
