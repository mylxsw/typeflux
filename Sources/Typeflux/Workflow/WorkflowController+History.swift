import Foundation

/// The clipboard panel opened by the history hotkey: voice results plus clipboard history.
extension WorkflowController {
    static let historyPanelVoiceLimit = 200
    /// Lets keyboard focus return to the target app after the key panel closes, before pasting.
    static let historyPanelFocusReturnDelay: Duration = .milliseconds(150)

    func configureHistoryPanel() {
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            historyPanelPrivacyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.retireHistoryPanelSnapshot() })
        }
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
        if !FeatureProcess.owns(.clipboard) {
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

    private static func historyPanelEntries(history: any HistoryStore, clipboard: (any ClipboardHistoryStore)?,
                                            latency: ShortcutLatencyTrace? = nil) -> [ClipboardEntry] {
        ShortcutLatency.record(.historyReadStarted, trace: latency)
        let records = StatusBarMenuSupport.recentTranscriptionRecords(
            from: history.list(limit: Self.historyPanelVoiceLimit * 3, offset: 0, searchQuery: nil),
            limit: Self.historyPanelVoiceLimit
        )
        ShortcutLatency.record(.historyReadFinished, trace: latency)
        let items = ShortcutLatency
            .measure(.clipboardReadStarted, .clipboardReadFinished, trace: latency) {
                clipboard?.items(limit: Int(Int32.max)) ?? []
            }
        let pins = ShortcutLatency
            .measure(.pinsReadStarted, .pinsReadFinished, trace: latency) { clipboard?.pinnedVoiceRecordIDs() ?? [] }
        return ShortcutLatency.measure(.mergeStarted, .mergeFinished, trace: latency) { ClipboardFeed.entries(
            // Trimming bounds the store; pinned items come on top of the unpinned limit.
            clipboardItems: items,
            voiceRecords: records,
            pinnedVoiceRecordIDs: pins
        ) }
    }

    func retireHistoryPanelSnapshot() {
        dismissHistoryPicker()
        historyPanelWarmupTask?.cancel()
        historyPanelWarmupTask = nil
        historyPanelSnapshot = nil
        historyPanelCacheRevision = UUID()
    }

    private var historyPanelCachePolicy: String {
        "\(settingsStore.clipboardRetention.rawValue)/\(settingsStore.clipboardMaxItems)/" +
            "\(settingsStore.clipboardStorageLimit.rawValue)/\(settingsStore.historyRetentionPolicy.rawValue)"
    }

    private func presentHistoryEntries(_ entries: [ClipboardEntry]) {
        ShortcutLatency.record(.modelUpdateStarted)
        historyPanelModel.showsPreview = settingsStore.clipboardShowsPreview
        historyPanelModel.isRecordingPaused = settingsStore.isClipboardRecordingPaused()
        historyPanelModel.singleClickPastes = settingsStore.clipboardSingleClickPastes
        historyPanelModel.reset(entries: entries, selectFirstUnpinned: settingsStore.clipboardSelectsFirstUnpinned)
        ShortcutLatency.record(.modelUpdateFinished)
        isHistoryPickerPresented = true
        clipboardPanelPresenter?.present(historyPanelModel)
    }

    func reloadHistoryPanel() {
        historyPanelSnapshot = nil
        historyPanelCacheRevision = UUID()
        historyPanelWarmupTask?.cancel()
        if isHistoryPickerLoading, historyPanelMaintenanceGeneration == historyPanelLoadGeneration {
            // Maintenance notifications precede the read. Fold them into that
            // read instead of replacing the opening request with another load.
            return
        }
        if isHistoryPickerPresented {
            requestHistoryPanel(opening: false)
        } else if !isHistoryPickerLoading, FeatureProcess.owns(.clipboard) {
            // Coalesce copy/delete/pin bursts while the panel is hidden.
            historyPanelWarmupTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                self?.prewarmHistoryPanelSnapshot()
            }
        }
    }

    func prewarmHistoryPanelSnapshot() {
        guard FeatureProcess.owns(.clipboard), !isHistoryPickerPresented, !isHistoryPickerLoading else { return }
        let generation = UUID(), revision = historyPanelCacheRevision
        historyPanelLoadGeneration = generation
        let policy = historyPanelCachePolicy
        let history = historyStore, clipboard = clipboardHistoryStore
        let storeIdentity = clipboard.map(ObjectIdentifier.init)
        var entries: [ClipboardEntry] = []
        historyPanelWork.submit({
            entries = Self.historyPanelEntries(history: history, clipboard: clipboard)
        }, completion: { [weak self] result in
            guard let self, case .success = result, self.historyPanelLoadGeneration == generation,
                  self.historyPanelCacheRevision == revision, self.historyPanelCachePolicy == policy,
                  !self.isHistoryPickerPresented, !self.isHistoryPickerLoading else { return }
            self.historyPanelSnapshot = ClipboardPanelSnapshot(entries: entries, policy: policy,
                store: storeIdentity, retentionDays: self.settingsStore.clipboardRetention.days,
                voiceRetentionDays: self.settingsStore.historyRetentionPolicy.days)
        })
    }

    private func requestHistoryPanel(opening: Bool) {
        historyPanelWarmupTask?.cancel()
        historyPanelWarmupTask = nil
        let latency = opening ? ShortcutLatency.current : nil
        let latencySink = ShortcutLatency.eventSink
        let policy = historyPanelCachePolicy
        let storeIdentity = clipboardHistoryStore.map(ObjectIdentifier.init)
        var presentedCachedEntries = false
        if opening {
            if let snapshot = historyPanelSnapshot, !snapshot.entries.isEmpty,
               snapshot.isValid(policy: policy, store: storeIdentity) {
                ShortcutLatency.record(.dataCacheHit, trace: latency)
                presentHistoryEntries(snapshot.entries)
                presentedCachedEntries = true
            } else {
                historyPanelSnapshot = nil
                ShortcutLatency.record(.dataCacheMiss, trace: latency)
            }
        }
        ShortcutLatency.record(.dataStarted, trace: latency)
        let generation = UUID()
        historyPanelLoadGeneration = generation
        isHistoryPickerLoading = true
        if opening {
            historyPanelMaintenanceGeneration = generation
            let maintenance = ShortcutLatency
                .measure(.maintenancePlanStarted, .maintenancePlanFinished, trace: latency) {
                    clipboardMaintenance(at: Date())
                }
            // A store posts its change notifications to the main queue before
            // this completion. Take the read revision only after they arrive.
            clipboardMaintenanceWork.submit({
                ShortcutLatency.$eventSink.withValue(latencySink) {
                    ShortcutLatency.measure(.maintenanceStarted, .maintenanceFinished, trace: latency) { maintenance() }
                }
            }, completion: { [weak self] result in
                guard let self, self.historyPanelLoadGeneration == generation else { return }
                self.historyPanelMaintenanceGeneration = nil
                ShortcutLatency.$eventSink.withValue(latencySink) {
                    ShortcutLatency.$current.withValue(latency) {
                        self.readHistoryPanel(opening: opening, presentedCachedEntries: presentedCachedEntries,
                            generation: generation, policy: policy, storeIdentity: storeIdentity,
                            latency: latency, latencySink: latencySink, preparation: result)
                    }
                }
            })
        } else {
            readHistoryPanel(opening: false, presentedCachedEntries: false, generation: generation,
                policy: policy, storeIdentity: storeIdentity, latency: latency, latencySink: latencySink)
        }
    }

    private func readHistoryPanel(opening: Bool, presentedCachedEntries: Bool, generation: UUID,
                                 policy: String, storeIdentity: ObjectIdentifier?, latency: ShortcutLatencyTrace?,
                                 latencySink: (@Sendable (ShortcutLatencyEvent) -> Void)?,
                                 preparation: Result<Void, Error> = .success(())) {
        guard historyPanelCachePolicy == policy, clipboardHistoryStore.map(ObjectIdentifier.init) == storeIdentity else {
            requestHistoryPanel(opening: opening && !isHistoryPickerPresented)
            return
        }
        let revision = historyPanelCacheRevision
        let history = historyStore, clipboard = clipboardHistoryStore
        var entries: [ClipboardEntry] = []
        let complete: (Result<Void, Error>) -> Void = { [weak self] result in
            ShortcutLatency.$eventSink.withValue(latencySink) {
                ShortcutLatency.record(.dataCallback, trace: latency)
                guard let self else { ShortcutLatency.record(.superseded, trace: latency); return }
                ShortcutLatency.$current.withValue(latency) {
                    guard self.historyPanelLoadGeneration == generation
                    else { ShortcutLatency.record(.superseded); return }
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
                        guard self.historyPanelCacheRevision == revision, self.historyPanelCachePolicy == policy else {
                            self.requestHistoryPanel(opening: opening && !self.isHistoryPickerPresented)
                            return
                        }
                        self.historyPanelSnapshot = ClipboardPanelSnapshot(entries: entries, policy: policy,
                            store: storeIdentity, retentionDays: self.settingsStore.clipboardRetention.days,
                            voiceRetentionDays: self.settingsStore.historyRetentionPolicy.days)
                        guard !entries.isEmpty else {
                            ShortcutLatency.record(.blocked)
                            if opening && !self.isHistoryPickerPresented {
                                self.overlayController.showNotice(message: L("overlay.historyPicker.empty"))
                                self.overlayController.dismiss(after: 2)
                            } else {
                                self.dismissHistoryPicker()
                            }
                            return
                        }
                        if opening {
                            guard !self.isRecording, self.processingTask == nil,
                                  !self.isPersonaPickerPresented else { ShortcutLatency.record(.blocked); return }
                            if presentedCachedEntries {
                                ShortcutLatency.measure(.modelUpdateStarted, .modelUpdateFinished) {
                                    self.historyPanelModel.replaceEntries(entries)
                                }
                            } else {
                                self.presentHistoryEntries(entries)
                            }
                        } else if self.isHistoryPickerPresented {
                            ShortcutLatency.measure(.modelUpdateStarted, .modelUpdateFinished) {
                                self.historyPanelModel.replaceEntries(entries)
                            }
                        }
                    }
                }
            }
        }
        if case .failure = preparation { complete(preparation); return }
        historyPanelWork.submit({
            ShortcutLatency.$eventSink.withValue(latencySink) {
                ShortcutLatency.record(.dataWorkerStarted, trace: latency)
                entries = Self.historyPanelEntries(history: history, clipboard: clipboard, latency: latency)
                ShortcutLatency.record(.dataFinished, trace: latency)
            }
        }, completion: complete)
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
        historyPanelMaintenanceGeneration = nil
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
