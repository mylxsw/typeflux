import AppKit
import AVFoundation

/// The setup bubble snaps to four corners so its layout maps exactly to the encoder.
@MainActor
final class ScreenRecordingCameraBubbleView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    private let statusLayer = CATextLayer()
    private let resizeHandle = CAShapeLayer()
    let model: ScreenRecordingCoordinator
    let pointerLocation: () -> CGPoint
    var targetFrame: CGRect = .zero
    private(set) var isDragging = false
    private var resizing = false
    private var initialFrame: CGRect = .zero
    private var initialPoint: CGPoint = .zero

    init(model: ScreenRecordingCoordinator, pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.model = model
        self.pointerLocation = pointerLocation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        layer?.borderWidth = 2; layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        statusLayer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLayer.fontSize = 10; statusLayer.foregroundColor = NSColor.white.cgColor
        statusLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        statusLayer.cornerRadius = 7; statusLayer.masksToBounds = true
        statusLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(statusLayer)
        resizeHandle.strokeColor = NSColor.white.cgColor; resizeHandle.lineWidth = 3
        resizeHandle.fillColor = nil
        layer?.addSublayer(resizeHandle)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout(); preview.frame = bounds
        updateChrome()
    }

    func updateChrome() {
        statusLayer.string = preview.session?
            .isRunning == true ? "● " + L("recording.liveCamera") : L("recording.starting")
        statusLayer.frame = CGRect(x: 6, y: bounds.maxY - 22, width: 58, height: 16)
        resizeHandle.isHidden = model.state != .setup
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.maxX - 16, y: 5))
        path.addLine(to: CGPoint(x: bounds.maxX - 5, y: 5))
        path.addLine(to: CGPoint(x: bounds.maxX - 5, y: 16))
        resizeHandle.path = path
    }

    override func mouseDown(with event: NSEvent) {
        guard model.state == .setup, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        resizing = point.x >= bounds.maxX - 22 && point.y <= 22
        initialFrame = window.frame; initialPoint = pointerLocation(); isDragging = true
    }

    override func mouseDragged(with _: NSEvent) {
        guard isDragging, let window else { return }
        let point = pointerLocation()
        var frame = initialFrame
        if resizing {
            let fraction = ScreenRecordingLayout.cameraFraction(
                width: initialFrame.width + point.x - initialPoint.x,
                targetWidth: targetFrame.width
            )
            let rect = ScreenRecordingGeometry.cameraRect(
                in: targetFrame.size,
                fraction: fraction,
                corner: model.options.cameraCorner
            )
            frame = CGRect(
                x: initialFrame.minX,
                y: initialFrame.maxY - rect.height,
                width: rect.width,
                height: rect.height
            )
            model.options.cameraFraction = fraction
        } else {
            frame.origin.x += point.x - initialPoint.x; frame.origin.y += point.y - initialPoint.y
            frame.origin.x = min(max(frame.minX, targetFrame.minX), targetFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, targetFrame.minY), targetFrame.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with _: NSEvent) {
        guard isDragging, let window else { return }
        isDragging = false
        if !resizing {
            model.options.cameraCorner = ScreenRecordingLayout.cameraCorner(
                at: CGPoint(x: window.frame.midX - targetFrame.minX, y: targetFrame.maxY - window.frame.midY),
                in: targetFrame.size
            )
        }
    }
}
