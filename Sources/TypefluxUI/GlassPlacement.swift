import AppKit

public enum GlassPlacement: Equatable, CaseIterable, Sendable {
    /// A panel of its own over other apps (the launcher, menus, hover cards):
    /// it blurs the desktop and windows behind it.
    case floating
    /// Chrome floating over the conversation window's own content (the
    /// workspace composer, sidebar, header and palette): it blurs the transcript.
    case inWindow
    /// An inset column at the window edge. In light mode it samples the desktop
    /// directly instead of inheriting the reading canvas's white backplate.
    case windowEdge
    /// The composer's menus and hover cards: a panel over the window, frosted
    /// enough that the rows stay legible over a busy transcript.
    case menu

    public var blending: NSVisualEffectView.BlendingMode {
        self == .inWindow ? .withinWindow : .behindWindow
    }

    /// How much of the surface's own fill frosts the glass. Clear glass over the
    /// transcript let black text show through the composer and made the header
    /// pills vanish on a white window. Menus need a stable light backplate over
    /// busy windows; floating panels keep a stable light surface over both
    /// bright windows and dark desktops. Light 0.92 reaches #F0F1F3 over black
    /// in the native compositor, while preserving the tint over white.
    /// A menu opens over the launcher, so it is never clearer than the card under
    /// it: the card's chips must not show through its rows.
    public func frost(dark: Bool, material: GlassMaterial = .visualEffect) -> Double {
        // Regular Liquid Glass already adapts its luminance and blurs busy
        // content. A light backplate below it preserves the native optics;
        // legacy blur still needs the stronger readability scrim.
        if material == .liquidGlass {
            switch self {
            case .floating: return dark ? 0.14 : 0.06
            case .inWindow, .windowEdge: return dark ? 0.18 : 0.08
            case .menu: return dark ? 0.32 : 0.28
            }
        }
        switch self {
        case .floating: return dark ? 0.78 : 0.92
        case .inWindow, .windowEdge: return 0.45
        case .menu: return dark ? 0.90 : 0.92
        }
    }

    /// Adaptive popover material avoids the HUD's grey cast in light mode.
    public var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .floating: .popover
        case .inWindow: .popover
        case .windowEdge: .sidebar
        case .menu: .menu
        }
    }
}
