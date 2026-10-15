import AppKit
import SwiftUI
#if canImport(Translation)
    import Translation
#endif

struct AskTranslationLanguageDownload: Identifiable {
    let id = UUID()
    var source: String
    var target: String
}

/// A view-owned session can ask for downloads; the headless installed-only engine cannot.
struct AskTranslationLanguageDownloadPresenter: View {
    @ObservedObject var model: AskTranslationSettingsModel
    var onReady: () -> Void
    var supportsSystemDownloads = Self.systemSupportsDownloads
    var openSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private static var systemSupportsDownloads: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var body: some View {
        if let request = model.languageDownload {
            #if canImport(Translation)
                if #available(macOS 15.0, *), supportsSystemDownloads {
                    Color.clear.frame(width: 1, height: 1)
                        .translationTask(.init(source: Locale.Language(identifier: request.source),
                                               target: Locale.Language(identifier: request.target))) { session in
                            await model.prepareLanguages(request, prepare: { try await session.prepareTranslation() },
                                                         onReady: onReady,
                                                         openSettings: openSettings)
                        }
                        .id(request.id)
                } else {
                    fallback
                }
            #else
                fallback
            #endif
        }
    }

    private var fallback: some View {
        Color.clear.onAppear {
            model.languageDownload = nil
            openSettings(AskTranslationSettingsModel.languagePackagesURL)
        }
    }
}
