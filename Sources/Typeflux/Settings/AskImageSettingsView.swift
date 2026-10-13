import SwiftUI

/// Uses the same pane, connection card, field and action styles as Agent and Models settings.
struct AskImageSettingsView: View {
    @StateObject private var model: AskImageSettingsModel
    @State private var showsKey = false
    @State private var showsAdvanced = false
    var onSaved: (Bool, Bool) -> Void

    init(store: AskImageSettings, onSaved: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        self.init(model: AskImageSettingsModel(store: store), onSaved: onSaved)
    }

    init(model: AskImageSettingsModel, onSaved: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        _model = StateObject(wrappedValue: model)
        self.onSaved = onSaved
        let config = model.configuration
        _showsAdvanced = State(initialValue: !config.size.isEmpty || !config.quality.isEmpty || !config.routingProvider
            .isEmpty)
    }

    var body: some View {
        TypefluxForm {
            AgentPaneHeader(symbol: "photo.badge.plus", title: L("imagegen.title")) {
                TypefluxStatus(model.status.label, tone: model.status.level.tone)
                Toggle("", isOn: Binding(get: { model.enabled }, set: {
                    model.setEnabled($0)
                    onSaved(model.store.enabled, model.store.isReady)
                }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(L("imagegen.title"))
            }
            AgentSettingsSection(title: L("imagegen.connection")) {
                connectionFields
                modelField
                advancedOptions
                actions
            }
        }
        .onChange(of: model.configuration) { _ in model.clearNotice() }
        .onChange(of: model.key) { _ in model.clearNotice() }
        .onDisappear { model.cancelDiscovery() }
    }

    private var endpoint: String {
        model.configuration.baseURL
    }

    @ViewBuilder
    private var connectionFields: some View {
        formRow(L("imagegen.provider"), required: true) {
            TypefluxPopup(title: L("imagegen.provider"),
                          options: AskImageProvider.allCases.map { (label: $0.title, value: $0) },
                          selection: Binding(get: { model.configuration.provider }, set: {
                              showsKey = false
                              model.select($0)
                          }))
        }
        formRow(L("imagegen.endpoint"), required: true) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://", text: Binding(get: { endpoint }, set: model.setEndpoint))
                    .textFieldStyle(.roundedBorder)
                if model.configuration.provider == .bailian {
                    HStack(spacing: 8) {
                        regionButton("imagegen.beijing", endpoint: "https://dashscope.aliyuncs.com/api/v1")
                        regionButton("imagegen.singapore", endpoint: "https://dashscope-intl.aliyuncs.com/api/v1")
                    }
                    hint("imagegen.bailian.help")
                }
            }
        }
        formRow("API Key", required: true) { keyField }
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            Group {
                if showsKey {
                    TextField("API Key", text: $model.key)
                } else {
                    SecureField("API Key", text: $model.key)
                }
            }.textFieldStyle(.roundedBorder).accessibilityLabel("API Key")
            TypefluxIconButton(L(showsKey ? "models.hideKey" : "models.showKey"),
                               systemImage: showsKey ? "eye.slash" : "eye") { showsKey.toggle() }
        }
    }

    private var modelField: some View {
        formRow(L("imagegen.model"), required: true) {
            HStack(spacing: 8) {
                TextField(L("imagegen.model.placeholder"), text: $model.configuration.model)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("imagegen-model")
                Menu {
                    ForEach(model.models, id: \.self) { name in
                        Button(name) { model.configuration.model = name }
                    }
                } label: {
                    Image(systemName: "list.bullet").font(.body)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(L("imagegen.models.suggestions"))
                .accessibilityLabel(L("imagegen.models.suggestions"))
            }
        }
    }

    private var advancedOptions: some View {
        DisclosureGroup(L("imagegen.advanced"), isExpanded: $showsAdvanced) {
            AgentFormRow(label: L("imagegen.size")) {
                TextField(L("imagegen.providerDefault"), text: $model.configuration.size).textFieldStyle(.roundedBorder)
            }
            if [.openAI, .openRouter].contains(model.configuration.provider) {
                AgentFormRow(label: L("imagegen.quality")) {
                    TextField(L("imagegen.providerDefault"), text: $model.configuration.quality)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if model.configuration.provider == .openRouter {
                AgentFormRow(label: L("imagegen.routing")) {
                    TextField(L("imagegen.routing.auto"), text: $model.configuration.routingProvider)
                        .textFieldStyle(.roundedBorder)
                }
            }
            hint("imagegen.options.help")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.configuration.provider.supportsDiscovery {
                    Button { model.refresh() } label: {
                        HStack(spacing: 6) {
                            if model.loading {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                            }
                            Text(L("imagegen.models.refresh"))
                        }
                    }
                    .buttonStyle(.bordered).disabled(model.loading || model.key.isEmpty)
                }
                Spacer(minLength: 8)
                if model.hasChanges {
                    Text(L("imagegen.unsaved")).font(.subheadline).foregroundStyle(StudioTheme.warning)
                }
                Button(L("ask.models.save")) {
                    model.save()
                    onSaved(model.store.enabled, model.store.isReady)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.loading || !model.hasChanges)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(notice).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .font(.subheadline)
                .foregroundStyle(model.noticeIsError ? StudioTheme.danger : StudioTheme.success)
            }
        }
    }

    private func formRow(_ label: String, required: Bool = false, @ViewBuilder field: () -> some View) -> some View {
        AgentFormRow(label: label, required: required, field: field)
    }

    private func regionButton(_ title: String, endpoint: String) -> some View {
        Button(L(title)) {
            model.setEndpoint(endpoint)
        }.buttonStyle(.bordered)
    }

    private func hint(_ key: String) -> some View {
        Text(L(key)).font(.subheadline).foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
