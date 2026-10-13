import SwiftUI

/// The offset and length show overlapping pipeline stages on a common time axis.
struct HistoryPipelineLaneView: View {
    let lane: HistoryPipelineTimelinePresentation.Lane

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(lane.title) {
                Text(lane.durationText).monospacedDigit().fontWeight(lane.isSlowest ? .semibold : .regular)
            }
            GeometryReader { geometry in
                let width = max(0, geometry.size.width)
                let offset = min(1, max(0, lane.offsetFraction))
                let fraction = min(1 - offset, max(0, lane.widthFraction))
                ProgressView(value: 1).progressViewStyle(.linear).tint(color)
                    .frame(width: max(2, width * fraction))
                    .offset(x: width * offset)
            }
            .frame(height: 6)
            .clipped()
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch lane.tone {
        case .audio: TypefluxColor.secondaryLabel.color
        case .realtime, .cloud: TypefluxColor.accent.color
        case .transcription: Color(nsColor: .systemCyan)
        case .local: Color(nsColor: .systemTeal)
        case .llm: Color(nsColor: .systemPurple)
        case .apply: TypefluxColor.success.color
        }
    }
}
