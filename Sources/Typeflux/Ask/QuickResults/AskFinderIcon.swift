import SwiftUI
import TypefluxMediaProtocol

enum AskFinderIcon {
    private static let admission = AskNativeIconAdmission(limit: 2)
    static func decode(_ icon: MediaNativeIcon, edge: Int = 56, worker: MediaWorker = .previews,
                       authorization: MediaWorker.Authorization? = nil) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        try icon.validate()
        guard (1...112).contains(edge) else { throw MediaFailure.tooLarge }
        let original = authorization ?? worker.authorization()
        guard worker.permits(original) else { throw MediaFailure.unavailable }
        let slot = try await admission.acquire(), cancellation = AskSearchCancellation()
        defer { withExtendedLifetime(slot) {} }
        return try await withTaskCancellationHandler {
            // Other previews share the worker's two child slots. Wait briefly for
            // those slots too, while preserving the child's failure as a failure.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while true {
                try Task.checkCancellation()
                guard worker.permits(original) else { throw MediaFailure.unavailable }
                if worker.activeCount >= 2 {
                    guard ContinuousClock.now < deadline else { throw MediaFailure.unavailable }
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let result = try await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    guard !cancellation.isCancelled, worker.permits(original) else { throw MediaFailure.unavailable }
                    return try MediaPreviewDisplay.renderIcon(icon, edge: edge, cancellation: cancellation, worker: worker,
                                                              authorization: original)
                }.value
                try Task.checkCancellation()
                guard worker.permits(original) else { throw MediaFailure.unavailable }
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

/// Binds one native-icon consumer before Context queues its preparation.
@MainActor struct AskNativeIconPreparation {
    struct Batch: Sendable {
        let decode: @MainActor @Sendable () async throws -> AskFilePreviewPDF.Result
        let isCurrent: @MainActor @Sendable () -> Bool
    }
    let icon: MediaNativeIcon?
    var revision: Date?
    var cache: AskLauncherIconCache?
    var decode: AskNativeIconDecoding?
    var useCache = true
    var worker: MediaWorker = .previews

    func bind(_ source: String) throws -> Batch {
        guard let icon, source == icon.kind.rawValue + ":" + icon.value else { throw MediaFailure.unavailable }
        if useCache, let cache, AskLauncherIconCache.eligible(icon, revision: revision) {
            return cache.nativeIconBatch(icon, revision: revision)
        }
        let original = decode == nil ? worker.authorization() : nil
        let current: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && (original.map { worker.permits($0) } ?? true)
        }
        return .init(decode: {
            guard current() else { throw MediaFailure.unavailable }
            let result: AskFilePreviewPDF.Result
            if let decode { result = try await decode(icon) }
            else { result = try await AskFinderIcon.decode(icon, worker: worker, authorization: original) }
            guard current() else { throw MediaFailure.unavailable }
            return result
        }, isCurrent: current)
    }
}

struct AskNativeIconDecoderOverride: Sendable { let decode: AskNativeIconDecoding }
private struct AskNativeIconDecoderKey: EnvironmentKey {
    static let defaultValue: AskNativeIconDecoderOverride? = nil
}
extension EnvironmentValues {
    var askNativeIconDecoder: AskNativeIconDecoding {
        get {
            if let custom = self[AskNativeIconDecoderKey.self] { return custom.decode }
            return { @Sendable in try await AskFinderIcon.decode($0) }
        }
        set { self[AskNativeIconDecoderKey.self] = .init(decode: newValue) }
    }
    var nativeIconDecoderOverride: AskNativeIconDecoderOverride? { self[AskNativeIconDecoderKey.self] }
}

/// Native icons remain scoped to visible views. Launcher searches also reuse
/// bounded application icons and temporarily cache versioned file icons.
struct AskNativeIconImage<Content: View>: View {
    let icon: MediaNativeIcon?
    var revision: Date?
    var folder = false
    var immediateLookup = true
    var decode: AskNativeIconDecoding?
    @ViewBuilder var content: (NSImage?) -> Content
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askIconGeneration) private var generation
    @Environment(\.nativeIconDecoderOverride) private var environmentDecode
    @Environment(\.askLauncherIconCache) private var launcherCache
    var body: some View {
        let selectedDecode: AskNativeIconDecoding?
        if let decode { selectedDecode = { @Sendable icon in try await decode(icon) } }
        else if let environmentDecode { selectedDecode = environmentDecode.decode }
        else { selectedDecode = nil }
        let useCache = decode == nil
        let cacheRevision = useCache ? icon.flatMap { launcherCache?.revision(for: $0, modified: revision) } : nil
        return AskNativeIconProjection(icon: icon, revision: revision, folder: folder,
            immediateLookup: immediateLookup, decode: selectedDecode, useCache: useCache,
            cache: launcherCache, cacheRevision: cacheRevision ?? AskLauncherIconCache.Revision(), content: content)
        .id(Identity(icon: icon, epoch: access.epoch, generation: generation, revision: revision))
    }
    private struct Identity: Hashable {
        let icon: MediaNativeIcon?; let epoch: UUID?; let generation: Int; let revision: Date?
    }
}

/// Each row observes only its own cached icon. A background preload can replace
/// a failed placeholder without invalidating the whole launcher list.
private struct AskNativeIconProjection<Content: View>: View {
    let icon: MediaNativeIcon?
    let revision: Date?
    let folder: Bool
    let immediateLookup: Bool
    let decode: AskNativeIconDecoding?
    let useCache: Bool
    let cache: AskLauncherIconCache?
    @ObservedObject var cacheRevision: AskLauncherIconCache.Revision
    let content: (NSImage?) -> Content
    @Environment(\.askContextImageAccess) private var access

    var body: some View {
        let cached = access.allows() && useCache ? icon.flatMap {
            (immediateLookup
                ? cache?.immediate($0, revision: revision, folder: folder)
                : cache?.cached($0, revision: revision))?.images.first
        }.map { NSImage(cgImage: $0, size: .zero) } : nil
        AskContextImage(source: icon.map { $0.kind.rawValue + ":" + $0.value },
            model: AskContextImageModel(maximumEdge: 56, nativeIcon: .init(icon: icon, revision: revision,
                cache: cache, decode: decode.map { decoder in { @Sendable icon in try await decoder(icon) } },
                useCache: useCache)), content: { image in content(image ?? cached) })
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
    var folder = false
    var immediateLookup = true
    var decode: AskNativeIconDecoding?
    var body: some View {
        AskNativeIconImage(icon: icon, revision: revision, folder: folder,
                           immediateLookup: immediateLookup,
                           decode: decode.map { decoder in { @Sendable icon in try await decoder(icon) } }) { image in
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: symbol).resizable().scaledToFit().padding(3).foregroundStyle(StudioTheme.textTertiary) }
        }
    }
}
