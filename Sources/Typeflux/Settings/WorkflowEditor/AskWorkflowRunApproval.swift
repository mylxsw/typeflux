import SwiftUI

/// Approval stays actionable both in the sidebar and in the modal creation sheet.
struct AskWorkflowRunApproval: View {
    @ObservedObject var model: AskWorkflowEditorModel
    var run: AskWorkflowEditorModel.PendingRun
    var allowsFallback = true
    var preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("ask.workflow.assistant.approval.titleNumbered", model.proposalNumber(run.proposalID)),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.warning)
                Spacer()
                Text(L("ask.workflow.assistant.approval.paused")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            AskWorkflowRiskChips(risks: model.proposal(run.proposalID)?.risks.sorted() ?? run.risks,
                                 new: Set(run.risks), showsAbsent: false)
            Text(L("ask.workflow.assistant.approval.body")).font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if allowsFallback, let fallback = model.fallbackProposal {
                    Button(L("ask.workflow.assistant.approval.useOnly", model.proposalNumber(fallback.id))) {
                        model.useFallbackProposal()
                    }
                } else {
                    Button(L("ask.workflow.assistant.approval.decline")) { model.resolvePendingRun(false) }
                        .accessibilityIdentifier("ask.workflow.assistant.decline")
                }
                Button(L("ask.workflow.assistant.preview"), action: preview)
                    .accessibilityIdentifier("ask.workflow.assistant.preview")
                Button(L("ask.workflow.assistant.approval.allow")) { model.resolvePendingRun(true) }
                    .buttonStyle(.borderedProminent).tint(AskWorkflowEditorStyle.assistant)
                    .accessibilityIdentifier("ask.workflow.assistant.allow")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(StudioTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.warning.opacity(0.5)))
    }
}
