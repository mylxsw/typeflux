import SwiftUI

struct AskWorkflowToolPermissionView: View {
    @ObservedObject var assistant: AskWorkflowAssistant
    @State private var showsDetails = false

    var body: some View {
        if let call = assistant.pendingPermission {
            TFCard {
                TFFormRow(title: AskToolAuthorization.entry(for: call).toolTitle) {
                    HStack(spacing: TFMetrics.toolbarSpacing) {
                        TFButton(title: L("agent.permissions.deny"), size: .small) { assistant.resolveToolPermission(false) }
                        TFButton(title: L("agent.permissions.allow"), kind: .primary, size: .small) {
                            assistant.resolveToolPermission(true)
                        }
                    }
                }
                TFDisclosureRow(title: L("ask.approval.arguments"), isExpanded: $showsDetails)
                if showsDetails {
                    ScrollView {
                        Text(call.function.arguments).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TFColors.textSecondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(maxHeight: 160)
                }
            }
        }
    }
}
