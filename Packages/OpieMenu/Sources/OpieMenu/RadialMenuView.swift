import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class RadialMenuView: NSView {
    var onSelect: ((OpieMenuItem) -> Void)?
    var onHover: ((OpieMenuItem) -> Void)?
    var onClose: (() -> Void)?
    /// When set, a click in the middle calls this instead of closing the ring.
    var onCenterClick: (() -> Void)? { didSet { needsDisplay = true } }
    var freezesPointerForPreview = false
    var onShapeChanged: (() -> Void)?
    var items: [OpieMenuItem]
    var centerTitle: String
    var centerContent = OpieMenuCenter.plain
    var style: OpieMenuStyle = .classic {
        didSet {
            guard style != oldValue else { return }
            cachedRing = nil
            cachedCenter = nil
            needsDisplay = true
            onShapeChanged?()
        }
    }
    private var hovered: Int? { didSet { if hovered != oldValue { startTicker() } } }
    private var keyboardSelection: Int?
    private var mousePressActive = false
    private var tracking: NSTrackingArea?
    private var cachedRing: NSImage?
    private var cachedCenter: NSImage?
    private struct SpritePair {
        let normal: NSImage
        let hot: NSImage
        let size: NSSize
    }
    private var iconSprites: [SpritePair?]
    private var labelSprites: [SpritePair?]
    private var hoverWeights: [CGFloat]
    private var pointerPoint: NSPoint?
    private var lastGlobalMouseLocation: NSPoint?
    private var jellyExtent: CGFloat = 0
    private var jellySpeed: CGFloat = 0
    private var recoilActive = false
    private var jellyAngle: CGFloat = 0
    private var jellyAngularSpeed: CGFloat = 0
    private var jellyTrailStretch: CGFloat = 0
    private struct JellyRipple {
        var age: CGFloat = 0
        let angle: CGFloat
        var strength: CGFloat
    }
    private var ripples: [JellyRipple] = []
    private var previousTargetExtent: CGFloat = 0
    private var wasContracting = false
    private var ticker: Timer?
    private var lastTick = CACurrentMediaTime()
    private enum Motion { case opening, closing, swapping }
    private var centerHot = false
    private var motion: Motion?
    private var motionStart = CACurrentMediaTime()
    private var visualScale: CGFloat = 1
    private var visualRotation: CGFloat = 0
    private var visualOpacity: CGFloat = 1
    // Fade the complete surface so native glass and painted content disappear together.
    private(set) var surfaceOpacity: CGFloat = 1
    private var symbolScale: CGFloat = 1
    private var symbolRotation: CGFloat = 0
    private var symbolOpacity: CGFloat = 1
    private var iconOffset: CGFloat = 0
    private var labelOffset: CGFloat = 0
    private var labelOpacity: CGFloat = 1
    private var holeExpansion: CGFloat = 0
    private var centerOpacity: CGFloat = 1
    private typealias Presentation = (ringScale: CGFloat, ringRotation: CGFloat, opacity: CGFloat,
                                      symbolScale: CGFloat, symbolRotation: CGFloat, symbolOpacity: CGFloat,
                                      iconOffset: CGFloat, labelOffset: CGFloat, labelOpacity: CGFloat,
                                      holeExpansion: CGFloat, centerOpacity: CGFloat)
    private var closingOrigin: Presentation?
    private var closeCompletion: (() -> Void)?
    private var isClosing = false
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private let outerRadius: CGFloat = 128
    private let menuMagnification: CGFloat = 1.08
    private let ringTileSide: CGFloat = 360
    private let innerRadius: CGFloat = 54
    private let centerRadius: CGFloat = 48
    private let maxJellyExtent: CGFloat = 54
    private let warm = NSColor(calibratedRed: 1, green: 0.77, blue: 0.34, alpha: 1)

    init(frame frameRect: NSRect, items: [OpieMenuItem], centerTitle: String) {
        self.items = items
        self.centerTitle = centerTitle
        iconSprites = Array(repeating: nil, count: items.count)
        labelSprites = Array(repeating: nil, count: items.count)
        hoverWeights = Array(repeating: 0, count: items.count)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cachedRing = nil; cachedCenter = nil }
        super.setFrameSize(newSize)
    }

    func update(items: [OpieMenuItem], centerTitle: String, center: OpieMenuCenter? = nil) {
        self.items = items
        self.centerTitle = centerTitle
        if let center { centerContent = center }
        hovered = nil
        keyboardSelection = nil
        iconSprites = Array(repeating: nil, count: items.count)
        labelSprites = Array(repeating: nil, count: items.count)
        hoverWeights = Array(repeating: 0, count: items.count)
        cachedRing = nil
        cachedCenter = nil
        needsDisplay = true
    }

    func prepareGraphics() {
        if cachedRing == nil { cachedRing = makeRingImage() }
        if cachedCenter == nil { cachedCenter = makeCenterImage() }
        for item in items.indices {
            _ = iconSprite(for: item)
            _ = labelSprite(for: item)
        }
    }

    func prepareForOpening() {
        surfaceOpacity = 1
        centerHot = false
        hovered = nil
        keyboardSelection = nil
        mousePressActive = false
        hoverWeights = Array(repeating: 0, count: items.count)
        pointerPoint = nil
        lastGlobalMouseLocation = NSEvent.mouseLocation
        jellyExtent = 0
        jellySpeed = 0
        recoilActive = false
        jellyAngle = 0
        jellyAngularSpeed = 0
        jellyTrailStretch = 0
        ripples.removeAll()
        previousTargetExtent = 0
        wasContracting = false
        labelSprites = Array(repeating: nil, count: items.count)
        prepareGraphics()
        onShapeChanged?()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        // The ring keeps following the pointer after it crosses the panel edge.
        refreshPointerFromScreen()
        startTicker()
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private func updateHover(_ event: NSEvent) {
        if freezesPointerForPreview { return }
        lastGlobalMouseLocation = NSEvent.mouseLocation
        let point = untransformed(convert(event.locationInWindow, from: nil))
        updateHover(at: point)
    }

    func updateHover(at point: NSPoint) {
        pointerPoint = point
        let previous = hovered
        hovered = item(at: point, reach: .infinity)
        if let hovered, hovered != previous { onHover?(items[hovered]) }
        let hot = onCenterClick != nil && isInCenter(point)
        if hot != centerHot { centerHot = hot; needsDisplay = true }
        if hovered != nil { keyboardSelection = nil }
        startTicker()
    }

    private func refreshPointerFromScreen() {
        if freezesPointerForPreview { return }
        guard !isClosing, let window, window.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        if let lastGlobalMouseLocation, distance(screenPoint, lastGlobalMouseLocation) < 0.5 { return }
        lastGlobalMouseLocation = screenPoint
        let point = untransformed(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        updateHover(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        beginPointerPress(at: untransformed(convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        movePointerDuringPress(to: untransformed(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        releasePointerPress(at: untransformed(convert(event.locationInWindow, from: nil)))
    }

    func beginPointerPress(at point: NSPoint) {
        guard !isClosing else { return }
        mousePressActive = true
        updateHover(at: point)
    }

    func movePointerDuringPress(to point: NSPoint) {
        if mousePressActive { updateHover(at: point) }
    }

    func releasePointerPress(at point: NSPoint) {
        guard mousePressActive, !isClosing else { return }
        mousePressActive = false
        updateHover(at: point)
        if let onCenterClick, isInCenter(point) { onCenterClick(); return }
        if !activateItem(at: point) { onClose?() }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    @discardableResult
    func activatePointerSelection() -> Bool {
        guard !isClosing else { return false }
        if let window {
            let point = untransformed(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
            return activateItem(at: point)
        }
        return pointerPoint.map { activateItem(at: $0) } ?? false
    }

    private func activateItem(at point: NSPoint) -> Bool {
        guard let item = item(at: point, reach: .infinity) else { return false }
        releaseJelly()
        onSelect?(items[item])
        return true
    }

    private func releaseJelly() {
        if jellyExtent > 10 { startRipple() }
        recoilActive = jellyExtent >= maxJellyExtent * 0.75
        pointerPoint = nil
        hovered = nil
        previousTargetExtent = 0
        wasContracting = true
        startTicker()
    }

    private func startRipple() {
        ripples.append(JellyRipple(angle: jellyAngle,
                                   strength: min(14, max(7, jellyExtent * 0.30))))
        if ripples.count > 3 { ripples.removeFirst() }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        pointerPoint = nil
        let old = keyboardSelection ?? hovered ?? 0
        keyboardSelection = (old + delta + items.count) % items.count
        hovered = keyboardSelection
    }
    func select(index: Int) {
        pointerPoint = nil
        keyboardSelection = items.indices.contains(index) ? index : nil
        hovered = keyboardSelection
        // Offscreen reference renders should show the settled hover state.
        if window == nil, let keyboardSelection {
            hoverWeights = items.indices.map { $0 == keyboardSelection ? 1 : 0 }
        }
    }
    func activateSelection() {
        guard !items.isEmpty else { return }
        onSelect?(items[keyboardSelection ?? hovered ?? 0])
    }

    func isInCenter(_ point: NSPoint) -> Bool {
        distance(point, center) <= centerRadius
    }

    private func item(at point: NSPoint, reach: CGFloat = 0) -> Int? {
        guard !items.isEmpty else { return nil }
        let r = distance(point, center)
        guard r >= innerRadius, r <= outerRadius + reach else { return nil }
        let theta = atan2(point.y - center.y, point.x - center.x)
        var clockwise = CGFloat.pi / 2 - theta
        if clockwise < 0 { clockwise += 2 * .pi }
        let index = Int((clockwise / (2 * .pi / CGFloat(items.count))).rounded()) % items.count
        return items.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: visualRotation)
        context.scaleBy(x: visualScale * menuMagnification, y: visualScale * menuMagnification)
        context.translateBy(x: -center.x, y: -center.y)
        drawCachedRing()
        for item in items.indices { drawSegment(item) }
        drawCenter()
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: symbolRotation)
        context.scaleBy(x: symbolScale * menuMagnification, y: symbolScale * menuMagnification)
        context.translateBy(x: -center.x, y: -center.y)
        for item in items.indices { drawIconAndLabel(item) }
        context.restoreGState()
    }

    private func drawCachedRing() {
        if abs(jellyExtent) > 0.25 || !ripples.isEmpty {
            drawDynamicRing()
            return
        }
        if cachedRing == nil { cachedRing = makeRingImage() }
        guard let cachedRing else { return }
        NSGraphicsContext.saveGraphicsState()
        if holeExpansion > 0.001 {
            let hole = innerRadius + holeExpansion
            let clip = NSBezierPath(rect: bounds)
            clip.windingRule = .evenOdd
            clip.appendOval(in: NSRect(x: center.x - hole, y: center.y - hole,
                                       width: hole * 2, height: hole * 2))
            clip.addClip()
        }
        let tile = NSRect(x: center.x - ringTileSide / 2, y: center.y - ringTileSide / 2,
                          width: ringTileSide, height: ringTileSide)
        cachedRing.draw(in: tile, from: .zero, operation: .sourceOver, fraction: visualOpacity)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func makeRingImage() -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(ringTileSide * scale), pixelsHigh: Int(ringTileSide * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let offscreen = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = offscreen
        offscreen.cgContext.scaleBy(x: scale, y: scale)
        offscreen.cgContext.translateBy(x: -(center.x - ringTileSide / 2),
                                         y: -(center.y - ringTileSide / 2))
        offscreen.cgContext.setShouldAntialias(true)
        let savedHole = holeExpansion
        holeExpansion = 0
        drawRingBase()
        for item in items.indices {
            let path = segmentPath(item)
            NSColor.white.withAlphaComponent(0.065).setStroke()
            path.lineWidth = 0.7
            path.stroke()
        }
        holeExpansion = savedHole
        offscreen.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: ringTileSide, height: ringTileSide))
        image.addRepresentation(rep)
        return image
    }

    private func drawRingBase() {
        // The native material owns the fill; a faint contour keeps the large ring legible.
        if style == .liquidGlass {
            let outline = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                                      width: outerRadius * 2, height: outerRadius * 2))
            drawLiquidEdges(outer: outline, holeRadius: innerRadius + holeExpansion, opacity: 1)
            return
        }
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
        let holeRadius = innerRadius + holeExpansion
        let cutout = NSBezierPath(ovalIn: NSRect(x: center.x - holeRadius, y: center.y - holeRadius,
                                                width: holeRadius * 2, height: holeRadius * 2))
        let ring = NSBezierPath()
        ring.windingRule = .evenOdd
        ring.append(circle)
        ring.append(cutout)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 23
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(calibratedWhite: style == .frosted ? 0.12 : 0.13,
                alpha: style == .frosted ? 0.22 : 0.98).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()
        if style == .frosted {
            NSGradient(starting: NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.39, alpha: 0.18),
                       ending: NSColor(calibratedRed: 0.025, green: 0.026, blue: 0.035, alpha: 0.25))?
                .draw(in: ring, angle: 112)
            drawGlassEdges(outer: circle, holeRadius: holeRadius, opacity: 1)
        } else {
            NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.085, alpha: 0.98),
                       ending: NSColor(calibratedRed: 0.115, green: 0.115, blue: 0.12, alpha: 0.97))?
                .draw(in: ring, angle: 282)
            NSColor.white.withAlphaComponent(0.13).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
        }
    }

    private func drawGlassEdges(outer: NSBezierPath, holeRadius: CGFloat, opacity: CGFloat) {
        let rimShadow = NSShadow()
        rimShadow.shadowColor = NSColor.white.withAlphaComponent(0.20 * opacity)
        rimShadow.shadowBlurRadius = 5
        NSGraphicsContext.saveGraphicsState()
        rimShadow.set()
        NSColor.white.withAlphaComponent(0.23 * opacity).setStroke()
        outer.lineWidth = 0.9
        outer.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.79, alpha: 0.26 * opacity).setStroke()
        outer.lineWidth = 0.55
        outer.stroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - holeRadius, y: center.y - holeRadius,
                                                width: holeRadius * 2, height: holeRadius * 2))
        NSColor.white.withAlphaComponent(0.15 * opacity).setStroke()
        inner.lineWidth = 1.0
        inner.stroke()
    }

    private func sectorAngle(_ item: Int) -> CGFloat {
        .pi / 2 - CGFloat(item) * 2 * .pi / CGFloat(items.count)
    }

    private func angularDifference(_ angle: CGFloat, _ focus: CGFloat) -> CGFloat {
        var difference = (angle - focus).truncatingRemainder(dividingBy: 2 * .pi)
        if difference > .pi { difference -= 2 * .pi }
        if difference < -.pi { difference += 2 * .pi }
        return difference
    }

    private func deformedRadius(at angle: CGFloat) -> CGFloat {
        let difference = angularDifference(angle, jellyAngle)
        let trailingSide = difference * jellyTrailStretch > 0
        let width = 0.245 + (trailingSide ? abs(jellyTrailStretch) * 0.30 : 0)
        let normalizedDistance = difference / width
        let peak = exp(-0.5 * normalizedDistance * normalizedDistance)
        var radius = outerRadius + jellyExtent * peak
        for ripple in ripples {
            let separation = abs(angularDifference(angle, ripple.angle))
            let wavefront = ripple.age * 3.1
            let ridgeDistance = (separation - wavefront) / 0.16
            let troughDistance = (separation - wavefront + 0.22) / 0.20
            let ridge = exp(-0.5 * ridgeDistance * ridgeDistance)
            let trough = exp(-0.5 * troughDistance * troughDistance)
            radius += ripple.strength * (ridge - 0.58 * trough)
        }
        return radius
    }

    private func outerPoint(at angle: CGFloat) -> NSPoint {
        let radius = deformedRadius(at: angle)
        return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    var glassShape: (path: CGPath, opacity: CGFloat) {
        let path = CGMutablePath()
        path.move(to: outerPoint(at: 0))
        for step in 1...180 {
            path.addLine(to: outerPoint(at: 2 * .pi * CGFloat(step) / 180))
        }
        path.closeSubpath()
        let hole = innerRadius + holeExpansion
        // Reverse the inner contour so SwiftUI's winding fill treats it as a hole.
        path.move(to: CGPoint(x: center.x + hole, y: center.y))
        path.addArc(center: center, radius: hole, startAngle: 0,
                    endAngle: -.pi * 2, clockwise: true)
        path.closeSubpath()
        var transform = glassPresentationTransform
        return (path.copy(using: &transform) ?? path, visualOpacity)
    }

    var centerGlassShape: (path: CGPath, opacity: CGFloat) {
        let diameter = centerRadius * 2
        let circle = CGPath(ellipseIn: CGRect(x: center.x - centerRadius,
                                              y: center.y - centerRadius,
                                              width: diameter, height: diameter), transform: nil)
        var transform = glassPresentationTransform
        return (circle.copy(using: &transform) ?? circle, visualOpacity * centerOpacity)
    }

    private var glassPresentationTransform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: visualRotation)
            .scaledBy(x: visualScale * menuMagnification, y: visualScale * menuMagnification)
            .translatedBy(x: -center.x, y: -center.y)
    }

    private func drawDynamicRing() {
        let outline = NSBezierPath()
        outline.move(to: outerPoint(at: 0))
        for step in 1...180 {
            outline.line(to: outerPoint(at: 2 * .pi * CGFloat(step) / 180))
        }
        outline.close()
        let ring = NSBezierPath()
        ring.windingRule = .evenOdd
        ring.append(outline)
        let hole = innerRadius + holeExpansion
        ring.appendOval(in: NSRect(x: center.x - hole, y: center.y - hole, width: 2 * hole, height: 2 * hole))
        if style != .liquidGlass {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.72 * visualOpacity)
            shadow.shadowBlurRadius = 23
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor(calibratedWhite: style == .frosted ? 0.12 : 0.13,
                    alpha: (style == .frosted ? 0.22 : 0.98) * visualOpacity).setFill()
            ring.fill()
            NSGraphicsContext.restoreGraphicsState()
            if style == .frosted {
                NSGradient(starting: NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.39, alpha: 0.18 * visualOpacity),
                           ending: NSColor(calibratedRed: 0.025, green: 0.026, blue: 0.035, alpha: 0.25 * visualOpacity))?
                    .draw(in: ring, angle: 112)
            } else {
                NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.085, alpha: 0.98 * visualOpacity),
                           ending: NSColor(calibratedRed: 0.115, green: 0.115, blue: 0.12, alpha: 0.97 * visualOpacity))?
                    .draw(in: ring, angle: 282)
            }
        }
        let pullProgress = max(0, min(1, jellyExtent / maxJellyExtent))
        if let context = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor(calibratedRed: 0.63, green: 0.48, blue: 0.72,
                                                      alpha: 0.58 * pullProgress * visualOpacity).cgColor,
                                              NSColor(calibratedRed: 0.73, green: 0.46, blue: 0.59,
                                                      alpha: 0.30 * pullProgress * visualOpacity).cgColor,
                                              NSColor.clear.cgColor] as CFArray,
                                     locations: [0, 0.42, 1]) {
            let focus = CGPoint(x: center.x + (outerRadius + jellyExtent * 0.58) * cos(jellyAngle),
                                y: center.y + (outerRadius + jellyExtent * 0.58) * sin(jellyAngle))
            context.saveGState()
            ring.addClip()
            context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0,
                                       endCenter: focus, endRadius: 115, options: [.drawsAfterEndLocation])
            context.restoreGState()
        }
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            ring.addClip()
            for item in items.indices {
                let weight = hoverWeights[item]
                guard weight > 0.001 else { continue }
                let angle = sectorAngle(item)
                let focus = CGPoint(x: center.x + 108 * cos(angle), y: center.y + 108 * sin(angle))
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                colors: [NSColor(calibratedRed: 0.93, green: 0.57, blue: 0.34,
                                                                 alpha: 0.28 * weight * visualOpacity).cgColor,
                                                         NSColor(calibratedRed: 0.72, green: 0.43, blue: 0.34,
                                                                 alpha: 0.13 * weight * visualOpacity).cgColor,
                                                         NSColor.clear.cgColor] as CFArray,
                                                locations: [0, 0.45, 1]) else { continue }
                context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0,
                                           endCenter: focus, endRadius: 155,
                                           options: [.drawsAfterEndLocation])
            }
            if abs(jellyTrailStretch) > 0.005 {
                let angle = jellyAngle + (jellyTrailStretch > 0 ? 1.05 : -1.05)
                let focus = CGPoint(x: center.x + 112 * cos(angle),
                                    y: center.y + 112 * sin(angle))
                let strength = min(1, abs(jellyTrailStretch) / 0.08) * visualOpacity
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: [NSColor(calibratedRed: 0.70, green: 0.42, blue: 0.40,
                                                              alpha: 0.22 * strength).cgColor,
                                                      NSColor(calibratedRed: 0.60, green: 0.34, blue: 0.35,
                                                              alpha: 0.10 * strength).cgColor,
                                                      NSColor.clear.cgColor] as CFArray,
                                             locations: [0, 0.45, 1]) {
                    context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0,
                                               endCenter: focus, endRadius: 150,
                                               options: [.drawsAfterEndLocation])
                }
            }
            context.restoreGState()
        }
        if style == .frosted {
            drawGlassEdges(outer: outline, holeRadius: hole, opacity: visualOpacity)
        } else if style == .liquidGlass {
            drawLiquidEdges(outer: outline, holeRadius: hole, opacity: visualOpacity)
        } else if style == .classic {
            NSColor.white.withAlphaComponent(0.13 * visualOpacity).setStroke()
            outline.lineWidth = 0.75
            outline.stroke()
        }
        NSColor.white.withAlphaComponent(0.065 * visualOpacity).setStroke()
        for item in items.indices {
            let angle = sectorAngle(item) + .pi / CGFloat(items.count)
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: center.x + hole * cos(angle), y: center.y + hole * sin(angle)))
            separator.line(to: outerPoint(at: angle))
            separator.lineWidth = 0.7
            separator.stroke()
        }
    }

    private func drawLiquidEdges(outer: NSBezierPath, holeRadius: CGFloat, opacity: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset = liquidInsetContour(by: 2.6)
        let topLeft = CGPoint(x: center.x - outerRadius, y: center.y + outerRadius)
        let bottomRight = CGPoint(x: center.x + outerRadius, y: center.y - outerRadius)

        // A glass edge needs thickness: the broad band catches ambient light while
        // the thin outer lip stays sharp. Both follow the live jelly silhouette.
        if let bevel = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor.white.withAlphaComponent(0.29 * opacity).cgColor,
                                           NSColor(calibratedRed: 0.76, green: 0.83, blue: 1,
                                                   alpha: 0.12 * opacity).cgColor,
                                           NSColor.white.withAlphaComponent(0.04 * opacity).cgColor,
                                           NSColor(calibratedWhite: 0.02, alpha: 0.06 * opacity).cgColor] as CFArray,
                                  locations: [0, 0.36, 0.72, 1]) {
            context.saveGState()
            context.addPath(outer.compatibleCGPath)
            context.addPath(inset.compatibleCGPath)
            context.clip(using: .evenOdd)
            context.drawLinearGradient(bevel, start: topLeft, end: bottomRight, options: [])
            context.restoreGState()
        }

        let outerLip = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor.white.withAlphaComponent(0.50 * opacity).cgColor,
                                           NSColor(calibratedRed: 0.75, green: 0.81, blue: 1,
                                                   alpha: 0.17 * opacity).cgColor,
                                           NSColor.white.withAlphaComponent(0.05 * opacity).cgColor] as CFArray,
                                  locations: [0, 0.48, 1])
        if let outerLip {
            context.saveGState()
            context.addPath(outer.compatibleCGPath)
            context.setLineWidth(0.75)
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(outerLip, start: topLeft, end: bottomRight, options: [])
            context.restoreGState()
        }

        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - holeRadius, y: center.y - holeRadius,
                                                width: holeRadius * 2, height: holeRadius * 2))
        if let innerLip = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor.white.withAlphaComponent(0.24 * opacity).cgColor,
                                              NSColor.white.withAlphaComponent(0.07 * opacity).cgColor,
                                              NSColor(calibratedWhite: 0.02, alpha: 0.13 * opacity).cgColor] as CFArray,
                                     locations: [0, 0.54, 1]) {
            context.saveGState()
            context.addPath(inner.compatibleCGPath)
            context.setLineWidth(1.4)
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(innerLip, start: topLeft, end: bottomRight, options: [])
            context.restoreGState()
        }

        guard jellyExtent > 0.25,
              let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [NSColor(calibratedRed: 0.90, green: 0.83, blue: 1,
                                                     alpha: 0.40 * opacity).cgColor,
                                             NSColor(calibratedRed: 0.69, green: 0.58, blue: 0.94,
                                                     alpha: 0.11 * opacity).cgColor,
                                             NSColor.clear.cgColor] as CFArray,
                                    locations: [0, 0.35, 1]) else { return }
        let focus = CGPoint(x: center.x + (outerRadius + jellyExtent) * cos(jellyAngle),
                            y: center.y + (outerRadius + jellyExtent) * sin(jellyAngle))
        context.saveGState()
        context.addPath(outer.compatibleCGPath)
        context.setLineWidth(4)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawRadialGradient(glow, startCenter: focus, startRadius: 0,
                                   endCenter: focus, endRadius: 78, options: [])
        context.restoreGState()

        context.saveGState()
        context.addPath(outer.compatibleCGPath)
        context.setLineWidth(0.9)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawRadialGradient(glow, startCenter: focus, startRadius: 0,
                                   endCenter: focus, endRadius: 92, options: [])
        context.restoreGState()
    }

    private func liquidInsetContour(by inset: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for step in 0...180 {
            let angle = 2 * CGFloat.pi * CGFloat(step) / 180
            let radius = deformedRadius(at: angle) - inset
            let point = NSPoint(x: center.x + radius * cos(angle),
                                y: center.y + radius * sin(angle))
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }

    private func segmentPath(_ item: Int, deformed: Bool = false) -> NSBezierPath {
        let mid = 90.0 - Double(item) * 360.0 / Double(items.count)
        let half = 180.0 / Double(items.count)
        let start = mid + half
        let end = mid - half
        let path = NSBezierPath()
        let rad = CGFloat(start * .pi / 180)
        let holeRadius = innerRadius + holeExpansion
        path.move(to: NSPoint(x: center.x + holeRadius * cos(rad), y: center.y + holeRadius * sin(rad)))
        if !deformed || (abs(jellyExtent) <= 0.25 && ripples.isEmpty) {
            path.line(to: NSPoint(x: center.x + outerRadius * cos(rad), y: center.y + outerRadius * sin(rad)))
            path.appendArc(withCenter: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: true)
        } else {
            path.line(to: outerPoint(at: rad))
            for step in 1...18 {
                let theta = rad - 2 * .pi / CGFloat(items.count) * CGFloat(step) / 18
                path.line(to: outerPoint(at: theta))
            }
        }
        let endRad = CGFloat(end * .pi / 180)
        path.line(to: NSPoint(x: center.x + holeRadius * cos(endRad), y: center.y + holeRadius * sin(endRad)))
        path.appendArc(withCenter: center, radius: holeRadius, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        return path
    }

    private func drawSegment(_ item: Int) {
        if abs(jellyExtent) > 0.25 || !ripples.isEmpty { return }
        let weight = hoverWeights[item]
        guard weight > 0.001 else { return }
        let path = segmentPath(item, deformed: abs(jellyExtent) > 0.25 || !ripples.isEmpty)
        let angle = sectorAngle(item)
        let focus = CGPoint(x: center.x + 108 * cos(angle), y: center.y + 108 * sin(angle))
        if let context = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor(calibratedRed: 0.93, green: 0.57, blue: 0.34, alpha: 0.42 * weight * visualOpacity).cgColor,
                                              NSColor(calibratedRed: 0.72, green: 0.43, blue: 0.34, alpha: 0.20 * weight * visualOpacity).cgColor,
                                              NSColor.clear.cgColor] as CFArray,
                                     locations: [0, 0.45, 1]) {
            context.saveGState()
            path.addClip()
            context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0,
                                       endCenter: focus, endRadius: 112,
                                       options: [.drawsAfterEndLocation])
            context.restoreGState()
        }
        if abs(jellyExtent) <= 0.25 {
            NSColor.white.withAlphaComponent(0.035 * weight * visualOpacity).setStroke()
            path.lineWidth = 0.7
            path.stroke()
        }
    }

    private func drawCenter() {
        guard centerOpacity > 0.001, visualOpacity > 0.001 else { return }
        if cachedCenter == nil { cachedCenter = makeCenterImage() }
        let side: CGFloat = 140
        cachedCenter?.draw(in: NSRect(x: center.x - side / 2, y: center.y - side / 2,
                                      width: side, height: side),
                           from: .zero, operation: .sourceOver,
                           fraction: visualOpacity * centerOpacity)
        guard centerHot, onCenterClick != nil else { return }
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - centerRadius - 1, y: center.y - centerRadius - 1,
                                               width: centerRadius * 2 + 2, height: centerRadius * 2 + 2))
        ring.lineWidth = 2
        NSColor(calibratedRed: 0.35, green: 0.69, blue: 1, alpha: 0.9 * visualOpacity * centerOpacity).setStroke()
        ring.stroke()
    }

    private func makeCenterImage() -> NSImage? {
        let side: CGFloat = 140
        return rasterize(size: NSSize(width: side, height: side)) {
            NSGraphicsContext.current?.cgContext.translateBy(x: side / 2 - center.x,
                                                               y: side / 2 - center.y)
            drawCenterFace()
        }
    }

    private func drawCenterFace() {
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - centerRadius, y: center.y - centerRadius, width: centerRadius * 2, height: centerRadius * 2))
        if style == .liquidGlass {
            // The center disk is native glass behind this transparent text layer.
            // Keep just a fine directional rim so the background stays visible.
            if let context = NSGraphicsContext.current?.cgContext,
               let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                           colors: [NSColor.white.withAlphaComponent(0.42).cgColor,
                                                    NSColor.white.withAlphaComponent(0.14).cgColor,
                                                    NSColor.white.withAlphaComponent(0.04).cgColor] as CFArray,
                                           locations: [0, 0.5, 1]) {
                context.saveGState()
                context.addPath(inner.compatibleCGPath)
                context.setLineWidth(1.2)
                context.replacePathWithStrokedPath()
                context.clip()
                context.drawLinearGradient(highlight,
                                           start: CGPoint(x: center.x - centerRadius, y: center.y + centerRadius),
                                           end: CGPoint(x: center.x + centerRadius, y: center.y - centerRadius),
                                           options: [])
                context.restoreGState()
            }
        } else {
            let outer = NSBezierPath(ovalIn: NSRect(x: center.x - 55, y: center.y - 55, width: 110, height: 110))
            NSColor(calibratedWhite: 0.055, alpha: 0.99).setFill()
            outer.fill()
            NSGradient(starting: NSColor(calibratedWhite: 0.155, alpha: 1),
                       ending: NSColor(calibratedWhite: 0.105, alpha: 1))?.draw(in: inner, angle: 100)
            NSColor.white.withAlphaComponent(0.22).setStroke()
            inner.lineWidth = 1
            inner.stroke()
        }
        if style == .liquidGlass {
            NSGraphicsContext.saveGraphicsState()
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.82)
            textShadow.shadowBlurRadius = 3
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.set()
        }
        drawCenterContent()
        if style == .liquidGlass { NSGraphicsContext.restoreGraphicsState() }
    }

    private func drawCenterContent() {
        let pages = centerContent.showsPages
        if let icon = centerContent.icon {
            // An app page: its icon, its name and the page dots.
            let side: CGFloat = 24
            icon.draw(in: NSRect(x: center.x - side / 2, y: center.y + (pages ? 6 : 1), width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1)
            drawText(fittedTitle(centerTitle, size: 10.5), at: NSPoint(x: center.x, y: center.y - (pages ? 5 : 9)),
                     size: 10.5, weight: .semibold, color: .white, centered: true)
        } else {
            drawText(centerTitle, at: NSPoint(x: center.x, y: center.y + (pages ? 8 : 5)), size: 11, weight: .semibold, color: .white, centered: true)
            drawText("\(items.count) ACTIONS", at: NSPoint(x: center.x, y: center.y - (pages ? 6 : 9)), size: 8, weight: .medium, color: NSColor.white.withAlphaComponent(0.53), centered: true, tracking: 0.9)
        }
        if pages { drawPageDots(at: NSPoint(x: center.x, y: center.y - 19)) }
    }

    /// The current page is a short bar, the others are dots.
    private func drawPageDots(at point: NSPoint) {
        let count = centerContent.pageCount
        let dot: CGFloat = 4, bar: CGFloat = 10, gap: CGFloat = 4
        let width = CGFloat(count - 1) * (dot + gap) + bar
        var x = point.x - width / 2
        for page in 0..<count {
            let current = page == centerContent.pageIndex
            let w = current ? bar : dot
            NSColor.white.withAlphaComponent(current ? 0.95 : 0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: point.y - dot / 2, width: w, height: dot),
                         xRadius: dot / 2, yRadius: dot / 2).fill()
            x += w + gap
        }
    }

    private func fittedTitle(_ text: String, size: CGFloat) -> String {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let limit = centerRadius * 2 - 18
        func width(_ value: String) -> CGFloat { (value as NSString).size(withAttributes: [.font: font]).width }
        guard width(text) > limit else { return text }
        var result = text
        while !result.isEmpty, width(result + "…") > limit { result.removeLast() }
        return result + "…"
    }

    private func drawIconAndLabel(_ item: Int) {
        let angle = sectorAngle(item)
        let iconR: CGFloat = 92 + iconOffset
        let iconPoint = NSPoint(x: center.x + iconR * cos(angle), y: center.y + iconR * sin(angle))
        let weight = hoverWeights[item]
        if let sprite = iconSprite(for: item) {
            draw(sprite, at: iconPoint, weight: weight, opacity: symbolOpacity)
        }
        let labelR: CGFloat = 166 + labelOffset
        let labelPoint = NSPoint(x: center.x + labelR * cos(angle), y: center.y + labelR * sin(angle))
        guard labelOpacity > 0.001 else { return }
        if let sprite = labelSprite(for: item) {
            draw(sprite, at: labelPoint, weight: weight, opacity: symbolOpacity * labelOpacity)
        }
    }

    private func draw(_ sprite: SpritePair, at point: NSPoint, weight: CGFloat, opacity: CGFloat) {
        let rect = NSRect(x: point.x - sprite.size.width / 2, y: point.y - sprite.size.height / 2,
                          width: sprite.size.width, height: sprite.size.height)
        if weight < 0.999 {
            sprite.normal.draw(in: rect, from: .zero, operation: .sourceOver,
                               fraction: opacity * (1 - weight))
        }
        if weight > 0.001 {
            sprite.hot.draw(in: rect, from: .zero, operation: .sourceOver,
                            fraction: opacity * weight)
        }
    }

    private func iconSprite(for item: Int) -> SpritePair? {
        if let sprite = iconSprites[item] { return sprite }
        let size = NSSize(width: 26, height: 26)
        func variant(_ color: NSColor) -> NSImage? {
            switch items[item].icon {
            case .smile:
                return rasterize(size: size) { drawSmile(at: NSPoint(x: 13, y: 13), color: color) }
            case .image(let image):
                return rasterize(size: size) { image.draw(in: NSRect(origin: .zero, size: size)) }
            case .systemSymbol(let name):
                guard let configured = NSImage(systemSymbolName: name, accessibilityDescription: items[item].title)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) else { return nil }
                return rasterize(size: size) { configured.draw(in: NSRect(origin: .zero, size: size)) }
            }
        }
        guard let normal = variant(NSColor.white.withAlphaComponent(0.85)),
              let hot = variant(warm) else { return nil }
        let sprite = SpritePair(normal: normal, hot: hot, size: size)
        iconSprites[item] = sprite
        return sprite
    }

    private func labelSprite(for item: Int) -> SpritePair? {
        if let sprite = labelSprites[item] { return sprite }
        let lines = items[item].title.components(separatedBy: "\n")
        let font = NSFont.systemFont(ofSize: 8.2, weight: .semibold)
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let size = NSSize(width: ceil(textWidth) + 10, height: CGFloat(lines.count) * 11 + 6)
        func variant(active: Bool) -> NSImage? {
            rasterize(size: size) {
                let pill = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4)
                NSColor(calibratedWhite: 0.045, alpha: active ? 0.74 : 0.58).setFill()
                pill.fill()
                for (lineIndex, line) in lines.enumerated() {
                    let y = size.height / 2 + CGFloat(lines.count - 1) * 5.4 - CGFloat(lineIndex) * 11
                    drawText(line, at: NSPoint(x: size.width / 2, y: y), size: 8.2,
                             weight: active ? .semibold : .medium,
                             color: active ? warm : NSColor.white.withAlphaComponent(0.48), centered: true)
                }
            }
        }
        guard let normal = variant(active: false), let hot = variant(active: true) else { return nil }
        let sprite = SpritePair(normal: normal, hot: hot, size: size)
        labelSprites[item] = sprite
        return sprite
    }

    private func rasterize(size: NSSize, drawing: () -> Void) -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let offscreen = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = offscreen
        offscreen.cgContext.scaleBy(x: scale, y: scale)
        drawing()
        offscreen.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func drawSmile(at point: NSPoint, color: NSColor) {
        let face = NSBezierPath(ovalIn: NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
        color.setFill()
        face.fill()
        let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 4.7, y: point.y + 2.1, width: 2.3, height: 2.3)).fill()
        NSBezierPath(ovalIn: NSRect(x: point.x + 2.4, y: point.y + 2.1, width: 2.3, height: 2.3)).fill()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: point.x - 5, y: point.y - 2))
        mouth.curve(to: NSPoint(x: point.x + 5, y: point.y - 2),
                    controlPoint1: NSPoint(x: point.x - 3, y: point.y - 7.5),
                    controlPoint2: NSPoint(x: point.x + 3, y: point.y - 7.5))
        mouth.lineWidth = 1.5
        mouth.lineCapStyle = .round
        ink.setStroke()
        mouth.stroke()
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, centered: Bool, tracking: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: tracking
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        let x = centered ? point.x - measured.width / 2 : point.x
        (text as NSString).draw(at: NSPoint(x: x, y: point.y - measured.height / 2), withAttributes: attributes)
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Stops hidden-window work and discards callbacks before the surface is reused.
    func stopMotion() {
        ticker?.invalidate()
        ticker = nil
        motion = nil
        closeCompletion = nil
        closingOrigin = nil
        isClosing = false
    }

    func animateIn() {
        closeCompletion = nil
        isClosing = false
        closingOrigin = nil
        motion = .opening
        motionStart = CACurrentMediaTime()
        applyOpening(0)
        needsDisplay = true
        startTicker()
    }

    func animateOut(completion: @escaping () -> Void) {
        guard !isClosing else { return }
        if pointerPoint != nil { releaseJelly() }
        isClosing = true
        closeCompletion = completion
        closingOrigin = (visualScale, visualRotation, visualOpacity,
                         symbolScale, symbolRotation, symbolOpacity,
                         iconOffset, labelOffset, labelOpacity,
                         holeExpansion, centerOpacity)
        motion = .closing
        motionStart = CACurrentMediaTime()
        startTicker()
    }

    /// Brings in a new set of items without reopening: the icons turn in while the ring stays put.
    func animateSwap() {
        guard !isClosing else { return }
        motion = .swapping
        motionStart = CACurrentMediaTime()
        applySwapping(0)
        if let pointerPoint { updateHover(at: pointerPoint) }
        needsDisplay = true
        startTicker()
    }

    // Makes the motion observable in deterministic offscreen renders.
    func setMotionPreview(phase: String, progress: CGFloat) {
        let t = max(0, min(1, progress))
        if phase == "open" { applyOpening(t) }
        else if phase == "close" { applyClosing(t) }
        else if phase == "swap" { applySwapping(t) }
        needsDisplay = true
        onShapeChanged?()
    }

    func setJellyPreview(item: Int, progress: CGFloat, angleOffset: CGFloat = 0) {
        jellyExtent = maxJellyExtent * max(0, min(1, progress))
        recoilActive = false
        jellyAngle = sectorAngle(item) + angleOffset
        jellyTrailStretch = 0
        ripples.removeAll()
        needsDisplay = true
        onShapeChanged?()
    }

    func setPointerPreview(_ point: NSPoint?) {
        if point == nil && pointerPoint != nil {
            releaseJelly()
            return
        }
        pointerPoint = point
        hovered = point.flatMap { item(at: $0, reach: .infinity) }
    }

    func stepJellyPreview(dt: CGFloat) {
        _ = advanceHover(dt: dt)
        _ = advanceJelly(dt: dt)
        onShapeChanged?()
    }

    var jellySnapshot: (extent: CGFloat, angle: CGFloat, speed: CGFloat, angularSpeed: CGFloat, trail: CGFloat) {
        (jellyExtent, jellyAngle, jellySpeed, jellyAngularSpeed, jellyTrailStretch)
    }

    var activeRippleCount: Int { ripples.count }

    var motionSnapshot: (scale: CGFloat, rotation: CGFloat, opacity: CGFloat,
                         iconOffset: CGFloat, symbolOpacity: CGFloat,
                         holeExpansion: CGFloat, centerOpacity: CGFloat) {
        (visualScale, visualRotation, visualOpacity * surfaceOpacity,
         iconOffset, symbolOpacity * surfaceOpacity, holeExpansion, centerOpacity)
    }

    private func untransformed(_ point: NSPoint) -> NSPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let c = cos(-visualRotation)
        let s = sin(-visualRotation)
        let effectiveScale = visualScale * menuMagnification
        return NSPoint(x: center.x + (dx * c - dy * s) / effectiveScale,
                       y: center.y + (dx * s + dy * c) / effectiveScale)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30.0, now - lastTick))
        lastTick = now
        refreshPointerFromScreen()
        var hoverSettled = advanceHover(dt: dt)
        if !advanceJelly(dt: dt) { hoverSettled = false }
        let shouldRedraw = !hoverSettled || motion != nil
        if let motion {
            let duration = switch motion {
            case .opening: 0.32
            case .closing: 0.50
            case .swapping: 0.28
            }
            let progress = CGFloat(max(0, min(1, (now - motionStart) / duration)))
            switch motion {
            case .opening: applyOpening(progress)
            case .closing: applyClosing(progress)
            case .swapping: applySwapping(progress)
            }
            if progress >= 1 {
                self.motion = nil
                if motion == .closing {
                    let completion = closeCompletion
                    closeCompletion = nil
                    completion?()
                }
            }
        }
        if shouldRedraw { needsDisplay = true }
        if shouldRedraw { onShapeChanged?() }
        if motion == nil && hoverSettled && window?.isVisible != true {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func advanceHover(dt: CGFloat) -> Bool {
        var settled = true
        for item in items.indices {
            let target: CGFloat = item == hovered ? 1 : 0
            let index = item
            let response: CGFloat = target > hoverWeights[index] ? 0.038 : 0.17
            let blend = 1 - exp(-dt / response)
            hoverWeights[index] += (target - hoverWeights[index]) * blend
            if abs(target - hoverWeights[index]) > 0.004 { settled = false }
        }
        return settled
    }

    private func advanceJelly(dt: CGFloat) -> Bool {
        var targetExtent: CGFloat = 0
        var targetAngle = jellyAngle
        if let pointerPoint, item(at: pointerPoint, reach: .infinity) != nil {
            let radius = distance(pointerPoint, center)
            let proximity = min(1, max(0, (radius - 88) / (outerRadius + 62 - 88)))
            targetExtent = maxJellyExtent * smoothstep(proximity)
            let rawAngle = atan2(pointerPoint.y - center.y, pointerPoint.x - center.x)
            if jellyExtent < 0.5 && targetExtent > 0.5 {
                jellyAngle = rawAngle
                jellyAngularSpeed = 0
            }
            targetAngle = jellyAngle + atan2(sin(rawAngle - jellyAngle), cos(rawAngle - jellyAngle))
        }
        let contracting = targetExtent < previousTargetExtent - 0.4 && jellyExtent > 12
        if contracting && !wasContracting { startRipple() }
        wasContracting = contracting
        previousTargetExtent = targetExtent
        advanceSpring(&jellyExtent, velocity: &jellySpeed,
                      target: targetExtent, dt: dt,
                      frequency: recoilActive ? 28 : 20,
                      damping: recoilActive ? 0.55 : 0.66)
        advanceSpring(&jellyAngle, velocity: &jellyAngularSpeed,
                      target: targetAngle, dt: dt, frequency: 17, damping: 0.70)
        let trailTarget = max(-0.15, min(0.15, -jellyAngularSpeed * 0.045))
        let trailResponse: CGFloat = abs(trailTarget) > abs(jellyTrailStretch) ? 0.045 : 0.20
        jellyTrailStretch += (trailTarget - jellyTrailStretch) * (1 - exp(-dt / trailResponse))
        if abs(jellyTrailStretch) < 0.001 && abs(trailTarget) < 0.001 { jellyTrailStretch = 0 }
        let rippleDecay = exp(-3.2 * dt)
        for index in ripples.indices {
            ripples[index].age += dt
            ripples[index].strength *= rippleDecay
        }
        ripples.removeAll { $0.age > 0.72 }
        if recoilActive && jellyExtent < -8 { jellyExtent = -8; jellySpeed = max(0, jellySpeed) }
        if !recoilActive && jellyExtent < 0 { jellyExtent = 0; jellySpeed = 0 }
        if recoilActive && abs(jellyExtent) < 0.15 && abs(jellySpeed) < 0.8 {
            jellyExtent = 0
            jellySpeed = 0
            recoilActive = false
        }
        return abs(jellyExtent - targetExtent) <= 0.15 && abs(jellySpeed) <= 0.8 &&
            abs(jellyAngle - targetAngle) <= 0.003 && abs(jellyAngularSpeed) <= 0.03 &&
            abs(jellyTrailStretch) <= 0.001 && ripples.isEmpty
    }

    private func applyOpening(_ t: CGFloat) {
        surfaceOpacity = 1
        let ringEase = 1 - pow(1 - t, 2)
        let iconTime = min(1, t / 0.80)
        let labelTime = max(0, min(1, (t - 0.10) / 0.85))
        visualScale = 1.50 - 0.50 * ringEase
        visualRotation = 0
        visualOpacity = smoothstep(min(1, t / 0.45))
        symbolScale = 1
        symbolRotation = 0
        symbolOpacity = smoothstep(max(0, min(1, (t - 0.12) / 0.25)))
        iconOffset = 160 * (1 - smoothstep(iconTime))
        labelOffset = 175 * (1 - smoothstep(labelTime))
        labelOpacity = smoothstep(max(0, min(1, (t - 0.14) / 0.46)))
        holeExpansion = 0
        centerOpacity = 1
    }

    private func applyClosing(_ t: CGFloat) {
        let from: Presentation = closingOrigin ?? (1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1)
        let turn = 1 - pow(1 - t, 2)
        surfaceOpacity = 1 - turn
        visualScale = from.ringScale + (1.16 - from.ringScale) * turn
        visualRotation = from.ringRotation + (-1.60 - from.ringRotation) * turn
        visualOpacity = from.opacity
        symbolScale = from.symbolScale + (1.16 - from.symbolScale) * turn
        symbolRotation = from.symbolRotation + (-1.60 - from.symbolRotation) * turn
        symbolOpacity = from.symbolOpacity
        iconOffset = from.iconOffset * (1 - turn)
        labelOffset = from.labelOffset * (1 - turn)
        labelOpacity = from.labelOpacity
        let holeProgress = 1 - pow(1 - min(1, t / 0.60), 2)
        holeExpansion = from.holeExpansion + (13 - from.holeExpansion) * holeProgress
        centerOpacity = from.centerOpacity * (1 - smoothstep(min(1, t / 0.25)))
    }

    private func applySwapping(_ t: CGFloat) {
        let ease = 1 - pow(1 - t, 3)
        surfaceOpacity = 1
        visualScale = 1
        visualRotation = 0
        visualOpacity = 1
        symbolScale = 0.88 + 0.12 * ease
        symbolRotation = 0.42 * (1 - ease)
        symbolOpacity = smoothstep(min(1, t / 0.7))
        iconOffset = 0
        labelOffset = 0
        labelOpacity = smoothstep(min(1, t / 0.8))
        holeExpansion = 0
        centerOpacity = 1
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    private func advanceSpring(_ value: inout CGFloat, velocity: inout CGFloat,
                               target: CGFloat, dt: CGFloat, frequency: CGFloat, damping: CGFloat) {
        let acceleration = frequency * frequency * (target - value) - 2 * damping * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
        if abs(target - value) < 0.015 && abs(velocity) < 0.15 {
            value = target
            velocity = 0
        }
    }
}

@available(macOS 26.0, *)
private struct LiquidRingShape: Shape, @unchecked Sendable {
    let outline: CGPath

    func path(in rect: CGRect) -> SwiftUI.Path { SwiftUI.Path(outline) }
}

@available(macOS 26.0, *)
private struct LiquidMenuMaterial: View {
    let ringOutline: CGPath
    let centerOutline: CGPath
    let ringOpacity: CGFloat
    let centerOpacity: CGFloat
    let size: CGSize

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .glassEffect(.regular, in: LiquidRingShape(outline: ringOutline))
                    .opacity(ringOpacity)
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .glassEffect(.clear, in: LiquidRingShape(outline: centerOutline))
                    .opacity(centerOpacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

@MainActor
final class RadialMenuSurface: NSView {
    let radialMenu: RadialMenuView
    private let frostedGlass: NSView
    private let liquidGlass: NSView?
    private let shapeMask = CAShapeLayer()
    private(set) var glassMaskBounds: CGRect = .null
    var glassIsVisible: Bool {
        switch radialMenu.style {
        case .classic: false
        case .frosted: !frostedGlass.isHidden
        case .liquidGlass: liquidGlass?.isHidden == false
        }
    }
    var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) {
            return frostedGlass is NSGlassEffectView && liquidGlass is NSHostingView<LiquidMenuMaterial>
        }
        return frostedGlass is NSVisualEffectView
    }

    init(frame: NSRect, menu: RadialMenuView) {
        self.radialMenu = menu
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: frame)
            effect.style = .clear
            effect.tintColor = NSColor(calibratedWhite: 0.07, alpha: 0.42)
            effect.cornerRadius = 0
            frostedGlass = effect
            liquidGlass = NSHostingView(rootView: LiquidMenuMaterial(
                ringOutline: CGPath(rect: .zero, transform: nil),
                centerOutline: CGPath(rect: .zero, transform: nil),
                ringOpacity: 0, centerOpacity: 0, size: frame.size))
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = NSAppearance(named: .darkAqua)
            frostedGlass = effect
            liquidGlass = nil
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.allowsGroupOpacity = true
        frostedGlass.wantsLayer = true
        frostedGlass.autoresizingMask = [.width, .height]
        frostedGlass.layer?.mask = shapeMask
        shapeMask.fillRule = .evenOdd
        addSubview(frostedGlass)
        if let liquidGlass {
            liquidGlass.frame = bounds
            liquidGlass.autoresizingMask = [.width, .height]
            addSubview(liquidGlass)
        }
        radialMenu.frame = bounds
        radialMenu.autoresizingMask = [.width, .height]
        addSubview(radialMenu)
        radialMenu.onShapeChanged = { [weak self] in self?.updateGlassShape() }
        updateGlassShape()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateGlassShape() {
        alphaValue = radialMenu.surfaceOpacity
        frostedGlass.isHidden = radialMenu.style != .frosted
        liquidGlass?.isHidden = radialMenu.style != .liquidGlass
        guard radialMenu.style != .classic else { return }
        let shape = radialMenu.glassShape
        glassMaskBounds = shape.path.boundingBox
        if radialMenu.style == .frosted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeMask.frame = bounds
            shapeMask.path = shape.path
            frostedGlass.alphaValue = shape.opacity
            CATransaction.commit()
        } else if #available(macOS 26.0, *),
                  let host = liquidGlass as? NSHostingView<LiquidMenuMaterial> {
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            let outline = shape.path.copy(using: &flip) ?? shape.path
            let center = radialMenu.centerGlassShape
            let centerOutline = center.path.copy(using: &flip) ?? center.path
            host.rootView = LiquidMenuMaterial(ringOutline: outline,
                                               centerOutline: centerOutline,
                                               ringOpacity: shape.opacity,
                                               centerOpacity: center.opacity,
                                               size: bounds.size)
        }
    }
}
