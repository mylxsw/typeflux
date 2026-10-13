import SwiftUI

/// Diagnostics use the same solid grouped sections as the rest of the detail page.
struct HistoryPipelineTimelineView: View {
    let title: String
    let timeline: HistoryPipelineTimelinePresentation

    var body: some View {
        TypefluxFormSection(title) {
            if let total = timeline.totalDurationText {
                metric(L("history.timeline.total"), value: total)
            }
            if let span = timeline.timelineSpanDurationText {
                metric(L("history.timeline.span"), value: span)
            }
            if let slowest = timeline.slowestStageText {
                metric(L("history.timeline.slowest"), value: slowest)
            }
            ForEach(timeline.summaryBadges) { item in
                LabeledContent(item.title) { TypefluxTag(item.value, tone: badgeTone(item.tone)) }
            }
            ForEach(timeline.lanes.filter { !$0.isDetail }) { lane in
                HistoryPipelineLaneView(lane: lane)
            }
        }
        if timeline.lanes.contains(where: \.isDetail) {
            TypefluxFormSection(L("history.timeline.breakdown")) {
                ForEach(timeline.lanes.filter(\.isDetail)) { lane in HistoryPipelineLaneView(lane: lane) }
            }
        }
        if !timeline.requestDetails.isEmpty {
            TypefluxFormSection(L("history.timeline.requestInfo")) {
                ForEach(timeline.requestDetails) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(item.endpoint).textSelection(.enabled).font(.body)
                        HStack { ForEach(item.badges, id: \.self) { TypefluxTag($0) } }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if !timeline.keyMetrics.isEmpty {
            TypefluxFormSection(L("history.timeline.keyWaits")) {
                ForEach(timeline.keyMetrics) { item in metric(item.title, value: item.value) }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit() }
    }

    private func badgeTone(_ tone: HistoryPipelineBadgePresentationItem.Tone) -> TypefluxTone {
        switch tone {
        case .neutral: .neutral
        case .selected: .success
        case .warning: .warning
        case .failure: .danger
        }
    }
}
