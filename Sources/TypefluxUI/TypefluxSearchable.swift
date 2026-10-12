import SwiftUI

public extension View {
    /// The rightmost native toolbar search, with deterministic Escape and blur behaviour.
    func typefluxSearchable(state: TypefluxSearchState, prompt: String) -> some View {
        modifier(TypefluxSearchable(state: state, prompt: prompt))
    }
}

private struct TypefluxSearchable: ViewModifier {
    @ObservedObject var state: TypefluxSearchState
    @Environment(\.interfaceStyle) private var style
    let prompt: String

    func body(content: Content) -> some View {
        content.searchable(text: $state.query, placement: .toolbar, prompt: Text(prompt))
            .background(TypefluxSearchToolbarBridge(state: state, style: style).frame(width: 0, height: 0))
    }
}
