import AppKit
import SwiftUI
import WebKit

struct AskArtifactAccess {
    var load: (AskArtifactRef) throws -> AskArtifactBundle = { _ in throw AskArtifactError.unavailable }
    var validate: (AskArtifactRef) throws -> Void = { _ in throw AskArtifactError.unavailable }
    var htmlEnabled = false
    var imageSource: AskArtifactImageSource?

    struct ImageTaskID: Equatable {
        var ref: AskArtifactRef
        var source: AskArtifactImageSource.Identity?
    }
    func imageTaskID(for ref: AskArtifactRef) -> ImageTaskID { .init(ref: ref, source: imageSource?.identity) }

    /// Bind once without reading artifacts. Delegates still perform full filesystem/grant validation.
    @MainActor static func boundImages(
        context: @escaping @MainActor () -> AskArtifactImageSource.Identity?,
        load: @escaping (AskArtifactRef, String) throws -> AskArtifactBundle,
        validate: @escaping (AskArtifactRef, String) throws -> Void, htmlEnabled: Bool = false
    ) -> Self {
        let source = AskArtifactImageSource(identity: context() ?? .unavailable, current: context)
        return .init(load: { ref in
            guard source.allows(ref) else { throw AskArtifactError.denied }
            return try load(ref, source.identity.owner)
        }, validate: { ref in
            guard source.allows(ref) else { throw AskArtifactError.denied }
            try validate(ref, source.identity.owner)
        }, htmlEnabled: htmlEnabled, imageSource: source)
    }
}

/// Memory-only account/selection binding. This never substitutes for artifact filesystem validation.
struct AskArtifactImageSource {
    struct Identity: Hashable {
        var owner: String
        var conversation: String?
        var selection: UUID
        private var credential: String
        init(owner: String, token: String, conversation: String?, selection: UUID) {
            self.owner = owner; credential = token; self.conversation = conversation; self.selection = selection
        }
        // Stable absence is always denied; it never creates a new task identity on body recomputation.
        static let unavailable = Identity(owner: "", token: "", conversation: nil,
            selection: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    }
    let identity: Identity
    let allows: @MainActor (AskArtifactRef) -> Bool

    init(identity: Identity, current: @escaping @MainActor () -> Identity?) {
        self.identity = identity
        allows = { ref in
            !identity.owner.isEmpty && ref.ownerId == identity.owner && ref.conversationId == identity.conversation && current() == identity
        }
    }
}

extension EnvironmentValues {
    @Entry var askArtifactAccess: AskArtifactAccess = .init()
}

struct AskStoredArtifactCard: View {
    let ref: AskArtifactRef
    @Environment(\.askArtifactAccess) private var access
    @State private var error: String?
    @State private var preview: AskArtifactBundle?
    @StateObject private var imageModel = AskArtifactImageModel()
    @State private var copying: Task<Void, Never>?

    @MainActor init(ref: AskArtifactRef, imageModel: AskArtifactImageModel? = nil) {
        self.ref = ref; _imageModel = StateObject(wrappedValue: imageModel ?? AskArtifactImageModel())
    }

    var body: some View {
        let projection = imageModel.projection(for: ref, access: access)
        return VStack(alignment: .leading, spacing: 7) {
            if let thumbnail = projection.image {
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 260)
                    .accessibilityLabel(L("imagegen.preview"))
            }
            Label(ref.mediaType, systemImage: "doc.richtext")
                .font(.system(size: 13, weight: .semibold))
            Text(ref.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(L("ask.artifact.device") + " · " + ByteCountFormatter.string(
                fromByteCount: ref.sizeBytes,
                countStyle: .file
            ))
            .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            if let expiry = AskArtifactStore.expirationDate(for: ref) {
                Text(L("ask.artifact.expires", expiry.formatted(date: .abbreviated, time: .omitted)))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            HStack {
                Button(L("ask.preview")) {
                    do { preview = try access.load(ref); error = nil } catch { self.error = error.localizedDescription }
                }
                Button(L("ask.artifact.save")) { save() }
                if ref.mediaType.hasPrefix("image/") {
                    Button(L("imagegen.copy")) {
                        copying?.cancel()
                        copying = Task { await imageModel.copy(ref, access: access) }
                    }.disabled(projection.busy)
                }
            }
            if let error = error ?? projection.error {
                Text(error).foregroundStyle(StudioTheme.danger).font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 10))
        .task(id: access.imageTaskID(for: ref)) {
            guard !Task.isCancelled else { return }
            copying?.cancel(); copying = nil
            guard ref.mediaType.hasPrefix("image/") else { return }
            await imageModel.load(ref, access: access)
        }
        .onDisappear { copying?.cancel(); copying = nil; imageModel.cancel() }
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
    @StateObject private var imageModel = AskArtifactImageModel()

    @MainActor init(bundle: AskArtifactBundle, access: AskArtifactAccess, close: @escaping () -> Void,
                    imageModel: AskArtifactImageModel? = nil) {
        self.bundle = bundle; self.access = access; self.close = close
        _imageModel = StateObject(wrappedValue: imageModel ?? AskArtifactImageModel())
    }

    var body: some View {
        let projection = imageModel.projection(for: bundle.manifest.ref, access: access)
        return VStack(alignment: .leading, spacing: 12) {
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
                } else if bundle.manifest.ref.mediaType.hasPrefix("image/") {
                    if let image = projection.image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else if projection.busy {
                        ProgressView()
                    } else {
                        Text(projection.error ?? AskArtifactError.unsupported.localizedDescription)
                    }
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
        .task(id: access.imageTaskID(for: bundle.manifest.ref)) {
            guard bundle.manifest.ref.mediaType.hasPrefix("image/") else { return }
            await imageModel.load(bundle.manifest.ref, access: access)
        }
        .onDisappear { imageModel.cancel() }
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
