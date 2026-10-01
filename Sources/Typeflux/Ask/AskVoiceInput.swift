import AppKit
import Combine

enum AskVoiceHotkeyEvent {
    case prepare(auxiliary: Bool, locked: Bool)
    case release(TimeInterval), lock, promote, finish, cancel
}

@MainActor
protocol AskVoiceRecording: AnyObject {
    var audioStartedAt: TimeInterval? { get }
    func handleHotkey(_ event: AskVoiceHotkeyEvent)
    func start() async throws
    func transcribe() async throws -> String
    func cancel() async
}

extension AskVoiceRecording {
    var audioStartedAt: TimeInterval? { nil }
    func handleHotkey(_ event: AskVoiceHotkeyEvent) {}
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
    private var buttonPressedAt: TimeInterval?
    private var beganAt: TimeInterval = 0
    private var startedAt: TimeInterval?
    var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var interruptionObservers: [NSObjectProtocol] = []
    var isOccupied: Bool { task != nil }
    var isActive: Bool { phase != .idle }

    @discardableResult
    func begin(in editor: AskComposerTextView.Editor, locked: Bool = false,
               auxiliary: Bool = false, hotkeyUptime: TimeInterval? = nil) -> Bool {
        guard !isOccupied, let recorder, editor.isEditable, !editor.hasMarkedText(),
              editor.window?.firstResponder === editor else { return false }
        self.editor = editor
        buttonPressedAt = nil
        context = editor.contextID
        let context = editor.contextID, original = editor.string, range = editor.selectedRange()
        released = false; cancelled = false; hotkeyLocked = locked
        beganAt = hotkeyUptime ?? monotonicNow(); startedAt = nil
        recorder.handleHotkey(.prepare(auxiliary: auxiliary, locked: locked))
        error = nil; phase = .listening
        observeInterruptions()
        task = Task { [weak self, weak editor] in
            guard let self else { return }
            defer {
                buttonPressedAt = nil
                timeout?.cancel(); timeout = nil; release = nil
                interruptionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
                interruptionObservers = []
                phase = .idle; self.context = nil; self.editor = nil; task = nil
            }
            do {
                try Task.checkCancellation()
                try await recorder.start()
                startedAt = recorder.audioStartedAt ?? monotonicNow()
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
        scheduleTimeout()
        return true
    }

    private func scheduleTimeout() {
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func observeInterruptions() {
        interruptionObservers = [
            NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification
        ].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    func stop() {
        buttonPressedAt = nil
        guard phase == .listening else { return }
        recorder?.handleHotkey(.finish)
        released = true; phase = .transcribing
        release?.resume(); release = nil
    }

    /// Keep the configured shortcut's short-tap-to-lock behavior.
    func releaseHotkey(at uptime: TimeInterval? = nil) {
        guard phase == .listening else { return }
        let releasedAt = uptime ?? monotonicNow()
        recorder?.handleHotkey(.release(releasedAt))
        guard !hotkeyLocked else { return }
        let audioStart = recorder?.audioStartedAt ?? startedAt
        if releasedAt - beganAt <= WorkflowController.tapToLockThreshold
            || audioStart == nil
            || releasedAt - (audioStart ?? releasedAt) < WorkflowController.minimumRecordingDuration {
            hotkeyLocked = true
            recorder?.handleHotkey(.lock)
        } else { stop() }
    }

    func promoteHotkey(at uptime: TimeInterval, locked: Bool) {
        guard phase == .listening else { return }
        beganAt = uptime; hotkeyLocked = hotkeyLocked || locked
        recorder?.handleHotkey(.promote)
    }

    func cancel() {
        buttonPressedAt = nil
        guard isOccupied else { return }
        cancelled = true; released = true
        recorder?.handleHotkey(.cancel)
        task?.cancel(); timeout?.cancel()
        release?.resume(); release = nil
        phase = .idle
    }

    func cancel(ifOwnedBy editor: AskComposerTextView.Editor) {
        if self.editor === editor { cancel() }
    }

    /// A short button press locks recording; a hold transcribes on release.
    /// The editor's existing hold gesture continues to call stop() directly.
    @discardableResult
    func pressButton(in editor: AskComposerTextView.Editor,
                     at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if phase == .listening, self.editor === editor {
            stop()
            return false
        }
        guard begin(in: editor, locked: true) else { return false }
        buttonPressedAt = timestamp
        return true
    }

    func releaseButton(inside: Bool,
                       at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let pressedAt = buttonPressedAt else { return }
        buttonPressedAt = nil
        if timestamp - pressedAt >= AskComposerTextView.Editor.mouseHoldDelay {
            stop()
        } else if !inside {
            cancel()
        }
    }
}
