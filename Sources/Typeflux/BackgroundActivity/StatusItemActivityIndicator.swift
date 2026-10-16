import AppKit
import QuartzCore

/// Colors the ∞ in the menu bar icon while background work runs: blue breathing
/// while work runs, orange blinking faster when a task needs the user.
///
/// The icon stays a template image, so the menu bar still tints and highlights it.
/// Over its ∞ cut-out sit two slightly thicker copies of the ∞, drawn from the same
/// symbols so they line up and the icon keeps its width: a template one in the disc's
/// own color, and the colored one that breathes above it. The ∞ therefore breathes
/// between full color and almost the disc's color, which reads on any wallpaper,
/// instead of fading into whatever shows through the cut-out.
@MainActor
final class StatusItemActivityIndicator {
    static let animationKey = "typeflux.activity.breathe"

    /// One copy of the ∞, laid over the template icon.
    private final class MarkView: NSImageView {
        private let vibrant: Bool

        init(vibrant: Bool) {
            self.vibrant = vibrant
            super.init(frame: .zero)
            imageScaling = .scaleProportionallyDown
            imageAlignment = .alignCenter
            isEditable = false
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            isHidden = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// The menu bar's vibrancy would mute the colored ∞; the template base follows the icon.
        override var allowsVibrancy: Bool {
            vibrant
        }

        /// Clicks belong to the status bar button underneath.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    private(set) var state: BackgroundActivityIndicator = .none
    /// The ∞ in the disc's color, under `mark`, so the breathing never reveals the wallpaper.
    let base: NSImageView
    /// The colored ∞ that breathes.
    let mark: NSImageView
    private var markKey: String?
    private var baseKey: String?

    init() {
        base = MarkView(vibrant: true)
        mark = MarkView(vibrant: false)
    }

    var isAnimating: Bool {
        mark.layer?.animation(forKey: Self.animationKey) != nil
    }

    static func color(for state: BackgroundActivityIndicator) -> NSColor? {
        switch state {
        case .none: nil
        case .running: .systemBlue
        case .attention: .systemOrange
        }
    }

    /// How far the ∞ thickens past the cut-out, so the thin line reads at menu bar size
    /// while the holes inside its loops stay open.
    static let markGrowth: CGFloat = 0.25

    /// How the ∞ fades for `state`: running breathes, attention blinks faster. Neither
    /// fades far, so the color stays readable through the whole cycle.
    static func animation(for state: BackgroundActivityIndicator) -> CABasicAnimation? {
        let (lowest, duration): (CGFloat, CFTimeInterval) = switch state {
        case .none: (1, 0)
        case .running: (0.12, 0.8)
        case .attention: (0.2, 0.45)
        }
        guard state != .none else { return nil }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = lowest
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The ∞ cut-out of `symbol` filled with `color` and thickened by `growth` points,
    /// transparent everywhere else.
    ///
    /// The filled disc of the same configuration, inset slightly so its soft edge stays
    /// under the icon's ring, minus the icon itself leaves exactly the cut-out. Drawing
    /// it again shifted in every direction thickens the line evenly.
    static func markImage(symbol: String, configuration: NSImage.SymbolConfiguration, size: NSSize,
                          color: NSColor, growth: CGFloat = markGrowth) -> NSImage? {
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
            let disc = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        icon.size = size
        disc.size = size
        let cutOut = NSImage(size: size, flipped: false) { rect in
            disc.draw(in: rect.insetBy(dx: 1.5, dy: 1.5))
            icon.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        let image = NSImage(size: size, flipped: false) { rect in
            // Keep the thicker ∞ inside the disc's white face.
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).addClip()
            for shiftX in [-growth, 0, growth] {
                for shiftY in [-growth, 0, growth] {
                    cutOut.draw(in: rect.offsetBy(dx: shiftX, dy: shiftY))
                }
            }
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }

    func apply(_ state: BackgroundActivityIndicator, to button: NSStatusBarButton, symbol: String,
               configuration: NSImage.SymbolConfiguration, size: NSSize,
               reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        let changed = state != self.state
        self.state = state
        for view in [base, mark] where view.superview !== button {
            view.removeFromSuperview()
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
        guard let color = Self.color(for: state) else {
            base.isHidden = true
            mark.isHidden = true
            mark.layer?.removeAnimation(forKey: Self.animationKey)
            return
        }
        let shape = "\(symbol)|\(size.width)x\(size.height)"
        if shape != baseKey {
            let image = Self.markImage(symbol: symbol, configuration: configuration, size: size, color: .black)
            image?.isTemplate = true
            base.image = image
            baseKey = shape
        }
        let key = "\(shape)|\(state)"
        if key != markKey {
            mark.image = Self.markImage(symbol: symbol, configuration: configuration, size: size, color: color)
            markKey = key
        }
        base.isHidden = false
        mark.isHidden = false
        if reduceMotion {
            mark.layer?.removeAnimation(forKey: Self.animationKey)
        } else if changed || !isAnimating, let animation = Self.animation(for: state) {
            mark.layer?.add(animation, forKey: Self.animationKey)
        }
    }
}
