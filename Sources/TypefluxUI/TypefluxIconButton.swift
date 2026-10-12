import SwiftUI

public struct TypefluxIconButton: View {
    private let title: String
    private let systemImage: String
    private let kind: TypefluxButtonKind
    private let size: ControlSize
    private let action: () -> Void

    public init(_ title: String, systemImage: String, kind: TypefluxButtonKind = .borderless,
                size: ControlSize = .regular, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.action = action
    }

    public var body: some View {
        TypefluxButton(kind: kind, size: size, action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }.accessibilityLabel(Text(title)).typefluxHelp(title)
    }
}
