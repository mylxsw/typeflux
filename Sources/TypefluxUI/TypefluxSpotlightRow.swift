import AppKit
import SwiftUI

/// A result's selection stays solid, even when its surrounding panel uses glass.
public struct TypefluxSpotlightRow: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    private let selected: Bool
    public init(selected: Bool) {
        self.selected = selected
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    TypefluxSpotlightSelectionBackground(radius: TypefluxRadius.sidebarRow.value(for: style))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
    }

    public static func labelColor(selected: Bool, secondary: Bool = false) -> Color {
        if selected { return Color(nsColor: .alternateSelectedControlTextColor) }
        return secondary ? TypefluxColor.secondaryLabel.color : TypefluxColor.label.color
    }
}

/// Keep the system paint dynamic and let AppKit convert it into the drawing
/// destination's color space, including cached hosting-view snapshots.
private struct TypefluxSpotlightSelectionBackground: NSViewRepresentable {
    let radius: CGFloat

    final class SelectionView: NSView {
        var radius: CGFloat

        init(radius: CGFloat) {
            self.radius = radius
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder _: NSCoder) { return nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView(radius: radius)
        updateNSView(view, context: context)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: SelectionView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ view: SelectionView, context: Context) {
        view.radius = radius
        let dark = context.environment.colorScheme == .dark
        let contrast = context.environment.colorSchemeContrast == .increased
        let appearance: NSAppearance.Name = contrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: appearance)
        view.needsDisplay = true
    }
}
