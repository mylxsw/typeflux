import Foundation

/// The Launcher → Translation pane: which engine translates, the AI's model,
/// and the services' keys, edited one service at a time and tested before saving.
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

    func reloadConfigured() {
        configured = Set(AskTranslationProvider.allCases.filter {
            credentials.credentials(for: $0)?.isComplete(for: $0) == true
        })
    }

    // MARK: - Engine

    /// The AI first, then every service; ones without keys say so.
    var engineOptions: [(label: String, value: String)] {
        [(label: L("ask.translation.engine.ai"), value: AskTranslationEngineChoice.ai.rawValue)]
            + AskTranslationProvider.allCases.map { provider in
                (label: configured.contains(provider) ? provider.title
                    : L("ask.translation.engine.notConfigured", provider.title),
                 value: provider.rawValue)
            }
    }

    func setEngine(_ rawValue: String) {
        update { $0.engine = AskTranslationEngineChoice(rawValue: rawValue) }
    }

    func setModel(_ reference: String) {
        update { $0.modelReference = reference }
    }

    func setPrefersOnDevice(_ value: Bool) {
        update { $0.prefersOnDevice = value }
    }

    func setFallsBackToAI(_ value: Bool) {
        update { $0.fallsBackToAI = value }
    }

    func setSecondLanguage(_ code: String) {
        secondLanguage = code
        store.askTranslationSecondLanguage = code
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
            options.append((label: L("ask.models.unavailable"), value: selected))
        }
        return options
    }

    // MARK: - Service keys

    func edit(_ provider: AskTranslationProvider) {
        cancelTest()
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

    /// Forgets the service's keys; translations that used it go back to the AI.
    func remove() {
        guard let editing else { return }
        credentials.remove(editing)
        configured.remove(editing)
        if settings.engine == .service(editing) { setEngine(AskTranslationEngineChoice.ai.rawValue) }
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
