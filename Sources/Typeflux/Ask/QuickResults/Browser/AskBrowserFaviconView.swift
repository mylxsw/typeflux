import SwiftUI
import TypefluxMediaProtocol

struct AskBrowserFaviconView: View {
    var url: URL
    var fallback: URL?
    var application: String? = nil
    var symbol: String
    var filled: Bool
    var cache = AskBrowserFaviconCache.shared
    @State private var settingsChanged = false
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askNativeIconDecoder) private var nativeDecode

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
        return AskContextImage(source: url.absoluteString, model: AskContextImageModel(maximumEdge: 56, decode: { _ in
            if let image = await cache.image(url, access: access) {
                return .init(images: [image], numbers: [], pages: 0)
            }
            try Task.checkCancellation()
            guard await access.allows(), let target else { throw MediaFailure.unavailable }
            return try await nativeDecode(target)
        })) { image in
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
