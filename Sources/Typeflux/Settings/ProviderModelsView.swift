import SwiftUI

struct ProviderModelsView: View {
    @ObservedObject var library: AskModelLibrary
    let providerID: String
    var onBack: (() -> Void)?
    @ObservedObject private var auth = AuthState.shared
    @State private var baseURL = ""
    @State private var key = ""
    @State private var savedBaseURL = ""
    @State private var savedKey = ""
    @State private var apiStyle = LLMRemoteAPIStyle.openAICompatible
    @State private var savedAPIStyle = LLMRemoteAPIStyle.openAICompatible
    @State private var modelID = ""
    @State private var manual = false
    @State private var loading = false
    @State private var loaded: [RegisteredModel] = []
    @State private var selected = Set<String>()
    @State private var showingCatalog = false
    @State private var notice: String?
    @State private var noticeIsSuccess = false
    @State private var pendingDeletion: RegisteredModel?
    @State private var operation: Task<Void, Never>?

    private var provider: RegisteredProvider? {
        library.providers.first { $0.id == providerID }
    }

    var body: some View {
        if provider?.isCloud == true {
            CloudProviderModelsView(library: library, onBack: onBack)
        } else {
            editableBody
        }
    }

    private var editableBody: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            if let provider {
                ModelDetailHeader(
                    title: provider.name,
                    icon: provider.studioProviderID,
                    connected: library.unavailableReason(provider, loggedIn: auth.isLoggedIn) == nil,
                    onBack: onBack
                )
                if provider.remote == .freeModel {
                    TFNotice(text: L("settings.models.freeModel.hint"))
                } else {
                    connectionCard(provider)
                }
                modelsSection(provider)
                if provider.remote == .freeModel, let notice {
                    noticeView(notice)
                }
            }
        }
        .onAppear {
            if let provider {
                let value = library.connection(provider)
                apiStyle = value.effectiveAPIStyle; savedAPIStyle = apiStyle
                baseURL = value.baseURL; key = value.apiKey
                savedBaseURL = value.baseURL; savedKey = value.apiKey
            }
        }
        .onDisappear { operation?.cancel() }
        .sheet(isPresented: $showingCatalog) { catalogSheet }
        .alert(
            L("ask.models.delete"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            })
        ) {
            Button(L("ask.models.cancel"), role: .cancel) { pendingDeletion = nil }
            Button(L("ask.models.delete"), role: .destructive) {
                if let model = pendingDeletion {
                    perform { try library.removeModel(
                        model.reference,
                        providerID: providerID
                    ) }
                }
                pendingDeletion = nil
            }
        } message: { Text(L("models.deleteHint")) }
    }

    private func connectionCard(_ provider: RegisteredProvider) -> some View {
        TFFormSection(title: L("models.connection")) {
            if provider.supportsProtocolSelection {
                TFFormRow(title: L("models.protocol"), icon: "arrow.left.arrow.right", controlWidth: .wide) {
                    TFPopUpButton(title: L("models.protocol"),
                                  options: LLMRemoteAPIStyle.customChoices.map { TFOption($0, $0.displayName) },
                                  selection: $apiStyle, width: TFMetrics.formControlWideWidth)
                }
                TFDivider.formWithIcon
            }
            TFFormRow(title: L("settings.models.apiEndpoint"), icon: "link", controlWidth: .wide) {
                TextField("https://api.example.com/v1", text: $baseURL)
                    .textFieldStyle(TFTextFieldStyle(monospaced: true))
            }
            if !provider.isOllama {
                TFDivider.formWithIcon
                TFFormRow(title: "API Key", icon: "key", controlWidth: .wide) {
                    TFSecureField(placeholder: "API Key", text: $key)
                }
            }
            TFDivider.form
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    if loading { TFSpinner() }
                    Spacer(minLength: 8)
                    TFButton(title: L("ask.models.test")) { testConnection(provider) }.disabled(loading)
                    TFButton(title: L("ask.models.save"), kind: .primary) { save(provider) }
                        .disabled(loading || !ModelSettingsPresentation.connectionChanged(
                            savedBaseURL: savedBaseURL, savedKey: savedKey, baseURL: baseURL, key: key,
                            savedAPIStyle: savedAPIStyle, apiStyle: apiStyle
                        ))
                }
                if !loading, let notice {
                    noticeView(notice)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func modelsSection(_ provider: RegisteredProvider) -> some View {
        let rewriteReferences = selectableReferences(scenario: "rewrite")
        let askReferences = selectableReferences(scenario: "ask")
        let showsHint = ModelSettingsPresentation.showsUsageHint(provider.models,
                                                                 rewriteReference: library.rewriteReference,
                                                                 defaultReference: library.defaultReference)
        return TFFormSection(title: L("common.model"), count: provider.models.count,
                             footnote: showsHint ? L("models.usageHint") : nil) {
            TFButton(title: L("models.manual"), systemImage: "plus") { manual = true }
            TFButton(title: L("models.load"), systemImage: "arrow.clockwise") { load(provider) }
                .disabled(loading)
        } content: {
            if manual {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    TextField(L("ask.models.modelID"), text: $modelID)
                        .textFieldStyle(TFTextFieldStyle(monospaced: true))
                        .onSubmit { addManualModel(provider) }
                    TFButton(title: L("ask.models.cancel")) { manual = false; modelID = "" }
                    TFButton(title: L("models.add"), kind: .primary) { addManualModel(provider) }
                        .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if !provider.models.isEmpty { TFDivider.form }
            }
            ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { TFDivider.formWithIcon }
                modelRow(model, provider: provider, canRewrite: rewriteReferences.contains(model.reference),
                         canAsk: askReferences.contains(model.reference))
            }
            if provider.models.isEmpty, !manual {
                TFCardNote(text: L("models.noModels"))
            }
        }
    }
}

