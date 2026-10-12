import SwiftUI

public struct TypefluxRadioGroup<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    private let title: String
    private let content: Content

    public init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    public var body: some View { Picker(title, selection: $selection) { content }.pickerStyle(.radioGroup) }
}
