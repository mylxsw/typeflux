import AppKit

/// Workflow feedback that survives the launcher, using the voice-input notice UI.
@MainActor
final class AskWorkflowNoticePanel {
    static let shared = AskWorkflowNoticePanel()
    var duration: TimeInterval = 3

    /// Own a presenter so workflow feedback cannot replace an active recording.
    private let overlay: OverlayController

    init(overlay: OverlayController = OverlayController(appState: AppStateStore())) {
        self.overlay = overlay
    }

    func show(_ text: String) {
        overlay.showPassiveNotice(message: text)
        overlay.dismiss(after: duration)
        AskAnnouncer.announce(text)
    }

    var presentedWindow: NSWindow? {
        overlay.presentedWindow
    }

    var isVisible: Bool {
        presentedWindow?.isVisible == true
    }
}
