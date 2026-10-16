import AppKit
import QuartzCore

/// The dot to the right of the menu bar icon while background work runs.
///
/// The icon stays a template image, so the menu bar still tints and highlights it;
/// the dot is a colored view in the extra width the status item gains while it shows.
@MainActor
final class StatusItemActivityIndicator {
    static let extraWidth: CGFloat = 8
    static let diameter: CGFloat = 6
    static let trailingInset: CGFloat = 3
    static let pulseKey = "typeflux.activity.pulse"

    private(set) var state: BackgroundActivityIndicator = .none
    let dot: NSView

    init() {
        dot = NSView(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.diameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        dot.setAccessibilityElement(false)
    }

    var isPulsing: Bool { dot.layer?.animation(forKey: Self.pulseKey) != nil }

    /// The status item's width for `state`, given the menu bar's thickness.
    static func length(for state: BackgroundActivityIndicator, thickness: CGFloat) -> CGFloat {
        state == .none ? NSStatusItem.squareLength : thickness + extraWidth
    }

    /// The icon drawn where a square status item would show it, followed by room for the dot.
    static func paddedIcon(_ icon: NSImage, thickness: CGFloat) -> NSImage {
        let size = NSSize(width: thickness + extraWidth, height: icon.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: (thickness - icon.size.width) / 2, y: 0,
                                 width: icon.size.width, height: icon.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = icon.accessibilityDescription
        return image
    }

    static func color(for state: BackgroundActivityIndicator) -> NSColor? {
        switch state {
        case .none: nil
        case .running: .systemBlue
        case .attention: .systemOrange
        }
    }

    func apply(_ state: BackgroundActivityIndicator, to button: NSStatusBarButton,
               reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.state = state
        if dot.superview !== button {
            dot.removeFromSuperview()
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Self.diameter),
                dot.heightAnchor.constraint(equalToConstant: Self.diameter),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.trailingInset),
                dot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        guard let color = Self.color(for: state) else {
            dot.isHidden = true
            dot.layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        dot.isHidden = false
        dot.layer?.backgroundColor = color.cgColor
        if state == .running, !reduceMotion {
            guard !isPulsing else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            dot.layer?.add(pulse, forKey: Self.pulseKey)
        } else {
            dot.layer?.removeAnimation(forKey: Self.pulseKey)
        }
    }
}
