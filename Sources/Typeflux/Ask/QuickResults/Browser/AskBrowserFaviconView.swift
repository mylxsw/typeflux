import SwiftUI

struct AskBrowserFaviconView: View {
    var url: URL
    var fallback: URL?
    var symbol: String
    var filled: Bool
    var cache = AskBrowserFaviconCache.shared
    @State private var loaded: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image = cache.cached(url) ?? (loadedURL == url ? loaded : nil) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
            } else {
                AskPluginItemIcon(icon: fallback.map(AskPluginItem.Icon.fileIcon), symbol: symbol, filled: filled)
            }
        }
        .frame(width: 28, height: 28)
        .task(id: url) {
            let image = await cache.image(url)
            guard !Task.isCancelled else { return }
            loaded = image
            loadedURL = url
        }
    }
}
