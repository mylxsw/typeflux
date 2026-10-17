import AppKit

/// Live desktop framing uses the screenshot's tested move/resize geometry.
@MainActor
final class ScreenRecordingSelectionView: NSView {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat
    let model: ScreenRecordingCoordinator
    var selection: ScreenshotSelection
    var hovered: ScreenRecordingChoice?
    var activate: () -> Void = {}
    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    init(frame: CGRect, displayID: CGDirectDisplayID, scale: CGFloat, model: ScreenRecordingCoordinator) {
        self.displayID = displayID
        displayFrame = frame
        self.scale = scale
        self.model = model
        selection = ScreenshotSelection(displayFrame: frame, scale: scale, windows: [])
        super.init(frame: CGRect(origin: .zero, size: frame.size))
        if case let .region(id, rect) = model.selectedSource?.target, id == displayID {
            let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            _ = selection.mouseDown(at: local.origin)
            _ = selection.mouseDragged(to: CGPoint(x: local.maxX, y: local.maxY))
            _ = selection.mouseUp(at: CGPoint(x: local.maxX, y: local.maxY))
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        ))
    }

    var highlighted: ScreenRecordingChoice? {
        if model.sourceKind == .region {
            if let source = model.selectedSource, case let .region(id, _) = source.target,
               id == displayID {
                return source
            }
            return nil
        }
        if model.sourceKind == .display {
            return model.choices.first { $0.target == .display(displayID) }
        }
        if let selected = model.selectedSource {
            return selected
        }
        return hovered
    }

    override func draw(_: NSRect) {
        let choice = highlighted
        let rect = choice?.frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY).intersection(bounds)
        let mask = NSBezierPath(rect: bounds)
        if let rect, !rect.isNull {
            mask.append(NSBezierPath(
                roundedRect: rect,
                xRadius: model.sourceKind == .window ? 12 : 0,
                yRadius: model.sourceKind == .window ? 12 : 0
            ))
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill(); mask.fill()
        guard let rect, !rect.isNull, rect.width > 0 else { return }
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: model.sourceKind == .window ? 12 : 0,
            yRadius: model.sourceKind == .window ? 12 : 0
        )
        let accent = ScreenshotOverlayChromeView.accent
        if model.sourceKind != .region {
            accent.withAlphaComponent(0.1).setFill(); path.fill()
        }
        accent.setStroke(); path.lineWidth = 1.5; path.stroke()
        if model.sourceKind == .region {
            for handle in ScreenshotSelection.Handle.allCases {
                let point = ScreenshotSelection.point(for: handle, in: rect)
                let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                NSColor.white.setFill(); dot.fill(); accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            drawLabel(
                "\(Int(rect.width)) × \(Int(rect.height)) pt",
                at: CGPoint(x: rect.minX, y: max(4, rect.minY - 25))
            )
        } else {
            drawLabel(
                (choice?.title ?? "") +
                    " · \(Int((choice?.frame.width ?? 0) * (choice?.scale ?? 1))) × \(Int((choice?.frame.height ?? 0) * (choice?.scale ?? 1))) px",
                at: CGPoint(x: rect.midX, y: rect.midY),
                centered: true
            )
        }
        if model.state == .countdown {
            drawCountdown(in: rect)
        }
    }

    private func drawCountdown(in rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - 66, y: center.y - 66, width: 132, height: 132))
        NSColor.black.withAlphaComponent(0.65).setFill(); circle.fill()
        let progress = NSBezierPath()
        let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        progress.appendArc(withCenter: center, radius: 62, startAngle: -90, endAngle: CGFloat(-90 + phase * 360))
        ScreenshotOverlayChromeView.accent.setStroke(); progress.lineWidth = 4; progress.stroke()
        let number = String(model.countdown) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = number.size(withAttributes: attributes)
        number.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
        drawLabel(L("recording.countdownKeys"), at: CGPoint(x: center.x, y: center.y + 86), centered: true)
    }

    private func drawLabel(_ value: String, at point: CGPoint, centered: Bool = false) {
        let text = value as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: centered ? 13 : 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let frame = CGRect(
            x: centered ? point.x - size.width / 2 - 9 : point.x,
            y: point.y,
            width: size.width + 18,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 4), withAttributes: attributes)
    }

    override func mouseMoved(with event: NSEvent) {
        guard model.state == .setup else { return }
        let point = convert(event.locationInWindow, from: nil)
        let global = CGPoint(x: point.x + displayFrame.minX, y: point.y + displayFrame.minY)
        hovered = model.choices.first {
            $0.target.kind == model.sourceKind && $0.frame.contains(global)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard model.state == .setup else { return }
        activate()
        window?.makeKey(); window?.makeFirstResponder(self)
        if model.sourceKind == .region {
            if case let .region(id, _) = model.selectedSource?.target, id != displayID {
                selection.clear()
            }
            _ = selection.mouseDown(at: convert(event.locationInWindow, from: nil))
        } else {
            mouseMoved(with: event)
            if let hovered {
                model.select(hovered)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.state == .setup, model.sourceKind == .region else { return }
        _ = selection.mouseDragged(to: convert(event.locationInWindow, from: nil))
        commitRegion()
    }

    override func mouseUp(with event: NSEvent) {
        guard model.state == .setup, model.sourceKind == .region else { return }
        _ = selection.mouseUp(at: convert(event.locationInWindow, from: nil))
        commitRegion()
    }

    private func commitRegion() {
        guard let rect = selection.rect else { return }
        let global = rect.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
        model.select(ScreenRecordingChoice(
            id: "region",
            title: L("recording.region"),
            target: .region(displayID: displayID, rect: global),
            frame: global,
            scale: scale
        ))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: model.start()
        case 53: if model.state == .countdown {
                model.returnToSelection()
            } else {
                model.cancel()
            }
        case 49: model.skipCountdown()
        case 48:
            let modes: [ScreenRecordingSourceKind] = [.region, .window, .display]
            model.selectSourceKind(modes[((modes.firstIndex(of: model.sourceKind) ?? 0) + 1) % modes.count])
        default: super.keyDown(with: event)
        }
    }
}

final class ScreenRecordingOverlayPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        KeyboardFocusPolicy.focusOnMouseDown(event, in: self)
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

final class ScreenRecordingBorderView: NSView {
    /// Keep the entire stroke (including the thicker corner brackets) outside
    /// the captured pixels, even before window exclusions reach the compositor.
    static func panelFrame(around captureFrame: CGRect) -> CGRect {
        captureFrame.insetBy(dx: -6, dy: -6)
    }

    var paused = false {
        didSet { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        let color = paused ? NSColor.systemOrange : .systemRed
        color.withAlphaComponent(0.75).setStroke()
        let strokeBounds = bounds.insetBy(dx: 2, dy: 2)
        let outline = NSBezierPath(rect: strokeBounds)
        outline.lineWidth = 1.5
        if paused {
            outline.setLineDash([6, 4], count: 2, phase: 0)
        }
        outline.stroke()
        color.setStroke()
        let corners = [(strokeBounds.minX, strokeBounds.minY, CGFloat(1), CGFloat(1)),
                       (strokeBounds.maxX, strokeBounds.minY, -1, 1),
                       (strokeBounds.minX, strokeBounds.maxY, 1, -1),
                       (strokeBounds.maxX, strokeBounds.maxY, -1, -1)]
        for (cornerX, cornerY, directionX, directionY) in corners {
            let bracket = NSBezierPath()
            bracket.move(to: CGPoint(x: cornerX + directionX * 16, y: cornerY))
            bracket.line(to: CGPoint(x: cornerX, y: cornerY))
            bracket.line(to: CGPoint(x: cornerX, y: cornerY + directionY * 16))
            bracket.lineWidth = 3; bracket.stroke()
        }
    }
}
