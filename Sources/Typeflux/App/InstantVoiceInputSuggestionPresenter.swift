import AppKit
import SwiftUI

@MainActor
enum InstantVoiceInputSuggestionPresenter {
    static func present() -> Bool {
        let content = InstantVoiceInputSuggestionView(
            onEnable: { NSApp.stopModal(withCode: .OK) },
            onCancel: { NSApp.stopModal(withCode: .cancel) }
        )
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let panel = InstantVoiceInputSuggestionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        panel.center()
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.orderOut(nil)
            panel.close()
        }
        return NSApp.runModal(for: panel) == .OK
    }
}

@MainActor
private final class InstantVoiceInputSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
