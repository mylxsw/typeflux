import AppKit
import SwiftUI

final class HistoryWindowController: NSObject {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryView()
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: StudioTheme.Layout.historyWindowWidth,
                height: StudioTheme.Layout.historyWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput History"
        window.center()
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension HistoryWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct HistoryView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("History UI will be wired to FileHistoryStore.")
                .font(.headline)
            Text("In v1 this window is a placeholder while core pipeline is implemented.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(StudioTheme.Insets.windowContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
