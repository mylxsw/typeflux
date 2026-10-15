import AppKit
import SwiftUI

/// Launcher → Clipboard → Don't record these apps: the list, with an app picker to add more.
struct ClipboardIgnoredAppsSection: View {
    @ObservedObject var model: ClipboardSettingsModel

    var body: some View {
        TFFormSection(title: L("clipboard.settings.section.ignored")) {
            ForEach(model.ignoredApps, id: \.id) { app in
                TFFormRow(title: app.name, icon: "app.dashed", image: appIcon(app.bundleID)) {
                    TFButton(title: L("clipboard.settings.ignored.remove"), systemImage: "minus", kind: .plain,
                             size: .small, iconOnly: true) { model.removeIgnoredApp(app.bundleID) }
                }
                TFDivider.formWithIcon
            }
            TFActionRow(systemImage: "plus", title: L("clipboard.settings.ignored.add"), action: chooseApp)
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
        TFFormSection(title: L("clipboard.settings.section.usage")) {
            summary
            if let usage = model.usage, !usage.apps.isEmpty {
                ForEach(usage.apps, id: \.id) { app in
                    TFDivider.formWithIcon
                    row(app, largest: usage.apps.first?.bytes ?? 1)
                }
            }
            TFDivider.form
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: L("clipboard.settings.usage.reveal"), action: revealData)
                TFButton(title: L("clipboard.menu.clearUnpinned"), destructive: true) { confirmingClearAll = true }
                    .disabled((model.usage?.totalCount ?? 0) == 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
        HStack(spacing: 12) {
            TFMetric(title: L("clipboard.settings.usage.items", model.usage?.totalCount ?? 0),
                     value: ByteCountFormatter.string(fromByteCount: model.usage?.totalBytes ?? 0, countStyle: .file))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(_ app: ClipboardUsage.App, largest: Int64) -> some View {
        TFFormRow(title: appName(app),
                  valueText: L("clipboard.settings.usage.row",
                            ByteCountFormatter.string(fromByteCount: app.bytes, countStyle: .file), app.itemCount),
                  icon: "app.dashed", image: appIcon(app.bundleID)) {
            TFMeter(value: Double(app.bytes), total: Double(max(largest, 1)))
            TFButton(title: L("clipboard.settings.usage.deleteApp.help"), systemImage: "trash", kind: .plain,
                     size: .small, iconOnly: true) { pendingDelete = app }
        }
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

/// The icon of an installed app; rows fall back to a generic tile without one.
private func appIcon(_ bundleID: String?) -> NSImage? {
    ClipboardAppIconProvider.shared.icon(forBundleID: bundleID)
}
