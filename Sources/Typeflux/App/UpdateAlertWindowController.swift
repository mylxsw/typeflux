import AppKit
import SwiftUI

@MainActor
final class UpdateAlertWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case update, installOnQuit, skip }

    var onAction: ((Action) -> Void)?
    private var actionFired = false

    convenience init(
        version: String,
        releaseNotes: String,
        releaseURL: URL?,
        appearanceMode: AppearanceMode,
        autoUpdateEnabled: Bool,
        onAutoUpdateChange: ((Bool) -> Void)?
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
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
            autoUpdateEnabled: autoUpdateEnabled,
            onAutoUpdateChange: onAutoUpdateChange,
            onUpdate: { [weak self] in self?.fire(.update) },
            onInstallOnQuit: { [weak self] in self?.fire(.installOnQuit) },
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
    let onAutoUpdateChange: ((Bool) -> Void)?
    let onUpdate: () -> Void
    let onInstallOnQuit: () -> Void
    let onSkip: () -> Void

    @State private var isAutoUpdateEnabled: Bool

    init(
        version: String,
        releaseNotes: String,
        releaseURL: URL?,
        appearanceMode: AppearanceMode,
        autoUpdateEnabled: Bool,
        onAutoUpdateChange: ((Bool) -> Void)?,
        onUpdate: @escaping () -> Void,
        onInstallOnQuit: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.appearanceMode = appearanceMode
        self.onAutoUpdateChange = onAutoUpdateChange
        self.onUpdate = onUpdate
        self.onInstallOnQuit = onInstallOnQuit
        self.onSkip = onSkip
        self._isAutoUpdateEnabled = State(initialValue: autoUpdateEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            releaseNotesSection
                .padding(.horizontal, 20)
                .padding(.top, 12)
            autoUpdateToggle
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Divider()
                .padding(.top, 12)
            buttonRow
        }
        .frame(width: 540)
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
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
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: Release Notes

    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownWebView(markdown: releaseNotes, appearanceMode: appearanceMode)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            if let releaseURL {
                Link(L("updater.action.viewDetails"), destination: releaseURL)
                    .font(.callout)
            }
        }
    }

    // MARK: Auto-update toggle

    private var autoUpdateToggle: some View {
        Toggle(isOn: $isAutoUpdateEnabled) {
            Text(L("updater.autoUpdate.checkbox"))
                .font(.callout)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isAutoUpdateEnabled) { newValue in
            onAutoUpdateChange?(newValue)
        }
    }

    // MARK: Buttons

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button(L("updater.action.skip"), action: onSkip)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("updater.action.installOnQuit"), action: onInstallOnQuit)
            Button(L("updater.action.installAndRelaunch"), action: onUpdate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
