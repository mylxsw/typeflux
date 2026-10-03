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
    @State private var showsKey = false
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
        VStack(alignment: .leading, spacing: 0) {
            if let provider {
                ModelDetailHeader(
                    title: provider.name,
                    subtitle: L("settings.models.domain.llm"),
                    icon: provider.studioProviderID,
                    connected: library.unavailableReason(provider, loggedIn: auth.isLoggedIn) == nil,
                    onBack: onBack
                )
                .padding(.bottom, 22)
                if provider.remote == .freeModel {
                    ModelSurface {
                        Text(L("settings.models.freeModel.hint")).font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textSecondary).padding(18)
                    }
                } else {
                    ModelSectionLabel(title: L("models.connection")).padding(.bottom, 8)
                    connectionCard(provider)
                }
                modelsHeader(provider).padding(.top, 26).padding(.bottom, 8)
                modelsCard(provider)
                Text(L("models.usageHint")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, 4).padding(.top, 10)
                if provider.remote == .freeModel, let notice {
                    noticeText(notice).padding(.horizontal, 4).padding(.top, 8)
                }
            }
        }
        .buttonStyle(ModelActionStyle())
        .onAppear {
            if let provider {
                let value = library.connection(provider)
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
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                formRow(L("settings.models.apiEndpoint")) {
                    TextField("https://api.example.com/v1", text: $baseURL).textFieldStyle(ModelFieldStyle())
                }
                if !provider.isOllama {
                    ModelRowDivider()
                    formRow("API Key") { keyField }
                }
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                HStack(spacing: 8) {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if let notice {
                        noticeText(notice)
                    }
                    Spacer(minLength: 8)
                    Button(L("ask.models.test")) { testConnection(provider) }.disabled(loading)
                    Button(L("ask.models.save")) { save(provider) }
                        .buttonStyle(ModelActionStyle(primary: true))
                        .disabled(loading || !ModelSettingsPresentation.connectionChanged(
                            savedBaseURL: savedBaseURL, savedKey: savedKey, baseURL: baseURL, key: key
                        ))
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }

    private var keyField: some View {
        Group {
            if showsKey {
                TextField("API Key", text: $key)
            } else {
                SecureField("API Key", text: $key)
            }
        }
        .textFieldStyle(ModelFieldStyle(trailingAccessoryWidth: 24))
        .overlay(alignment: .trailing) {
            Button { showsKey.toggle() } label: {
                Image(systemName: showsKey ? "eye.slash" : "eye")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .help(L(showsKey ? "models.hideKey" : "models.showKey"))
        }
    }

    private func modelsHeader(_ provider: RegisteredProvider) -> some View {
        HStack(spacing: 8) {
            ModelSectionLabel(title: L("common.model"), detail: "\(provider.models.count)")
            Spacer()
            Button { manual = true } label: { Label(L("models.manual"), systemImage: "plus") }
            Button { load(provider) } label: { Label(L("models.load"), systemImage: "arrow.clockwise") }
                .disabled(loading)
        }
    }

    private func modelsCard(_ provider: RegisteredProvider) -> some View {
        let rewriteReferences = selectableReferences(scenario: "rewrite")
        let askReferences = selectableReferences(scenario: "ask")
        return ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                if manual {
                    HStack(spacing: 8) {
                        TextField(L("ask.models.modelID"), text: $modelID).textFieldStyle(ModelFieldStyle())
                            .onSubmit { addManualModel(provider) }
                        Button(L("ask.models.cancel")) { manual = false; modelID = "" }
                        Button(L("models.add")) { addManualModel(provider) }
                            .buttonStyle(ModelActionStyle(primary: true))
                            .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                    if !provider.models.isEmpty {
                        ModelRowDivider()
                    }
                }
                ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, model in
                    if index > 0 {
                        ModelRowDivider()
                    }
                    modelRow(
                        model,
                        canRewrite: rewriteReferences.contains(model.reference),
                        canAsk: askReferences.contains(model.reference)
                    )
                }
                if provider.models.isEmpty && !manual {
                    Text(L("models.noModels")).font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
        }
    }

}

extension ProviderModelsView {
    private func modelRow(_ model: RegisteredModel, canRewrite: Bool, canAsk: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id).font(.system(size: 13, design: .monospaced)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = model.exclusionReason {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            ForEach(ModelSettingsPresentation.usageKeys(
                reference: model.reference,
                rewriteReference: library.rewriteReference,
                defaultReference: library.defaultReference
            ), id: \.self) { key in
                ModelUsageBadge(text: L(key), accent: true)
            }
            visionIndicator(model)
            Menu {
                Button(L("models.useForRewrite")) { library.rewriteReference = model.reference }
                    .disabled(!canRewrite || library.rewriteReference == model.reference)
                Button(L("ask.models.makeDefault")) { library.defaultReference = model.reference }
                    .disabled(!canAsk || library.defaultReference == model.reference)
                Divider()
                Text(L("models.capabilityHint"))
                Toggle(L("models.visionYes"), isOn: Binding(
                    get: { model.vision == true },
                    set: { setCapability(\.vision, $0, model: model) }
                ))
                // Unset reasoning still offers the effort menu (see `AskReasoningEffort`), so it reads as on.
                Toggle(L("models.reasoningYes"), isOn: Binding(
                    get: { model.reasoning != false },
                    set: { setCapability(\.reasoning, $0, model: model) }
                ))
                Divider()
                Button(L("ask.models.delete"), role: .destructive) { pendingDeletion = model }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
        .padding(.leading, 18).padding(.trailing, 12).frame(minHeight: 46)
    }

    @ViewBuilder
    private func visionIndicator(_ model: RegisteredModel) -> some View {
        switch model.vision {
        case true?:
            Text(L("ask.models.badge.vision")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1).fixedSize()
                .help(L("ask.models.supportsImages"))
        case nil:
            Text(L("models.visionUnknownShort")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1).fixedSize()
                .help(L("models.capabilityHint"))
        case false?:
            EmptyView()
        }
    }

    private func noticeText(_ text: String) -> some View {
        Text(text).font(.system(size: 12))
            .foregroundStyle(noticeIsSuccess ? StudioTheme.success : StudioTheme.danger)
            .lineLimit(2).textSelection(.enabled)
    }

    private func formRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 96, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// References the scene pickers would offer, so row shortcuts never assign an ineligible model.
    private func selectableReferences(scenario: String) -> Set<String> {
        Set(library.selectableProviders(loggedIn: auth.isLoggedIn, hasImage: false, scenario: scenario)
            .flatMap { $0.models.map(\.reference) })
    }

    private func save(_ provider: RegisteredProvider) {
        perform {
            try library.updateConnection(provider, baseURL: baseURL, key: key)
            savedBaseURL = baseURL; savedKey = key
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
                         })
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
                        key: key
                    )
                    savedBaseURL = baseURL; savedKey = key
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
                try library.updateConnection(provider, baseURL: baseURL, key: key)
                savedBaseURL = baseURL; savedKey = key
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
