import SwiftUI

public struct TypefluxStatus: View {
    private let title: String
    private let tone: TypefluxTone

    public init(_ title: String, tone: TypefluxTone = .neutral) { self.title = title; self.tone = tone }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone == .inactive ? Color.clear : tone.color)
                .overlay { if tone == .inactive { Circle().stroke(tone.color, lineWidth: 1) } }
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
        }.accessibilityElement(children: .ignore).accessibilityLabel(Text(title))
    }
}
