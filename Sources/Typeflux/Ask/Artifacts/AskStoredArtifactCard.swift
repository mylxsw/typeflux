import AppKit
import ImageIO
import SwiftUI
import WebKit

struct AskArtifactAccess {
    var load: (AskArtifactRef) throws -> AskArtifactBundle = { _ in throw AskArtifactError.unavailable }
    var validate: (AskArtifactRef) throws -> Void = { _ in throw AskArtifactError.unavailable }
    var htmlEnabled = false
}

extension EnvironmentValues {
    @Entry var askArtifactAccess: AskArtifactAccess = .init()
}

struct AskStoredArtifactCard: View {
    let ref: AskArtifactRef
    @Environment(\.askArtifactAccess) private var access
    @State private var error: String?
    @State private var preview: AskArtifactBundle?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(ref.mediaType, systemImage: "doc.richtext")
                .font(.system(size: 13, weight: .semibold))
            Text(ref.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(L("ask.artifact.device") + " · " + ByteCountFormatter.string(
                fromByteCount: ref.sizeBytes,
                countStyle: .file
            ))
            .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            if let expiry = ref.expiresAt {
                Text(L("ask.artifact.expires", expiry.formatted(date: .abbreviated, time: .omitted)))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            HStack {
                Button(L("ask.preview")) {
                    do { preview = try access.load(ref); error = nil } catch { self.error = error.localizedDescription }
                }
                Button(L("ask.artifact.save")) { save() }
            }
            if let error {
                Text(error).foregroundStyle(StudioTheme.danger).font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: Binding(get: { preview != nil }, set: {
            if !$0 {
                preview = nil
            }
        })) {
            if let preview {
                AskArtifactPreviewView(bundle: preview, access: access, close: { self.preview = nil })
            }
        }
    }

    private func save() {
        do {
            let initial = try access.load(ref)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (initial.manifest.entry as NSString).lastPathComponent
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // A dialog may outlive account/grant changes. Revalidate immediately before export.
            try AskArtifactExport.write(access.load(ref), to: url)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

enum AskArtifactExport {
    static func write(_ bundle: AskArtifactBundle, to url: URL) throws {
        guard let bytes = bundle.files[bundle.manifest.entry],
              AskToolPolicy.digest(bytes) == bundle.manifest.ref.sha256 else { throw AskArtifactError.corrupt }
        try bytes.write(to: url, options: .atomic)
    }
}

struct AskArtifactPreviewView: View {
    let bundle: AskArtifactBundle
    let access: AskArtifactAccess
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text((bundle.manifest.entry as NSString).lastPathComponent).font(.headline)
                Spacer()
                Button(L("ask.artifact.close"), action: close)
            }
            if bundle.manifest.ref.mediaType == "text/html" {
                if access.htmlEnabled {
                    AskArtifactWebView(ref: bundle.manifest.ref, access: access, error: $error)
                } else {
                    Text(AskArtifactError.previewDisabled.localizedDescription)
                }
            } else if let data = bundle.files[bundle.manifest.entry] {
                if bundle.manifest.ref.mediaType.hasPrefix("text/") || bundle.manifest.ref
                    .mediaType == "application/json" {
                    if let text = String(data: data, encoding: .utf8) {
                        let clipped = AskProjectFileAccess.preview(text)
                        if clipped != text {
                            Text(L("ask.artifact.truncated"))
                        }
                        ScrollView { Text(clipped).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    } else {
                        Text(AskArtifactError.unsupported.localizedDescription)
                    }
                } else if bundle.manifest.ref.mediaType.hasPrefix("image/"),
                          let image = AskArtifactPresentation.image(data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Text(AskArtifactError.unsupported.localizedDescription)
                }
            }
            if let error {
                Text(error).foregroundStyle(StudioTheme.danger).lineLimit(8).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }
}

private struct AskArtifactWebView: NSViewRepresentable {
    let ref: AskArtifactRef
    let access: AskArtifactAccess
    @Binding var error: String?

    @MainActor final class Coordinator {
        let host = AskPreviewHost()
        var loading: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let host = context.coordinator.host
        host.report = { error = $0 }
        context.coordinator.loading = Task { @MainActor in
            do {
                let view = try await host.open(.artifact(ref), enabled: access.htmlEnabled,
                                               validateAccess: access.validate, load: access.load)
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            } catch { self.error = error.localizedDescription }
        }
        return container
    }

    func updateNSView(_: NSView, context _: Context) {}

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
        coordinator.host.close()
    }
}

enum AskArtifactPresentation {
    static func image(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
