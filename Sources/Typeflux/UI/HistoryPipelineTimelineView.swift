import SwiftUI

struct HistoryPipelineSummaryBadgesView: View {
    let items: [HistoryPipelineBadgePresentationItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: StudioTheme.Spacing.xSmall)],
            alignment: .leading,
            spacing: StudioTheme.Spacing.xSmall
        ) {
            ForEach(items) { item in
                HStack(spacing: StudioTheme.Spacing.xxSmall) {
                    Text(item.title)
                        .foregroundStyle(StudioTheme.textTertiary)
                    Text(item.value)
                        .fontWeight(.semibold)
                        .foregroundStyle(foregroundColor(for: item.tone))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .medium))
                .padding(.horizontal, StudioTheme.Spacing.xSmall)
                .padding(.vertical, StudioTheme.Spacing.xxxSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Capsule().fill(backgroundColor(for: item.tone))
                )
                .help("\(item.title) \(item.value)")
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func foregroundColor(for tone: HistoryPipelineBadgePresentationItem.Tone) -> Color {
        switch tone {
        case .neutral:
            StudioTheme.textSecondary
        case .selected:
            StudioTheme.success
        case .warning:
            StudioTheme.warning
        case .failure:
            StudioTheme.danger
        }
    }

    private func backgroundColor(for tone: HistoryPipelineBadgePresentationItem.Tone) -> Color {
        foregroundColor(for: tone).opacity(0.09)
    }
}

struct HistoryPipelineTimelineView: View {
    let title: String
    let timeline: HistoryPipelineTimelinePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
            header
            slowestStage
            lanes
            requestDetails
            keyMetrics
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudioTheme.Insets.cardDense)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.large, style: .continuous)
                .fill(StudioTheme.controlSurface)
        )
    }

    @ViewBuilder
    private var requestDetails: some View {
        if !timeline.requestDetails.isEmpty {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                Text(L("history.timeline.requestInfo"))
                    .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)

                ForEach(timeline.requestDetails) { item in
                    HistoryPipelineRequestInfoView(item: item)
                }
            }
            .padding(.top, StudioTheme.Spacing.xxSmall)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.small) {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)

            Spacer()

            HStack(spacing: StudioTheme.Spacing.smallMedium) {
                if let total = timeline.totalDurationText {
                    durationSummary(label: L("history.timeline.total"), value: total)
                }
                if let span = timeline.timelineSpanDurationText {
                    durationSummary(label: L("history.timeline.span"), value: span)
                }
            }
        }
    }

    private func durationSummary(label: String, value: String) -> some View {
        HStack(spacing: StudioTheme.Spacing.xxxSmall) {
            Text(label)
                .foregroundStyle(StudioTheme.textTertiary)
            Text(value)
                .foregroundStyle(StudioTheme.textPrimary)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.studioBody(StudioTheme.Typography.caption))
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
        let overviewLanes = timeline.lanes.filter { !$0.isDetail }
        let asrLanes = timeline.lanes.filter { $0.isDetail && $0.id.hasPrefix("asr-") }
        let llmLanes = timeline.lanes.filter { $0.isDetail && $0.id.hasPrefix("llm-request-") }

        return VStack(alignment: .leading, spacing: StudioTheme.Spacing.smallMedium) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                ForEach(overviewLanes) { lane in
                    HistoryPipelineTimelineLaneView(lane: lane)
                }
            }

            if !asrLanes.isEmpty || !llmLanes.isEmpty {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                    Text(L("history.timeline.breakdown"))
                        .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)

                    if !asrLanes.isEmpty {
                        HistoryPipelineDetailGroupView(
                            title: L("history.timeline.asrBreakdown"),
                            color: StudioTheme.accent,
                            lanes: asrLanes
                        )
                    }

                    if !llmLanes.isEmpty {
                        HistoryPipelineDetailGroupView(
                            title: L("history.timeline.llmBreakdown"),
                            color: Color(nsColor: .systemPurple),
                            lanes: llmLanes
                        )
                    }
                }
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

private struct HistoryPipelineRequestInfoView: View {
    let item: HistoryPipelineRequestPresentationItem

    var body: some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.small) {
            Image(systemName: "network")
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxxSmall) {
                Text(item.title)
                    .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                Text(item.endpoint)
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: StudioTheme.Spacing.small)

            HStack(spacing: StudioTheme.Spacing.xxSmall) {
                ForEach(item.badges, id: \.self) { badge in
                    Text(badge)
                        .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, StudioTheme.Spacing.xSmall)
                        .padding(.vertical, StudioTheme.Spacing.xxxSmall)
                        .background(
                            Capsule().fill(StudioTheme.rowSurface)
                        )
                }
            }
        }
        .padding(.horizontal, StudioTheme.Spacing.small)
        .padding(.vertical, StudioTheme.Spacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(StudioTheme.rowSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: 1)
        )
    }
}

private struct HistoryPipelineDetailGroupView: View {
    let title: String
    let color: Color
    let lanes: [HistoryPipelineTimelinePresentation.Lane]

    private var orderedLanes: [HistoryPipelineTimelinePresentation.Lane] {
        lanes.sorted {
            if $0.offsetFraction == $1.offsetFraction {
                return $0.durationMilliseconds < $1.durationMilliseconds
            }
            return $0.offsetFraction < $1.offsetFraction
        }
    }

