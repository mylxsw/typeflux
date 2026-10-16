import SwiftUI
import TypefluxMediaProtocol

struct AskBrowserFaviconView: View {
    var url: URL
    var fallback: URL?
    var symbol: String
    var filled: Bool
    var cache = AskBrowserFaviconCache.shared
    @State private var settingsChanged = false
    @Environment(\.askContextImageAccess) private var access

    var body: some View {
        Group {
            if settingsChanged { fallbackIcon }
            else { preparedIcon }
        }
        .frame(width: 28, height: 28)
        .onReceive(NotificationCenter.default.publisher(for: .askLauncherSearchSettingsDidChange)) { _ in
            // Old rows must not start new origin requests after a privacy-settings change.
            settingsChanged = true; cache.cancel()
        }
    }

    private var preparedIcon: some View {
        AskContextImage(source: url.absoluteString, model: AskContextImageModel(maximumEdge: 56, decode: { _ in
            guard let image = await cache.image(url, access: access) else { throw MediaFailure.unavailable }
            return .init(images: [image], numbers: [], pages: 0)
        })) { image in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
            } else { fallbackIcon }
        }
        .id(AskContextImageModel.Identity(source: url.absoluteString, epoch: access.epoch))
    }

    private var fallbackIcon: some View {
        AskPluginItemIcon(icon: fallback.map(AskPluginItem.Icon.fileIcon), symbol: symbol, filled: filled)
    }
}
