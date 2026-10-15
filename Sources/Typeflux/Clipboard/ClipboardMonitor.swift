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
    private let workQueue: DispatchQueue
    private let workBudget = ClipboardWorkBudget()
    private let captureWorker: (any ClipboardCaptureWorking)?
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
        interval: TimeInterval = 0.5,
        workQueue: DispatchQueue = DispatchQueue(label: "clipboard.monitor", qos: .utility),
        captureWorker: (any ClipboardCaptureWorking)? = nil
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.isEnabled = isEnabled
        self.policy = policy
        self.sourceProvider = sourceProvider
        self.now = now
        self.suppression = suppression
        self.interval = interval
        self.workQueue = workQueue
        self.captureWorker = captureWorker
    }

    deinit {
        timer?.invalidate()
        workBudget.invalidate()
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
        workBudget.invalidate()
    }

    /// Reads the pasteboard if it changed. Returns whether contents were queued for recording;
    /// decoding and storage happen off the main thread.
    @discardableResult
    func poll() -> Bool {
        let changeCount = pasteboard.changeCount
        let policy = policy()
        guard isEnabled(), policy.isRecording, !suppression.isSuppressed else {
            lastChangeCount = changeCount
            workBudget.invalidate()
            return false
        }
        guard changeCount != lastChangeCount else { return false }
        lastChangeCount = changeCount
        // An ignored app's copy is never read, not just never stored.
        let source = sourceProvider()
        if let bundleID = source?.bundleID, policy.ignoredBundleIDs.contains(bundleID) {
            return false
        }
        // Drop overload before reading another payload. Replaying a skipped
        // change later could capture a private or suppressed replacement copy.
        guard let generation = workBudget.reserve() else { return false }
        if let captureWorker {
            enqueue(captureWorker, changeCount: changeCount, generation: generation, policy: policy, source: source)
            return true
        }
        var queued = false
        defer {
            if !queued {
                workBudget.release()
            }
        }
        let contents = pasteboard.readContents()
        guard ClipboardCaptureRules.isWithinBudget(contents),
              !ClipboardCaptureRules.shouldIgnore(types: contents.types) else { return false }
        let date = now()
        let store = store
        let workBudget = workBudget
        queued = true
        workQueue.async {
            defer { workBudget.release() }
            guard workBudget.accepts(generation),
                  let capture = ClipboardCaptureRules.capture(from: contents, plainTextOnly: policy.plainTextOnly),
                  workBudget.accepts(generation)
            else { return }
            store.record(capture, source: source, at: date)
            Self.applyLimits(of: policy, to: store)
        }
        return true
    }

    private func enqueue(_ worker: any ClipboardCaptureWorking, changeCount: Int, generation: UUID,
                         policy: ClipboardCapturePolicy, source: ClipboardSource?) {
        let date = now(), store = store, budget = workBudget
        workQueue.async {
            defer { budget.release() }
            guard budget.accepts(generation) else { return }
            do {
                guard let capture = try worker.capture(changeCount: changeCount,
                                                       plainTextOnly: policy.plainTextOnly,
                                                       cancelled: { !budget.accepts(generation) }),
                      budget.accepts(generation) else { return }
                store.record(capture, source: source, at: date)
                Self.applyLimits(of: policy, to: store)
            } catch { /* The worker reports a redacted failure; do not replay this copy. */ }
        }
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
