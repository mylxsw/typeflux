import AppKit
import Foundation

enum AskTranslationPanelSource: String {
    case input, selection, screenshot, launcher
    var title: String {
        L("ask.translation.panel.source." + rawValue)
    }
}

/// One editable session. Only explicit submission calls the shared translation plugin.
@MainActor
final class AskTranslationPanelModel: ObservableObject {
    @Published var text = "" {
        didSet {
            guard oldValue != text else { return }
            cancelTranslation()
            output = nil
            notice = nil
        }
    }

    @Published var output: AskPluginOutput?
    @Published private(set) var running = false
    @Published var pinned = false
    @Published private(set) var source: AskTranslationPanelSource = .input
    @Published private(set) var screenshot: NSImage?
    @Published private(set) var screenshotLines = 0
    @Published var notice: String?
    /// A short confirmation shown in the footer after copying or inserting.
    @Published private(set) var feedback: String?
    @Published var sourceLanguage: String?
    @Published var targetLanguage: String?
    let settings: SettingsStore
    let history: AskTranslationHistory
    let configuration: AskTranslationSettingsModel
    private(set) var plugin: AskTranslatePlugin
    private let defaultPlugin: AskTranslatePlugin
    private var engineOverride: String?
    var now: () -> Date
    var onDismiss: () -> Void = {}
    var onCopy: (String) -> Void
    var onInsert: (String) -> Void = { _ in }
    var onSpeak: (String, String) -> Void = { _, _ in }
    var onSettings: () -> Void = {}
    var onWordBook: (String?) -> Void = { _ in }
    var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var dismissedAt: Date?
    private var submittedText: String?
    private(set) var wordBookTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var generation = UUID()
    private var confirmedStar: (generation: UUID, key: String, starred: Bool)?
    var historyIndex: Int?
    var historyDraft = ""
    private var autoCopied = false
    private var autoCopy: AskTranslationAutoCopy = .none
    private var cancelHandoff: (() -> Void)?
    private var feedbackTask: Task<Void, Never>?
    static let feedbackDuration: Duration = .milliseconds(1600)

    init(settings: SettingsStore, plugin: AskTranslatePlugin,
         configuration: AskTranslationSettingsModel? = nil,
         now: @escaping () -> Date = Date.init, copy: @escaping (String) -> Void) {
        self.settings = settings
        self.plugin = plugin
        defaultPlugin = plugin
        self.configuration = configuration ?? AskTranslationSettingsModel(store: settings)
        self.now = now
        onCopy = copy
        history = AskTranslationHistory(defaults: settings.defaults)
    }

    deinit { wordBookTask?.cancel(); translationTask?.cancel(); feedbackTask?.cancel(); cancelHandoff?() }

