import AppKit

public final class RoundedVisualEffectView: NSVisualEffectView {
    public var preferredCornerRadius: CGFloat?

    override public func layout() {
        super.layout()
        layer?.cornerRadius = preferredCornerRadius ?? 0
    }
}
