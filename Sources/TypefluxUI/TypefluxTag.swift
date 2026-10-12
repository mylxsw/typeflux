import SwiftUI

/// Read-only metadata; filtering uses a segmented control or menu instead.
public struct TypefluxTag: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast
    private let title: String
    private let tone: TypefluxTone

    public init(_ title: String, tone: TypefluxTone = .neutral) { self.title = title; self.tone = tone }

    public var body: some View {
        Text(title).font(.subheadline).fontWeight(.medium)
            .foregroundStyle(contrast == .increased ? TypefluxColor.label.color : tone.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: style == .classic ? 5 : 99)
                    .fill(TypefluxColor.controlBackground.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: style == .classic ? 5 : 99).fill(tone.color.opacity(0.12))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: style == .classic ? 5 : 99))
            .accessibilityLabel(Text(title))
    }
}
