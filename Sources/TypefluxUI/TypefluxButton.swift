import SwiftUI

/// Content buttons keep the OS bezel, sizing, focus and press behavior.
public struct TypefluxButton<Label: View>: View {
    private let kind: TypefluxButtonKind
    private let size: ControlSize
    private let defaultAction: Bool
    private let action: () -> Void
    private let label: Label

    public init(kind: TypefluxButtonKind = .regular, size: ControlSize = .regular,
                defaultAction: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.kind = kind
        self.size = size
        self.defaultAction = defaultAction
        self.action = action
        self.label = label()
    }

    @ViewBuilder public var body: some View {
        if defaultAction {
            styledButton.controlSize(size).keyboardShortcut(.defaultAction)
        } else {
            styledButton.controlSize(size)
        }
    }

    @ViewBuilder private var styledButton: some View {
        switch kind {
        case .primary: button.buttonStyle(.borderedProminent)
        case .regular: button.buttonStyle(.bordered)
        case .destructive: button.buttonStyle(.bordered)
        case .borderless: button.buttonStyle(.borderless)
        case .link: button.buttonStyle(.link)
        }
    }

    private var button: some View { Button(role: kind.role, action: action) { label } }
}

extension TypefluxButton where Label == Text {
    public init(_ title: String, kind: TypefluxButtonKind = .regular, size: ControlSize = .regular,
                defaultAction: Bool = false, action: @escaping () -> Void) {
        self.init(kind: kind, size: size, defaultAction: defaultAction, action: action) { Text(title) }
    }
}
