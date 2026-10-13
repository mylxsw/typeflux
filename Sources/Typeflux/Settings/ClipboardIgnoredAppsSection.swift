import AppKit
import SwiftUI

/// Launcher → Clipboard → Don't record these apps: the list, with an app picker to add more.
struct ClipboardIgnoredAppsSection: View {
    @ObservedObject var model: ClipboardSettingsModel

    var body: some View {
        ForEach(model.ignoredApps) { app in
            HStack(spacing: 12) {
                ClipboardAppIcon(bundleID: app.bundleID)
                Text(app.name)
                    .font(.body)
                    .foregroundStyle(TypefluxColor.label.color)
                Spacer()
                Button {
                    model.removeIgnoredApp(app.bundleID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .help(L("clipboard.settings.ignored.remove"))
                .accessibilityLabel(L("clipboard.settings.ignored.remove"))
            }
        }
        HStack(spacing: 10) {
            Button(L("clipboard.settings.ignored.add"), action: chooseApp)
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
