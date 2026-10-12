import SwiftUI

/// Place in a table's trailing column. Selected rows and keyboard focus also reveal actions.
public struct TypefluxTableActions<Content: View>: View {
    @Environment(\.typefluxTableHoverState) private var hoverState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var focused: Bool
    private let selected: Bool
    private let rowID: AnyHashable
    private let content: Content

    public init<ID: Hashable>(rowID: ID, selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.rowID = AnyHashable(rowID)
        self.selected = selected
        self.content = content()
    }

    public var body: some View {
        TypefluxTableCell(rowID: rowID) {
            content.opacity(visible ? 1 : 0).allowsHitTesting(visible)
        }.focusable().focused($focused)
    }

    private var visible: Bool {
        TypefluxTableActionVisibility.isVisible(hovered: hoverState.wrappedValue.isHovered(rowID),
                                               selected: selected, focused: focused, voiceOver: voiceOver)
    }
}
