import SwiftUI

struct AskTranslationConfigurationPresenter: View {
    @ObservedObject var model: AskTranslationSettingsModel
    var onConfigured: (AskTranslationProvider) -> Void = { _ in }
    var onLanguagesReady: () -> Void = {}
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .background(AskTranslationLanguageDownloadPresenter(model: model, onReady: onLanguagesReady))
            .sheet(isPresented: Binding(get: { model.editing != nil }, set: {
                if !$0 {
                    model.cancelEdit()
                }
            })) {
                if let provider = model.editing {
                    AskTranslationProviderSheet(model: model, provider: provider, onSaved: { onConfigured(provider) })
                }
            }
    }
}
