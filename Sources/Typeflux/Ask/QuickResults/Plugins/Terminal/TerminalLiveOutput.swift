import AppKit
import SwiftUI

/// The emulator belongs to the session. A host only borrows it for the active block.
struct TerminalLiveOutput: NSViewRepresentable {
    let session: TerminalSession
    let background: NSColor
    let availableRows: Int

    func makeNSView(context: Context) -> OutputContainer {
        let terminal = session.terminalView
        let container = OutputContainer(frame: NSRect(origin: .zero, size: terminal.frame.size))
        container.clipsToBounds = true
        container.autoresizesSubviews = false
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        container.addSubview(terminal)
        return container
    }

    func updateNSView(_ view: OutputContainer, context: Context) {
        session.terminalView.inlineBackground = background
        view.availableRows = availableRows
        view.resizeTerminal()
    }

    final class OutputContainer: TerminalKeyboardContainer {
        var availableRows = 0

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            resizeTerminal()
        }

        func resizeTerminal() {
            guard availableRows > 0, bounds.width >= 120,
                  let terminal = subviews.first as? TerminalRunnerTerminalView else { return }
            // Keep extra rows behind the clipping edge so a burst of output can fill the viewport.
            let gridHeight = CGFloat(availableRows) * terminal.rowHeight
            terminal.frame = NSRect(x: 0, y: bounds.height - gridHeight, width: bounds.width, height: gridHeight)
        }
    }
}
