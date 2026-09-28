import AppKit
import Combine

@MainActor
protocol AskVoiceRecording: AnyObject {
    func start() async throws
    func transcribe() async throws -> String
    func cancel() async
}

/// Owns one editor and its insertion range for the entire recording transaction.
/// Cancellation keeps the recorder reserved until asynchronous cleanup completes.
@MainActor
final class AskVoiceInput: ObservableObject {
    enum Phase { case idle, listening, transcribing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var context: String?
    @Published var focusedContext: String?
    @Published var error: String?
    var recorder: (any AskVoiceRecording)?
    private weak var editor: AskComposerTextView.Editor?
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var released = false
    private var cancelled = false
    private var hotkeyLocked = false
    private var beganAt = Date()
    private var interruptionObservers: [NSObjectProtocol] = []
    var isOccupied: Bool { task != nil }
    var isActive: Bool { phase != .idle }

    @discardableResult
    func begin(in editor: AskComposerTextView.Editor, locked: Bool = false) -> Bool {
        guard !isOccupied, let recorder, editor.isEditable, !editor.hasMarkedText(),
              editor.window?.firstResponder === editor else { return false }
        self.editor = editor
        context = editor.contextID
        let context = editor.contextID, original = editor.string, range = editor.selectedRange()
        released = false; cancelled = false; hotkeyLocked = locked; beganAt = Date()
        error = nil; phase = .listening
        interruptionObservers = [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
        task = Task { [weak self, weak editor] in
            guard let self else { return }
            defer {
                timeout?.cancel(); timeout = nil; release = nil
                interruptionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
                interruptionObservers = []
                phase = .idle; self.context = nil; self.editor = nil; task = nil
            }
            do {
                try Task.checkCancellation()
                try await recorder.start()
                try Task.checkCancellation()
                if !released {
                    await withCheckedContinuation { self.release = $0 }
                }
                try Task.checkCancellation()
                phase = .transcribing
                let text = try await recorder.transcribe()
                try Task.checkCancellation()
                guard !cancelled, let editor, editor.contextID == context,
                      editor.string == original, editor.window?.firstResponder === editor,
                      editor.window?.isKeyWindow == true else { return }
                if !text.isEmpty, editor.shouldChangeText(in: range, replacementString: text) {
                    editor.replaceCharacters(in: range, with: text)
                    editor.setSelectedRange(NSRange(location: range.location + text.utf16.count, length: 0))
                    editor.didChangeText()
                }
            } catch is CancellationError {
                await recorder.cancel()
            } catch {
                await recorder.cancel()
                if !cancelled { self.error = error.localizedDescription }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        return true
    }

    func stop() {
        guard phase == .listening else { return }
        released = true; phase = .transcribing
        release?.resume(); release = nil
    }

    /// Keep Fn's short-tap-to-lock behavior; mouse releases always call stop().
    func releaseHotkey() {
        guard !hotkeyLocked else { return }
        if Date().timeIntervalSince(beganAt) < WorkflowController.tapToLockThreshold { hotkeyLocked = true }
        else { stop() }
    }

    func cancel() {
        guard isOccupied else { return }
        cancelled = true; released = true
        task?.cancel(); timeout?.cancel()
        release?.resume(); release = nil
        phase = .idle
    }

    func cancel(ifOwnedBy editor: AskComposerTextView.Editor) {
        if self.editor === editor { cancel() }
    }
}
