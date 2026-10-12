import SwiftUI

/// Use labeled SF Symbols in `content` for accessible icon-only segments.
public struct TypefluxSegmentedControl<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    private let title: String
    private let iconsOnly: Bool
    private let content: Content

    public init(_ title: String, selection: Binding<Selection>, iconsOnly: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.iconsOnly = iconsOnly
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        if iconsOnly { picker.labelStyle(.iconOnly) } else { picker }
    }

    private var picker: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel(Text(title))
    }
}
