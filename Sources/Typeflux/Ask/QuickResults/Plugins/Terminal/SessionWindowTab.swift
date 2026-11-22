import AppKit
import SwiftUI

extension TerminalSession {
    var tabFolder: String { URL(fileURLWithPath: cwd).lastPathComponent }

    func tabCommand(duplicateFolder: Bool) -> String? {
        if let runningBlock { return runningBlock.command }
        return duplicateFolder ? blocks.last?.command : nil
    }

    var tabTooltip: String {
        guard let command = blocks.last?.command else { return cwd }
        return cwd + "\n" + command
    }
}

struct SessionWindowTab: View {
    @ObservedObject var session: TerminalSession
    let duplicateFolder: Bool
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let move: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                if hovered {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 20, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help(L("terminal.session.close.short") + " ⌘W")
                    .accessibilityLabel(L("terminal.session.close"))
                    .accessibilityIdentifier("terminal.tab.close.\(session.id)")
                } else {
                    TerminalSessionStatusDot(status: session.status)
                        .frame(width: 20, height: 28)
                }
            }
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(session.tabFolder).layoutPriority(1)
                    if let command = session.tabCommand(duplicateFolder: duplicateFolder) {
                        Text(command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .help(session.tabTooltip)
            .accessibilityIdentifier("terminal.tab.\(session.id)")
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .frame(minWidth: 76, maxWidth: 220)
        .fixedSize(horizontal: true, vertical: false)
        .background(selected || hovered ? Color.primary.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .background(TerminalTabMiddleClick(action: close))
        .onHover { hovered = $0 }
        .contextMenu {
            Button(L("terminal.session.close"), action: close).keyboardShortcut("w", modifiers: .command)
            Button(L("terminal.session.close.others"), action: closeOthers)
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button(L("terminal.session.move.launcher"), action: move).keyboardShortcut("o", modifiers: .command)
        }
    }
}

private struct TerminalTabMiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Listener { Listener() }
    func updateNSView(_ view: Listener, context: Context) { view.action = action }
    static func dismantleNSView(_ view: Listener, coordinator: ()) { view.stop() }

    final class Listener: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, let window, event.window === window, window.attachedSheet == nil,
                      event.buttonNumber == 2, visibleRect.contains(convert(event.locationInWindow, from: nil))
                else { return event }
                action?()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
