import Foundation

/// Clipboard history and panel preferences (Settings → Launcher → Clipboard).
extension SettingsStore {
    /// Whether text, images and files copied in any app are recorded for the clipboard panel.
    var clipboardHistoryEnabled: Bool {
        get { defaults.object(forKey: "clipboard.historyEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboard.historyEnabled") }
    }

    /// Whether the clipboard panel shows its preview pane; `⌘\` in the panel toggles it.
    var clipboardShowsPreview: Bool {
        get { defaults.bool(forKey: "clipboard.showsPreview") }
        set { defaults.set(newValue, forKey: "clipboard.showsPreview") }
    }

    /// Unset until chosen: follows what the voice history retention used to imply.
    var clipboardRetention: ClipboardRetention {
        get {
            guard defaults.object(forKey: "clipboard.retentionDays") != nil else {
                return .migrated(from: historyRetentionPolicy)
            }
            return ClipboardRetention(rawValue: defaults.integer(forKey: "clipboard.retentionDays")) ?? .oneMonth
        }
        set { defaults.set(newValue.rawValue, forKey: "clipboard.retentionDays") }
    }

    /// Unpinned items kept at most; the oldest go first.
    var clipboardMaxItems: Int {
        get {
            let value = defaults.integer(forKey: "clipboard.maxItems")
            return ClipboardItemLimit.options.contains(value) ? value : ClipboardMonitor.maximumItemCount
        }
        set { defaults.set(newValue, forKey: "clipboard.maxItems") }
    }

    var clipboardStorageLimit: ClipboardStorageLimit {
        get {
            guard defaults.object(forKey: "clipboard.storageLimitMB") != nil else { return .gigabyte1 }
            return ClipboardStorageLimit(rawValue: defaults.integer(forKey: "clipboard.storageLimitMB")) ?? .gigabyte1
        }
        set { defaults.set(newValue.rawValue, forKey: "clipboard.storageLimitMB") }
    }

    /// Records only text; copied images and files are skipped.
    var clipboardPlainTextOnly: Bool {
        get { defaults.bool(forKey: "clipboard.plainTextOnly") }
        set { defaults.set(newValue, forKey: "clipboard.plainTextOnly") }
    }

    /// A single click pastes a row instead of selecting it.
    var clipboardSingleClickPastes: Bool {
        get { defaults.bool(forKey: "clipboard.singleClickPastes") }
        set { defaults.set(newValue, forKey: "clipboard.singleClickPastes") }
    }

    /// Opening the panel selects the newest unpinned row rather than the first pinned one.
    var clipboardSelectsFirstUnpinned: Bool {
        get { defaults.object(forKey: "clipboard.selectsFirstUnpinned") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboard.selectsFirstUnpinned") }
    }

    var clipboardPanelPosition: ClipboardPanelPosition {
        get {
            defaults.string(forKey: "clipboard.panelPosition").flatMap(ClipboardPanelPosition.init(rawValue:))
                ?? .launcher
        }
        set { defaults.set(newValue.rawValue, forKey: "clipboard.panelPosition") }
    }

    /// Recording is paused until this moment; `.distantFuture` until resumed by hand.
    var clipboardPausedUntil: Date? {
        get {
            guard defaults.object(forKey: "clipboard.pausedUntil") != nil else { return nil }
            return Date(timeIntervalSince1970: defaults.double(forKey: "clipboard.pausedUntil"))
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: "clipboard.pausedUntil")
            } else {
                defaults.removeObject(forKey: "clipboard.pausedUntil")
            }
            NotificationCenter.default.post(name: .clipboardRecordingPauseDidChange, object: self)
        }
    }

    func isClipboardRecordingPaused(now: Date = Date()) -> Bool {
        guard let until = clipboardPausedUntil else { return false }
        return until > now
    }

    func pauseClipboardRecording(for duration: ClipboardPauseDuration, now: Date = Date()) {
        clipboardPausedUntil = duration.interval.map { now.addingTimeInterval($0) } ?? .distantFuture
    }

    func resumeClipboardRecording() {
        clipboardPausedUntil = nil
    }

    /// What the monitor records right now.
    func clipboardCapturePolicy(now: Date = Date()) -> ClipboardCapturePolicy {
        ClipboardCapturePolicy(
            isRecording: clipboardHistoryEnabled && !isClipboardRecordingPaused(now: now),
            plainTextOnly: clipboardPlainTextOnly,
            maxItemCount: clipboardMaxItems,
            maxImageBytes: clipboardStorageLimit.bytes
        )
    }
}

extension Notification.Name {
    /// Posted when clipboard recording is paused or resumed, so open panels update their state.
    static let clipboardRecordingPauseDidChange = Notification.Name("SettingsStore.clipboardRecordingPauseDidChange")
}
