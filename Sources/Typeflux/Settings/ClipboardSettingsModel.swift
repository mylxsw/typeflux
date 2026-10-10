import Combine
import Foundation

/// State behind Settings → Launcher → Clipboard. Every change is written to `SettingsStore`
/// at once; the monitor and panel read the store when they next run.
final class ClipboardSettingsModel: ObservableObject {
    /// The pause menu's choices. `pausedUntil` stands for a running timed pause.
    enum PauseChoice: Hashable {
        case recording
        case pause(ClipboardPauseDuration)
        case pausedUntil(Date)
    }

    @Published private(set) var historyEnabled: Bool
    @Published private(set) var retention: ClipboardRetention
    @Published private(set) var maxItems: Int
    @Published private(set) var storageLimit: ClipboardStorageLimit
    @Published private(set) var plainTextOnly: Bool
    @Published private(set) var singleClickPastes: Bool
    @Published private(set) var showsPreview: Bool
    @Published private(set) var selectsFirstUnpinned: Bool
    @Published private(set) var panelPosition: ClipboardPanelPosition
    @Published private(set) var pause: PauseChoice
    @Published private(set) var ignoredApps: [ClipboardIgnoredApp]
    /// `nil` until loaded, or when there is no history store.
    @Published private(set) var usage: ClipboardUsage?

    let store: SettingsStore
    let history: ClipboardHistoryStore?
    var now: () -> Date
    private var pauseObserver: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?

    init(store: SettingsStore, history: ClipboardHistoryStore? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.history = history
        self.now = now
        ignoredApps = store.clipboardIgnoredApps
        historyEnabled = store.clipboardHistoryEnabled
        retention = store.clipboardRetention
        maxItems = store.clipboardMaxItems
        storageLimit = store.clipboardStorageLimit
        plainTextOnly = store.clipboardPlainTextOnly
        singleClickPastes = store.clipboardSingleClickPastes
        showsPreview = store.clipboardShowsPreview
        selectsFirstUnpinned = store.clipboardSelectsFirstUnpinned
        panelPosition = store.clipboardPanelPosition
        pause = Self.pauseChoice(store: store, now: now())
        pauseObserver = NotificationCenter.default.addObserver(
            forName: .clipboardRecordingPauseDidChange, object: store, queue: .main
        ) { [weak self] _ in
            self?.reloadPause()
        }
        historyObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadUsage()
        }
    }

    deinit {
        if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    // MARK: - Ignored apps

    /// Adds an app chosen in an open panel; returns false when it is not an app bundle.
    @discardableResult
    func addIgnoredApp(at url: URL) -> Bool {
        guard let app = ClipboardIgnoredApp(appURL: url) else { return false }
        guard !ignoredApps.contains(where: { $0.bundleID == app.bundleID }) else { return true }
        ignoredApps.append(app)
        store.clipboardIgnoredApps = ignoredApps
        return true
    }

    func removeIgnoredApp(_ bundleID: String) {
        ignoredApps.removeAll { $0.bundleID == bundleID }
        store.clipboardIgnoredApps = ignoredApps
    }

    // MARK: - Data usage

    func reloadUsage() {
        usage = history?.usage()
    }

    /// Deletes the unpinned items from one app, or from every app.
    func deleteUnpinned(bundleID: String?) {
        history?.deleteUnpinned(sourceBundleID: bundleID)
        reloadUsage()
    }

    /// Options for the pause menu; a running timed pause shows its end time as the current choice.
    var pauseOptions: [(label: String, value: PauseChoice)] {
        var options: [(label: String, value: PauseChoice)] = [(L("clipboard.settings.pause.off"), .recording)]
        if case let .pausedUntil(date) = pause {
            let time = date.formatted(date: .omitted, time: .shortened)
            options.append((L("clipboard.settings.pause.until", time), pause))
        }
        options += ClipboardPauseDuration.allCases.map { ($0.title, .pause($0)) }
        return options
    }

    func setHistoryEnabled(_ value: Bool) {
        historyEnabled = value
        store.clipboardHistoryEnabled = value
    }

    func setRetention(_ value: ClipboardRetention) {
        retention = value
        store.clipboardRetention = value
    }

    func setMaxItems(_ value: Int) {
        maxItems = value
        store.clipboardMaxItems = value
    }

    func setStorageLimit(_ value: ClipboardStorageLimit) {
        storageLimit = value
        store.clipboardStorageLimit = value
    }

    func setPlainTextOnly(_ value: Bool) {
        plainTextOnly = value
        store.clipboardPlainTextOnly = value
    }

    func setSingleClickPastes(_ value: Bool) {
        singleClickPastes = value
        store.clipboardSingleClickPastes = value
    }

    func setShowsPreview(_ value: Bool) {
        showsPreview = value
        store.clipboardShowsPreview = value
    }

    func setSelectsFirstUnpinned(_ value: Bool) {
        selectsFirstUnpinned = value
        store.clipboardSelectsFirstUnpinned = value
    }

    func setPanelPosition(_ value: ClipboardPanelPosition) {
        panelPosition = value
        store.clipboardPanelPosition = value
    }

    func setPause(_ choice: PauseChoice) {
        switch choice {
        case .recording:
            store.resumeClipboardRecording()
        case let .pause(duration):
            store.pauseClipboardRecording(for: duration, now: now())
        case .pausedUntil:
            return
        }
        reloadPause()
    }

    func reloadPause() {
        pause = Self.pauseChoice(store: store, now: now())
    }

    static func pauseChoice(store: SettingsStore, now: Date) -> PauseChoice {
        guard store.isClipboardRecordingPaused(now: now), let until = store.clipboardPausedUntil else {
            return .recording
        }
        return until == .distantFuture ? .pause(.untilResumed) : .pausedUntil(until)
    }
}
