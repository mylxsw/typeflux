import AppKit
import SwiftUI

@MainActor
final class UpdateAlertWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case update, skip }

    var onAction: ((Action) -> Void)?
    private var actionFired = false

    convenience init(
        version: String,
        releaseNotes: String,
        releaseURL: URL?,
        appearanceMode: AppearanceMode
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        // Stay visible even when the app loses activation focus
        panel.hidesOnDeactivate = false
        // Float above all windows in all spaces
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

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
            releaseNotesSection
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            Divider()
            buttonRow
        }
        .frame(width: 540)
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("updater.available.title"))
                    .font(.headline)
                    .fontWeight(.bold)
                Text(L("updater.available.subtitle", version))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 16)
    }

    // MARK: Release Notes

    private var releaseNotesSection: some View {
        let notesWithLink: String
        if let releaseURL {
            notesWithLink = releaseNotes + "\n\n[" + L("updater.action.viewDetails") + "](" + releaseURL.absoluteString + ")"
        } else {
            notesWithLink = releaseNotes
        }

        return MarkdownWebView(markdown: notesWithLink, appearanceMode: appearanceMode)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
    }

    // MARK: Buttons

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button(L("updater.action.skip"), action: onSkip)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("updater.action.installAndRelaunch"), action: onUpdate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
