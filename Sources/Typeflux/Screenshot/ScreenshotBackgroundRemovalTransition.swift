import AppKit
import QuartzCore

/// Small, deterministic alpha masks keep the dissolve on the compositor rather than
/// redrawing a full-resolution screenshot on every frame.
enum ScreenshotBackgroundDissolve {
    static let duration: TimeInterval = 0.65
    static let frameCount = 28

    static func mask(width: Int, height: Int, progress: CGFloat) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let progress = min(max(progress, 0), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0 ..< width * height {
            var noise = UInt32(truncatingIfNeeded: index) &+ 0x9e3779b9
            noise = (noise ^ (noise >> 16)) &* 0x85ebca6b
            noise = (noise ^ (noise >> 13)) &* 0xc2b2ae35
            noise ^= noise >> 16
            let threshold = CGFloat(noise & 0xffff) / 65535
            let value = min(max((threshold - progress * 1.2 + 0.2) / 0.2, 0), 1)
            let alpha = UInt8((value * value * (3 - 2 * value) * 255).rounded())
            for channel in 0 ..< 4 { bytes[index * 4 + channel] = alpha }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A temporary preview beneath the annotation canvas. Only the background dissolves;
/// the extracted subject is held above it, and exported pixels never use these layers.
@MainActor
final class ScreenshotBackgroundRemovalTransition: NSView {
    private let originalLayer = CALayer()
    private let subjectLayer = CALayer()
    private let gridLayer = CALayer()
    private let dissolveMask = CALayer()
    private var generation = 0
    private(set) var isTransitioning = false
    private(set) var result: CGImage?
    var onFinish: (() -> Void)?
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(gridLayer)
        layer?.addSublayer(originalLayer)
        layer?.addSublayer(subjectLayer)
        originalLayer.mask = dissolveMask
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: CGImage, original: CGImage, in rect: CGRect) {
        cancel()
        result = image
        frame = rect
        guard window != nil else { return }
        let token = generation
        let reduced = reducesMotion()
        let scale = min(0.5, 320 / max(rect.width, rect.height, 1))
        let width = max(1, Int(ceil(rect.width * scale)))
        let height = max(1, Int(ceil(rect.height * scale)))
        let steps = reduced ? 1 : ScreenshotBackgroundDissolve.frameCount
        let masks = (0 ... steps).compactMap {
            ScreenshotBackgroundDissolve.mask(width: width, height: height, progress: CGFloat($0) / CGFloat(steps))
        }
        guard let first = masks.first, let last = masks.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.frame = bounds
        originalLayer.frame = bounds
        subjectLayer.frame = bounds
        dissolveMask.frame = bounds
        originalLayer.contents = original
        subjectLayer.contents = image
        gridLayer.contents = Self.grid(size: rect.size)
        dissolveMask.contents = reduced ? first : last
        originalLayer.opacity = reduced ? 0 : 1
        isHidden = false
        isTransitioning = true
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.complete()
            }
        }
        if reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.15
            originalLayer.add(fade, forKey: "backgroundFade")
        } else {
            let dissolve = CAKeyframeAnimation(keyPath: "contents")
            dissolve.values = masks
            dissolve.duration = ScreenshotBackgroundDissolve.duration
            dissolve.calculationMode = .discrete
            dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dissolveMask.add(dissolve, forKey: "backgroundDissolve")
        }
        CATransaction.commit()
    }

    /// Reversal starts at the currently displayed mask, even partway through a dissolve.
    func restore() {
        guard result != nil, window != nil else { cancel(); return }
        let visibleMask = dissolveMask.presentation()?.contents ?? dissolveMask.contents
        let visibleOpacity = originalLayer.presentation()?.opacity ?? originalLayer.opacity
        generation += 1
        let token = generation
        dissolveMask.removeAllAnimations()
        originalLayer.removeAllAnimations()
        let opaque = ScreenshotBackgroundDissolve.mask(width: 1, height: 1, progress: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dissolveMask.contents = opaque
        originalLayer.opacity = 1
        isHidden = false
        isTransitioning = true
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.cancel()
                self.onFinish?()
            }
        }
        let mask = CABasicAnimation(keyPath: "contents")
        mask.fromValue = visibleMask
        mask.toValue = opaque
        mask.duration = 0.18
        dissolveMask.add(mask, forKey: "restoreBackground")
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = visibleOpacity
        opacity.toValue = 1
        opacity.duration = 0.18
        originalLayer.add(opacity, forKey: "restoreFade")
        CATransaction.commit()
    }

    func cancel() {
        generation += 1
        isTransitioning = false
        result = nil
        isHidden = true
        dissolveMask.removeAllAnimations()
        originalLayer.removeAllAnimations()
        originalLayer.contents = nil
        subjectLayer.contents = nil
        gridLayer.contents = nil
    }

    private func complete() {
        isTransitioning = false
        isHidden = true
        onFinish?()
    }

    private static func grid(size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: max(1, Int(ceil(size.width))),
                                      height: max(1, Int(ceil(size.height))), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ScreenshotAnnotationCanvasView.drawTransparencyGrid(in: CGRect(origin: .zero, size: size), context: context)
        return context.makeImage()
    }
}
