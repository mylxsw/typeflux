import SwiftUI

private struct TypefluxTableHoverStateKey: EnvironmentKey {
    static let defaultValue: Binding<TypefluxTableHoverState> = .constant(TypefluxTableHoverState())
}

extension EnvironmentValues {
    var typefluxTableHoverState: Binding<TypefluxTableHoverState> {
        get { self[TypefluxTableHoverStateKey.self] }
        set { self[TypefluxTableHoverStateKey.self] = newValue }
    }
}
