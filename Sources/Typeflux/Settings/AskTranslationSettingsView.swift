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
        VStack(alignment: .leading, spacing: 10) {
            ModelSectionLabel(title: L("ask.translation.section.engine"))
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    AgentSettingsRow(icon: "arrow.triangle.branch", title: L("ask.translation.engine"),
                                     subtitle: L("ask.translation.engine.subtitle"), subtitleLineLimit: nil) {
                        SettingsMenuPicker(title: L("ask.translation.engine"), options: model.engineOptions,
                                           selection: Binding(get: { model.settings.engine.rawValue },
                                                              set: model.setEngine))
                            .frame(width: 200)
                    }
                    ModelRowDivider(leading: 66)
                    AgentSettingsRow(icon: "sparkles", title: L("ask.translation.model"),
                                     subtitle: L("ask.translation.model.subtitle"), subtitleLineLimit: nil) {
                        SettingsMenuPicker(
                            title: L("ask.translation.model"),
                            options: AskTranslationSettingsModel.modelOptions(
                                providers: library.selectableProviders(loggedIn: auth.isLoggedIn, hasImage: false,
                                                                       scenario: "rewrite"),
                                selected: model.settings.modelReference
                            ),
                            selection: Binding(get: { model.settings.modelReference }, set: model.setModel)
                        )
                        .frame(width: 200)
                    }
                    ModelRowDivider(leading: 66)
                    toggleRow(icon: "laptopcomputer", title: "ask.translation.onDevice",
                              subtitle: "ask.translation.onDevice.subtitle",
                              isOn: Binding(get: { model.settings.prefersOnDevice }, set: model.setPrefersOnDevice))
                    ModelRowDivider(leading: 66)
                    toggleRow(icon: "arrow.uturn.backward", title: "ask.translation.fallback",
                              subtitle: "ask.translation.fallback.subtitle",
                              isOn: Binding(get: { model.settings.fallsBackToAI }, set: model.setFallsBackToAI))
                    ModelRowDivider(leading: 66)
                    AgentSettingsRow(icon: "globe", title: L("ask.settings.plugins.translate.second"),
                                     subtitle: L("ask.settings.plugins.translate.secondSubtitle"), subtitleLineLimit: nil) {
                        SettingsMenuPicker(title: L("ask.settings.plugins.translate.second"),
                                           options: AskTranslationLanguages.common.map { (
                                               label: AskTranslationLanguages.name($0, in: interface),
                                               value: $0
                                           ) },
                                           selection: Binding(get: { model.secondLanguage }, set: model.setSecondLanguage))
                            .frame(width: 200)
                    }
                }
            }
            ModelSectionLabel(title: L("ask.translation.section.services")).padding(.top, 14)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AskTranslationProvider.allCases.enumerated()), id: \.element) { index, provider in
                        if index > 0 { ModelRowDivider(leading: 18) }
                        serviceRow(provider)
                    }
                }
            }
            Text(L("ask.translation.services.footnote"))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 4)
        }
        .onAppear(perform: model.reloadConfigured)
        .sheet(isPresented: Binding(get: { model.editing != nil }, set: { if !$0 { model.cancelEdit() } })) {
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
                .font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            HStack(spacing: 4) {
                Circle().fill(configured ? StudioTheme.success : StudioTheme.textTertiary).frame(width: 6, height: 6)
                Text(L(configured ? "ask.translation.service.configured" : "ask.translation.service.notConfigured"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            if model.settings.engine == .service(provider) {
                ModelUsageBadge(text: L("ask.translation.service.inUse"))
            }
            Spacer()
            Button(L(configured ? "ask.translation.service.edit" : "ask.translation.service.configure")) {
                model.edit(provider)
            }
            .buttonStyle(ModelActionStyle())
            .accessibilityIdentifier("ask.translation.service." + provider.rawValue)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

/// The keys for one translation service, with a connection test.
struct AskTranslationProviderSheet: View {
    @ObservedObject var model: AskTranslationSettingsModel
    let provider: AskTranslationProvider
    @State private var showsSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.translation.sheet.title", provider.title))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            AgentFormRow(label: provider.keyLabel, required: true, labelWidth: 130) {
                secureField(provider.keyLabel, text: $model.draft.key)
            }
            if let secretLabel = provider.secretLabel {
                AgentFormRow(label: secretLabel, required: true, labelWidth: 130) {
                    secureField(secretLabel, text: $model.draft.secret)
                }
            }
            if let regionLabel = provider.regionLabel {
                AgentFormRow(label: regionLabel, labelWidth: 130) {
                    TextField(provider.defaultRegion.isEmpty ? "eastasia" : provider.defaultRegion,
                              text: $model.draft.region)
                        .textFieldStyle(ModelFieldStyle())
                }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 12))
                    .foregroundStyle(model.noticeIsError ? StudioTheme.danger : StudioTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L("ask.translation.test")) { model.test() }
                    .buttonStyle(ModelActionStyle())
                    .disabled(!model.canSave || model.testing)
                if model.testing { ProgressView().controlSize(.small) }
                Spacer()
                if model.configured.contains(provider) {
                    Button(role: .destructive) { model.remove() } label: {
                        Text(L("ask.translation.remove")).foregroundStyle(StudioTheme.danger)
                    }
                    .buttonStyle(ModelActionStyle())
                }
                Button(L("ask.workflow.cancel")) { model.cancelEdit() }
                    .buttonStyle(ModelActionStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("ask.settings.keywords.save")) { model.save() }
                    .buttonStyle(ModelActionStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        Group {
            if showsSecret {
                TextField(title, text: text)
            } else {
                SecureField(title, text: text)
            }
        }
        .textFieldStyle(ModelFieldStyle(trailingAccessoryWidth: 24))
        .overlay(alignment: .trailing) {
            Button { showsSecret.toggle() } label: {
                Image(systemName: showsSecret ? "eye.slash" : "eye")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.trailing, 3)
            .help(L(showsSecret ? "models.hideKey" : "models.showKey"))
            .accessibilityLabel(L(showsSecret ? "models.hideKey" : "models.showKey"))
        }
    }
}
