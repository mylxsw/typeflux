import AppKit

/// An embedded practice surface using the floating menu's own renderer and pointer handling.
/// Selection is reported to the host; this view never opens a panel or runs system actions.
@MainActor
public final class OpieMenuPreviewView: NSView {
    let radialMenu: RadialMenuView
    private let surface: RadialMenuSurface
    private let contentScale: CGFloat

    public var onSelect: ((OpieMenuItem) -> Void)? {
        didSet { radialMenu.onSelect = onSelect }
    }

    public var onHover: ((OpieMenuItem) -> Void)? {
        didSet { radialMenu.onHover = onHover }
    }

    public init(items: [OpieMenuItem], centerTitle: String, style: OpieMenuStyle, scale: CGFloat = 1) {
        contentScale = max(0.1, scale)
        let frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        radialMenu = RadialMenuView(frame: frame, items: items, centerTitle: centerTitle)
        radialMenu.style = style.isAvailable ? style : .frosted
        radialMenu.tracksPointerOutsideBounds = false
        surface = RadialMenuSurface(frame: frame, menu: radialMenu)
        super.init(frame: NSRect(x: 0, y: 0, width: frame.width * contentScale,
                                 height: frame.height * contentScale))
        addSubview(surface)
        layoutSurface()
        radialMenu.prepareGraphics()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(items: [OpieMenuItem], centerTitle: String, style: OpieMenuStyle) {
        radialMenu.stopMotion()
        radialMenu.style = style.isAvailable ? style : .frosted
        radialMenu.update(items: items, centerTitle: centerTitle)
        radialMenu.prepareForOpening()
        surface.updateGlassShape()
    }

    override public func layout() {
        super.layout()
        layoutSurface()
    }

    private func layoutSurface() {
        // Scale native view coordinates as well as drawing, so hit testing follows the smaller ring.
        surface.frame = bounds
        surface.bounds = NSRect(x: 0, y: 0, width: bounds.width / contentScale,
                                height: bounds.height / contentScale)
        for child in surface.subviews {
            child.frame = surface.bounds
        }
        surface.updateGlassShape()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { radialMenu.stopMotion() }
    }

    public func stop() {
        radialMenu.stopMotion()
        onSelect = nil
        onHover = nil
    }
}
