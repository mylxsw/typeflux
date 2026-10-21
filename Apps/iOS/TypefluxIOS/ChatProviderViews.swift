// swiftlint:disable file_length
import SwiftUI
import TypefluxChat

/// Settings → Model providers: Typeflux Cloud's status and the user's own providers.
struct ChatProvidersView: View {
    @Bindable var store: ChatStore

    var body: some View {
        List {
            Section("Typeflux Cloud") {
                HStack(spacing: 12) {
                    ChatProviderMark(kind: nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Typeflux Cloud").font(.system(size: 16, weight: .medium))
                        Text(store.isAuthenticated
                            ? String(format: NSLocalizedString("%d models · managed by Typeflux", comment: ""),
                                     store.models.count)
                            : NSLocalizedString("Sign in to use Typeflux Cloud models.", comment: ""))
                            .font(.footnote).foregroundStyle(ChatTheme.secondary)
                    }
                    Spacer()
                    ChatCloudStatus(store: store)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("providers.cloud")
            }
            Section {
                ForEach(store.library.providers) { provider in
                    NavigationLink {
                        ChatProviderEditor(store: store, existing: provider)
                    } label: {
                        HStack(spacing: 12) {
                            ChatProviderMark(kind: provider.kind)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name).font(.system(size: 16, weight: .medium))
                                Text(String(format: NSLocalizedString("%d models", comment: ""),
                                            provider.models.filter(\.enabled).count))
                                    .font(.footnote).foregroundStyle(ChatTheme.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("providers.item." + provider.id)
                }
                NavigationLink {
                    ChatProviderEditor(store: store, existing: nil)
                } label: {
                    Label("Add provider", systemImage: "plus.circle.fill").foregroundStyle(ChatTheme.accentText)
                }
                .accessibilityIdentifier("providers.add")
            } header: {
                Text("Your providers")
            } footer: {
                Text("Conversations with your own models stay only on this iPhone. API keys are kept in this iPhone's Keychain and are never sent to Typeflux.")
            }
        }
        .navigationTitle("Model providers")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("providers.root")
    }
}

struct ChatCloudStatus: View {
    @Bindable var store: ChatStore

    var body: some View {
        let (label, color): (LocalizedStringKey, Color) = if !store.isAuthenticated {
            ("Signed out", ChatTheme.tertiary)
        } else {
            switch store.connectivity {
            case .online: ("Online", ChatTheme.success)
            case .serviceUnavailable: ("Unavailable", .orange)
            case .offline: ("Offline", .orange)
            }
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.footnote).foregroundStyle(ChatTheme.secondary)
        }
    }
}

/// A provider's initial on its brand-neutral tile.
struct ChatProviderMark: View {
    var kind: ChatProviderKind?
    var size: CGFloat = 30

    var body: some View {
        let letter = kind.map { String($0.displayName.prefix(1)) } ?? "T"
        Text(verbatim: letter)
            .font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind == nil ? ChatTheme.accent : Color(red: 0.42, green: 0.32, blue: 0.86),
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Adds or edits one provider: address, key, then the models to show.
struct ChatProviderEditor: View {
    @Bindable var store: ChatStore
    let existing: ChatProvider?
    var onSaved: (ChatProvider) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ChatProviderKind = .openAI
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var models: [ChatProviderModel] = []
    @State private var phase = Phase.idle
    @State private var saveError: String?
    @State private var confirmingDelete = false

    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private var hasSavedKey: Bool {
        existing.map { store.library.key(for: $0.id)?.isEmpty == false } ?? false
    }

    private var draftProvider: ChatProvider {
        ChatProvider(id: existing?.id ?? UUID().uuidString.lowercased(), kind: kind,
                     name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name,
                     baseURL: kind.hasEditableAddress ? address : kind.defaultBaseURL, models: models)
    }

    /// The typed key, or the saved one while the field is left empty.
    private var effectiveKey: String? {
        key.isEmpty ? existing.flatMap { store.library.key(for: $0.id) } : key
    }

    private var canSave: Bool {
        draftProvider.endpoint != nil && models.contains(where: \.enabled) &&
            (!kind.requiresKey || effectiveKey?.isEmpty == false) && phase != .loading
    }

    var body: some View {
        Form {
            if existing == nil {
                Section("Provider") {
                    Picker("Provider", selection: $kind) {
                        ForEach(ChatProviderKind.allCases) { kind in
                            Text(NSLocalizedString(kind.displayName, comment: "Provider name")).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("provider.kind")
                }
            }
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text(verbatim: kind.displayName))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("provider.name")
                }
                if kind.hasEditableAddress {
                    LabeledContent("Address") {
                        TextField("Address", text: $address,
                                  prompt: Text(verbatim: kind == .ollama ? "http://192.168.1.20:11434" : "https://"))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("provider.address")
                    }
                } else {
                    LabeledContent("Address", value: kind.defaultBaseURL)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.requiresKey ? "API key" : "API key (optional)")
                    SecureField(kind.requiresKey ? "API key" : "API key (optional)", text: $key,
                                prompt: Text(verbatim: "sk-…"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("provider.key")
                    if hasSavedKey {
                        Text("Saved · enter a new key to replace it")
                            .font(.footnote).foregroundStyle(ChatTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(kind.hasEditableAddress
                    ? "Use HTTPS, or HTTP to a computer on your local network such as Ollama or LM Studio."
                    : "The address is fixed for this provider. Choose “OpenAI-compatible” for a proxy or gateway.")
            }
            Section {
                Button {
                    Task { await loadModels() }
                } label: {
                    HStack {
                        Text(models.isEmpty ? "Test and load models" : "Reload models")
                        if phase == .loading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(phase == .loading || draftProvider.endpoint == nil ||
                    (kind.requiresKey && effectiveKey?.isEmpty != false))
                .accessibilityIdentifier("provider.test")
                if case let .failed(message) = phase {
                    Text(NSLocalizedString(message, comment: "Provider error")).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("provider.error")
                }
            }
            if !models.isEmpty {
                Section {
                    ForEach($models) { $model in
                        Toggle(isOn: $model.enabled) {
                            Text(model.name).font(.system(size: 15))
                        }
                        .accessibilityIdentifier("provider.model." + model.id)
                        if model.enabled {
                            Toggle(isOn: $model.vision) {
                                Text("Accepts photos").font(.footnote).foregroundStyle(ChatTheme.secondary)
                            }
                            .accessibilityIdentifier("provider.vision." + model.id)
                        }
                    }
                } header: {
                    Text("Models to show")
                } footer: {
                    Text("Turn on “Accepts photos” only when the provider documents image input for that model.")
                }
            }
            if let saveError {
                Text(NSLocalizedString(saveError, comment: "")).font(.footnote).foregroundStyle(.red)
            }
            if existing != nil {
                Section {
                    Button("Delete provider", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("provider.delete")
                } footer: {
                    Text("Private conversations that used it stay on this iPhone; choose another model to continue them.")
                }
            }
        }
        .navigationTitle(existing == nil ? "Add provider" : "Edit provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!canSave).accessibilityIdentifier("provider.save")
            }
        }
        .confirmationDialog("Delete this provider?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let existing {
                    try? store.library.delete(providerID: existing.id)
                    dismiss()
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: kind) { _, _ in
            if existing == nil {
                models = []
                phase = .idle
                address = ""
            }
        }
    }

    private func load() {
        guard let existing, models.isEmpty else { return }
        kind = existing.kind
        name = existing.name
        address = existing.baseURL
        models = existing.models
    }

    private func loadModels() async {
        phase = .loading
        do {
            let found = try await store.providerService.models(provider: draftProvider, apiKey: effectiveKey)
            let previous = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            // Keep earlier choices; a fresh catalog starts with the first two models shown.
            models = found.enumerated().map { index, model in
                previous[model.id] ?? ChatProviderModel(id: model.id, name: model.name, vision: model.vision,
                                                        enabled: previous.isEmpty && index < 2)
            }
            phase = found.isEmpty ? .failed("The provider returned no models.") : .loaded
        } catch {
            phase = .failed(ChatStore.providerMessage(for: error))
        }
    }

    private func save() {
        let provider = draftProvider
        do {
            try store.library.save(provider, key: key.isEmpty ? nil : key)
            if store.library.defaultModelRef == nil, !store.isAuthenticated,
               let first = provider.chatModels.first {
                // Without an account, the first provider becomes the default.
                store.setDefaultModel(first.reference)
            }
            store.adoptPreferredModelIfUnset()
            onSaved(provider)
            dismiss()
        } catch {
            saveError = "The API key couldn't be saved in the Keychain. Please try again."
        }
    }
}

/// Settings → Default model.
struct ChatDefaultModelView: View {
    @Bindable var store: ChatStore

    var body: some View {
        List {
            if !store.models.isEmpty {
                Section("Typeflux Cloud") {
                    ForEach(store.models) { row($0) }
                }
            }
            if !store.library.models.isEmpty {
                Section {
                    ForEach(store.library.models) { row($0) }
                } header: {
                    Text("Your providers")
                } footer: {
                    Text("Conversations with these models stay only on this iPhone.")
                }
            }
            Section {
                Button {
                    store.setDefaultModel(nil)
                } label: {
                    HStack {
                        Text("Use the first available model")
                        Spacer()
                        if store.library.defaultModelRef == nil {
                            Image(systemName: "checkmark").foregroundStyle(ChatTheme.accent)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("defaultModel.reset")
            } footer: {
                Text("New conversations start with the default model. You can still choose another model in each conversation.")
            }
        }
        .navigationTitle("Default model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ model: ChatModel) -> some View {
        Button {
            store.setDefaultModel(model.reference)
        } label: {
            HStack(spacing: 11) {
                ChatModelLogo(model: model)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name).foregroundStyle(.primary)
                    if let provider = model.providerName {
                        Text(provider).font(.footnote).foregroundStyle(ChatTheme.secondary)
                    }
                }
                Spacer()
                if store.library.defaultModelRef == model.reference {
                    Image(systemName: "checkmark").foregroundStyle(ChatTheme.accent)
                }
            }
        }
        .accessibilityIdentifier("defaultModel." + model.reference)
    }
}

/// The notice shown while Typeflux cannot be reached, with a manual retry.
struct ChatConnectivityBanner: View {
    @Bindable var store: ChatStore
    @State private var retrying = false

    var body: some View {
        let expiry = store.connectivityNoticeDismissedAt?.addingTimeInterval(86_400) ?? Date()
        TimelineView(.explicit([Date(), expiry].sorted())) { context in
            if store.showsConnectivityNotice(at: context.date), let notice = store.connectivityNotice {
                banner(notice)
            }
        }
    }

    private func banner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: store.connectivity == .offline ? "wifi.slash" : "exclamationmark.icloud")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString(notice, comment: "Connectivity notice"))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let synced = store.cloudSyncedAt {
                    Text(String(format: NSLocalizedString("Updated %@", comment: "Cache time"),
                                synced.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 11.5)).foregroundStyle(ChatTheme.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                retrying = true
                Task {
                    await store.retryConnection()
                    retrying = false
                }
            } label: {
                if retrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry").font(.system(size: 13, weight: .semibold))
                }
            }
            .disabled(retrying)
            .accessibilityIdentifier("connectivity.retry")
            Button { store.dismissConnectivityNotice() } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("Dismiss", comment: ""))
            .accessibilityIdentifier("connectivity.dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectivity.banner")
    }
}
