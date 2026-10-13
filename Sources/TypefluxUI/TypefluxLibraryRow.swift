import SwiftUI

/// Compact library list content; List continues to own selection, focus and keyboard navigation.
public struct TypefluxLibraryRow: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let selected: Bool

    public init(selected: Bool) { self.selected = selected }

    public func body(content: Content) -> some View {
        content
            .frame(height: TypefluxControlHeight.sidebarRow.value(for: style))
            .foregroundStyle(TypefluxColor.label.color)
            .contentShape(RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style)))
            .listRowInsets(EdgeInsets(top: 0, leading: TypefluxSpacing.sidebarRowInset.value(for: style),
                                     bottom: 0, trailing: TypefluxSpacing.sidebarRowInset.value(for: style)))
            .listRowBackground(
                RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style))
                    .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                    .overlay {
                        if selected, contrast == .increased || accessibility.increasedContrast {
                            RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style))
                                .strokeBorder(TypefluxColor.label.color)
                        }
                    }
            )
    }
}
