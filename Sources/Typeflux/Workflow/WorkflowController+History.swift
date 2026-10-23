import Foundation

/// The clipboard panel opened by the history hotkey: voice results plus clipboard history.
extension WorkflowController {
    static let historyPanelVoiceLimit = 200
    /// Lets keyboard focus return to the target app after the key panel closes, before pasting.
    static let historyPanelFocusReturnDelay: Duration = .milliseconds(150)

    func configureHistoryPanel() {
        historyPanelModel.onAction = { [weak self] action, entry in
            self?.performHistoryAction(action, on: entry)
        }
        historyPanelModel.onSaveSnippet = { [weak self] draft in
            guard let store = self?.clipboardHistoryStore else { throw ClipboardSnippetError.unavailable }
            let id: UUID?
            if case let .clipboard(sourceID) = draft.entry.origin { id = sourceID } else { id = nil }
            return try store.saveSnippet(id: id, name: draft.name, text: draft.text, alias: draft.alias,
                                         source: ClipboardSource(bundleID: draft.entry.sourceBundleID,
                                                                 appName: draft.entry.sourceAppName), at: Date())
        }
        historyPanelModel.onDismiss = { [weak self] in
            self?.dismissHistoryPicker()
        }
        historyPanelModel.onPreviewVisibilityChange = { [weak self] shows in
            self?.settingsStore.clipboardShowsPreview = shows
        }
        historyPanelModel.onCommand = { [weak self] command in
            self?.performHistoryPanelCommand(command)
        }
        clipboardPauseObserver = NotificationCenter.default.addObserver(
            forName: .clipboardRecordingPauseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            historyPanelModel.isRecordingPaused = settingsStore.isClipboardRecordingPaused()
        }
        clipboardHistoryObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHistoryPanel()
        }
        transcriptionHistoryObserver = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHistoryPanel()
        }
    }

    func handleHistoryPickerRequested() {
        if FeatureProcess.enabled, FeatureProcess.role != .clipboard {
            FeatureProcess.send(.init(destination: .clipboard, action: "toggleClipboard")); return
        }
        clipboardActionGeneration = UUID()
        if isHistoryPickerPresented || isHistoryPickerLoading {
            ShortcutLatency.record(.dismissed)
            dismissHistoryPicker()
            return
        }

        if isPersonaPickerPresented {
            dismissPersonaPicker()
        }

        guard !isRecording, processingTask == nil else { ShortcutLatency.record(.blocked); return }

        requestHistoryPanel(opening: true)
    }

    /// The rows currently shown in the panel.
    var historyPickerItems: [ClipboardEntry] {
        historyPanelModel.visibleEntries
    }

    func historyPanelEntries() -> [ClipboardEntry] {
        Self.historyPanelEntries(history: historyStore, clipboard: clipboardHistoryStore)
    }

    private static func historyPanelEntries(history: any HistoryStore, clipboard: (any ClipboardHistoryStore)?) -> [ClipboardEntry] {
        let records = StatusBarMenuSupport.recentTranscriptionRecords(
            from: history.list(limit: Self.historyPanelVoiceLimit * 3, offset: 0, searchQuery: nil),
            limit: Self.historyPanelVoiceLimit
        )
        return ClipboardFeed.entries(
            // Trimming bounds the store; pinned items come on top of the unpinned limit.
            clipboardItems: clipboard?.items(limit: Int(Int32.max)) ?? [],
            voiceRecords: records,
            pinnedVoiceRecordIDs: clipboard?.pinnedVoiceRecordIDs() ?? []
        )
    }

    func reloadHistoryPanel() {
        guard isHistoryPickerPresented else { return }
        requestHistoryPanel(opening: false)
    }

    private func requestHistoryPanel(opening: Bool) {
        let latency = opening ? ShortcutLatency.current : nil
        ShortcutLatency.record(.dataStarted, trace: latency)
        let generation = UUID()
        historyPanelLoadGeneration = generation
        isHistoryPickerLoading = true
        // Capture settings on the UI thread; the worker only accesses synchronized stores.
        let history = historyStore, clipboard = clipboardHistoryStore
        let maintenance = clipboardMaintenance(at: Date())
        var entries: [ClipboardEntry] = []
        historyPanelWork.submit({
            if opening { maintenance() }
            entries = Self.historyPanelEntries(history: history, clipboard: clipboard)
            ShortcutLatency.record(.dataFinished, trace: latency)
        }, completion: { [weak self] result in
            guard let self else { ShortcutLatency.record(.superseded, trace: latency); return }
            ShortcutLatency.$current.withValue(latency) {
                guard self.historyPanelLoadGeneration == generation else { ShortcutLatency.record(.superseded); return }
                self.isHistoryPickerLoading = false
                switch result {
                case .failure:
                    ShortcutLatency.record(.failed)
                    if self.isHistoryPickerPresented { self.historyPanelModel.showNotice(L("ask.plugin.clip.unavailable")) }
                    else {
                        self.overlayController.showNotice(message: L("ask.plugin.clip.unavailable"))
                        self.overlayController.dismiss(after: 2)
                    }
                case .success:
                    guard !entries.isEmpty else {
                        ShortcutLatency.record(.blocked)
                        if opening {
                            self.overlayController.showNotice(message: L("overlay.historyPicker.empty"))
                            self.overlayController.dismiss(after: 2)
                        } else { self.dismissHistoryPicker() }
                        return
                    }
                    if opening {
                        // Another feature can start while the read is suspended.
                        guard !self.isRecording, self.processingTask == nil, !self.isPersonaPickerPresented else { ShortcutLatency.record(.blocked); return }
                        self.historyPanelModel.showsPreview = self.settingsStore.clipboardShowsPreview
                        self.historyPanelModel.isRecordingPaused = self.settingsStore.isClipboardRecordingPaused()
                        self.historyPanelModel.singleClickPastes = self.settingsStore.clipboardSingleClickPastes
                        self.historyPanelModel.reset(entries: entries, selectFirstUnpinned: self.settingsStore.clipboardSelectsFirstUnpinned)
                        self.isHistoryPickerPresented = true
                        self.clipboardPanelPresenter?.present(self.historyPanelModel)
                    } else if self.isHistoryPickerPresented { self.historyPanelModel.replaceEntries(entries) }
                }
            }
        })
    }

    func confirmHistorySelection() {
        guard isHistoryPickerPresented else { return }
        historyPanelModel.perform(.paste)
    }

    func performHistoryAction(_ action: ClipboardEntryAction, on entry: ClipboardEntry) {
        switch action {
        case .paste:
            pasteHistoryEntry(entry, plainText: false)
        case .pastePlainText:
            pasteHistoryEntry(entry, plainText: true)
        case .copy:
            copyHistoryEntry(entry)
        case .quickLook:
            clipboardPanelPresenter?.toggleQuickLook(urls: entry.contentURLs)
        case .revealInFinder:
            dismissHistoryPicker()
            clipboardContentActions.revealInFinder(entry.fileURLs)
        case .saveToDownloads:
            saveHistoryImageToDownloads(entry)
        case .copyImageText:
            copyHistoryImageText(entry)
        case .saveSnippet, .editSnippet, .retryTranscription, .togglePin, .delete, .editBeforePaste,
             .showOnlyApp, .deleteAllFromApp:
            performHistoryManagementAction(action, on: entry)
        }
    }

    private func performHistoryManagementAction(_ action: ClipboardEntryAction, on entry: ClipboardEntry) {
        switch action {
        case .retryTranscription:
            retryHistoryEntry(entry)
        case .togglePin:
            toggleHistoryEntryPin(entry)
        case .delete:
            deleteHistoryEntry(entry)
        default:
            // Editing, the app filter and deleting an app's items are handled by the panel model,
            // which reports their results as panel commands.
            break
        }
    }

    func performHistoryPanelCommand(_ command: ClipboardPanelCommand) {
        switch command {
        case let .deleteSnippet(entry):
            deleteHistoryEntry(entry)
        case .togglePause:
            if settingsStore.isClipboardRecordingPaused() {
                settingsStore.resumeClipboardRecording()
            } else {
                settingsStore.pauseClipboardRecording(for: .untilResumed)
            }
            let paused = settingsStore.isClipboardRecordingPaused()
            historyPanelModel.isRecordingPaused = paused
            historyPanelModel.showNotice(L(paused ? "clipboard.notice.paused" : "clipboard.notice.resumed"))
        case .openSettings:
            dismissHistoryPicker()
            let settingsStore = settingsStore
            let historyStore = historyStore
            Task { @MainActor in
                SettingsWindowController.shared.show(
                    settingsStore: settingsStore,
                    historyStore: historyStore,
                    initialSection: .launcher,
                    launcherPane: .clipboard
                )
            }
        case .clearUnpinned:
            clipboardHistoryStore?.deleteUnpinned(sourceBundleID: nil)
            reloadHistoryPanel()
        case let .deleteApp(bundleID):
            clipboardHistoryStore?.deleteUnpinned(sourceBundleID: bundleID)
            historyPanelModel.setAppFilter(nil)
            reloadHistoryPanel()
        case let .pasteText(text):
            pasteHistoryText(text)
        }
    }

    func dismissHistoryPicker() {
        historyPanelLoadGeneration = UUID()
        isHistoryPickerLoading = false
        historyPanelWork.cancel()
        Task { @MainActor [weak self] in self?.clipboardAction.cancelPreparation() }
        guard isHistoryPickerPresented else { return }
        isHistoryPickerPresented = false
        clipboardPanelPresenter?.dismiss()
    }

    /// Applies the clipboard's own retention, item limit and image storage limit
    /// (Settings → Launcher → Clipboard).
    func enforceClipboardRetentionPolicy(now: Date = Date()) {
        clipboardMaintenanceWork.submit(clipboardMaintenance(at: now), completion: { _ in })
    }

    private func clipboardMaintenance(at now: Date) -> () -> Void {
        let store = clipboardHistoryStore
        let cutoff = settingsStore.clipboardRetention.days.map {
            now.addingTimeInterval(-TimeInterval(max(1, $0)) * 24 * 3600)
        }
        let policy = settingsStore.clipboardCapturePolicy(now: now)
        return {
            guard let store else { return }
            if let cutoff { store.purge(olderThan: cutoff) }
            ClipboardMonitor.applyLimits(of: policy, to: store)
        }
    }

    // MARK: - Actions

    private func pasteHistoryEntry(_ entry: ClipboardEntry, plainText: Bool) {
        soundEffectPlayer.playAsync(.tip)

        if entry.kind.isTextual, let text = entry.text {
            dismissHistoryPicker()
            deliverHistoryText(text)
            return
        }

        runHistoryClipboardAction(entry, plainText: plainText, paste: true)

    }

    /// Pastes text edited in the panel.
    private func pasteHistoryText(_ text: String) {
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()
        deliverHistoryText(text)
    }

    /// Puts text on the clipboard and inserts it into the app that was frontmost.
    private func deliverHistoryText(_ text: String) {
        clipboard.write(text: text)
        Task { [weak self] in
            guard let self else { return }
            await sleep(Self.historyPanelFocusReturnDelay)
            _ = await applyText(
                text,
                replace: false,
                fallbackTitle: L("overlay.historyPicker.pasteFallbackTitle")
            )
        }
    }

    private func copyHistoryEntry(_ entry: ClipboardEntry) {
        if entry.kind.isTextual, let text = entry.text {
            clipboard.write(text: text)
        } else {
            runHistoryClipboardAction(entry, plainText: false, paste: false)
            return
        }
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()
    }

    private func runHistoryClipboardAction(_ entry: ClipboardEntry, plainText: Bool, paste: Bool) {
        // Panel actions originate on the UI thread. Refuse off-thread callers before any mutation.
        guard Thread.isMainThread else { return }
        let generation = clipboardActionGeneration
        MainActor.assumeIsolated {
            let auth = billingAuth(), accountGeneration = billingAuth().sessionGeneration
            clipboardAction.start(entry: entry, plainText: plainText, paste: paste, actions: clipboardContentActions,
                authorized: { [weak self] in
                    guard let self else { return false }
                    return self.clipboardActionGeneration == generation && self.billingAuth() === auth && auth.sessionGeneration == accountGeneration && self.historyPanelEntries().contains { $0.id == entry.id }
                }, beforeCommit: { [weak self] in self?.isHistoryPickerPresented == true },
                committed: { [weak self] in
                    guard let self else { return }
                    if !paste { self.soundEffectPlayer.playAsync(.tip) }
                    self.dismissHistoryPicker()
                }, failed: { [weak self] in self?.historyPanelModel.showNotice(L("ask.plugin.clip.unavailable")) },
                delay: { [weak self] in await self?.sleep(Self.historyPanelFocusReturnDelay) })
        }
    }

    private func saveHistoryImageToDownloads(_ entry: ClipboardEntry) {
        guard let imagePath = entry.imagePath,
              let saved = clipboardContentActions.saveToDownloads(URL(fileURLWithPath: imagePath))
        else {
            historyPanelModel.showNotice(L("clipboard.notice.saveFailed"))
            return
        }
        historyPanelModel.showNotice(L("clipboard.notice.savedToDownloads", saved.lastPathComponent))
    }

    private func copyHistoryImageText(_ entry: ClipboardEntry) {
        guard Thread.isMainThread, let url = entry.contentURLs.first else { return }
        let generation = clipboardActionGeneration
        MainActor.assumeIsolated {
            let auth = billingAuth(), accountGeneration = billingAuth().sessionGeneration
            clipboardAction.startText(url: url, actions: clipboardContentActions,
                authorized: { [weak self] in
                    guard let self else { return false }
                    return self.isHistoryPickerPresented && self.historyPanelModel.selectedEntry == entry && self.clipboardActionGeneration == generation &&
                        self.billingAuth() === auth && auth.sessionGeneration == accountGeneration && self.historyPanelEntries().contains(entry)
                }, commit: { [weak self] text in
                    guard let self else { return }
                    if let text {
                        self.clipboard.write(text: text)
                        self.historyPanelModel.showNotice(L("clipboard.notice.imageTextCopied"))
                    } else { self.historyPanelModel.showNotice(L("clipboard.notice.noImageText")) }
                }, failed: { [weak self] in self?.historyPanelModel.showNotice(L("ask.plugin.clip.unavailable")) })
        }
    }

    private func retryHistoryEntry(_ entry: ClipboardEntry) {
        guard case let .voice(id) = entry.origin, let record = historyStore.record(id: id) else { return }
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()
        retry(record: record)
    }

    private func toggleHistoryEntryPin(_ entry: ClipboardEntry) {
        guard entry.snippet == nil else { return }
        switch entry.origin {
        case let .voice(id):
            clipboardHistoryStore?.setVoiceRecordPinned(!entry.isPinned, recordID: id)
        case let .clipboard(id):
            clipboardHistoryStore?.setPinned(!entry.isPinned, id: id)
        }
        reloadHistoryPanel()
    }

    private func deleteHistoryEntry(_ entry: ClipboardEntry) {
        switch entry.origin {
        case let .voice(id):
            clipboardHistoryStore?.setVoiceRecordPinned(false, recordID: id)
            historyStore.delete(id: id)
        case let .clipboard(id):
            clipboardHistoryStore?.delete(id: id)
        }
        reloadHistoryPanel()
    }
}
