import SwiftUI

/// Settings → Agent → Image Generation: the switch, the provider connection and its models.
struct AskImageSettingsView: View {
    @StateObject private var model: AskImageSettingsModel
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
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFPaneHeader(systemImage: "photo.badge.plus", title: L("imagegen.title")) {
                model.status.statusLabel
                TFSwitch(title: L("imagegen.title"), isOn: Binding(get: { model.enabled }, set: {
                    model.setEnabled($0)
                    onSaved(model.store.enabled, model.store.isReady)
                }))
            }
            TFFormSection(title: L("imagegen.connection")) {
                connectionFields
                TFDivider.formWithIcon
                modelField
                TFDivider.form
                advancedOptions
                TFDivider.form
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

    @ViewBuilder private var connectionFields: some View {
        TFFormRow(title: L("imagegen.provider"), icon: "building.2", isRequired: true, controlWidth: .wide) {
            TFPopUpButton(title: L("imagegen.provider"),
                          options: AskImageProvider.allCases.map { TFOption($0, $0.title) },
                          selection: Binding(get: { model.configuration.provider }, set: { model.select($0) }),
                          width: TFMetrics.formControlWideWidth)
        }
        TFDivider.formWithIcon
        TFFormRow(title: L("imagegen.endpoint"), icon: "link", isRequired: true, controlWidth: .wide) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://", text: Binding(get: { endpoint }, set: model.setEndpoint))
                    .textFieldStyle(TFTextFieldStyle(monospaced: true))
                if model.configuration.provider == .bailian {
                    HStack(spacing: TFMetrics.toolbarSpacing) {
                        regionButton("imagegen.beijing", endpoint: "https://dashscope.aliyuncs.com/api/v1")
                        regionButton("imagegen.singapore", endpoint: "https://dashscope-intl.aliyuncs.com/api/v1")
                    }
                    TFFootnote(text: L("imagegen.bailian.help"))
                }
            }
        }
        TFDivider.formWithIcon
        TFFormRow(title: "API Key", icon: "key", isRequired: true, controlWidth: .wide) {
            TFSecureField(placeholder: "API Key", text: $model.key)
        }
    }

    private var modelField: some View {
        TFFormRow(title: L("imagegen.model"), icon: "cube", isRequired: true, controlWidth: .wide) {
            TextField(L("imagegen.model.placeholder"), text: $model.configuration.model)
                .textFieldStyle(TFTextFieldStyle(monospaced: true)).accessibilityIdentifier("imagegen-model")
            TFMenuButton(title: L("imagegen.models.suggestions"), systemImage: "list.bullet", iconOnly: true,
                         actions: model.models.map { name in .action(name) { model.configuration.model = name } })
                .disabled(model.models.isEmpty)
        }
    }

    @ViewBuilder private var advancedOptions: some View {
        TFDisclosureRow(title: L("imagegen.advanced"), isExpanded: $showsAdvanced)
        if showsAdvanced {
            TFFormRow(title: L("imagegen.size"), controlWidth: .wide) {
                TextField(L("imagegen.providerDefault"), text: $model.configuration.size)
                    .textFieldStyle(TFTextFieldStyle())
            }
            if [.openAI, .openRouter].contains(model.configuration.provider) {
                TFFormRow(title: L("imagegen.quality"), controlWidth: .wide) {
                    TextField(L("imagegen.providerDefault"), text: $model.configuration.quality)
                        .textFieldStyle(TFTextFieldStyle())
                }
            }
            if model.configuration.provider == .openRouter {
                TFFormRow(title: L("imagegen.routing"), controlWidth: .wide) {
                    TextField(L("imagegen.routing.auto"), text: $model.configuration.routingProvider)
                        .textFieldStyle(TFTextFieldStyle())
                }
            }
            TFFootnote(text: L("imagegen.options.help")).padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: TFMetrics.toolbarSpacing) {
                if model.configuration.provider.supportsDiscovery {
                    TFButton(title: L("imagegen.models.refresh"), isLoading: model.loading) { model.refresh() }
                        .disabled(model.loading || model.key.isEmpty)
                }
                Spacer(minLength: 8)
                if model.hasChanges {
                    TFFieldMessage(text: L("imagegen.unsaved"), tone: .warning)
                }
                TFButton(title: L("ask.models.save"), kind: .primary) {
                    model.save()
                    onSaved(model.store.enabled, model.store.isReady)
                }
                .disabled(model.loading || !model.hasChanges)
            }
            if let notice = model.notice {
                TFNotice(text: notice, tone: model.noticeIsError ? .danger : .success)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func regionButton(_ title: String, endpoint: String) -> some View {
        TFButton(title: L(title), size: .small) { model.setEndpoint(endpoint) }
    }
}
