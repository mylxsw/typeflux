import SwiftUI
import TypefluxMediaProtocol

enum AskFinderIcon {
    private static let admission = AskNativeIconAdmission(limit: 2)
    static func decode(_ icon: MediaNativeIcon, edge: Int = 56, worker: MediaWorker = .previews) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        try icon.validate()
        guard (1...112).contains(edge) else { throw MediaFailure.tooLarge }
        let slot = try await admission.acquire(), cancellation = AskSearchCancellation()
        defer { withExtendedLifetime(slot) {} }
        return try await withTaskCancellationHandler {
            // Other previews share the worker's two child slots. Wait briefly for
            // those slots too, while preserving the child's failure as a failure.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while true {
                try Task.checkCancellation()
                if worker.activeCount >= 2 {
                    guard ContinuousClock.now < deadline else { throw MediaFailure.unavailable }
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let result = try await Task.detached(priority: .utility) {
                    try MediaPreviewDisplay.renderIcon(icon, edge: edge, cancellation: cancellation, worker: worker)
                }.value
                try Task.checkCancellation()
                return result
            }
        } onCancel: { cancellation.cancel() }
    }

    @MainActor static func image(for url: URL, scale: CGFloat = 2, worker: MediaWorker = .previews) async -> NSImage? {
        guard url.isFileURL, scale.isFinite, scale > 0, scale <= 4,
              let result = try? await decode(.init(kind: .file, value: url.path), edge: Int(ceil(28 * scale)), worker: worker),
              let image = result.images.first else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(width: 28, height: 28)
        let display = NSImage(size: representation.size)
        display.addRepresentation(representation)
        return display
    }
}

typealias AskNativeIconDecoding = @Sendable (MediaNativeIcon) async throws -> AskFilePreviewPDF.Result
private struct AskNativeIconDecoderKey: EnvironmentKey {
    static let defaultValue: AskNativeIconDecoding = { try await AskFinderIcon.decode($0) }
}
extension EnvironmentValues {
    var askNativeIconDecoder: AskNativeIconDecoding {
        get { self[AskNativeIconDecoderKey.self] }
        set { self[AskNativeIconDecoderKey.self] = newValue }
    }
}

/// Native icons remain scoped to visible views. Launcher searches also reuse
/// bounded application icons and temporarily cache versioned file icons.
struct AskNativeIconImage<Content: View>: View {
    let icon: MediaNativeIcon?
    var revision: Date?
    var decode: AskNativeIconDecoding?
    @ViewBuilder var content: (NSImage?) -> Content
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askIconGeneration) private var generation
    @Environment(\.askNativeIconDecoder) private var environmentDecode
    @Environment(\.askLauncherIconCache) private var launcherCache
    var body: some View {
        let iconCache = launcherCache
        let selectedDecode = decode ?? environmentDecode
        let useCache = decode == nil
        let cached = access.allows() && useCache ? icon.flatMap {
            iconCache?.cached($0, revision: revision)?.images.first
        }.map { NSImage(cgImage: $0, size: .zero) } : nil
        return AskContextImage(source: icon.map { $0.kind.rawValue + ":" + $0.value },
            model: AskContextImageModel(maximumEdge: 56, decode: { _ in
                guard let icon else { throw MediaFailure.unavailable }
                if useCache, let iconCache, AskLauncherIconCache.eligible(icon, revision: revision) {
                    return try await iconCache.load(icon, revision: revision)
                }
                return try await selectedDecode(icon)
            }), content: { image in content(image ?? cached) })
        .id(Identity(icon: icon, epoch: access.epoch, generation: generation, revision: revision))
    }
    private struct Identity: Hashable {
        let icon: MediaNativeIcon?; let epoch: UUID?; let generation: Int; let revision: Date?
    }
}

struct AskApplicationIcon<Content: View>: View {
    let bundleID: String?
    @ViewBuilder var content: (NSImage?) -> Content
    var body: some View {
        AskNativeIconImage(icon: bundleID.map { .init(kind: .application, value: $0) }, content: content)
    }
}

struct AskNativeIconView: View {
    let icon: MediaNativeIcon
    var symbol = "doc"
    var revision: Date?
    var decode: AskNativeIconDecoding?
    var body: some View {
        AskNativeIconImage(icon: icon, revision: revision, decode: decode) { image in
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: symbol).resizable().scaledToFit().padding(3).foregroundStyle(StudioTheme.textTertiary) }
        }
    }
}
