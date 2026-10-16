import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject {
    private enum MenuTag {
        static let transcriptionHistory = 9002
        static let personas = 9003
        static let textTransformation = 9004
        static let screenshot = 9005
        static let screenshotText = 9006
        static let restorePinnedScreenshots = 9007
        static let closePinnedScreenshots = 9008
    }

    private enum MenuValue {
        static let noPersona = "__no_persona__"
    }

    private enum MenuLayout {
        static let recentHistoryLimit = 10
    }

    enum IconLayout {
        static let statusItemLength = NSStatusItem.squareLength
        static let imageSize = NSSize(width: 22, height: 22)
        static let pointSize: CGFloat = 16
    }

    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let wordBookWindow: AskWordBookWindowController?
    private let modelManager: OllamaModelManaging
    private let localModelManager: LocalSTTModelManaging
    private let notificationService: LocalNotificationSending
    private let onRetryHistory: (HistoryRecord) -> Void
    private let onOpenOnboarding: () -> Void
    private let onOpenHelp: () -> Void
    private let onOpenFeedbackURL: (URL) -> Void
    private let onOpenAskConversations: () -> Void
    private let onScreenshot: () -> Void
    private let onScreenshotText: () -> Void
    private let onScreenRecording: () -> Void
    /// How many screenshots are pinned, and how many of them let clicks through.
    private let pinnedScreenshots: () -> (count: Int, clickThrough: Int)
    private let onRestorePinnedScreenshots: () -> Void
    private let onClosePinnedScreenshots: () -> Void
    private let activityCenter: BackgroundActivityCenter?
    private(set) lazy var activityWindow: BackgroundActivityWindowController? = activityCenter.map {
        BackgroundActivityWindowController(center: $0, settingsStore: settingsStore)
    }

    /// The tasks the open (or next) menu shows.
    private(set) var menuActivityLayout = BackgroundActivityMenuLayout(activities: [])
    /// The status menu while it is open; other refreshes may replace `menu` meanwhile.
    private weak var openMenu: NSMenu?
    private var isMenuOpen: Bool {
        openMenu != nil
    }

    private var activityRebuildPending = false

    private var statusItem: NSStatusItem?
    private(set) var menu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    private var languageObserver: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?
    private var personaSelectionObserver: NSObjectProtocol?
    private var autoUpdateStateObserver: NSObjectProtocol?

    init(
        appState: AppStateStore,
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        wordBookWindow: AskWordBookWindowController? = nil,
        modelManager: OllamaModelManaging = OllamaLocalModelManager(),
        localModelManager: LocalSTTModelManaging = LocalModelManager(),
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in },
        onOpenOnboarding: @escaping () -> Void = {},
        onOpenHelp: @escaping () -> Void = {},
        onOpenFeedbackURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        onOpenAskConversations: @escaping () -> Void = {},
        onScreenshot: @escaping () -> Void = {},
        onScreenshotText: @escaping () -> Void = {},
        onScreenRecording: @escaping () -> Void = {},
        pinnedScreenshots: @escaping () -> (count: Int, clickThrough: Int) = { (0, 0) },
        onRestorePinnedScreenshots: @escaping () -> Void = {},
        onClosePinnedScreenshots: @escaping () -> Void = {},
        activityCenter: BackgroundActivityCenter? = nil
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.wordBookWindow = wordBookWindow
        self.modelManager = modelManager
        self.localModelManager = localModelManager
        self.notificationService = notificationService
        self.onRetryHistory = onRetryHistory
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenHelp = onOpenHelp
        self.onOpenFeedbackURL = onOpenFeedbackURL
        self.onOpenAskConversations = onOpenAskConversations
        self.onScreenshot = onScreenshot
        self.onScreenshotText = onScreenshotText
        self.onScreenRecording = onScreenRecording
        self.pinnedScreenshots = pinnedScreenshots
        self.onRestorePinnedScreenshots = onRestorePinnedScreenshots
        self.onClosePinnedScreenshots = onClosePinnedScreenshots
        self.activityCenter = activityCenter
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: IconLayout.statusItemLength)
        updateTitle()
        rebuildMenu()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
        historyObserver = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        personaSelectionObserver = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        autoUpdateStateObserver = NotificationCenter.default.addObserver(
            forName: .autoUpdateStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
        // Published values arrive before they are stored; read them on the next main queue turn.
        activityCenter?.$activities
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.activitiesDidChange() }
            .store(in: &cancellables)

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
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
        historyObserver = nil
        if let personaSelectionObserver {
            NotificationCenter.default.removeObserver(personaSelectionObserver)
        }
        personaSelectionObserver = nil
        if let autoUpdateStateObserver {
            NotificationCenter.default.removeObserver(autoUpdateStateObserver)
        }
        autoUpdateStateObserver = nil
        cancellables.removeAll()
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: IconLayout.pointSize, weight: .medium)
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

        let description = activityCenter.map { Self.accessibilityTitle(accessibilityTitle, center: $0) }
            ?? accessibilityTitle

        button.title = ""
        let image = NSImage(
            systemSymbolName: StudioTheme.Symbol.brand,
            accessibilityDescription: description
        )?.withSymbolConfiguration(symbolConfig)
        image?.size = IconLayout.imageSize
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = nil
    }

    /// "Ready, 2 background tasks in progress, a background task needs your attention".
    static func accessibilityTitle(_ status: String, center: BackgroundActivityCenter) -> String {
        var parts = [status]
        if center.activeCount > 0 {
            parts.append(L("activity.accessibility", center.activeCount))
        }
        if center.activities.contains(where: \.needsUser) {
            parts.append(L("activity.accessibility.attention"))
        }
        return parts.joined(separator: L("activity.accessibility.separator"))
    }

    /// The menu bar button, for tests that check the icon.
    var statusItemButton: NSStatusBarButton? {
        statusItem?.button
    }

    private func activitiesDidChange() {
        updateTitle()
        guard let activityCenter else { return }
        let layout = BackgroundActivityMenuLayout(activities: activityCenter.activities)
        guard layout.rows != menuActivityLayout.rows || layout.hiddenCount != menuActivityLayout.hiddenCount
        else { return }
        // Rebuilding an open menu changes its height under the pointer; wait until it closes.
        if isMenuOpen {
            activityRebuildPending = true
        } else {
            rebuildMenu()
        }
    }

    /// Opens the background tasks window.
    func showBackgroundActivity() {
        activityWindow?.show()
    }

    private func addActivitySection(to menu: NSMenu) {
        guard let activityCenter else { return }
        menuActivityLayout = BackgroundActivityMenuLayout(activities: activityCenter.activities)
        guard !menuActivityLayout.isEmpty else { return }
        menu.addItem(BackgroundActivityMenuSection.menuItem(
            center: activityCenter,
            layout: menuActivityLayout,
            perform: { [weak self, weak activityCenter] action, id in
                // Opening something leaves the menu; row buttons such as pause keep it open.
                if action == .open {
                    self?.openMenu?.cancelTracking()
                }
                activityCenter?.perform(action, on: id)
            },
            showAll: { [weak self] in
                self?.openMenu?.cancelTracking()
                self?.showBackgroundActivity()
            }
        ))
        menu.addItem(NSMenuItem.separator())
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = self

        addActivitySection(to: menu)
        menu.addItem(makeItem(title: L("menu.openVoiceStudio"), action: #selector(openAskConversations)))
        let toolboxItem = NSMenuItem(title: L("menu.toolbox"), action: nil, keyEquivalent: "")
        toolboxItem.submenu = buildToolboxMenu()
        menu.addItem(toolboxItem)
        let voiceInputItem = NSMenuItem(title: L("menu.voiceInput"), action: nil, keyEquivalent: "")
        voiceInputItem.submenu = buildVoiceInputMenu()
        menu.addItem(voiceInputItem)
        menu.addItem(makeSettingsItem())
        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeItem(title: L("menu.help"), action: #selector(openHelp)))
        menu.addItem(makeItem(title: L("menu.setupGuide"), action: #selector(openOnboarding)))
        menu.addItem(makeUpdateMenuItem())
        let feedbackItem = NSMenuItem(title: L("menu.feedback"), action: nil, keyEquivalent: "")
        feedbackItem.submenu = buildFeedbackMenu()
        menu.addItem(feedbackItem)
        menu.addItem(makeItem(title: L("menu.about"), action: #selector(openAbout)))
        // Developer builds expose the shared component gallery next to About.
        if ComponentGalleryAccess.isAvailable() {
            menu.addItem(makeItem(title: L("appMenu.componentGallery"), action: #selector(openComponentGallery)))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))

        self.menu = menu
        statusItem?.menu = menu
    }

    private func buildFeedbackMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.feedback"))
        menu.autoenablesItems = false
        for destination in FeedbackDestination.allCases {
            let item = makeItem(title: destination.title, action: #selector(selectFeedback))
            item.representedObject = destination.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func buildToolboxMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.toolbox"))
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(makeScreenshotItem())
        menu.addItem(makeScreenshotTextItem())
        menu.addItem(makeItem(title: L("recording.title"), action: #selector(startScreenRecording)))
        for item in makePinnedScreenshotItems() {
            menu.addItem(item)
        }
        menu.addItem(makeItem(title: L("menu.notes"), action: #selector(openNotes)))
        menu.addItem(makeItem(title: L("ask.wordBook.title"), action: #selector(openWordBook)))
        return menu
    }

    private func buildVoiceInputMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.voiceInput"))
        menu.autoenablesItems = false
        let historyItem = NSMenuItem(title: L("menu.transcriptionHistory"), action: nil, keyEquivalent: "")
        historyItem.tag = MenuTag.transcriptionHistory
        historyItem.submenu = buildTranscriptionHistoryMenu()
        menu.addItem(historyItem)
        let personasItem = NSMenuItem(title: L("menu.personas"), action: nil, keyEquivalent: "")
        personasItem.tag = MenuTag.personas
        personasItem.submenu = buildPersonasMenu()
        menu.addItem(personasItem)
        if settingsStore.isTextTransformationAvailable {
            let textTransformationItem = NSMenuItem(title: L("menu.textTransformation"), action: nil, keyEquivalent: "")
            textTransformationItem.tag = MenuTag.textTransformation
            textTransformationItem.submenu = buildTextTransformationMenu()
            menu.addItem(textTransformationItem)
        }
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
            limit: MenuLayout.recentHistoryLimit
        )

        if records.isEmpty {
            let emptyItem = NSMenuItem(
                title: L("menu.transcriptionHistory.empty"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for record in records {
                let item = NSMenuItem(
                    title: StatusBarMenuSupport.recentHistoryTitle(for: record),
                    action: #selector(copyRecentHistoryResult(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = record.finalText
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.transcriptionHistory.viewAll"), action: #selector(openHistory)))
    }

    private func buildTextTransformationMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.textTransformation"))
        menu.delegate = self
        populateTextTransformationMenu(menu)
        return menu
    }

    private func populateTextTransformationMenu(_ menu: NSMenu) {
        guard settingsStore.isTextTransformationAvailable else { return }

        let isEnabled = settingsStore.isOutputOpenCCEffectiveEnabled
        let activeConfig = settingsStore.outputOpenCCConfig

        let enableItem = NSMenuItem(
            title: L("menu.textTransformation.enable"),
            action: #selector(toggleTextTransformation(_:)),
            keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.state = isEnabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let rules = [
            (label: L("settings.output.opencc.config.s2twp"), value: "s2twp"),
            (label: L("settings.output.opencc.config.s2tw"), value: "s2tw"),
            (label: L("settings.output.opencc.config.s2hk"), value: "s2hk"),
            (label: L("settings.output.opencc.config.t2s"), value: "t2s")
        ]

        for rule in rules {
            let item = NSMenuItem(
                title: rule.label,
                action: #selector(selectTextTransformationRule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = rule.value
            item.state = (isEnabled && rule.value == activeConfig) ? .on : .off
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
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
            keyEquivalent: ""
        )
        noPersonaItem.target = self
        noPersonaItem.representedObject = MenuValue.noPersona
        noPersonaItem.state = activePersonaID.isEmpty ? .on : .off
        menu.addItem(noPersonaItem)

        for persona in personas {
            let item = NSMenuItem(
                title: persona.name,
                action: #selector(selectPersonaFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = persona.id.uuidString
            item.state = persona.id.uuidString == activePersonaID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(title: L("menu.personas.edit"), action: #selector(openPersonas)))
    }

    private func makeItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// "Screenshot", showing its global shortcut when it is a plain key chord.
    func makeScreenshotItem() -> NSMenuItem {
        let item = makeItem(title: L("menu.screenshot"), action: #selector(takeScreenshot))
        item.tag = MenuTag.screenshot
        applyScreenshotShortcut(to: item)
        return item
    }

    private func applyScreenshotShortcut(to item: NSMenuItem) {
        let equivalent = settingsStore.screenshotHotkey.flatMap(StatusBarMenuSupport.keyEquivalent(for:))
        item.keyEquivalent = equivalent?.key ?? ""
        item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
    }

    @objc private func startScreenRecording() {
        DispatchQueue.main.async { [onScreenRecording] in onScreenRecording() }
    }

    @objc private func takeScreenshot() {
        // Let the menu close before the displays freeze.
        DispatchQueue.main.async { [onScreenshot] in onScreenshot() }
    }

    /// "Screenshot to text": frames a region and shows its text in the launcher.
    func makeScreenshotTextItem() -> NSMenuItem {
        let item = makeItem(title: L("menu.screenshotText"), action: #selector(takeScreenshotText))
        item.tag = MenuTag.screenshotText
        return item
    }

    @objc private func takeScreenshotText() {
        DispatchQueue.main.async { [onScreenshotText] in onScreenshotText() }
    }

    /// "Let pinned screenshots take clicks" and "Close pinned screenshots (2)": hidden until something is pinned.
    func makePinnedScreenshotItems() -> [NSMenuItem] {
        let restore = makeItem(title: L("menu.pins.restoreMouse"), action: #selector(restorePinnedScreenshots))
        restore.tag = MenuTag.restorePinnedScreenshots
        let close = makeItem(title: L("menu.pins.closeAll"), action: #selector(closePinnedScreenshots))
        close.tag = MenuTag.closePinnedScreenshots
        let items = [restore, close]
        updatePinnedScreenshotItems(in: items)
        return items
    }

    func updatePinnedScreenshotItems(in items: [NSMenuItem]) {
        let pins = pinnedScreenshots()
        for item in items {
            switch item.tag {
            case MenuTag.restorePinnedScreenshots:
                item.isHidden = pins.clickThrough == 0
            case MenuTag.closePinnedScreenshots:
                item.isHidden = pins.count == 0
                item.title = L("menu.pins.closeAll", pins.count)
            default:
                break
            }
        }
    }

    @objc private func restorePinnedScreenshots() {
        onRestorePinnedScreenshots()
    }

    @objc private func closePinnedScreenshots() {
        onClosePinnedScreenshots()
    }

    private func makeSettingsItem() -> NSMenuItem {
        makeItem(title: L("menu.settings"), action: #selector(showConfiguration))
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

    private func openStudio(_ section: StudioSection, modelDomain: StudioModelDomain? = nil) {
        switch section {
        case .history:
            openHistory()
        default:
            SettingsWindowController.shared.show(
                settingsStore: settingsStore,
                historyStore: historyStore,
                initialSection: section,
                initialModelDomain: modelDomain,
                modelManager: modelManager,
                localModelManager: localModelManager,
                notificationService: notificationService,
                onRetryHistory: onRetryHistory
            )
        }
    }

    /// Opens the settings window from outside the menu, e.g. the Ask sidebar footer.
    func showSettings(section: StudioSection = .settings) {
        openStudio(section, modelDomain: section == .models ? .llm : nil)
    }

    @objc private func showConfiguration() {
        openStudio(.settings)
    }

    @objc private func openPersonas() {
        openStudio(.personas)
    }

    @objc private func openHistory() {
        SettingsWindowController.shared.show(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .history,
            modelManager: modelManager,
            localModelManager: localModelManager,
            notificationService: notificationService,
            onRetryHistory: onRetryHistory
        )
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

    @objc private func toggleTextTransformation(_: NSMenuItem) {
        guard settingsStore.isTextTransformationAvailable else { return }
        settingsStore.outputOpenCCEnabled.toggle()
        rebuildMenu()
    }

    @objc private func selectTextTransformationRule(_ sender: NSMenuItem) {
        guard settingsStore.isTextTransformationAvailable else { return }
        guard let rule = sender.representedObject as? String else { return }
        settingsStore.outputOpenCCConfig = rule
        rebuildMenu()
    }

    @objc private func selectFeedback(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let destination = FeedbackDestination(rawValue: value) else { return }
        showFeedback(destination)
    }

    /// Both feedback menus use this route, including the existing direct feedback form.
    func showFeedback(_ destination: FeedbackDestination) {
        if destination != .direct {
            if let url = destination.url { onOpenFeedbackURL(url) }
            return
        }
        SettingsWindowController.shared.show(
            settingsStore: settingsStore,
            historyStore: historyStore,
            presentFeedback: true,
            modelManager: modelManager,
            localModelManager: localModelManager,
            notificationService: notificationService,
            onRetryHistory: onRetryHistory
        )
    }

    @objc private func checkUpdates() {
        AutoUpdater.shared.checkForUpdates()
    }

    @objc private func openOnboarding() {
        onOpenOnboarding()
    }

    @objc private func openHelp() {
        onOpenHelp()
    }

    @objc private func openAskConversations() {
        onOpenAskConversations()
    }

    @objc private func openWordBook() {
        (wordBookWindow ?? .shared).show()
    }

    @objc private func openNotes() {
        AskNotesWindowController.shared.show()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func openComponentGallery() {
        ComponentGalleryWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            openMenu = menu
        }
        // The shortcut may have changed in Settings since the menu was built.
        if let item = menu.item(withTag: MenuTag.screenshot) {
            applyScreenshotShortcut(to: item)
        }
        updatePinnedScreenshotItems(in: [MenuTag.restorePinnedScreenshots, MenuTag.closePinnedScreenshots]
            .compactMap { menu.item(withTag: $0) })

        if menu.title == L("menu.transcriptionHistory") {
            menu.removeAllItems()
            populateTranscriptionHistoryMenu(menu)
        }

        if menu.title == L("menu.personas") {
            menu.removeAllItems()
            populatePersonasMenu(menu)
        }

        if menu.title == L("menu.textTransformation") {
            menu.removeAllItems()
            populateTextTransformationMenu(menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === openMenu else { return }
        openMenu = nil
        if activityRebuildPending {
            activityRebuildPending = false
            rebuildMenu()
        }
    }
}

enum StatusBarMenuSupport {
    private static let titleTextLimit = 42

    /// A menu key equivalent for a shortcut that is modifiers plus one letter or digit;
    /// nil for modifier-only, double-press and other keys a menu cannot show.
    static func keyEquivalent(for binding: HotkeyBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard (binding.pressCount ?? 1) == 1, binding.modifierKeyCodes == nil, !binding.isModifierOnlyTrigger,
              let key = HotkeyFormat.components(binding).last, key.count == 1,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
            .intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return nil }
        return (key.lowercased(), flags)
    }

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
            .map(\.self)
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

/// Opening a particular settings page, for links from the usage guide.
extension StatusBarController {
    /// Opens the speech recognition models page.
    func showSpeechModels() {
        openStudio(.models, modelDomain: .stt)
    }

    /// Opens one pane of Settings, such as Shortcuts.
    func showAppSettings(_ pane: AppSettingsPane) {
        openStudio(.settings)
        SettingsWindowController.shared.requestSettingsPane(pane)
    }

    /// Opens one pane of the launcher settings, such as Keywords.
    func showLauncherSettings(_ pane: LauncherSettingsPane) {
        SettingsWindowController.shared.show(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .launcher,
            launcherPane: pane,
            modelManager: modelManager,
            localModelManager: localModelManager,
            notificationService: notificationService,
            onRetryHistory: onRetryHistory
        )
    }
}
