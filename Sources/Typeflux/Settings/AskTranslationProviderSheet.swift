import SwiftUI

/// The keys for one translation service, with a connection test.
struct AskTranslationProviderSheet: View {
    @ObservedObject var model: AskTranslationSettingsModel
    let provider: AskTranslationProvider
    @State private var showsSecret = false

    var body: some View {
        TypefluxSheet(title: L("ask.translation.sheet.title", provider.title), cancelTitle: L("ask.workflow.cancel"),
                      confirmTitle: L("ask.settings.keywords.save"), isConfirmEnabled: model.canSave,
                      cancel: { model.cancelEdit() }, confirm: { model.save() }, content: {
                          TypefluxForm {
                              Section {
                                  AgentFormRow(label: provider.keyLabel, required: true) { secureField(
                                      provider.keyLabel,
                                      text: $model.draft.key
                                  ) }
                                  if let secretLabel = provider.secretLabel {
                                      AgentFormRow(label: secretLabel, required: true) { secureField(
                                          secretLabel,
                                          text: $model.draft.secret
                                      ) }
                                  }
                                  if let regionLabel = provider.regionLabel {
                                      AgentFormRow(label: regionLabel) {
                                          TextField(
                                              provider.defaultRegion.isEmpty ? "eastasia" : provider.defaultRegion,
                                              text: $model.draft.region
                                          ).textFieldStyle(.roundedBorder)
                                      }
                                  }
                                  if let notice = model.notice {
                                      Text(notice).font(.subheadline)
                                          .foregroundStyle(model.noticeIsError ? TypefluxColor.danger
                                              .color : TypefluxColor.success.color)
                                  }
                              }
                              Section {
                                  Button(L("ask.translation.test")) { model.test() }
                                      .disabled(!model.canSave || model.testing)
                                  if model.testing {
                                      ProgressView().controlSize(.small)
                                  }
                                  if model.configured.contains(provider) {
                                      Button(L("ask.translation.remove"), role: .destructive) { model.remove() }
                                  }
                              }
                          }.frame(height: 300)
                      }).frame(width: 520)
            .onDisappear { model.cancelEdit() }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Group {
                if showsSecret {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }.textFieldStyle(.roundedBorder).accessibilityLabel(title)
            TypefluxIconButton(L(showsSecret ? "models.hideKey" : "models.showKey"),
                               systemImage: showsSecret ? "eye.slash" : "eye") { showsSecret.toggle() }
        }
    }
}
