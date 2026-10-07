import SwiftUI

/// A workflow's identity, description and metadata get their own space beside its controls.
struct AskWorkflowSettingsRow<Controls: View>: View {
    let symbol: String
    let summary: AskWorkflowSummary
    let edit: () -> Void
    var review: (() -> Void)?
    var fix: (() -> Void)?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: edit) {
                        Text(summary.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(summary.title)
                    .accessibilityLabel(L("ask.workflow.editor.edit") + " " + summary.title)
                    .accessibilityIdentifier("ask.workflow.edit")
                    HStack(spacing: 10) { controls }.fixedSize()
                }
                if !summary.description.isEmpty {
                    Text(summary.description).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(summary.description)
                }
                AgentFlowLayout(spacing: 6) {
                    if let runtime = summary.runtime {
                        AgentFactChip(text: runtime)
                    }
                    ForEach(Array(summary.keywords.enumerated()), id: \.offset) { _, keyword in
                        AskKeywordListChip(keyword: keyword)
                    }
                    AgentStatusBadge(level: summary.level, label: summary.status)
                    if let review {
                        Button(L("ask.workflow.review"), action: review)
                            .accessibilityIdentifier("ask.workflow.review")
                    }
                    if let fix {
                        Button(L("ask.workflow.editor.fixButton"), action: fix)
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
                if let lastRun = summary.lastRun {
                    Text(lastRun).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
