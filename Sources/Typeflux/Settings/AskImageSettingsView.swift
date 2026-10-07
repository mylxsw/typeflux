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
        VStack(alignment: .leading, spacing: 20) {
            AgentPaneHeader(symbol: "photo.badge.plus", title: L("imagegen.title"), subtitle: L("imagegen.summary")) {
                AgentStatusBadge(level: model.status.level, label: model.status.label)
                Toggle("", isOn: Binding(get: { model.enabled }, set: {
                    model.setEnabled($0)
                    onSaved(model.store.enabled, model.store.isReady)
                }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(L("imagegen.title"))
            }
            AgentSettingsSection(title: L("imagegen.connection"), footnote: L("imagegen.billing")) {
                connectionFields
                ModelRowDivider(leading: 18)
                modelField
                ModelRowDivider(leading: 18)
                advancedOptions
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                actions
            }
            AgentInfoNote(text: L("imagegen.retention"))
        }
        .onChange(of: model.configuration) { _ in model.clearNotice() }
        .onChange(of: model.key) { _ in model.clearNotice() }
        .onDisappear { model.cancelDiscovery() }
    }

    private var endpoint: String {
        model.configuration.baseURL
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            formRow(L("imagegen.provider"), required: true) {
                Picker(L("imagegen.provider"), selection: Binding(get: { model.configuration.provider }, set: {
                    showsKey = false
                    model.select($0)
                })) {
                    ForEach(AskImageProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            ModelRowDivider(leading: 18)
            formRow(L("imagegen.endpoint"), required: true) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://", text: Binding(get: { endpoint }, set: model.setEndpoint))
                        .textFieldStyle(ModelFieldStyle())
                    if model.configuration.provider == .bailian {
                        HStack(spacing: 8) {
                            regionButton("imagegen.beijing", endpoint: "https://dashscope.aliyuncs.com/api/v1")
                            regionButton("imagegen.singapore", endpoint: "https://dashscope-intl.aliyuncs.com/api/v1")
                        }
                        hint("imagegen.bailian.help")
                    }
                }
            }
            ModelRowDivider(leading: 18)
            formRow("API Key", required: true) { keyField }
        }
    }

    private var keyField: some View {
        Group {
            if showsKey {
                TextField("API Key", text: $model.key)
            } else {
                SecureField("API Key", text: $model.key)
            }
        }
        .textFieldStyle(ModelFieldStyle(trailingAccessoryWidth: 24))
        .overlay(alignment: .trailing) {
            Button { showsKey.toggle() } label: {
                Image(systemName: showsKey ? "eye.slash" : "eye")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.trailing, 3)
            .help(L(showsKey ? "models.hideKey" : "models.showKey"))
            .accessibilityLabel(L(showsKey ? "models.hideKey" : "models.showKey"))
        }
    }

    private var modelField: some View {
        formRow(L("imagegen.model"), required: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(L("imagegen.model.placeholder"), text: $model.configuration.model)
                        .textFieldStyle(ModelFieldStyle()).accessibilityIdentifier("imagegen-model")
                    Menu {
                        ForEach(model.models, id: \.self) { name in
                            Button(name) { model.configuration.model = name }
                        }
                    } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help(L("imagegen.models.suggestions"))
                        .accessibilityLabel(L("imagegen.models.suggestions"))
                }
                hint("imagegen.models.help")
                if !model.configuration.provider.supportsDiscovery {
                    hint("imagegen.models.builtin")
                }
            }
        }
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentDisclosureButton(title: L("imagegen.advanced"), expanded: $showsAdvanced)
            if showsAdvanced {
                AgentFormRow(label: L("imagegen.size")) {
                    TextField(L("imagegen.providerDefault"), text: $model.configuration.size)
                        .textFieldStyle(ModelFieldStyle())
                }
                if [.openAI, .openRouter].contains(model.configuration.provider) {
                    AgentFormRow(label: L("imagegen.quality")) {
                        TextField(L("imagegen.providerDefault"), text: $model.configuration.quality)
                            .textFieldStyle(ModelFieldStyle())
                    }
                }
                if model.configuration.provider == .openRouter {
                    AgentFormRow(label: L("imagegen.routing")) {
                        TextField(L("imagegen.routing.auto"), text: $model.configuration.routingProvider)
                            .textFieldStyle(ModelFieldStyle())
                    }
                }
                hint("imagegen.options.help")
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.configuration.provider.supportsDiscovery {
                    Button { model.refresh() } label: {
                        HStack(spacing: 6) {
                            if model.loading {
                                ProgressView().controlSize(.small)
                            }
                            Text(L("imagegen.models.refresh"))
                        }
                    }
                    .buttonStyle(ModelActionStyle()).disabled(model.loading || model.key.isEmpty)
                }
                Spacer(minLength: 8)
                Button(L("ask.models.save")) {
                    model.save()
                    onSaved(model.store.enabled, model.store.isReady)
                }
                .buttonStyle(ModelActionStyle(primary: true))
                .disabled(model.loading || !model.hasChanges)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(notice).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .font(.system(size: 12))
                .foregroundStyle(model.noticeIsError ? StudioTheme.danger : StudioTheme.success)
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func formRow(_ label: String, required: Bool = false, @ViewBuilder field: () -> some View) -> some View {
        AgentFormRow(label: label, required: required, field: field)
            .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func regionButton(_ title: String, endpoint: String) -> some View {
        Button(L(title)) {
            model.setEndpoint(endpoint)
        }.buttonStyle(ModelActionStyle())
    }

    private func hint(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
