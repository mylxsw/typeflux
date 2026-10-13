import SwiftUI

/// The launcher's bottom bar after a workflow's actions ran:
/// "✓ Copied “100 USD = …” · ✓ Notification sent      ⌘Z to undo the copy".
struct AskWorkflowActionsSummaryView: View {
    var state: AskWorkflowActionsState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(state.outcomes.enumerated()), id: \.offset) { index, outcome in
                    if let text = Self.text(for: outcome) {
                        if index > 0 {
                            Text("·").foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        }
                        Text(text)
                            .foregroundStyle(outcome.succeeded ? TypefluxColor.success.color : TypefluxColor.danger
                                .color)
                            .lineLimit(1)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if state.undone {
                Text(L("ask.workflow.action.copyUndone")).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            } else if state.canUndo {
                Text(L("ask.workflow.action.undoHint")).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.workflow.actions.summary")
    }

    /// One outcome as the bar says it; nil for steps that were not run.
    static func text(for outcome: AskWorkflowActionOutcome) -> String? {
        AskWorkflowActionRunner.summary([outcome]).nilIfEmpty
    }
}

/// The launcher's bottom bar while a workflow asks to open a web host it does not name:
/// "Exchange Rates wants to open xe.com. Allow?   Allow ↩   Don't Allow esc".
struct AskWorkflowApprovalView: View {
    var approval: AskWorkflowApproval
    var answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network").foregroundStyle(TypefluxColor.warning.color)
            Text(L("ask.workflow.approval.question", approval.workflowName, approval.host))
                .foregroundStyle(TypefluxColor.label.color).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            button(L("ask.workflow.approval.deny"), key: "esc", primary: false) { answer(false) }
            button(L("ask.workflow.approval.allow"), key: "↩", primary: true) { answer(true) }
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.workflow.approval")
    }

    private func button(_ title: String, key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text(key).font(.system(size: 10.5)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            .foregroundStyle(primary ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, 7).frame(height: 20)
            .background(primary ? TypefluxColor.accent.color.opacity(0.16) : TypefluxColor.label.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
