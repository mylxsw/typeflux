import AppKit
import Foundation

/// Records clipboard changes into `ClipboardHistoryStore`.
///
/// macOS has no clipboard-change notification, so the monitor polls `changeCount`, which is
/// a cheap integer read. Payloads are only read after a change.
final class ClipboardMonitor {
    static let maximumItemCount = 500

    private let pasteboard: PasteboardReading
    private let store: ClipboardHistoryStore
    private let isEnabled: () -> Bool
    private let policy: () -> ClipboardCapturePolicy
    private let sourceProvider: () -> ClipboardSource?
    private let now: () -> Date
    private let suppression: ClipboardCaptureSuppression
    private let interval: TimeInterval
    private let workQueue = DispatchQueue(label: "clipboard.monitor", qos: .utility)
    private var timer: Timer?
    private var lastChangeCount: Int?

    init(
        pasteboard: PasteboardReading = SystemPasteboardReader(),
        store: ClipboardHistoryStore,
        isEnabled: @escaping () -> Bool,
        policy: @escaping () -> ClipboardCapturePolicy = { .default },
        sourceProvider: @escaping () -> ClipboardSource? = ClipboardMonitor.frontmostApplicationSource,
        now: @escaping () -> Date = Date.init,
        suppression: ClipboardCaptureSuppression = .shared,
        interval: TimeInterval = 0.5
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.isEnabled = isEnabled
        self.policy = policy
        self.sourceProvider = sourceProvider
        self.now = now
        self.suppression = suppression
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts polling. Whatever is on the clipboard at launch is not recorded.
    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the pasteboard if it changed. Returns whether contents were queued for recording;
    /// decoding and storage happen off the main thread.
    @discardableResult
    func poll() -> Bool {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return false }
        lastChangeCount = changeCount
        let policy = policy()
        guard isEnabled(), policy.isRecording, !suppression.isSuppressed else { return false }
        // An ignored app's copy is never read, not just never stored.
        let source = sourceProvider()
        if let bundleID = source?.bundleID, policy.ignoredBundleIDs.contains(bundleID) { return false }
        let contents = pasteboard.readContents()
        guard !ClipboardCaptureRules.shouldIgnore(types: contents.types) else { return false }
        let date = now()
        let store = store
        workQueue.async {
            guard let capture = ClipboardCaptureRules.capture(from: contents, plainTextOnly: policy.plainTextOnly)
            else { return }
            store.record(capture, source: source, at: date)
            Self.applyLimits(of: policy, to: store)
        }
        return true
    }

    /// Removes the oldest unpinned items beyond the item and image storage limits.
    static func applyLimits(of policy: ClipboardCapturePolicy, to store: ClipboardHistoryStore) {
        store.trim(toMaxCount: policy.maxItemCount)
        if let bytes = policy.maxImageBytes {
            store.trim(toMaxImageBytes: bytes)
        }
    }

    /// Waits for queued writes; used by tests.
    func drain() {
        workQueue.sync {}
    }

    static func frontmostApplicationSource() -> ClipboardSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ClipboardSource(bundleID: app.bundleIdentifier, appName: app.localizedName)
    }
}
