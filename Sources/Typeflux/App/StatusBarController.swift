import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject {
    private enum MenuTag {
        static let agentTasks = 9001
        static let transcriptionHistory = 9002
        static let personas = 9003
    }

    private enum MenuValue {
        static let noPersona = "__no_persona__"
    }

    private enum MenuLayout {
        static let runningJobTitleLimit = 44
        static let recentHistoryLimit = 10
    }

    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let agentJobStore: AgentJobStore
    private let autoModelDownloadService: AutoModelDownloadService?
    private let notificationService: LocalNotificationSending
    private let onRetryHistory: (HistoryRecord) -> Void
    private let onOpenOnboarding: () -> Void
    private let onOpenAgentJobs: () -> Void
    private let onOpenAgentJob: (UUID) -> Void

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    private var languageObserver: NSObjectProtocol?
    private var agentJobObserver: NSObjectProtocol?
    private var agentSettingsObserver: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?
    private var personaSelectionObserver: NSObjectProtocol?
    private var autoUpdateStateObserver: NSObjectProtocol?
    private var autoModelDownloadObserver: NSObjectProtocol?
    private var runningJobDurationTimer: Timer?
    private var runningAgentJobs: [AgentJob] = []

    init(
        appState: AppStateStore,
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        agentJobStore: AgentJobStore,
        autoModelDownloadService: AutoModelDownloadService? = nil,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in },
        onOpenOnboarding: @escaping () -> Void = {},
        onOpenAgentJobs: @escaping () -> Void = {},
        onOpenAgentJob: @escaping (UUID) -> Void = { _ in },
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.agentJobStore = agentJobStore
        self.autoModelDownloadService = autoModelDownloadService
        self.notificationService = notificationService
        self.onRetryHistory = onRetryHistory
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenAgentJobs = onOpenAgentJobs
        self.onOpenAgentJob = onOpenAgentJob
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateTitle()
        rebuildMenu()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
        agentJobObserver = NotificationCenter.default.addObserver(
            forName: .agentJobStoreDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRunningAgentJobs()
            }
        }
        agentSettingsObserver = NotificationCenter.default.addObserver(
            forName: .agentConfigurationDidChange,
            object: settingsStore,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRunningAgentJobs()
                self?.rebuildMenu()
            }
        }
        historyObserver = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        personaSelectionObserver = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: settingsStore,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        autoUpdateStateObserver = NotificationCenter.default.addObserver(
            forName: .autoUpdateStateDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        autoModelDownloadObserver = NotificationCenter.default.addObserver(
            forName: .autoModelDownloadStateDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        refreshRunningAgentJobs()

        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTitle()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    func stop() {
        menu = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        languageObserver = nil
        if let agentJobObserver {
            NotificationCenter.default.removeObserver(agentJobObserver)
        }
        agentJobObserver = nil
        if let agentSettingsObserver {
            NotificationCenter.default.removeObserver(agentSettingsObserver)
        }
        agentSettingsObserver = nil
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
        historyObserver = nil
        if let personaSelectionObserver {
            NotificationCenter.default.removeObserver(personaSelectionObserver)
        }
        personaSelectionObserver = nil
        if let autoModelDownloadObserver {
            NotificationCenter.default.removeObserver(autoModelDownloadObserver)
        }
        autoModelDownloadObserver = nil
        stopRunningJobDurationTimer()
        cancellables.removeAll()
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 3, weight: .medium)
        let accessibilityTitle: String = switch appState.status {
        case .idle:
            L("menu.status.ready")
        case .recording:
            L("menu.status.recording")
        case .processing:
            L("menu.status.processing")
        case let .failed(message):
            L("menu.status.failed", message)
        }

        button.title = ""
        let image = NSImage(
            systemSymbolName: StudioTheme.Symbol.brand,
            accessibilityDescription: accessibilityTitle,
        )?.withSymbolConfiguration(symbolConfig)
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyUpOrDown
        button.contentTintColor = nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(makeItem(title: L("menu.openVoiceStudio"), action: #selector(openHome)))
        menu.addItem(makeItem(title: L("menu.addVocabulary"), action: #selector(addVocabularyTerm)))
        let historyItem = NSMenuItem(title: L("menu.transcriptionHistory"), action: nil, keyEquivalent: "")
        historyItem.tag = MenuTag.transcriptionHistory
        historyItem.submenu = buildTranscriptionHistoryMenu()
        menu.addItem(historyItem)
        let personasItem = NSMenuItem(title: L("menu.personas"), action: nil, keyEquivalent: "")
        personasItem.tag = MenuTag.personas
        personasItem.submenu = buildPersonasMenu()
        menu.addItem(personasItem)
        if settingsStore.agentFrameworkEnabled, settingsStore.agentEnabled {
            let agentTasksItem = NSMenuItem(title: L("menu.agentTasks"), action: nil, keyEquivalent: "")
            agentTasksItem.tag = MenuTag.agentTasks
            agentTasksItem.submenu = buildAgentTasksMenu()
            menu.addItem(agentTasksItem)
        }
        menu.addItem(NSMenuItem.separator())

        let appearanceItem = NSMenuItem(title: L("menu.appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = buildAppearanceMenu()
        menu.addItem(appearanceItem)
        menu.addItem(makeUpdateMenuItem())
        if let downloadItem = makeAutoModelDownloadMenuItem() {
            menu.addItem(downloadItem)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.setupGuide"), action: #selector(openOnboarding)))
        menu.addItem(makeItem(title: L("menu.about"), action: #selector(openAbout)))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))

        self.menu = menu
        statusItem?.menu = menu
    }

    private func buildAppearanceMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.appearance"))

        menu.addItem(makeAppearanceItem(mode: .system))
        menu.addItem(makeAppearanceItem(mode: .light))
        menu.addItem(makeAppearanceItem(mode: .dark))

        return menu
    }

    private func buildTranscriptionHistoryMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.transcriptionHistory"))
        menu.delegate = self
        populateTranscriptionHistoryMenu(menu)
        return menu
    }

    private func populateTranscriptionHistoryMenu(_ menu: NSMenu) {
        let records = StatusBarMenuSupport.recentTranscriptionRecords(
            from: historyStore.list(limit: MenuLayout.recentHistoryLimit * 3, offset: 0, searchQuery: nil),
            limit: MenuLayout.recentHistoryLimit,
        )

        if records.isEmpty {
            let emptyItem = NSMenuItem(
                title: L("menu.transcriptionHistory.empty"),
                action: nil,
                keyEquivalent: "",
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for record in records {
                let item = NSMenuItem(
                    title: StatusBarMenuSupport.recentHistoryTitle(for: record),
                    action: #selector(copyRecentHistoryResult(_:)),
                    keyEquivalent: "",
                )
                item.target = self
                item.representedObject = record.finalText
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.transcriptionHistory.viewAll"), action: #selector(openHistory)))
    }

    private func buildPersonasMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.personas"))
        menu.delegate = self
        populatePersonasMenu(menu)
        return menu
    }

    private func populatePersonasMenu(_ menu: NSMenu) {
        let personas = settingsStore.personas
        let activePersonaID = settingsStore.personaRewriteEnabled ? settingsStore.activePersonaID : ""

        let noPersonaItem = NSMenuItem(
            title: L("persona.none.title"),
            action: #selector(selectPersonaFromMenu(_:)),
            keyEquivalent: "",
        )
        noPersonaItem.target = self
        noPersonaItem.representedObject = MenuValue.noPersona
        noPersonaItem.state = activePersonaID.isEmpty ? .on : .off
        menu.addItem(noPersonaItem)

        for persona in personas {
            let item = NSMenuItem(
                title: persona.name,
                action: #selector(selectPersonaFromMenu(_:)),
                keyEquivalent: "",
            )
            item.target = self
            item.representedObject = persona.id.uuidString
            item.state = persona.id.uuidString == activePersonaID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.personas.edit"), action: #selector(openPersonas)))
    }

    private func buildAgentTasksMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.agentTasks"))
        menu.delegate = self

        if runningAgentJobs.isEmpty {
            let emptyItem = NSMenuItem(title: L("menu.agentTasks.empty"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for job in runningAgentJobs.prefix(8) {
                let item = NSMenuItem(
                    title: agentTaskMenuTitle(for: job),
                    action: #selector(openAgentJob(_:)),
                    keyEquivalent: "",
                )
                item.target = self
                item.representedObject = job.id.uuidString
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.agentTasks.viewAll"), action: #selector(openAgentJobs)))
        return menu
    }

    private func makeAppearanceItem(mode: AppearanceMode) -> NSMenuItem {
        let item = NSMenuItem(title: mode.displayName, action: #selector(selectAppearanceMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = settingsStore.appearanceMode == mode ? .on : .off
        return item
    }

    /// Returns a menu item showing local model download progress, or nil when there is nothing to display.
    private func makeAutoModelDownloadMenuItem() -> NSMenuItem? {
        guard let service = autoModelDownloadService else { return nil }
        if case .downloading(let progress) = service.status {
            let percent = Int(progress * 100)
            let item = NSMenuItem(
                title: L("menu.downloadingLocalModel", percent),
                action: nil,
                keyEquivalent: "",
            )
            item.isEnabled = false
            return item
        }
        return nil
    }

    private func makeItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makeUpdateMenuItem() -> NSMenuItem {
        switch AutoUpdater.shared.state {
        case .idle:
            return makeItem(title: L("menu.checkForUpdates"), action: #selector(checkUpdates))
        case .downloading:
            let item = NSMenuItem(title: L("menu.downloadingUpdate"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .installing:
            let item = NSMenuItem(title: L("menu.installingUpdate"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    private func openStudio(_ section: StudioSection) {
        switch section {
        case .history:
            openHistory()
        default:
            SettingsWindowController.shared.show(
                settingsStore: settingsStore,
                historyStore: historyStore,
                initialSection: section,
                notificationService: notificationService,
                onRetryHistory: onRetryHistory,
            )
        }
    }

    @objc private func openHome() {
        openStudio(.home)
    }

    @objc private func openPersonas() {
        openStudio(.personas)
    }

    @objc private func openHistory() {
        SettingsWindowController.shared.show(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .history,
            notificationService: notificationService,
            onRetryHistory: onRetryHistory,
        )
    }

    @objc private func addVocabularyTerm() {
        let alert = NSAlert()
        alert.messageText = L("menu.addVocabulary.dialog.title")
        alert.informativeText = L("menu.addVocabulary.dialog.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("menu.addVocabulary.dialog.confirm"))
        alert.addButton(withTitle: L("common.cancel"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = L("vocabulary.sheet.placeholder")
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let terms = textField.stringValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for term in terms {
            VocabularyStore.add(term: term, source: .manual)
        }
    }

    @objc private func copyRecentHistoryResult(_ sender: NSMenuItem) {
        guard
            let text = sender.representedObject as? String,
            !text.isEmpty
        else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func selectAppearanceMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = AppearanceMode(rawValue: rawValue)
        else {
            return
        }

        settingsStore.appearanceMode = mode
        rebuildMenu()
    }

    @objc private func selectPersonaFromMenu(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String
        else {
            return
        }

        if rawValue == MenuValue.noPersona {
            settingsStore.applyPersonaSelection(nil)
            rebuildMenu()
            return
        }

        guard let personaID = UUID(uuidString: rawValue) else { return }
        settingsStore.applyPersonaSelection(personaID)
        rebuildMenu()
    }

    @objc private func checkUpdates() {
        AutoUpdater.shared.checkForUpdates()
    }

    @objc private func openOnboarding() {
        onOpenOnboarding()
    }

    @objc private func openAgentJobs() {
        onOpenAgentJobs()
    }

    @objc private func openAgentJob(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let jobID = UUID(uuidString: rawValue)
        else {
            return
        }
        onOpenAgentJob(jobID)
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshRunningAgentJobs() {
        Task {
            let jobs = await (try? agentJobStore.list(limit: 100, offset: 0)) ?? []
            let runningJobs = jobs.filter { $0.status == .running }
            await MainActor.run {
                self.runningAgentJobs = runningJobs
                self.rebuildMenu()
                self.refreshVisibleAgentTaskMenuTitles()
            }
        }
    }

    private func agentTaskMenuTitle(for job: AgentJob, relativeTo now: Date = Date()) -> String {
        "\(job.truncatedTitle(limit: MenuLayout.runningJobTitleLimit)) · \(job.runningElapsedText(relativeTo: now))"
    }

    private func refreshVisibleAgentTaskMenuTitles(relativeTo now: Date = Date()) {
        guard let agentTasksMenu = menu?.item(withTag: MenuTag.agentTasks)?.submenu else { return }

        for item in agentTasksMenu.items {
            guard
                let rawValue = item.representedObject as? String,
                let jobID = UUID(uuidString: rawValue),
                let job = runningAgentJobs.first(where: { $0.id == jobID })
            else {
                continue
            }

            item.title = agentTaskMenuTitle(for: job, relativeTo: now)
        }
    }

    private func startRunningJobDurationTimer() {
        guard runningJobDurationTimer == nil, !runningAgentJobs.isEmpty else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVisibleAgentTaskMenuTitles()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        runningJobDurationTimer = timer
    }

    private func stopRunningJobDurationTimer() {
        runningJobDurationTimer?.invalidate()
        runningJobDurationTimer = nil
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu == self.menu || menu.title == L("menu.agentTasks") {
            refreshVisibleAgentTaskMenuTitles()
            startRunningJobDurationTimer()
        }

        if menu.title == L("menu.transcriptionHistory") {
            menu.removeAllItems()
            populateTranscriptionHistoryMenu(menu)
        }

        if menu.title == L("menu.personas") {
            menu.removeAllItems()
            populatePersonasMenu(menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu == self.menu || menu.title == L("menu.agentTasks") else { return }
        stopRunningJobDurationTimer()
    }
}

enum StatusBarMenuSupport {
    private static let titleTextLimit = 42

    static func recentTranscriptionRecords(from records: [HistoryRecord], limit: Int = 10) -> [HistoryRecord] {
        records
            .filter { record in
                guard let text = record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return !text.isEmpty
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    static func recentHistoryTitle(for record: HistoryRecord) -> String {
        let dateText = DateFormatter.localizedString(from: record.date, dateStyle: .none, timeStyle: .short)
        let text = (record.finalText ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(dateText)  \(truncated(text, limit: titleTextLimit))"
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 3))) + "..."
    }
}
