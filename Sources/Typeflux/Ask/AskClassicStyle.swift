import AppKit
import SwiftUI

/// Compatibility colours for Classic surfaces, backed by the shared semantic palette.
enum AskClassic {
    /// Opaque launchers need a quiet outline rather than a bright glass rim.
    static let launcherBorder = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1, alpha: 0.06)
    )

    static let canvas = TypefluxColor.contentBackground.color
    static let sidebar = TypefluxColor.windowBackground.color
    static let card = TypefluxColor.controlBackground.color
    static let cardHover = TypefluxColor.label.color.opacity(0.06)
    static let cardBorder = TypefluxColor.separator.color
    static let divider = TypefluxColor.separator.color
    static let selection = TypefluxColor.selection.color
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

    static let liquidGlass = library(style: .liquidGlass)
    static let classic = library(style: .classic)

    private static func library(style: InterfaceStyle) -> Self {
        Self(sidebarRowHeight: TypefluxControlHeight.sidebarRow.value(for: style),
             sidebarRowCorner: TypefluxRadius.sidebarRow.value(for: style),
             searchFieldHeight: TypefluxControlHeight.textField.value(for: style),
             searchFieldCorner: TypefluxRadius.textField.value(for: style),
             filterCorner: TypefluxRadius.segmented.value(for: style),
             suggestionCorner: TypefluxRadius.form.value(for: style),
             composerCorner: TypefluxRadius.form.value(for: style),
             paletteCorner: TypefluxRadius.spotlightResults.value(for: style),
             menuCorner: TypefluxRadius.menu.value(for: style),
             hoverCardCorner: TypefluxRadius.popover.value(for: style),
             menuRowCorner: TypefluxRadius.menuHighlight.value(for: style),
             headerChipHeight: TypefluxControlHeight.toolbarItem.value(for: style))
    }
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

/// Chrome for auxiliary columns and drawers at a window edge. Liquid Glass floats
/// an inset glass panel; classic lays it flush, solid, with a hairline on its inner side. A
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
            TypefluxGlassContainer(radius: .sidebar, placement: .inWindow) { content }
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
