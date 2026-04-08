import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let agentJobStore: AgentJobStore
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
    private var runningJobDurationTimer: Timer?
    private var runningAgentJobs: [AgentJob] = []

    init(
        appState: AppStateStore,
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        agentJobStore: AgentJobStore,
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in },
        onOpenOnboarding: @escaping () -> Void = {},
        onOpenAgentJobs: @escaping () -> Void = {},
        onOpenAgentJob: @escaping (UUID) -> Void = { _ in },
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.agentJobStore = agentJobStore
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
        runningJobDurationTimer?.invalidate()
        runningJobDurationTimer = nil
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

        menu.addItem(makeItem(title: L("menu.openVoiceStudio"), action: #selector(openHome)))
        menu.addItem(makeItem(title: L("menu.history"), action: #selector(openHistory)))
        menu.addItem(makeItem(title: L("menu.personas"), action: #selector(openPersonas)))
        if settingsStore.agentFrameworkEnabled, settingsStore.agentEnabled {
            let agentTasksItem = NSMenuItem(title: L("menu.agentTasks"), action: nil, keyEquivalent: "")
            agentTasksItem.submenu = buildAgentTasksMenu()
            menu.addItem(agentTasksItem)
        }
        menu.addItem(NSMenuItem.separator())

        let appearanceItem = NSMenuItem(title: L("menu.appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = buildAppearanceMenu()
        menu.addItem(appearanceItem)
        menu.addItem(makeItem(title: L("menu.checkForUpdates"), action: #selector(checkUpdates)))
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

    private func buildAgentTasksMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.agentTasks"))

        if runningAgentJobs.isEmpty {
            let emptyItem = NSMenuItem(title: L("menu.agentTasks.empty"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for job in runningAgentJobs.prefix(8) {
                let item = NSMenuItem(
                    title: "\(job.displayTitle) · \(job.runningElapsedText())",
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

    private func makeItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
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
            onRetryHistory: onRetryHistory,
        )
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

    @objc private func checkUpdates() {
        AutoUpdater.checkForUpdates()
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
                self.updateRunningJobDurationTimer()
                self.rebuildMenu()
            }
        }
    }

    private func updateRunningJobDurationTimer() {
        guard !runningAgentJobs.isEmpty else {
            runningJobDurationTimer?.invalidate()
            runningJobDurationTimer = nil
            return
        }

        guard runningJobDurationTimer == nil else { return }
        runningJobDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
    }
}
