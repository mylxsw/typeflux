import AppKit
import SwiftUI

/// Launcher → Clipboard → Data usage: total size, a bar per app, and deletes.
struct ClipboardUsageSection: View {
    @ObservedObject var model: ClipboardSettingsModel
    @State private var pendingDelete: ClipboardUsage.App?
    @State private var confirmingClearAll = false

    var body: some View {
        Group {
            summary
            if let usage = model.usage, !usage.apps.isEmpty {
                ForEach(usage.apps) { app in
                    row(app, largest: usage.apps.first?.bytes ?? 1)
                }
            }
            HStack(spacing: 10) {
                Button(L("clipboard.settings.usage.reveal"), action: revealData)
                Button(L("clipboard.menu.clearUnpinned"), role: .destructive) { confirmingClearAll = true }
                    .disabled((model.usage?.totalCount ?? 0) == 0)
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
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(L("clipboard.action.delete"), role: .destructive) {
                if let app = pendingDelete {
                    model.deleteUnpinned(bundleID: app.bundleID)
                }
                pendingDelete = nil
            }
        } message: {
            Text(L("clipboard.settings.usage.deleteApp.message"))
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ByteCountFormatter.string(fromByteCount: model.usage?.totalBytes ?? 0, countStyle: .file))
                .font(.title2)
                .foregroundStyle(TypefluxColor.label.color)
            Text(L("clipboard.settings.usage.items", model.usage?.totalCount ?? 0))
                .font(.subheadline)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
        }
    }

    private func row(_ app: ClipboardUsage.App, largest: Int64) -> some View {
        HStack(spacing: 12) {
            ClipboardAppIcon(bundleID: app.bundleID)
            Text(appName(app))
                .font(.body)
                .foregroundStyle(TypefluxColor.label.color)
                .lineLimit(1)
            Spacer(minLength: 12)
            ProgressView(value: Double(app.bytes), total: Double(max(largest, 1)))
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(L(
                "clipboard.settings.usage.row",
                ByteCountFormatter.string(fromByteCount: app.bytes, countStyle: .file), app.itemCount
            ))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
            .frame(width: 130, alignment: .trailing)
            Button {
                pendingDelete = app
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
            .help(L("clipboard.settings.usage.deleteApp.help"))
            .accessibilityLabel(L("clipboard.settings.usage.deleteApp.help"))
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
