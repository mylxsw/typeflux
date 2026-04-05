import Foundation

enum WorkflowOverlayPresentationPolicy {
    static func shouldShowProcessingAfterRecording() -> Bool {
        // Once audio capture ends, the overlay should always leave the recording state.
        // Some windows can only return a final dialog instead of allowing write-back, but
        // that should still show a processing state rather than looking stuck on recording.
        true
    }

    static func shouldPresentResultDialog(for snapshot: TextSelectionSnapshot) -> Bool {
        snapshot.hasAskSelectionContext && !snapshot.canReplaceSelection
    }
}
