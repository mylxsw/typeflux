import SwiftUI

struct HistoryPipelineTimelineView: View {
    let title: String
    let timeline: HistoryPipelineTimelinePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
            header
            slowestStage
            lanes
            keyMetrics
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(StudioTheme.controlSurface)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.small) {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)

            Spacer()

            if let total = timeline.totalDurationText {
                HStack(spacing: StudioTheme.Spacing.xxxSmall) {
                    Text(L("history.timeline.total"))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Text(total)
                        .foregroundStyle(StudioTheme.textPrimary)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.studioBody(StudioTheme.Typography.caption))
            }
        }
    }

    @ViewBuilder
    private var slowestStage: some View {
        if let slowest = timeline.slowestStageText {
            HStack(spacing: StudioTheme.Spacing.xxSmall) {
                Image(systemName: "scope")
                    .font(.system(size: StudioTheme.Typography.iconTiny, weight: .semibold))
                Text(L("history.timeline.slowest"))
                Text(slowest)
                    .fontWeight(.semibold)
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            .font(.studioBody(StudioTheme.Typography.caption))
            .foregroundStyle(StudioTheme.warning)
        }
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            ForEach(timeline.lanes) { lane in
                HistoryPipelineTimelineLaneView(lane: lane)
            }
        }
    }

    @ViewBuilder
    private var keyMetrics: some View {
        if !timeline.keyMetrics.isEmpty {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                Text(L("history.timeline.keyWaits"))
                    .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 138), spacing: StudioTheme.Spacing.xSmall)],
                    alignment: .leading,
                    spacing: StudioTheme.Spacing.xSmall
                ) {
                    ForEach(timeline.keyMetrics) { item in
                        HistoryPipelineTimelineMetricView(item: item)
                    }
                }
            }
            .padding(.top, StudioTheme.Spacing.xxSmall)
        }
    }
}

private struct HistoryPipelineTimelineLaneView: View {
    let lane: HistoryPipelineTimelinePresentation.Lane

    var body: some View {
        let color = timelineColor(lane.tone)
        HStack(spacing: StudioTheme.Spacing.small) {
            laneTitle(color: color)
            timelineBar(color: color)
            duration(color: color)
        }
        .accessibilityElement(children: .combine)
    }

    private func laneTitle(color: Color) -> some View {
        HStack(spacing: StudioTheme.Spacing.xxSmall) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(lane.title)
                .lineLimit(1)
        }
        .font(.studioBody(StudioTheme.Typography.caption, weight: lane.isSlowest ? .semibold : .medium))
        .foregroundStyle(lane.isSlowest ? StudioTheme.textPrimary : StudioTheme.textSecondary)
        .frame(width: 86, alignment: .leading)
    }

    private func timelineBar(color: Color) -> some View {
        GeometryReader { proxy in
            let trackWidth = max(1, proxy.size.width)
            let segmentWidth = max(7, trackWidth * lane.widthFraction)
            let segmentOffset = trackWidth * lane.offsetFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudioTheme.border.opacity(0.42))
                    .frame(height: 3)
                Capsule()
                    .fill(color.opacity(lane.isSlowest ? 0.95 : 0.72))
                    .frame(width: segmentWidth, height: lane.isSlowest ? 11 : 8)
                    .offset(x: segmentOffset)
                Circle()
                    .fill(color)
                    .frame(width: lane.isSlowest ? 7 : 5, height: lane.isSlowest ? 7 : 5)
                    .offset(x: segmentOffset)
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func duration(color: Color) -> some View {
        Text(lane.durationText)
            .font(.studioBody(StudioTheme.Typography.caption, weight: lane.isSlowest ? .semibold : .medium))
            .foregroundStyle(lane.isSlowest ? color : StudioTheme.textSecondary)
            .monospacedDigit()
            .frame(width: 58, alignment: .trailing)
    }

    private func timelineColor(_ tone: HistoryPipelineTimelineTone) -> Color {
        switch tone {
        case .audio:
            StudioTheme.textTertiary
        case .realtime:
            StudioTheme.accent
        case .transcription:
            Color(nsColor: .systemCyan)
        case .llm:
            Color(nsColor: .systemPurple)
        case .apply:
            StudioTheme.success
        }
    }
}

private struct HistoryPipelineTimelineMetricView: View {
    let item: HistoryPipelineStatPresentationItem

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
            Text(item.value)
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .monospacedDigit()
            Text(item.title)
                .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, StudioTheme.Spacing.small)
        .padding(.vertical, StudioTheme.Spacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.rowSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: 1)
        )
    }
}
