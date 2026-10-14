import Foundation

/// The ordered service list and credential editor in Launcher → Translation.
@MainActor
final class AskTranslationSettingsModel: ObservableObject {
    @Published private(set) var settings: AskTranslationSettings
    @Published private(set) var secondLanguage: String
    @Published private(set) var configured: Set<AskTranslationProvider> = []
    /// The service whose keys are being edited.
    @Published private(set) var editing: AskTranslationProvider?
    @Published var draft = AskTranslationCredentials()
    @Published private(set) var testing = false
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published var languageDownload: AskTranslationLanguageDownload?

    let store: SettingsStore
    let credentials: any AskTranslationCredentialStoring
    /// Where connection tests go; tests answer them without the network.
    var http: any AskTranslationHTTP = AskURLSessionTranslationHTTP()
    private var testTask: Task<Void, Never>?

    init(store: SettingsStore, credentials: any AskTranslationCredentialStoring = AskKeychainTranslationCredentials()) {
        self.store = store
        self.credentials = credentials
        settings = store.askTranslationSettings
        secondLanguage = store.askTranslationSecondLanguage
            ?? AskTranslationLanguages.defaultSecond(for: AppLocalization.shared.language)
        reloadConfigured()
    }

    deinit { testTask?.cancel() }

    func reloadConfigured() {
        configured = Set(AskTranslationProvider.allCases.filter {
            credentials.credentials(for: $0)?.isComplete(for: $0) == true
        })
    }

    // MARK: - Ordered services

    static let languagePackagesURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    func downloadLanguages(source: String, target: String) {
        languageDownload = .init(source: source, target: target)
    }

    func prepareLanguages(_ request: AskTranslationLanguageDownload,
                          prepare: () async throws -> Void, onReady: () -> Void,
                          openSettings: (URL) -> Void) async {
        do {
            try await prepare()
            guard !Task.isCancelled, languageDownload?.id == request.id else { return }
            languageDownload = nil
            onReady()
        } catch {
            guard !Task.isCancelled, languageDownload?.id == request.id else { return }
            languageDownload = nil
            if error is CancellationError {
                return
            }
            openSettings(Self.languagePackagesURL)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let service = settings.services.first(where: { $0.id == id }) else { return }
        update { settings in
            guard let index = settings.services.firstIndex(where: { $0.id == id }) else { return }
            settings.services[index].enabled = enabled
        }
        if enabled, let provider = service.provider, !configured.contains(provider) { edit(provider) }
    }

    func setModel(_ reference: String, for id: String) {
        update { settings in
            guard let index = settings.services.firstIndex(where: { $0.id == id && $0.isAI }) else { return }
            settings.services[index].kind = .ai(modelReference: reference)
        }
    }

    @discardableResult
    func addAI() -> String {
        let service = AskTranslationService.ai(id: UUID().uuidString, enabled: false)
        update { $0.services.append(service) }
        return service.id
    }

    func removeAI(_ id: String) {
        guard id != settings.firstAI?.id else { return }
        update { $0.services.removeAll { $0.id == id && $0.isAI } }
    }

    func move(_ id: String, to index: Int) {
        update { settings in
            guard let from = settings.services.firstIndex(where: { $0.id == id }) else { return }
            let service = settings.services.remove(at: from)
            settings.services.insert(service, at: min(max(0, index), settings.services.count))
        }
    }

    func setSecondLanguage(_ code: String) {
        secondLanguage = code
        store.askTranslationSecondLanguage = code
    }

    func setPanelPreference<Value: Equatable>(_ value: Value, at keyPath: WritableKeyPath<AskTranslationSettings, Value>) {
        update { $0[keyPath: keyPath] = value }
    }

    private func update(_ change: (inout AskTranslationSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        store.askTranslationSettings = next
    }

    /// "Follow the text-processing model", then the models a rewrite could use; a
    /// chosen model that was removed stays listed as unavailable.
    static func modelOptions(providers: [RegisteredProvider], selected: String) -> [(label: String, value: String)] {
        var options = [(label: L("ask.translation.model.follow"), value: "")]
        for provider in providers {
            for model in provider.models {
                options.append((label: provider.name + " · " + model.displayName, value: model.reference))
            }
        }
        if !selected.isEmpty, !options.contains(where: { $0.value == selected }) {
            options.append((label: L("ask.translation.model.pickAgain"), value: selected))
        }
        return options
    }

    // MARK: - Service keys

    func edit(_ provider: AskTranslationProvider) {
        cancelTest()
        settings = store.askTranslationSettings
        reloadConfigured()
        editing = provider
        draft = credentials.credentials(for: provider) ?? AskTranslationCredentials()
        notice = nil
        noticeIsError = false
    }

    func cancelEdit() {
        cancelTest()
        editing = nil
        draft = AskTranslationCredentials()
        notice = nil
    }

    var canSave: Bool {
        guard let editing else { return false }
        return draft.isComplete(for: editing)
    }

    /// Saves the keys; false when the Keychain refused them.
    @discardableResult
    func save() -> Bool {
        guard let editing, canSave else { return false }
        guard credentials.save(draft.trimmed(), for: editing) else {
            show(L("ask.translation.keychainFailed"), error: true)
            return false
        }
        configured.insert(editing)
        cancelEdit()
        return true
    }

    /// Forgetting keys disables that service without changing any other service.
    func remove() {
        guard let editing else { return }
        credentials.remove(editing)
        configured.remove(editing)
        for service in settings.services where service.provider == editing { setEnabled(service.id, false) }
        cancelEdit()
    }

    /// Translates "hello" with the keys being edited.
    func test() {
        guard let editing, canSave else { return }
        cancelTest()
        testing = true
        notice = nil
        let engine = AskServiceTranslationEngine(client: AskServiceTranslationEngine.client(for: editing),
                                                 credentials: credentials, http: http)
        let keys = draft.trimmed()
        testTask = Task { [weak self] in
            do {
                let result = try await engine.test(keys)
                guard !Task.isCancelled else { return }
                self?.show(L("ask.translation.test.success", result), error: false)
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(AskTranslatePlugin.reason(error), error: true)
            }
            self?.testing = false
        }
    }

    /// Waits for the running connection test; tests use it.
    func waitForTest() async { await testTask?.value }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
    }

    private func show(_ message: String, error: Bool) {
        notice = message
        noticeIsError = error
    }
}
