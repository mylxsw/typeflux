import AppKit
import SwiftUI

@MainActor
final class UpdateAlertWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case update, skip }

    var onAction: ((Action) -> Void)?
    private var actionFired = false

    convenience init(version: String, releaseNotes: String, appearanceMode: AppearanceMode) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true

        self.init(window: panel)

        let view = UpdateAlertContentView(
            version: version,
            releaseNotes: releaseNotes,
            appearanceMode: appearanceMode,
            onUpdate: { [weak self] in self?.fire(.update) },
            onSkip: { [weak self] in self?.fire(.skip) }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.center()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fire(_ action: Action) {
        guard !actionFired else { return }
        actionFired = true
        onAction?(action)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Treat window close (X button) as skip
        fire(.skip)
    }
}

// MARK: - SwiftUI content

private struct UpdateAlertContentView: View {
    let version: String
    let releaseNotes: String
    let appearanceMode: AppearanceMode
    let onUpdate: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            MarkdownWebView(markdown: releaseNotes, appearanceMode: appearanceMode)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            Divider()
            buttonRow
        }
        .frame(width: 440)
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(L("updater.available.title"))
                .font(.title3)
                .fontWeight(.semibold)
            Text(L("updater.available.versionLabel", version))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var buttonRow: some View {
        HStack(spacing: 12) {
            Button(L("updater.action.skip"), action: onSkip)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("updater.action.update"), action: onUpdate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
