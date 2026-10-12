import SwiftUI

/// Small, always visible search for menus, popovers and pickers that have no toolbar.
public struct TypefluxInlineSearch: View {
    @Binding private var text: String
    @State private var focused = false
    private let prompt: String

    public init(text: Binding<String>, prompt: String) {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        TypefluxNativeSearchField(text: $text, focused: $focused, prompt: prompt,
                                  identifier: "typeflux.inline-search", onEscape: { text = "" })
            .frame(minHeight: 22)
            .controlSize(.small)
    }
}