    private var diagnosticLanes: [HistoryPipelineTimelinePresentation.Lane] {
        orderedLanes.filter { $0.id == "asr-first-audio-queue" }
    }

    private var connectionLanes: [HistoryPipelineTimelinePresentation.Lane] {
        orderedLanes.filter {
            $0.id.hasPrefix("asr-")
                && $0.id != "asr-first-audio-queue"
                && $0.id != "asr-streaming"
                && $0.id != "asr-final-wait"
                && $0.id != "asr-cleanup"
        }
    }

    private var recognitionLanes: [HistoryPipelineTimelinePresentation.Lane] {
        orderedLanes.filter {
            $0.id == "asr-streaming"
                || $0.id == "asr-final-wait"
                || $0.id == "asr-cleanup"
        }
    }

    private var isASRGroup: Bool {
        lanes.contains { $0.id.hasPrefix("asr-") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
            }
            .padding(.bottom, StudioTheme.Spacing.xxxSmall)

            if isASRGroup {
                if !diagnosticLanes.isEmpty {
                    ForEach(diagnosticLanes) { lane in
                        HistoryPipelineCompactDetailLaneView(
                            lane: lane,
                            color: color,
                            isDiagnosticInterval: true
                        )
                    }
                }

                detailSection(
                    title: L("history.timeline.connectionSetup"),
                    lanes: connectionLanes
                )
                detailSection(
                    title: L("history.timeline.recognitionProcess"),
                    lanes: recognitionLanes
                )
            } else {
                ForEach(orderedLanes) { lane in
                    HistoryPipelineCompactDetailLaneView(
                        lane: lane,
                        color: color,
                        isDiagnosticInterval: false
                    )
                }
            }
        }
        .padding(StudioTheme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(color.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(color.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailSection(
        title: String,
        lanes: [HistoryPipelineTimelinePresentation.Lane]
    ) -> some View {
        if !lanes.isEmpty {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                Rectangle()
                    .fill(StudioTheme.border.opacity(0.48))
                    .frame(height: 1)
            }
            .padding(.top, StudioTheme.Spacing.xxxSmall)

            ForEach(lanes) { lane in
                HistoryPipelineCompactDetailLaneView(
                    lane: lane,
                    color: color,
                    isDiagnosticInterval: false
                )
            }
        }
    }
}

private struct HistoryPipelineCompactDetailLaneView: View {
    let lane: HistoryPipelineTimelinePresentation.Lane
    let color: Color
    let isDiagnosticInterval: Bool

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.xxSmall) {
                Circle()
                    .fill(color.opacity(lane.isSlowest ? 1 : 0.72))
                    .frame(width: 4, height: 4)
                Text(lane.title)
            }
            .font(.studioBody(StudioTheme.Typography.eyebrow, weight: lane.isSlowest ? .semibold : .medium))
            .foregroundStyle(lane.isSlowest ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .frame(width: 192, alignment: .leading)
            .lineLimit(1)
            .help(lane.title)

            GeometryReader { proxy in
                let trackWidth = max(1, proxy.size.width)
                let rawWidth = trackWidth * lane.widthFraction
                let segmentWidth = lane.durationMilliseconds == 0 ? 2 : max(3, rawWidth)
                let segmentOffset = min(trackWidth - segmentWidth, trackWidth * lane.offsetFraction)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StudioTheme.border.opacity(0.34))
                        .frame(height: 2)

                    if isDiagnosticInterval {
                        Capsule()
                            .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: max(5, segmentWidth), height: 7)
                            .offset(x: max(0, segmentOffset))
                    } else if lane.durationMilliseconds == 0 {
                        Rectangle()
                            .fill(color.opacity(0.82))
                            .frame(width: 2, height: 9)
                            .offset(x: max(0, segmentOffset))
                    } else {
                        Capsule()
                            .fill(color.opacity(lane.isSlowest ? 0.95 : 0.72))
                            .frame(width: segmentWidth, height: lane.isSlowest ? 8 : 6)
                            .offset(x: max(0, segmentOffset))
                    }
                }
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            Text(lane.durationText)
                .font(.studioBody(StudioTheme.Typography.eyebrow, weight: .semibold))
                .foregroundStyle(lane.isSlowest ? color : StudioTheme.textTertiary)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, StudioTheme.Spacing.xxSmall)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small, style: .continuous)
                .fill(
                    lane.isSlowest
                        ? color.opacity(0.09)
                        : (isDiagnosticInterval ? color.opacity(0.045) : Color.clear)
                )
        )
        .accessibilityElement(children: .combine)
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
                .frame(width: lane.isDetail ? 4 : 6, height: lane.isDetail ? 4 : 6)
            Text(lane.title)
                .lineLimit(1)
        }
        .font(.studioBody(StudioTheme.Typography.caption, weight: lane.isSlowest ? .semibold : .medium))
        .foregroundStyle(lane.isSlowest ? StudioTheme.textPrimary : StudioTheme.textSecondary)
        .padding(.leading, lane.isDetail ? StudioTheme.Spacing.small : 0)
        .frame(width: 146, alignment: .leading)
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
                    .frame(width: segmentWidth, height: lane.isSlowest ? 11 : (lane.isDetail ? 6 : 8))
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
        case .cloud:
            StudioTheme.accent
        case .local:
            Color(nsColor: .systemTeal)
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
