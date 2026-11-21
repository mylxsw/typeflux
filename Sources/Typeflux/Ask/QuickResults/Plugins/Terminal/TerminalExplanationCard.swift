import SwiftUI

struct TerminalExplanationCard: View {
    @ObservedObject var explanation: TerminalFailureExplanation
    let block: TerminalCommandBlock
    let canFill: Bool
    let fill: () -> Void

    var body: some View {
        if explanation.blockID == block.id {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.purple)
                VStack(alignment: .leading, spacing: 6) {
                    switch explanation.phase {
                    case .disclosure:
                        Text(L("terminal.ai.disclosure"))
                        HStack {
                            Button(L("terminal.ai.explain")) { explanation.explain(block, consent: true) }
                                .accessibilityIdentifier("terminal.ai.consent")
                            Button(L("common.cancel")) { explanation.clear() }
                        }
                    case .loading:
                        Text("•••").accessibilityLabel(L("terminal.ai.loading"))
                    case .offline, .failed:
                        Text(L(explanation.phase == .offline ? "terminal.ai.offline" : "terminal.ai.failed"))
                        Button(L("common.retry")) { explanation.explain(block) }
                            .accessibilityIdentifier("terminal.ai.retry")
                    case let .ready(answer):
                        Text(answer.explanation).textSelection(.enabled)
                        HStack {
                            Button(action: fill) {
                                HStack(spacing: 6) {
                                    Text(answer.command)
                                    Text("⇥").foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .disabled(!canFill)
                            Spacer(minLength: 4)
                            Button(L("terminal.ai.continue")) { explanation.continueInAsk(block) }
                                .fixedSize()
                        }
                    }
                }
            }
            .font(.system(size: 12)).buttonStyle(.borderless)
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
