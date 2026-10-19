import SwiftUI

/// A run that stopped at the agent's step limit, asked as one question: keep
/// going or end here. It names what is left rather than explaining the limit.
struct AskStepLimitPrompt: View {
    let steps: Int
    let plan: [AskPlanItem]?
    var onEnd: () -> Void
    var onContinue: () -> Void

    /// Whether the run stopped at the on-device engine's step limit.
    static func applies(_ run: AskRun) -> Bool {
        run.status == "failed" && run.error == L("ask.local.stepLimit")
    }

    static func title(steps: Int) -> String { L("ask.stepLimit.title", max(steps, 1)) }

    /// "1 left: check the result", or a plain hint when the run kept no plan.
    static func subtitle(plan: [AskPlanItem]?) -> String {
        let remaining = (plan ?? []).filter { $0.status != "completed" }
        guard let next = remaining.first?.step.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty else {
            return L("ask.stepLimit.hint")
        }
        return L("ask.stepLimit.remaining", remaining.count, next)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AskTheme.accentText)
                .frame(width: 28, height: 28)
                .background(AskTheme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(steps: steps))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(Self.subtitle(plan: plan))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onEnd) { Text(L("ask.stepLimit.end")) }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
            Button(action: onContinue) { Text(L("ask.stepLimit.continue")) }
                .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
        .accessibilityElement(children: .contain)
    }
}
