import AppKit

/// The editor subtree may survive native hiding; retire playback at that boundary.
final class ScreenRecordingPreviewPanel: NSPanel {
    var retire: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        KeyboardFocusPolicy.focusOnMouseDown(event, in: self)
        super.sendEvent(event)
    }
    override func orderOut(_ sender: Any?) { retire?(); super.orderOut(sender) }
    override func close() { retire?(); super.close() }
    override func miniaturize(_ sender: Any?) { retire?(); super.miniaturize(sender) }
}
