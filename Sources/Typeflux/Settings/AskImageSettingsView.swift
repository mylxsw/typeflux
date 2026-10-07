import SwiftUI

@MainActor
final class AskImageSettingsModel: ObservableObject {
    @Published var configuration = AskImageConfiguration()
    @Published var key = ""
    @Published var enabled = false
    @Published var models: [String] = []
    @Published var loading = false
    @Published var notice: String?
    let store: AskImageSettings
    private let discover: (AskImageConfiguration, String) async throws -> [String]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(store: AskImageSettings, discover: @escaping (AskImageConfiguration, String) async throws -> [String] = {
        try await AskImageModelDiscovery().models(configuration: $0, key: $1)
    }) {
        self.store = store; self.discover = discover
        enabled = store.enabled
        select(store.provider)
    }

    func select(_ provider: AskImageProvider) {
        cancelDiscovery()
        configuration = store.configuration(for: provider)
        key = store.key(for: configuration)
        models = provider.suggestedModels
        notice = nil
    }

    func endpointChanged() {
        cancelDiscovery()
        key = store.key(for: configuration)
        models = configuration.provider.suggestedModels
        notice = nil
    }

    func save() {
        do {
            if enabled {
                try configuration.validate(key: key)
            }
            try store.save(configuration, key: key)
            store.enabled = enabled
            notice = L("imagegen.saved")
        } catch { notice = error.localizedDescription }
    }

    func refresh() {
        cancelDiscovery()
        let snapshot = configuration, secret = key, id = generation
        loading = true; notice = nil
        task = Task {
            defer {
                if generation == id {
                    loading = false; task = nil
                }
            }
            do {
                let found = try await discover(snapshot, secret)
                guard !Task.isCancelled, generation == id, configuration == snapshot, key == secret else { return }
                models = Array(Set(found + snapshot.provider.suggestedModels)).sorted {
                    let lhs = AskImageModelDiscovery.imageLike($0), rhs = AskImageModelDiscovery.imageLike($1)
                    return lhs == rhs ? $0 < $1 : lhs
                }
                notice = L("imagegen.models.loaded", found.count)
            } catch {
                guard !Task.isCancelled, generation == id, configuration == snapshot, key == secret else { return }
                notice = L("imagegen.models.failed")
            }
        }
    }

    func cancelDiscovery() {
        generation = UUID(); task?.cancel(); task = nil; loading = false
    }
}

struct AskImageSettingsView: View {
    @StateObject private var model: AskImageSettingsModel
    var onSaved: (Bool, Bool) -> Void

    init(store: AskImageSettings, onSaved: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        _model = StateObject(wrappedValue: AskImageSettingsModel(store: store))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AgentPaneHeader(symbol: "photo.badge.plus", title: L("imagegen.title"), subtitle: L("imagegen.summary")) {
                Toggle("", isOn: $model.enabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("imagegen.title"))
            }
            AgentSettingsSection(title: L("imagegen.connection"), footnote: L("imagegen.billing")) {
                VStack(alignment: .leading, spacing: 14) {
                    AgentFormRow(label: L("imagegen.provider"), required: true) {
                        Picker("", selection: Binding(get: { model.configuration.provider }, set: model.select)) {
                            ForEach(AskImageProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    AgentFormRow(label: L("imagegen.endpoint"), required: true) {
                        TextField("https://", text: $model.configuration.baseURL).textFieldStyle(ModelFieldStyle())
                    }
                    if model.configuration.provider == .bailian {
                        HStack {
                            Button(L("imagegen.beijing")) {
                                model.configuration.baseURL = "https://dashscope.aliyuncs.com/api/v1"
                            }
                            Button(L("imagegen.singapore")) {
                                model.configuration.baseURL = "https://dashscope-intl.aliyuncs.com/api/v1"
                            }
                        }.buttonStyle(ModelActionStyle())
                        Text(L("imagegen.bailian.help")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                    }
                    AgentFormRow(label: "API Key", required: true) {
                        SecureField("API Key", text: $model.key).textFieldStyle(ModelFieldStyle())
                    }
                    AgentFormRow(label: L("imagegen.model"), required: true) {
                        HStack {
                            TextField(L("imagegen.model.placeholder"), text: $model.configuration.model)
                                .textFieldStyle(ModelFieldStyle()).accessibilityIdentifier("imagegen-model")
                            Menu {
                                ForEach(model.models, id: \.self) { name in
                                    Button(name) { model.configuration.model = name }
                                }
                            } label: { Image(systemName: "list.bullet") }
                                .help(L("imagegen.models.suggestions"))
                        }
                    }
                    Text(L("imagegen.models.help")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                    if model.configuration.provider.supportsDiscovery {
                        HStack {
                            Button(L("imagegen.models.refresh")) { model.refresh() }.buttonStyle(ModelActionStyle())
                                .disabled(model.loading || model.key.isEmpty)
                            if model.loading {
                                ProgressView().controlSize(.small)
                            }
                        }
                    } else {
                        Text(L("imagegen.models.builtin")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                    }
                    DisclosureGroup(L("imagegen.advanced")) {
                        VStack(alignment: .leading, spacing: 12) {
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
                            Text(L("imagegen.options.help")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                        }.padding(.top, 12)
                    }
                    Button(L("imagegen.save")) {
                        model.save()
                        onSaved(model.store.enabled, model.store.isReady)
                    }.buttonStyle(ModelActionStyle())
                    if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                    }
                }.padding(18)
            }
            AgentInfoNote(text: L("imagegen.retention"))
        }
        .onChange(of: model.configuration.baseURL) { _ in model.endpointChanged() }
        .onDisappear { model.cancelDiscovery() }
    }
}