extension ProviderModelsView {
    private func modelRow(_ model: RegisteredModel, provider: RegisteredProvider, canRewrite: Bool, canAsk: Bool) -> some View {
        HStack(spacing: 12) {
            TFLogoTile { ModelIcon(model: model, provider: provider) }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id).font(.system(size: 13, design: .monospaced)).foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = model.exclusionReason {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            ModelUsageTags(reference: model.reference, library: library)
            visionIndicator(model)
            TFMenuButton(title: L("component.more"), systemImage: "ellipsis", kind: .plain, size: .small,
                         iconOnly: true, actions: modelActions(model, provider: provider, canRewrite: canRewrite,
                                                               canAsk: canAsk))
        }
        .padding(.leading, 14).padding(.trailing, 10).frame(minHeight: 46)
    }

    /// Checked when already in use; greyed out only when the scene cannot take it, with the reason below.
    private func modelActions(_ model: RegisteredModel, provider: RegisteredProvider, canRewrite: Bool,
                              canAsk: Bool) -> [TFMenuAction] {
        var actions: [TFMenuAction] = [
            .toggle(L("models.useForRewrite"), isOn: library.rewriteReference == model.reference,
                    isEnabled: canRewrite) { if $0 { library.rewriteReference = model.reference } },
            .toggle(L("ask.models.makeDefault"), isOn: library.defaultReference == model.reference,
                    isEnabled: canAsk) { if $0 { library.defaultReference = model.reference } }
        ]
        actions += sceneBlockedNotes(model, provider: provider, canRewrite: canRewrite, canAsk: canAsk).map { .note($0) }
        actions += [
            .separator,
            .note(L("models.capabilityHint")),
            .toggle(L("models.visionYes"), isOn: model.effectiveVision == true) {
                setCapability(\.vision, $0, model: model)
            },
            // Unset reasoning still offers the effort menu (see `AskReasoningEffort`), so it reads as on.
            .toggle(L("models.reasoningYes"), isOn: model.reasoning != false) {
                setCapability(\.reasoning, $0, model: model)
            },
            .separator,
            .action(L("ask.models.delete"), destructive: true) { pendingDeletion = model }
        ]
        return actions
    }

    private func sceneBlockedNotes(_ model: RegisteredModel, provider: RegisteredProvider,
                                   canRewrite: Bool, canAsk: Bool) -> [String] {
        func reason(_ scenario: String) -> String {
            library.selectionReason(model, provider: provider, hasImage: false, loggedIn: auth.isLoggedIn, scenario: scenario)
                ?? L("ask.models.unavailable")
        }
        return ModelSettingsPresentation.sceneBlockedNotes(rewrite: canRewrite ? nil : reason("rewrite"),
                                                           ask: canAsk ? nil : reason("ask"))
    }

