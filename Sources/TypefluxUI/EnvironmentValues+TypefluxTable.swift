import SwiftUI

private struct TypefluxTableHoverStateKey: EnvironmentKey {
    static let defaultValue: Binding<TypefluxTableHoverState> = .constant(TypefluxTableHoverState())
}

private struct TypefluxTableStripesEmptyRowsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var typefluxTableStripesEmptyRows: Bool {
        get { self[TypefluxTableStripesEmptyRowsKey.self] }
        set { self[TypefluxTableStripesEmptyRowsKey.self] = newValue }
    }

    var typefluxTableHoverState: Binding<TypefluxTableHoverState> {
        get { self[TypefluxTableHoverStateKey.self] }
        set { self[TypefluxTableHoverStateKey.self] = newValue }
    }
}
