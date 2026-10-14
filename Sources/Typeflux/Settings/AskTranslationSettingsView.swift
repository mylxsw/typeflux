import SwiftUI
import UniformTypeIdentifiers

/// Launcher → Translation: enabled services, order, AI models and provider credentials.
struct AskTranslationSettingsView: View {
    @StateObject private var model: AskTranslationSettingsModel
    @ObservedObject private var library: AskModelLibrary
    @ObservedObject private var auth = AuthState.shared
    @State private var dragging: String?

    @MainActor
    init(settings: SettingsStore, library: AskModelLibrary? = nil,
         credentials: any AskTranslationCredentialStoring = AskKeychainTranslationCredentials()) {
        _model = StateObject(wrappedValue: AskTranslationSettingsModel(store: settings, credentials: credentials))
        self.library = library ?? .shared
    }

    private var interface: AppLanguage {
        AppLocalization.shared.language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelSurface {
                AgentSettingsRow(icon: "globe", title: L("ask.settings.plugins.translate.second"),
                                 subtitle: L("ask.settings.plugins.translate.secondSubtitle"), subtitleLineLimit: nil) {
                    SettingsMenuPicker(title: L("ask.settings.plugins.translate.second"),
                                       options: AskTranslationLanguages.common.map { (label: AskTranslationLanguages.name($0, in: interface), value: $0) },
                                       selection: Binding(get: { model.secondLanguage }, set: model.setSecondLanguage))
                        .frame(width: 180)
                }
            }
            HStack {
                ModelSectionLabel(title: L("ask.translation.section.services"))
                Spacer()
                Button { model.addAI() } label: { Label(L("ask.translation.stack.addAI"), systemImage: "plus") }
                    .buttonStyle(ModelActionStyle())
            }
            .padding(.top, 14)
            ModelSurface {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.services.enumerated()), id: \.element.id) { index, service in
                        if index > 0 { ModelRowDivider(leading: 18) }
                        serviceRow(service)
                            .onDrop(of: [UTType.text], delegate: AskTranslationServiceDropDelegate(
                                id: service.id, services: model.settings.services, move: model.move, dragging: $dragging
                            ))
                    }
                }
            }
            Text(L("ask.translation.stack.footnote"))
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .onAppear(perform: model.reloadConfigured)
        .sheet(isPresented: Binding(get: { model.editing != nil }, set: { if !$0 { model.cancelEdit() } })) {
            if let provider = model.editing { AskTranslationProviderSheet(model: model, provider: provider) }
        }
    }

    private func title(_ service: AskTranslationService) -> String {
        switch service.kind {
        case .device: L("ask.translation.stack.deviceTitle")
        case let .ai(reference): AskPluginRegistry.sourceLabel(AskPluginRegistry.translationModelName(model.store, reference: reference))
        case let .provider(provider): provider.title
        }
    }

    private func status(_ service: AskTranslationService) -> String {
        switch service.kind {
        case .device: L("ask.translation.stack.local")
        case .ai: L(service.id == model.settings.firstAI?.id ? "ask.translation.stack.dictionary" : "ask.translation.stack.brief")
        case let .provider(provider): L(configured(provider) ? "ask.translation.service.configured" : "ask.translation.service.notConfigured")
        }
    }

    private func configured(_ provider: AskTranslationProvider) -> Bool { model.configured.contains(provider) }

    private func serviceRow(_ service: AskTranslationService) -> some View {
        HStack(spacing: 10) {
            Text("⋮⋮").font(.system(size: 13))
                .foregroundStyle(StudioTheme.textTertiary).frame(width: 12, height: 28).contentShape(Rectangle())
                .onDrag { dragging = service.id; return NSItemProvider(object: service.id as NSString) }
                .accessibilityLabel(L("ask.translation.stack.reorder"))
            Toggle("", isOn: Binding(get: { service.enabled }, set: { model.setEnabled(service.id, $0) }))
                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(title(service))
            AskTranslationServiceIcon(service: service)
            Text(title(service)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(service.enabled ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(service.provider.map(configured) == false ? StudioTheme.textTertiary : StudioTheme.success)
                    .frame(width: 5, height: 5)
                Text(status(service)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            switch service.kind {
            case .device:
                Button(L("ask.translation.stack.languages")) { NSWorkspace.shared.open(AskTranslationSettingsModel.languagePackagesURL) }
                    .buttonStyle(ModelActionStyle())
            case let .ai(reference):
                SettingsMenuPicker(title: L("ask.translation.model"), options: AskTranslationSettingsModel.modelOptions(
                    providers: library.selectableProviders(loggedIn: auth.isLoggedIn, hasImage: false, scenario: "rewrite"), selected: reference
                ), selection: Binding(get: { reference }, set: { model.setModel($0, for: service.id) }))
                    .frame(width: 165)
                if service.id != model.settings.firstAI?.id {
                    Button { model.removeAI(service.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                        .accessibilityLabel(L("ask.translation.stack.removeAI"))
                }
            case let .provider(provider):
                Button(L(configured(provider) ? "ask.translation.service.edit" : "ask.translation.service.configure")) { model.edit(provider) }
                    .buttonStyle(ModelActionStyle())
            }
        }
        .padding(.horizontal, 14).frame(height: 50)
        .accessibilityIdentifier("ask.translation.service." + service.id)
    }
}

private struct AskTranslationServiceDropDelegate: DropDelegate {
    let id: String
    var services: [AskTranslationService]
    var move: (String, Int) -> Void
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != id,
              let index = services.firstIndex(where: { $0.id == id }) else { return }
        move(dragging, index)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// The keys for one translation service, with a connection test.
struct AskTranslationProviderSheet: View {
    @ObservedObject var model: AskTranslationSettingsModel
    let provider: AskTranslationProvider
    var onSaved: () -> Void = {}
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
                Button(L("ask.settings.keywords.save")) { if model.save() { onSaved() } }
                    .buttonStyle(ModelActionStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("ask.translation.provider.save")
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
