import AppKit
import SwiftUI

/// Launcher → Clipboard → Don't record these apps: the list, with an app picker to add more.
struct ClipboardIgnoredAppsSection: View {
    @ObservedObject var model: ClipboardSettingsModel

    var body: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.ignoredApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { ModelRowDivider(leading: 54) }
                    HStack(spacing: 12) {
                        ClipboardAppIcon(bundleID: app.bundleID)
                        Text(app.name)
                            .font(.system(size: StudioTheme.Typography.settingTitle, weight: .medium))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Spacer()
                        Button {
                            model.removeIgnoredApp(app.bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .help(L("clipboard.settings.ignored.remove"))
                        .accessibilityLabel(L("clipboard.settings.ignored.remove"))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                if !model.ignoredApps.isEmpty { ModelRowDivider() }
                HStack(spacing: 10) {
                    Button(L("clipboard.settings.ignored.add"), action: chooseApp)
                    Text(L("clipboard.settings.ignored.footnote"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("clipboard.settings.ignored.choose")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { model.addIgnoredApp(at: $0) }
    }
}

/// Launcher → Clipboard → Data usage: total size, a bar per app, and deletes.
struct ClipboardUsageSection: View {
    @ObservedObject var model: ClipboardSettingsModel
    @State private var pendingDelete: ClipboardUsage.App?
    @State private var confirmingClearAll = false

    var body: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                summary
                if let usage = model.usage, !usage.apps.isEmpty {
                    ModelRowDivider()
                    ForEach(Array(usage.apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { ModelRowDivider(leading: 54) }
                        row(app, largest: usage.apps.first?.bytes ?? 1)
                    }
                }
                ModelRowDivider()
                HStack(spacing: 10) {
                    Button(L("clipboard.settings.usage.reveal"), action: revealData)
                    Button(L("clipboard.menu.clearUnpinned"), role: .destructive) { confirmingClearAll = true }
                        .disabled((model.usage?.totalCount ?? 0) == 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .confirmationDialog(
            L("clipboard.settings.usage.clearAll.title"), isPresented: $confirmingClearAll, titleVisibility: .visible
        ) {
            Button(L("clipboard.action.delete"), role: .destructive) { model.deleteUnpinned(bundleID: nil) }
        } message: {
            Text(L("clipboard.settings.usage.clearAll.message"))
        }
        .confirmationDialog(
            L("clipboard.settings.usage.deleteApp.title", pendingDelete.map(appName) ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("clipboard.action.delete"), role: .destructive) {
                if let app = pendingDelete { model.deleteUnpinned(bundleID: app.bundleID) }
                pendingDelete = nil
            }
        } message: {
            Text(L("clipboard.settings.usage.deleteApp.message"))
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ByteCountFormatter.string(fromByteCount: model.usage?.totalBytes ?? 0, countStyle: .file))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(L("clipboard.settings.usage.items", model.usage?.totalCount ?? 0))
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func row(_ app: ClipboardUsage.App, largest: Int64) -> some View {
        HStack(spacing: 12) {
            ClipboardAppIcon(bundleID: app.bundleID)
            Text(appName(app))
                .font(.system(size: StudioTheme.Typography.settingTitle, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            ProgressView(value: Double(app.bytes), total: Double(max(largest, 1)))
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(L(
                "clipboard.settings.usage.row",
                ByteCountFormatter.string(fromByteCount: app.bytes, countStyle: .file), app.itemCount
            ))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(StudioTheme.textSecondary)
            .frame(width: 130, alignment: .trailing)
            Button {
                pendingDelete = app
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.textSecondary)
            .help(L("clipboard.settings.usage.deleteApp.help"))
            .accessibilityLabel(L("clipboard.settings.usage.deleteApp.help"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func appName(_ app: ClipboardUsage.App) -> String {
        app.name ?? app.bundleID ?? L("clipboard.settings.usage.unknownApp")
    }

    private func revealData() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux", isDirectory: true)
        let database = directory.appendingPathComponent("clipboard.sqlite")
        NSWorkspace.shared.activateFileViewerSelecting([database])
    }
}

/// The icon of an installed app, or a generic one.
private struct ClipboardAppIcon: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let icon = ClipboardAppIconProvider.shared.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}
