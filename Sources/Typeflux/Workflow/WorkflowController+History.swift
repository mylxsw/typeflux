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
        historyPanelModel.onDismiss = { [weak self] in
            self?.dismissHistoryPicker()
        }
        historyPanelModel.onPreviewVisibilityChange = { [weak self] shows in
            self?.settingsStore.clipboardShowsPreview = shows
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
        historyPanelModel.reset(entries: entries)
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
            clipboardItems: clipboardHistoryStore?.items(limit: ClipboardMonitor.maximumItemCount) ?? [],
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
        case .retryTranscription:
            retryHistoryEntry(entry)
        case .togglePin:
            toggleHistoryEntryPin(entry)
        case .delete:
            deleteHistoryEntry(entry)
        }
    }

    func dismissHistoryPicker() {
        guard isHistoryPickerPresented else { return }
        isHistoryPickerPresented = false
        clipboardPanelPresenter?.dismiss()
    }

    /// Clipboard items follow the history retention setting. "Don't keep history" still keeps
    /// one day, because the panel is useless without a short buffer; recording itself has its own switch.
    func enforceClipboardRetentionPolicy(now: Date = Date()) {
        guard let store = clipboardHistoryStore else { return }
        if let days = settingsStore.historyRetentionPolicy.days {
            store.purge(olderThan: now.addingTimeInterval(-TimeInterval(max(1, days)) * 24 * 3600))
        }
        store.trim(toMaxCount: ClipboardMonitor.maximumItemCount)
    }

    // MARK: - Actions

    private func pasteHistoryEntry(_ entry: ClipboardEntry, plainText: Bool) {
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()

        if entry.kind.isTextual, let text = entry.text {
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
            return
        }

        guard clipboardContentActions.writeToPasteboard(entry, asPlainText: plainText) else { return }
        let actions = clipboardContentActions
        Task { [weak self] in
            guard let self else { return }
            await sleep(Self.historyPanelFocusReturnDelay)
            actions.sendPasteShortcut()
        }
    }

    private func copyHistoryEntry(_ entry: ClipboardEntry) {
        if entry.kind.isTextual, let text = entry.text {
            clipboard.write(text: text)
        } else {
            guard clipboardContentActions.writeToPasteboard(entry, asPlainText: false) else { return }
        }
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()
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
        guard let url = entry.contentURLs.first else { return }
        let actions = clipboardContentActions
        Task { @MainActor [weak self] in
            let text = await actions.recognizeText(in: url)
            guard let self else { return }
            if let text {
                clipboard.write(text: text)
                historyPanelModel.showNotice(L("clipboard.notice.imageTextCopied"))
            } else {
                historyPanelModel.showNotice(L("clipboard.notice.noImageText"))
            }
        }
    }

    private func retryHistoryEntry(_ entry: ClipboardEntry) {
        guard case let .voice(id) = entry.origin, let record = historyStore.record(id: id) else { return }
        soundEffectPlayer.playAsync(.tip)
        dismissHistoryPicker()
        retry(record: record)
    }

    private func toggleHistoryEntryPin(_ entry: ClipboardEntry) {
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
