import SwiftUI

public struct TypefluxPopup<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    private let title: String
    private let borderless: Bool
    private let content: Content

    public init(_ title: String, selection: Binding<Selection>, borderless: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.borderless = borderless
        self.content = content()
    }

    public var body: some View {
        if borderless {
            picker.buttonStyle(.borderless).menuStyle(.borderlessButton)
        } else {
            picker.buttonStyle(.bordered).menuStyle(.button)
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) { content }.pickerStyle(.menu).labelsHidden()
            .accessibilityLabel(Text(title))
    }
}

public extension TypefluxPopup where Content == AnyView {
    /// Tuple options ease migration of existing settings without drawing control chrome.
    init(title: String, options: [(label: String, value: Selection)], selection: Binding<Selection>) {
        self.init(title, selection: selection, borderless: true) {
            AnyView(Group {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
                if !options.contains(where: { $0.value == selection.wrappedValue }) {
                    Text(title).tag(selection.wrappedValue)
                }
            })
        }
    }
}
