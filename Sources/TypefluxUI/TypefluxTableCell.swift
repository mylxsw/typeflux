import SwiftUI

/// Wrap each column's content so hovering anywhere in a row reveals its actions.
public struct TypefluxTableCell<ID: Hashable, Content: View>: View {
    @Environment(\.typefluxTableHoverState) private var hoverState
    @State private var cellID = UUID()
    private let rowID: ID
    private let content: Content

    public init(rowID: ID, @ViewBuilder content: () -> Content) { self.rowID = rowID; self.content = content() }

    public var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                hoverState.wrappedValue.update(cell: cellID, row: AnyHashable(rowID), hovering: hovering)
            }
            .onDisappear { hoverState.wrappedValue.update(cell: cellID, row: AnyHashable(rowID), hovering: false) }
            .onChange(of: rowID) { hoverState.wrappedValue.updateRow(cell: cellID, row: AnyHashable($0)) }
    }
}
