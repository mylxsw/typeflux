import SwiftUI

struct TerminalRiskCard: View {
    let risk: TerminalCommandRisk
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(risk.impact)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(L("terminal.risk.cancel") + " esc", action: cancel)
            Button(L("terminal.risk.runAnyway") + " ⌘↩", action: confirm)
                .tint(.red)
        }
        .font(.system(size: 12))
        .padding(8)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityIdentifier("terminal.risk.card")
    }
}
