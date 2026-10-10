import AppKit
import SwiftUI

/// Tokens for the Ask surfaces in the classic interface style: the flat,
/// opaque design macOS used before Liquid Glass. The layout is the glass
/// design's (sidebar, title row, empty state, floating composer); only the
/// material changes. Panels sit flush with the window edges and are divided by
/// hairlines, cards are solid with a hairline border, and only what floats
/// above the window (menus, the ⌘K palette, the drawer) casts a shadow.
///
/// Colours are specified in sRGB, like the design board's.
enum AskClassic {
    /// The conversation column and the title row above it.
    static let canvas = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
    )
    /// The history column: a step off the canvas, lighter in dark like the
    /// system's source lists, a cool grey in light.
    static let sidebar = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1),
        dark: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.149, alpha: 1)
    )
    /// The composer and the empty state's cards, raised off the canvas.
    static let card = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.165, alpha: 1)
    )
    /// A card under the pointer.
    static let cardHover = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.200, green: 0.200, blue: 0.200, alpha: 1)
    )
    /// Edges of cards and fields: one firmer step than the glass hairline,
    /// because nothing else (no rim light, no shadow) separates them.
    static let cardBorder = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.11),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11)
    )
    /// The rules between columns and under the title row.
    static let divider = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
    )
    /// A selected history row: the system's unemphasised source-list selection.
    static let selection = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )
}

/// Geometry that differs between the two interface styles. Everything not
/// listed here is shared, so both styles keep the same layout and hit targets.
struct AskStyleMetrics: Equatable {
    var sidebarRowHeight: CGFloat
    var sidebarRowCorner: CGFloat
    var searchFieldHeight: CGFloat
    var searchFieldCorner: CGFloat
    /// The history filter's track; its thumb is 2pt tighter.
    var filterCorner: CGFloat
    var suggestionCorner: CGFloat
    var composerCorner: CGFloat
    var paletteCorner: CGFloat
    var menuCorner: CGFloat
    var hoverCardCorner: CGFloat
    /// Rows inside a menu, concentric with `menuCorner` at their 6pt inset.
    var menuRowCorner: CGFloat
    /// The private chip in the title row.
    var headerChipHeight: CGFloat

    static let liquidGlass = AskStyleMetrics(
        sidebarRowHeight: 38, sidebarRowCorner: AskMetrics.sidebarRowCorner,
        searchFieldHeight: 34, searchFieldCorner: 12, filterCorner: 9,
        suggestionCorner: 18, composerCorner: 28, paletteCorner: AskMetrics.paletteCorner,
        menuCorner: 18, hoverCardCorner: 14, menuRowCorner: 10,
        headerChipHeight: AskMetrics.headerCapsuleHeight
    )

    static let classic = AskStyleMetrics(
        sidebarRowHeight: 32, sidebarRowCorner: 6,
        searchFieldHeight: 28, searchFieldCorner: 7, filterCorner: 7,
        suggestionCorner: 10, composerCorner: 12, paletteCorner: 12,
        menuCorner: 10, hoverCardCorner: 8, menuRowCorner: 4,
        headerChipHeight: 24
    )
}

extension InterfaceStyle {
    /// The Ask surfaces' geometry in this style.
    var ask: AskStyleMetrics { usesGlass ? .liquidGlass : .classic }

    /// The hover wash behind a borderless icon button of `height`: a capsule on
    /// glass, the toolbar's small rounded square in classic.
    func controlShape(height: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: usesGlass ? height / 2 : 6, style: .continuous)
    }
}

/// A hairline dividing two flush classic surfaces, e.g. the sidebar from the conversation.
struct AskClassicDivider: View {
    var axis: Axis = .vertical

    var body: some View {
        Rectangle().fill(AskClassic.divider)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The chrome of a column at a window edge: the sidebar, the usage panel and
/// the drawers. Liquid Glass floats it as an inset glass panel; classic lays
/// it flush against the edge, solid, with a hairline on its inner side. A
/// classic drawer over the conversation also casts a shadow along that side.
struct AskSidePanelChrome: ViewModifier {
    /// The window edge the column sits against.
    var edge: HorizontalEdge
    var glassFill: Color
    var classicFill: Color = AskClassic.sidebar
    /// Where the glass panel is inset from the window.
    var glassInset: Edge.Set
    /// Over the conversation, as a drawer, rather than beside it.
    var floating = false
    @Environment(\.interfaceStyle) private var style

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.usesGlass {
            content
                .askInWindowGlass(corner: AskMetrics.sidebarPanelCorner, opaqueFill: glassFill)
                .padding(glassInset, AskMetrics.sidebarPanelInset)
        } else {
            content
                .frame(maxHeight: .infinity, alignment: .top)
                .background(classicFill)
                .overlay(alignment: edge == .leading ? .trailing : .leading) { AskClassicDivider() }
                .background {
                    if floating { AskOuterShadow(shape: Rectangle(), elevation: .popover) }
                }
        }
    }
}

extension View {
    func askSidePanel(edge: HorizontalEdge, glassFill: Color, classicFill: Color = AskClassic.sidebar,
                      glassInset: Edge.Set, floating: Bool = false) -> some View {
        modifier(AskSidePanelChrome(edge: edge, glassFill: glassFill, classicFill: classicFill,
                                    glassInset: glassInset, floating: floating))
    }
}
