import AppKit

/// An embedded practice surface using the floating menu's own renderer and pointer handling.
/// Selection is reported to the host; this view never opens a panel or runs system actions.
@MainActor
public final class OpieMenuPreviewView: NSView {
    let radialMenu: RadialMenuView
    private let surface: RadialMenuSurface

    public var onSelect: ((OpieMenuItem) -> Void)? {
        didSet { radialMenu.onSelect = onSelect }
    }

    public var onHover: ((OpieMenuItem) -> Void)? {
        didSet { radialMenu.onHover = onHover }
    }

    public init(items: [OpieMenuItem], centerTitle: String, style: OpieMenuStyle) {
        let frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        radialMenu = RadialMenuView(frame: frame, items: items, centerTitle: centerTitle)
        radialMenu.style = style.isAvailable ? style : .frosted
        radialMenu.tracksPointerOutsideBounds = false
        surface = RadialMenuSurface(frame: frame, menu: radialMenu)
        super.init(frame: frame)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
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
