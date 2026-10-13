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
            .background(selected ? TypefluxColor.selection.color : .clear,
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style)))
            .contentShape(Rectangle())
    }

    public static func labelColor(selected: Bool, secondary: Bool = false) -> Color {
        if selected { return Color(nsColor: .alternateSelectedControlTextColor) }
        return secondary ? TypefluxColor.secondaryLabel.color : TypefluxColor.label.color
    }
}
