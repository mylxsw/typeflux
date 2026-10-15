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
            TFIconTile(systemImage: symbol, style: .neutral).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button(action: edit) {
                        Text(summary.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(titleHovered ? TFColors.accent : TFColors.textPrimary)
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
                    HStack(spacing: TFMetrics.toolbarSpacing) { controls }.fixedSize()
                }
                if !summary.description.isEmpty {
                    Text(summary.description).font(.system(size: 12))
                        .foregroundStyle(TFColors.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(summary.description)
                }
                TFFlowLayout(spacing: 6) {
                    if let runtime = summary.runtime {
                        TFTag(text: runtime)
                    }
                    ForEach(Array(summary.keywords.enumerated()), id: \.offset) { _, keyword in
                        AskKeywordListChip(keyword: keyword)
                    }
                    if summary.showsStatus {
                        TFStatusLabel(text: summary.status, level: .warning, tintsText: true)
                            .accessibilityIdentifier("ask.workflow.status")
                    }
                    if let review {
                        TFButton(title: L("ask.workflow.review"), kind: .link, size: .small, action: review)
                            .accessibilityIdentifier("ask.workflow.review")
                    }
                    if let fix {
                        TFButton(title: L("ask.workflow.editor.fixButton"), kind: .link, size: .small, action: fix)
                            .accessibilityIdentifier("ask.workflow.fix")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(summary.notices.enumerated()), id: \.offset) { _, notice in
                    TFFieldMessage(text: notice, tone: .warning).textSelection(.enabled)
                }
                if let notice = summary.runNotice {
                    HStack(spacing: 8) {
                        TFStatusLabel(text: notice, level: .warning, tintsText: true)
                            .accessibilityIdentifier("ask.workflow.runNotice")
                        if let viewLastRun {
                            TFButton(title: L("ask.workflow.lastRun.details"), kind: .link, size: .small,
                                     action: viewLastRun)
                                .accessibilityIdentifier("ask.workflow.runDetails")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
