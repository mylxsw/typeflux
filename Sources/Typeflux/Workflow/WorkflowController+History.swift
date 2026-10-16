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
    }

    func handleHistoryPickerRequested() {
        clipboardActionGeneration = UUID()
        if isHistoryPickerPresented {
            dismissHistoryPicker()
            return
        }

        if isPersonaPickerPresented {
            dismissPersonaPicker()
        }

        guard !isRecording, processingTask == nil else { return }

        enforceClipboardRetentionPolicy()
        let entries = historyPanelEntries()
        guard !entries.isEmpty else {
            overlayController.showNotice(message: L("overlay.historyPicker.empty"))
            overlayController.dismiss(after: 2.0)
            return
        }

        historyPanelModel.showsPreview = settingsStore.clipboardShowsPreview
        historyPanelModel.isRecordingPaused = settingsStore.isClipboardRecordingPaused()
        historyPanelModel.singleClickPastes = settingsStore.clipboardSingleClickPastes
        historyPanelModel.reset(entries: entries, selectFirstUnpinned: settingsStore.clipboardSelectsFirstUnpinned)
        isHistoryPickerPresented = true
        clipboardPanelPresenter?.present(historyPanelModel)
    }

    /// The rows currently shown in the panel.
    var historyPickerItems: [ClipboardEntry] {
        historyPanelModel.visibleEntries
    }

    func historyPanelEntries() -> [ClipboardEntry] {
        let records = StatusBarMenuSupport.recentTranscriptionRecords(
            from: historyStore.list(limit: Self.historyPanelVoiceLimit * 3, offset: 0, searchQuery: nil),
            limit: Self.historyPanelVoiceLimit
        )
        return ClipboardFeed.entries(
            // Trimming bounds the store; pinned items come on top of the unpinned limit.
            clipboardItems: clipboardHistoryStore?.items(limit: Int(Int32.max)) ?? [],
            voiceRecords: records,
            pinnedVoiceRecordIDs: clipboardHistoryStore?.pinnedVoiceRecordIDs() ?? []
        )
    }

    func reloadHistoryPanel() {
        guard isHistoryPickerPresented else { return }
        let entries = historyPanelEntries()
        guard !entries.isEmpty else {
            dismissHistoryPicker()
            return
        }
        historyPanelModel.replaceEntries(entries)
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
        Task { @MainActor [weak self] in self?.clipboardAction.cancelPreparation() }
        guard isHistoryPickerPresented else { return }
        isHistoryPickerPresented = false
        clipboardPanelPresenter?.dismiss()
    }

    /// Applies the clipboard's own retention, item limit and image storage limit
    /// (Settings → Launcher → Clipboard).
    func enforceClipboardRetentionPolicy(now: Date = Date()) {
        guard let store = clipboardHistoryStore else { return }
        if let days = settingsStore.clipboardRetention.days {
            store.purge(olderThan: now.addingTimeInterval(-TimeInterval(max(1, days)) * 24 * 3600))
        }
        ClipboardMonitor.applyLimits(of: settingsStore.clipboardCapturePolicy(now: now), to: store)
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
                    return self.clipboardActionGeneration == generation && self.billingAuth() === auth && auth.sessionGeneration == accountGeneration && self.historyPanelEntries().contains(entry)
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
