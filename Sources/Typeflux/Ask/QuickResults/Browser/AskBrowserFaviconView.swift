import SwiftUI
import TypefluxMediaProtocol

/// One accepted chooser retains both original native branches, then checks only the selected result.
@MainActor struct AskBrowserIconPreparation {
    let url: URL
    let cache: AskBrowserFaviconCache
    var fallback: MediaNativeIcon?
    var decode: AskNativeIconDecoding?
    var worker: MediaWorker = .previews

    func bind(_ source: String, access: AskImagePresentationAccess) throws -> Batch {
        guard source == url.absoluteString else { throw MediaFailure.unavailable }
        let native = try fallback.map { icon in
            try AskNativeIconPreparation(icon: icon, decode: decode, useCache: false, worker: worker)
                .bind(icon.kind.rawValue + ":" + icon.value)
        }
        return Batch(favicon: cache.preparation(url, access: access), native: native, access: access)
    }

    @MainActor final class Batch {
        private let favicon: AskBrowserFaviconCache.ImagePreparation
        private let native: AskNativeIconPreparation.Batch?
        private let access: AskImagePresentationAccess
        private var selected: (@MainActor @Sendable () -> Bool)?
        init(favicon: AskBrowserFaviconCache.ImagePreparation, native: AskNativeIconPreparation.Batch?,
             access: AskImagePresentationAccess) {
            self.favicon = favicon; self.native = native; self.access = access
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && favicon.isCurrent() && (selected?() ?? true)
        }
        func decode() async throws -> AskFilePreviewPDF.Result {
            guard isCurrent() else { throw MediaFailure.unavailable }
            if let result = await favicon.image() {
                selected = result.isCurrent
                guard isCurrent() else { throw MediaFailure.unavailable }
                return .init(images: [result.image], numbers: [], pages: 0)
            }
            try Task.checkCancellation()
            guard isCurrent(), access.allows() else { throw MediaFailure.unavailable }
            try Task.checkCancellation()
            guard isCurrent(), let native else { throw MediaFailure.unavailable }
            selected = native.isCurrent
            let result = try await native.decode()
            guard isCurrent() else { throw MediaFailure.unavailable }
            return result
        }
    }
}

struct AskBrowserFaviconView: View {
    var url: URL
    var fallback: URL?
    var application: String? = nil
    var symbol: String
    var filled: Bool
    var cache = AskBrowserFaviconCache.shared
    @State private var settingsChanged = false
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.nativeIconDecoderOverride) private var nativeDecode

    var body: some View {
        Group {
            if settingsChanged { AskPluginItemIcon(icon: nil, symbol: symbol, filled: filled) }
            else { preparedIcon }
        }
        .frame(width: 28, height: 28)
        .onReceive(NotificationCenter.default.publisher(for: .askLauncherSearchSettingsDidChange)) { _ in
            // Old rows must not start new origin requests after a privacy-settings change.
            settingsChanged = true; cache.cancel()
        }
    }

    private var preparedIcon: some View {
        let target = fallbackTarget
        return AskContextImage(source: url.absoluteString,
            model: AskContextImageModel(maximumEdge: 56, browserIcon: .init(url: url, cache: cache,
                fallback: target, decode: nativeDecode?.decode))) { image in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
            } else { AskPluginItemIcon(icon: nil, symbol: symbol, filled: filled) }
        }
        .id(Identity(url: url, fallback: target, epoch: access.epoch))
    }

    private struct Identity: Hashable { let url: URL; let fallback: MediaNativeIcon?; let epoch: UUID? }

    /// One owned preparation chooses favicon or application, rather than creating a native
    /// fallback task each time the favicon's loading/failure view changes.
    private var fallbackTarget: MediaNativeIcon? {
        if let fallback, fallback.isFileURL { return .init(kind: .file, value: fallback.path) }
        return application.map { .init(kind: .application, value: $0) }
    }
}
