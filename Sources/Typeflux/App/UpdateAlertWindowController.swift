import AppKit
import SwiftUI

@MainActor
final class UpdateAlertWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case update, skip }

    var onAction: ((Action) -> Void)?
    private var actionFired = false

    convenience init(version: String, releaseNotes: String, releaseURL: URL?, appearanceMode: AppearanceMode) {
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
        // Always float above all windows in all spaces (menu bar agent app has no main window)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces]

        self.init(window: panel)

        let view = UpdateAlertContentView(
            version: version,
            releaseNotes: releaseNotes,
            releaseURL: releaseURL,
            appearanceMode: appearanceMode,
            onUpdate: { [weak self] in self?.fire(.update) },
            onSkip: { [weak self] in self?.fire(.skip) }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
    let releaseURL: URL?
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
                .padding(.top, 8)
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

            // Title + optional external-link icon
            HStack(spacing: 4) {
                Text(L("updater.available.title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                if let releaseURL {
                    Link(destination: releaseURL) {
                        Image(systemName: "arrow.up.right.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Version label — acts as a link when release_url is present
            if let releaseURL {
                Link(destination: releaseURL) {
                    Text(L("updater.available.versionLabel", version))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(L("updater.available.versionLabel", version))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