    var interface: AppLanguage {
        AppLocalization.shared.language
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isDirty: Bool {
        submittedText != trimmedText || output == nil
    }

    /// Input shortcuts restore recent content; selection and screenshot shortcuts always start fresh.
    func open(source: AskTranslationPanelSource, text: String? = nil, image: NSImage? = nil, lines: Int = 0) {
        if source != .input || !settings.askTranslationSettings.keepState
            .retains(dismissedAt: dismissedAt, now: now()) {
            clear()
            sourceLanguage = nil
            targetLanguage = nil
            pinned = false
            configuration.cancelEdit()
            configuration.languageDownload = nil
            if source != .launcher {
                plugin.fanout?.reset()
            }
            plugin = defaultPlugin
            if source != .launcher {
                plugin.fanout?.reset()
            }
            engineOverride = nil
        }
        self.source = source
        if source == .input {
            output?.translation?.replacesSelection = false
        }
        screenshot = image
        screenshotLines = lines
        dismissedAt = nil
        historyIndex = nil
        if let text {
            self.text = text
        }
    }

    private var featureTransferID: UUID?
    private var featureTransferSequence = -1
    private var featureTransfers: Set<UUID> = []

    func receiveFeatureTransfer(_ transfer: FeatureTranslationTransfer) -> Bool {
        if transfer.initial, featureTransferID != transfer.id {
            guard !featureTransfers.contains(transfer.id), featureTransfers.count < 4096 else { return false }
            importLauncher(transfer.output.output)
            featureTransferID = transfer.id
            featureTransferSequence = -1
            featureTransfers.insert(transfer.id)
            generation = transfer.id
            engineOverride = transfer.engine
            autoCopy = .none
            cancelHandoff = { FeatureProcess.send(.init(destination: transfer.source, action: "cancelTranslationTransfer", payload: Data(transfer.id.uuidString.utf8))) }
        }
        guard featureTransferID == transfer.id, generation == transfer.id else { return false }
        if transfer.sequence <= featureTransferSequence { return true }
        featureTransferSequence = transfer.sequence
        running = transfer.running
        receiveHandoff(transfer.failed ? .cancelled : transfer.running ? .progress(transfer.output.output) : .done(transfer.output.output), id: transfer.id)
        return true
    }

    func importLauncher(_ result: AskPluginOutput) {
        open(source: .launcher, text: result.original)
        output = result
        submittedText = result.translation?.submitted == true ? trimmedText : nil
        sourceLanguage = result.translation?.sourceIsAutomatic == false ? result.translation?.source : nil
        targetLanguage = result.translation?.target
        pinned = true
    }

    func finishRecognition(text: String, lines: Int) {
        self.text = text
        screenshotLines = lines
        notice = nil
    }

    func adoptHandoff(_ handoff: AskPluginHandoff, id: UUID) {
        if let translation = handoff.plugin as? AskTranslatePlugin {
            plugin = translation
        }
        engineOverride = handoff.request.options[AskTranslatePlugin.engineOption]
        generation = id
        if handoff.plan
            .mode == .onSubmit {
            submittedText = handoff.request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        running = handoff.running
        if handoff.running {
            cancelHandoff = { handoff.cancel() }
        } else {
            cancelHandoff = nil
        }
        autoCopy = .none
    }

    func receiveHandoff(_ event: AskPluginHandoff.Event, id: UUID) {
        guard generation == id else { return }
        switch event {
        case let .progress(result): receive(result)
        case let .done(result):
            receive(result)
            running = false
            cancelHandoff = nil
            if let lookup = result.wordBook, settings.askWordBookRecordsHistory {
                recordWordBook(lookup)
            }
        case .failed, .cancelled:
            running = false
            cancelHandoff = nil
            submittedText = nil
            notice = L("ask.translation.stack.failed")
        }
    }

    func saveWordBook(_ lookup: AskWordBookLookup, toggle: Bool) {
        guard let store = plugin.wordBook else { return }
        guard wordBookTask == nil else { notice = L("ask.wordBook.saveFailed"); return }
        let current = generation, date = now()
        wordBookTask = Task { [weak self] in
            guard let self else { return }
            defer { wordBookTask = nil }
            do {
                if toggle {
                    let starred = try await store.entry(forKey: lookup.key)?.isStarred != true
                    try Task.checkCancellation()
                    guard let saved = try await store.setStarred(starred, lookup: lookup, at: date) else {
                        throw LocalStoreFailure.unavailable
                    }
                    guard generation == current, !Task.isCancelled else { return }
                    confirmedStar = (current, lookup.key, saved.isStarred)
                    output = output?.starring(saved.isStarred)
                } else {
                    guard try await store.record(lookup, at: date, counts: true) != nil else {
                        throw LocalStoreFailure.unavailable
                    }
                }
            } catch {
                if generation == current, !Task.isCancelled { notice = L("ask.wordBook.saveFailed") }
            }
        }
    }

    private func recordWordBook(_ lookup: AskWordBookLookup) { saveWordBook(lookup, toggle: false) }

    func dismiss() {
        cancelTranslation()
        configuration.cancelEdit()
        configuration.languageDownload = nil
        dismissedAt = now()
        onDismiss()
    }

    func escape() {
        if pinned, !text.isEmpty {
            clear()
        } else {
            dismiss()
        }
    }

    func clear() {
        cancelTranslation()
        text = ""
        output = nil
        submittedText = nil
        screenshot = nil
        screenshotLines = 0
        historyIndex = nil
        notice = nil
    }

    func submit() {
        guard !trimmedText.isEmpty else { return }
        if isDirty {
            if !running {
                translate()
            }
        } else {
            copy(number: 1, closes: true)
        }
    }

    func translate(options: [String: String] = [:]) {
        guard !trimmedText.isEmpty else { return }
        cancelTranslation()
        let current = UUID()
        generation = current
        let original = trimmedText
        var options = options
        if let engineOverride {
            options[AskTranslatePlugin.engineOption] = engineOverride
        }
        if let sourceLanguage {
            options["source"] = sourceLanguage
        }
        if let targetLanguage {
            options[AskTranslatePlugin.targetOption] = targetLanguage
        }
        let request = AskPluginRequest(text: original, origin: source == .selection ? .selection : .argument,
                                       keyword: AskTranslatePlugin.keywords[0], options: options,
                                       interfaceLanguage: interface, selection: source == .selection ? original : nil)
        running = true
        submittedText = original
        notice = nil
        autoCopied = false
        autoCopy = settings.askTranslationSettings.autoCopy
        history.record(original)
        historyIndex = nil
        translationTask = Task { [weak self, plugin] in
            var plan = await plugin.plan(request)
            guard let self, generation == current, !Task.isCancelled else { return }
            plan.values["submitted"] = "true"
            do {
                let result = try await plugin.run(request, plan: plan) { [weak self] output in
                    guard let self, generation == current, !Task.isCancelled else { return }
                    receive(output)
                }
                guard generation == current, !Task.isCancelled else { return }
                receive(result)
                if let lookup = result.wordBook, settings.askWordBookRecordsHistory {
                    recordWordBook(lookup)
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                notice = L("ask.translation.stack.failed")
            }
            running = false
            translationTask = nil
        }
    }

    private func receive(_ next: AskPluginOutput) {
        var next = next
        if let confirmedStar, confirmedStar.generation == generation, confirmedStar.key == next.wordBook?.key {
            next = next.starring(confirmedStar.starred)
        }
        next.selectedItem = min(output?.selectedItem ?? 0, max(0, (next.translation?.results.count ?? 1) - 1))
        output = next
        if !autoCopied, let results = next.translation?.results,
           let text = autoCopy.text(original: next.original, results: results) {
            autoCopied = true
            onCopy(text)
        }
    }

    func waitForTranslation() async {
        await translationTask?.value
    }

    private func cancelTranslation() {
        generation = UUID()
        translationTask?.cancel()
        translationTask = nil
        cancelHandoff?()
        cancelHandoff = nil
        if running {
            submittedText = nil
        }
        running = false
    }
}

extension AskTranslationPanelModel {
    func flash(_ message: String) {
        feedback = message
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    func lostFocus() {
        if !pinned, configuration.editing == nil, configuration.languageDownload == nil {
            dismiss()
        }
    }

}
