import SwiftUI

/// Failure diagnostics stay available without adding routine run logs to every list row.
struct AskWorkflowRunDetails: View, Identifiable {
    let title: String
    let entry: AskWorkflowLog.Entry
    @Environment(\.dismiss) private var dismiss

    var id: String {
        entry.workflowID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(entry.timedOut
                ? L("ask.workflow.lastRun.timedOut", entry.duration)
                : L("ask.workflow.lastRun", Int(entry.exitCode), entry.duration))
                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.warning)
            Text(entry.date, style: .date).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            ScrollView {
                Text(entry.stderr.isEmpty ? L("ask.workflow.editor.test.nothing") : entry.stderr)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 220)
            .background(ModelVisualStyle.input, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(L("ask.workflow.editor.close")) { dismiss() }
                    .buttonStyle(ModelActionStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 520).background(ModelVisualStyle.canvas)
    }
}
