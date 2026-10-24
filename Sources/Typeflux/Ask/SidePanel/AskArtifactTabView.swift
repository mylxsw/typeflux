import AppKit
import SwiftUI

extension AskArtifactTab {
    /// A tab title for an artifact whose entry name is unknown, such as a generated image.
    nonisolated static func defaultName(_ ref: AskArtifactRef) -> String {
        let ext = ref.mediaType.split(separator: "/").last.map(String.init) ?? ""
        let base = L("ask.sidePanel.artifact") + " " + String(ref.id.prefix(8))
        return ext.isEmpty || ext.contains(".") || ext.contains("+") ? base : base + "." + ext
    }
}

/// An artifact in a side panel tab. It loads through the conversation's artifact access and
/// shows it with the artifact preview (HTML in its offline sandbox with all its resources).
struct AskArtifactTabView: View {
    let tab: AskArtifactTab
    @Environment(\.askArtifactAccess) private var access
    @StateObject private var previewModel = AskArtifactPreviewModel()
    @StateObject private var saveModel = AskArtifactSaveModel()

    var body: some View {
        let projection = previewModel.projection(for: tab.ref, access: access)
        return VStack(spacing: 0) {
            toolbar
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            if let error = saveModel.projectedError(for: tab.ref, access: access) {
                Text(error).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Group {
                if let preview = projection.preview {
                    AskArtifactPreviewView(bundle: preview.bundle, access: access, close: {},
                                           source: preview.source, embedded: true)
                } else if let error = projection.error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .light))
                        Text(error).font(.system(size: 12.5)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(24)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { previewModel.open(tab.ref, access: access) }
        .onDisappear { previewModel.close(); saveModel.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.sidePanel.artifactTab")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(L("ask.artifact.device") + " · " + ByteCountFormatter.string(fromByteCount: tab.ref.sizeBytes,
                                                                                 countStyle: .file))
                    .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("ask.artifact.save")) {
                saveModel.save(tab.ref, access: access, choose: { initial in
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = (initial.manifest.entry as NSString).lastPathComponent
                    return panel.runModal() == .OK ? panel.url : nil
                }, write: AskArtifactExport.write)
            }
            .controlSize(.small)
            .accessibilityIdentifier("ask.sidePanel.artifact.save")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}
