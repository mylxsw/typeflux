import SwiftUI

struct ProviderModelsView: View {
    @ObservedObject var library: AskModelLibrary
    let providerID: String
    var onBack: (() -> Void)?
    @State private var baseURL = ""
    @State private var key = ""
    @State private var modelID = ""
    @State private var manual = false
    @State private var loading = false
    @State private var loaded: [RegisteredModel] = []
    @State private var selected = Set<String>()
    @State private var showingCatalog = false
    @State private var notice: String?
    @State private var pendingDeletion: RegisteredModel?
    @State private var operation: Task<Void, Never>?

    private var provider: RegisteredProvider? {
        library.providers.first { $0.id == providerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let provider {
                HStack(spacing: 12) {
                    if let onBack {
                        Button(action: onBack) { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
                    }
                    Text(provider.name).font(.system(size: 23, weight: .bold))
                    Text(L("settings.models.domain.llm") + " › " + provider.name)
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
                ModelSurface {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: provider.isCloud ? "cloud" : "server.rack")
                                .frame(width: 32, height: 32)
                                .background(
                                    StudioTheme.textSecondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            Text(provider.name).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if library.unavailableReason(provider, loggedIn: AuthState.shared.isLoggedIn) == nil {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                ModelUsageBadge(text: L("models.connected"))
                            }
                        }
                        if provider.isCloud {
                            Text(L("models.cloudConnection")).foregroundStyle(StudioTheme.textSecondary)
                        } else if provider.remote == .freeModel {
                            Text(L("settings.models.freeModel.hint")).foregroundStyle(StudioTheme.textSecondary)
                        } else {
                            field(L("settings.models.apiEndpoint")) { TextField(
                                "https://api.example.com/v1",
                                text: $baseURL
                            ) }
                            if !provider.isOllama {
                                field("API Key") { SecureField("API Key", text: $key) }
                            }
                            HStack {
                                Button(L("ask.models.save")) { perform { try library.updateConnection(
                                    provider,
                                    baseURL: baseURL,
                                    key: key
                                ) } }
                                Button(L("ask.models.test")) { testConnection(provider) }.disabled(loading)
                                if loading {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                    }.padding(18)
                }
                ModelSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(L("common.model")).font(.system(size: 13, weight: .semibold))
                            Text("\(provider.models.count)").font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Spacer()
                            if !provider.isCloud {
                                Button { manual = true } label: { Label(L("models.manual"), systemImage: "plus") }
                            }
                            Button { load(provider) } label: { Label(L("models.load"), systemImage: "arrow.clockwise") }
                                .buttonStyle(ModelActionStyle(primary: true)).disabled(loading)
                        }.padding(.horizontal, 18).frame(height: 58)
                        if manual {
                            HStack {
                                TextField(L("ask.models.modelID"), text: $modelID).textFieldStyle(ModelFieldStyle())
                                Button(L("models.add")) {
                                    perform {
                                        try library.addModels(
                                            [.init(id: modelID, name: modelID)],
                                            providerID: provider.id
                                        )
                                        modelID = ""; manual = false
                                    }
                                }.disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(L("ask.models.cancel")) { manual = false }
                            }.padding(.horizontal, 18).padding(.bottom, 14)
                        }
                        ForEach(provider.models) { model in
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.id).font(.system(size: 13, design: .monospaced))
                                    if let reason = model
                                        .exclusionReason {
                                        Text(reason).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                                    }
                                }
                                Spacer()
                                if library.rewriteReference == model
                                    .reference {
                                    ModelUsageBadge(text: L("ask.models.rewrite"))
                                }
                                if library.defaultReference == model
                                    .reference {
                                    ModelUsageBadge(text: L("models.askDefault"))
                                }
                                Menu {
                                    Text(L("models.visionHint"))
                                    Button(L("models.visionYes")) { setVision(true, model: model) }
                                    Button(L("models.visionNo")) { setVision(false, model: model) }
                                    Divider()
                                    Button(L("ask.models.delete"), role: .destructive) { pendingDeletion = model }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden).frame(width: 26)
                            }.padding(.horizontal, 18).frame(minHeight: 44)
                        }
                        if provider.models
                            .isEmpty {
                            Text(L("models.noModels")).foregroundStyle(StudioTheme.textSecondary).padding(18)
                        }
                    }
                }
                Text(L("models.usageHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                }
            }
        }
        .buttonStyle(ModelActionStyle())
        .onAppear {
            if let provider {
                let value = library.connection(provider); baseURL = value.baseURL; key = value.apiKey
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
}

extension ProviderModelsView {
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            content().textFieldStyle(ModelFieldStyle())
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
        do { try action(); notice = nil } catch { notice = error.localizedDescription }
    }

    private func setVision(_ value: Bool, model: RegisteredModel) {
        perform {
            var next = library.registry
            guard let index = next.providers.firstIndex(where: { $0.id == providerID }),
                  let modelIndex = next.providers[index].models.firstIndex(where: { $0.reference == model.reference })
            else { return }
            next.providers[index].models[modelIndex].vision = value
            try library.commit(next)
        }
    }

    private func load(_ provider: RegisteredProvider) {
        operation?.cancel(); loading = true; notice = nil
        operation = Task {
            defer { loading = false }
            do {
                if !provider.isCloud, provider.remote != .freeModel {
                    try library.updateConnection(
                        provider,
                        baseURL: baseURL,
                        key: key
                    )
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
        operation?.cancel(); loading = true; notice = nil
        operation = Task {
            defer { loading = false }
            do {
                try library.updateConnection(provider, baseURL: baseURL, key: key)
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
            } catch is CancellationError {
                return
            } catch { notice = error.localizedDescription }
        }
    }
}

struct AddModelEndpointView: View {
    @ObservedObject var library: AskModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = "https://"
    @State private var key = ""
    @State private var model = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("models.addEndpoint")).font(.title2.bold())
            TextField(L("ask.models.name"), text: $name)
            TextField(L("ask.models.url"), text: $endpoint)
            SecureField("API Key", text: $key)
            TextField(L("ask.models.modelID"), text: $model)
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button(L("ask.models.cancel")) { dismiss() }
                Button(L("ask.models.save")) {
                    do {
                        try library.save(.init(name: name, baseURL: endpoint, model: model), key: key)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
    }
}
