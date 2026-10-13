import SwiftUI

/// Launcher → Translation: the engine, the AI's model, and the translation services.
struct AskTranslationSettingsView: View {
    @StateObject private var model: AskTranslationSettingsModel
    @ObservedObject private var library: AskModelLibrary
    @ObservedObject private var auth = AuthState.shared

    @MainActor
    init(settings: SettingsStore, library: AskModelLibrary? = nil) {
        _model = StateObject(wrappedValue: AskTranslationSettingsModel(store: settings))
        self.library = library ?? .shared
    }

    private var interface: AppLanguage {
        AppLocalization.shared.language
    }

    var body: some View {
        TypefluxForm {
            TypefluxFormSection(L("ask.translation.section.engine")) {
                AgentSettingsRow(icon: "arrow.triangle.branch", title: L("ask.translation.engine"),
                                 subtitle: L("ask.translation.engine.subtitle"), subtitleLineLimit: nil) {
                    TypefluxPopup(title: L("ask.translation.engine"), options: model.engineOptions,
                                  selection: Binding(get: { model.settings.engine.rawValue },
                                                     set: model.setEngine))
                        .frame(width: 200)
                }
                AgentSettingsRow(icon: "sparkles", title: L("ask.translation.model"),
                                 subtitle: L("ask.translation.model.subtitle"), subtitleLineLimit: nil) {
                    TypefluxPopup(title: L("ask.translation.model"),
                                  options: AskTranslationSettingsModel.modelOptions(
                                      providers: library.selectableProviders(
                                          loggedIn: auth.isLoggedIn,
                                          hasImage: false,
                                          scenario: "rewrite"
                                      ),
                                      selected: model.settings.modelReference
                                  ),
                                  selection: Binding(get: { model.settings.modelReference }, set: model.setModel))
                        .frame(width: 200)
                }
                toggleRow(icon: "laptopcomputer", title: "ask.translation.onDevice",
                          subtitle: "ask.translation.onDevice.subtitle",
                          isOn: Binding(get: { model.settings.prefersOnDevice }, set: model.setPrefersOnDevice))
                toggleRow(icon: "arrow.uturn.backward", title: "ask.translation.fallback",
                          subtitle: "ask.translation.fallback.subtitle",
                          isOn: Binding(get: { model.settings.fallsBackToAI }, set: model.setFallsBackToAI))
                AgentSettingsRow(icon: "globe", title: L("ask.settings.plugins.translate.second"),
                                 subtitle: L("ask.settings.plugins.translate.secondSubtitle"),
                                 subtitleLineLimit: nil) {
                    TypefluxPopup(title: L("ask.settings.plugins.translate.second"),
                                  options: AskTranslationLanguages.common.map { (
                                      label: AskTranslationLanguages.name($0, in: interface),
                                      value: $0
                                  ) },
                                  selection: Binding(get: { model.secondLanguage }, set: model.setSecondLanguage))
                        .frame(width: 200)
                }
            }
            TypefluxFormSection(L("ask.translation.section.services"), footer: L("ask.translation.services.footnote")) {
                ForEach(AskTranslationProvider.allCases) { serviceRow($0) }
            }
        }
        .onAppear(perform: model.reloadConfigured)
        .sheet(isPresented: Binding(get: { model.editing != nil }, set: {
            if !$0 {
                model.cancelEdit()
            }
        })) {
            if let provider = model.editing {
                AskTranslationProviderSheet(model: model, provider: provider)
            }
        }
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        AgentSettingsRow(icon: icon, title: L(title), subtitle: L(subtitle), subtitleLineLimit: nil) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(L(title))
        }
    }

    private func serviceRow(_ provider: AskTranslationProvider) -> some View {
        let configured = model.configured.contains(provider)
        return HStack(spacing: 10) {
            Text(provider.title)
                .font(.body)
                .foregroundStyle(TypefluxColor.label.color)
            TypefluxStatus(
                L(configured ? "ask.translation.service.configured" : "ask.translation.service.notConfigured"),
                tone: configured ? .success : .inactive
            )
            if model.settings.engine == .service(provider) {
                Text(L("ask.translation.service.inUse")).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L(configured ? "ask.translation.service.edit" : "ask.translation.service.configure")) {
                model.edit(provider)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ask.translation.service." + provider.rawValue)
        }
    }
}
