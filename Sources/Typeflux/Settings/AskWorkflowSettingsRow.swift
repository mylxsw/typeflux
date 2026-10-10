import SwiftUI

/// A workflow's identity, description and metadata get their own space beside its controls.
struct AskWorkflowSettingsRow<Controls: View>: View {
    let symbol: String
    let summary: AskWorkflowSummary
    let edit: () -> Void
    var review: (() -> Void)?
    var fix: (() -> Void)?
    var viewLastRun: (() -> Void)?
    @ViewBuilder var controls: Controls
    @State private var titleHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button(action: edit) {
                        Text(summary.title).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(titleHovered ? ModelVisualStyle.accent : StudioTheme.textPrimary)
                            .underline(titleHovered)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { titleHovered = $0 }
                    .help(L("ask.workflow.editor.edit") + " " + summary.title)
                    .accessibilityLabel(L("ask.workflow.editor.edit") + " " + summary.title)
                    .accessibilityIdentifier("ask.workflow.edit")
                    HStack(spacing: 10) { controls }.fixedSize()
                }
                if !summary.description.isEmpty {
                    Text(summary.description).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(summary.description)
                }
                AgentFlowLayout(spacing: 6) {
                    if let runtime = summary.runtime {
                        Text(runtime).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                    }
                    ForEach(Array(summary.keywords.enumerated()), id: \.offset) { _, keyword in
                        AskKeywordListChip(keyword: keyword)
                    }
                    if summary.showsStatus {
                        AgentStatusBadge(level: summary.level, label: summary.status)
                            .accessibilityIdentifier("ask.workflow.status")
                    }
                    if let review {
                        Button(L("ask.workflow.review"), action: review)
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(StudioTheme.warning)
                            .accessibilityIdentifier("ask.workflow.review")
                    }
                    if let fix {
                        Button(L("ask.workflow.editor.fixButton"), action: fix)
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(StudioTheme.warning)
                            .accessibilityIdentifier("ask.workflow.fix")
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(summary.notices.enumerated()), id: \.offset) { _, notice in
                    Text(notice).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let notice = summary.runNotice {
                    HStack(spacing: 8) {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .accessibilityIdentifier("ask.workflow.runNotice")
                        if let viewLastRun {
                            Button(L("ask.workflow.lastRun.details"), action: viewLastRun)
                                .buttonStyle(.plain).underline()
                                .accessibilityIdentifier("ask.workflow.runDetails")
                        }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }
}
