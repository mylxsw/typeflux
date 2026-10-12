import SwiftUI

public struct TypefluxMenu<Content: View, Label: View>: View {
    private let content: Content
    private let label: Label
    private let borderless: Bool

    public init(borderless: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
        self.borderless = borderless
    }

    @ViewBuilder public var body: some View {
        if borderless { menu.menuStyle(.borderlessButton) } else { menu.menuStyle(.button) }
    }

    private var menu: some View { Menu { content } label: { label } }
}
