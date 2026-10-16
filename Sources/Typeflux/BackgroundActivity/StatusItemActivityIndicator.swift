import AppKit
import QuartzCore

/// Colors the ∞ in the menu bar icon while background work runs: blue breathing
/// while work runs, orange blinking slowly when a task needs the user.
///
/// The icon stays a template image, so the menu bar still tints and highlights it.
/// On top of it sits a colored copy of only the ∞ cut-out, drawn from the same
/// symbols, so the color fills the cut-out exactly and the icon keeps its width.
@MainActor
final class StatusItemActivityIndicator {
    static let animationKey = "typeflux.activity.breathe"

    /// The ∞ cut-out in a color, shown over the template icon.
    private final class MarkView: NSImageView {
        /// Clicks belong to the status bar button underneath.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    private(set) var state: BackgroundActivityIndicator = .none
    let mark: NSImageView
    private var markKey: String?

    init() {
        mark = MarkView()
        mark.imageScaling = .scaleProportionallyDown
        mark.imageAlignment = .alignCenter
        mark.isEditable = false
        mark.wantsLayer = true
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.isHidden = true
        mark.setAccessibilityElement(false)
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

    /// How the ∞ fades for `state`: running breathes deeply, attention blinks gently.
    static func animation(for state: BackgroundActivityIndicator) -> CABasicAnimation? {
        let (lowest, duration): (CGFloat, CFTimeInterval) = switch state {
        case .none: (1, 0)
        case .running: (0.15, 1.0)
        case .attention: (0.45, 0.8)
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

    /// The ∞ cut-out of `symbol` filled with `color`, transparent everywhere else.
    ///
    /// The filled disc of the same configuration, inset slightly so its soft edge stays
    /// under the icon's ring, minus the icon itself leaves exactly the cut-out.
    static func markImage(symbol: String, configuration: NSImage.SymbolConfiguration, size: NSSize,
                          color: NSColor) -> NSImage? {
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
            let disc = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        icon.size = size
        disc.size = size
        let image = NSImage(size: size, flipped: false) { rect in
            disc.draw(in: rect.insetBy(dx: 1.5, dy: 1.5))
            icon.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
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
        if mark.superview !== button {
            mark.removeFromSuperview()
            button.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                mark.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                mark.topAnchor.constraint(equalTo: button.topAnchor),
                mark.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
        guard let color = Self.color(for: state) else {
            mark.isHidden = true
            mark.layer?.removeAnimation(forKey: Self.animationKey)
            return
        }
        let key = "\(symbol)|\(state)|\(size.width)x\(size.height)"
        if key != markKey {
            mark.image = Self.markImage(symbol: symbol, configuration: configuration, size: size, color: color)
            markKey = key
        }
        mark.isHidden = false
        if reduceMotion {
            mark.layer?.removeAnimation(forKey: Self.animationKey)
        } else if changed || !isAnimating, let animation = Self.animation(for: state) {
            mark.layer?.add(animation, forKey: Self.animationKey)
        }
    }
}
