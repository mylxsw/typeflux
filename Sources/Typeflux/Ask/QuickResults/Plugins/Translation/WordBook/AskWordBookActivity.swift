import SwiftUI

/// Weekly lookup counts are data visualization, with a spoken total for VoiceOver.
struct AskWordBookActivity: View {
    @ObservedObject var model: AskWordBookViewModel

    var body: some View {
        let peak = max(1, model.week.max() ?? 1)
        let labels = L("ask.wordBook.weekdays").split(separator: ",").map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(model.week.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(TypefluxColor.controlBackground.color)
                        Rectangle().fill(index == model.todayIndex
                            ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
                            .frame(height: count == 0 ? 0 : max(3, 20 * CGFloat(count) / CGFloat(peak)))
                    }
                    .frame(height: 20)
                    Text(labels.indices.contains(index) ? labels[index] : "").font(.caption2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ask.wordBook.weekTotal", model.weekTotal))
    }
}