    @ViewBuilder
    private func visionIndicator(_ model: RegisteredModel) -> some View {
        switch model.effectiveVision {
        case true?:
            TFTag(text: L("ask.models.badge.vision"))
                .help(L(model.visionIsGuessed ? "models.visionGuessed" : "ask.models.supportsImages"))
        case nil:
            TFTag(text: L("models.visionUnknownShort")).opacity(0.7)
                .help(L("models.capabilityHint"))
        case false?:
            EmptyView()
        }
    }

    private func noticeView(_ text: String) -> some View {
        TFNotice(text: text, tone: noticeIsSuccess ? .success : .danger)
    }

    /// References the scene pickers would offer, so row shortcuts never assign an ineligible model.
    private func selectableReferences(scenario: String) -> Set<String> {
        Set(library.selectableProviders(loggedIn: auth.isLoggedIn, hasImage: false, scenario: scenario)
            .flatMap { $0.models.map(\.reference) })
    }

    private func save(_ provider: RegisteredProvider) {
        perform {
            try library.updateConnection(provider, baseURL: baseURL, key: key, apiStyle: apiStyle)
            savedBaseURL = baseURL; savedKey = key; savedAPIStyle = apiStyle
        }
    }

    private func addManualModel(_ provider: RegisteredProvider) {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        perform {
            try library.addModels([.init(id: id, name: id)], providerID: provider.id)
            modelID = ""; manual = false
        }
    }

    private var catalogSheet: some View {
        ModelCatalogView(providerName: provider?.name ?? "", models: loaded,
                         existingIDs: Set(provider?.models.map(\.id) ?? []), selected: $selected,
                         onCancel: { showingCatalog = false }, onAdd: {
                             perform {
                                 try library.addModels(
                                     loaded.filter { selected.contains($0.id) },
                                     providerID: providerID
                                 )
                                 showingCatalog = false
                             }
                         }, provider: provider)
    }

    private func perform(_ action: () throws -> Void) {
        noticeIsSuccess = false
        do { try action(); notice = nil } catch { notice = error.localizedDescription }
    }

    private func setCapability(_ capability: WritableKeyPath<RegisteredModel, Bool?>, _ value: Bool,
                               model: RegisteredModel) {
        perform { try library.setCapability(capability, value, reference: model.reference, providerID: providerID) }
    }

    private func load(_ provider: RegisteredProvider) {
        operation?.cancel(); loading = true; notice = nil; noticeIsSuccess = false
        operation = Task {
            defer { loading = false }
            do {
                if !provider.isCloud, provider.remote != .freeModel {
                    try library.updateConnection(
                        provider,
                        baseURL: baseURL,
                        key: key, apiStyle: apiStyle
                    )
                    savedBaseURL = baseURL; savedKey = key; savedAPIStyle = apiStyle
                }
                guard let latest = self.provider else { return }
                let models = try await library.loadModels(provider: latest)
                try Task.checkCancellation()
                loaded = models
                selected = Set(latest.models.map(\.id))
                showingCatalog = true
                if provider.isOllama {
                    library.ollamaAvailable = true
                }
            } catch is CancellationError {
                return
            } catch { notice = L("models.loadFailed") + " " + error.localizedDescription }
        }
    }

    private func testConnection(_ provider: RegisteredProvider) {
        operation?.cancel(); loading = true; notice = nil; noticeIsSuccess = false
        operation = Task {
            defer { loading = false }
            do {
                try library.updateConnection(provider, baseURL: baseURL, key: key, apiStyle: apiStyle)
                savedBaseURL = baseURL; savedKey = key; savedAPIStyle = apiStyle
                guard let latest = self.provider,
                      let model = latest.models.first else { throw AskLocalError.message(L("models.noModels")) }
                _ = try await AskCustomInference().complete(
                    provider: latest,
                    connection: library.connection(latest, model: model),
                    payload: #"{"messages":[{"role":"user","content":"Reply OK"}],"max_tokens":16}"#
                )
                try Task.checkCancellation()
                if provider.isOllama {
                    library.ollamaAvailable = true
                }
                notice = L("ask.models.testOK")
                noticeIsSuccess = true
            } catch is CancellationError {
                return
            } catch { notice = error.localizedDescription }
        }
    }
}
