import SwiftUI

/// The caller owns navigation; using a native button preserves keyboard activation.
public struct TypefluxNavigationRow: View {
    private let title: String
    private let systemImage: String
    private let color: Color
    private let detail: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String, color: Color, detail: String? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        TypefluxButton(kind: .borderless, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(TypefluxColor.label.color)
                Spacer()
                if let detail { Text(detail).foregroundStyle(TypefluxColor.secondaryLabel.color) }
                Image(systemName: "chevron.right").foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .accessibilityHidden(true)
            }.contentShape(Rectangle())
        }.accessibilityLabel(Text(title))
            .accessibilityValue(Text(detail ?? ""))
    }
}
