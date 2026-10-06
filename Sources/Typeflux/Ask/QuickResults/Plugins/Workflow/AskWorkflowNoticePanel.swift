import AppKit
import SwiftUI

/// A small note near the bottom of the screen for two seconds: a workflow's
/// bottom-bar note once the launcher has closed (after writing back or opening).
@MainActor
final class AskWorkflowNoticePanel {
    static let shared = AskWorkflowNoticePanel()
    /// How long a note stays.
    var duration: Duration = .seconds(2)

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: AskWorkflowNoticeView(text: text))
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width,
                              height: size.height), display: true)
        panel.orderFrontRegardless()
        AskAnnouncer.announce(text)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: self?.duration ?? .seconds(2))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    /// The note is on screen.
    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        return panel
    }
}

struct AskWorkflowNoticeView: View {
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.success)
            Text(text.count > 80 ? String(text.prefix(80)) + "…" : text).lineLimit(1)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
