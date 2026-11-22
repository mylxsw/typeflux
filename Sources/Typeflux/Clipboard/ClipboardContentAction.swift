import AppKit
import Darwin
import TypefluxMediaProtocol

/// Metadata checks reject replacement; they do not make an external file an immutable transaction.
struct ClipboardImageRevision: Equatable, Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t
    let bytes: off_t
    let modified: Int
    let modifiedNanos: Int
    let changed: Int
    let changedNanos: Int
    init(_ url: URL) throws {
        var value = stat()
        guard url.isFileURL, url.path.utf8.count <= 4096, !url.path.contains("\0"),
              lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size > 0, value.st_size <= ClipboardCaptureRules.maximumImageBytes,
              value.st_flags & UInt32(SF_DATALESS) == 0 else { throw MediaFailure.unreadable }
        path = url.path; device = value.st_dev; inode = value.st_ino; bytes = value.st_size
        modified = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changed = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    func matches(_ url: URL) -> Bool { (try? Self(url)) == self }
}

/// An explicit action outlives its intentional panel dismissal, but never its owner or account.
/// Cancellation keeps admission occupied until even an uncooperative preparation returns.
@MainActor final class ClipboardContentAction {
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var committed = false
    private var disabled = false
    var isRunning: Bool { task != nil }
    nonisolated init() {}
    private func observeAccount() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh, NSApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }
    deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    func preventNewWork() { disabled = true; cancel() }
    func cancelPreparation() { if !committed { cancel() } }
    func cancel() { generation = UUID(); task?.cancel() }
    @discardableResult
    func start(entry: ClipboardEntry, plainText: Bool, paste: Bool, actions: any ClipboardContentActing,
               authorized: @escaping @MainActor () -> Bool,
               beforeCommit: @escaping @MainActor () -> Bool = { true },
               committed: @escaping @MainActor () -> Void = {},
               failed: @escaping @MainActor () -> Void = {},
               delay: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(150)) }) -> Bool {
        let current = generation
        guard !Task.isCancelled, !disabled, task == nil, authorized(), beforeCommit(),
              !Task.isCancelled, generation == current, !disabled, task == nil else { return false }
        observeAccount()
        self.committed = false
        let preparation = actions.imagePreparation(for: entry)
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                guard !Task.isCancelled, self?.generation == current else { return }
                guard preparation.isCurrent() else { throw MediaFailure.unavailable }
                let image = try await preparation.prepare()
                guard !Task.isCancelled, self?.generation == current, authorized(), beforeCommit(),
                      !Task.isCancelled, self?.generation == current else { return }
                guard preparation.isCurrent() else { throw MediaFailure.unavailable }
                let written = actions.writeToPasteboard(entry, asPlainText: plainText, image: image)
                guard !Task.isCancelled, self?.generation == current else { return }
                guard written else { failed(); return }
                self?.committed = true
                let revision = actions.pasteboardRevision
                committed()
                guard paste else { return }
                await delay()
                guard !Task.isCancelled, self?.generation == current, authorized(), actions.pasteboardRevision == revision,
                      image?.sourceRevision == nil || image?.sourceRevision?.matches(URL(fileURLWithPath: entry.imagePath ?? "")) == true else { return }
                actions.sendPasteShortcut()
            } catch {
                if !Task.isCancelled, self?.generation == current, authorized(), beforeCommit(),
                   !Task.isCancelled, self?.generation == current { failed() }
            }
        }
        return true
    }
    /// OCR is read-only until this owner commits once, with the original authority and file revision.
    @discardableResult
    func startText(url: URL, actions: any ClipboardContentActing,
                   authorized: @escaping @MainActor () -> Bool,
                   commit: @escaping @MainActor (String?) -> Void,
                   failed: @escaping @MainActor () -> Void) -> Bool {
        let current = generation
        guard !Task.isCancelled, !disabled, task == nil, authorized(),
              !Task.isCancelled, generation == current, !disabled, task == nil else { return false }
        observeAccount()
        let recognition = actions.textRecognition(in: url)
        guard !Task.isCancelled, generation == current, !disabled, task == nil else { return false }
        let originalRevision = Result {
            let available = recognition.isCurrent()
            guard !Task.isCancelled, generation == current, !disabled, task == nil else { throw CancellationError() }
            guard available else { throw MediaFailure.unavailable }
            return try ClipboardImageRevision(url)
        }
        guard !Task.isCancelled, generation == current, !disabled, task == nil else { return false }
        committed = false
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                guard !Task.isCancelled, self?.generation == current else { return }
                let revision = try originalRevision.get()
                let text = try await recognition.recognize()
                guard !Task.isCancelled, self?.generation == current, authorized(),
                      !Task.isCancelled, self?.generation == current else { return }
                guard revision.matches(url) else { throw MediaFailure.unreadable }
                let result = MediaOCRResult(lines: text?.components(separatedBy: "\n") ?? [])
                try result.validate()
                let available = recognition.isCurrent()
                guard !Task.isCancelled, self?.generation == current else { return }
                guard available else { throw MediaFailure.unavailable }
                self?.committed = true
                commit(result.text)
            } catch {
                if !Task.isCancelled, self?.generation == current, authorized(),
                   !Task.isCancelled, self?.generation == current { failed() }
            }
        }
        return true
    }

}
