import SwiftUI

struct AskBudgetView: View {
    let budget: AskBudgetSummary

    static func reasonKey(_ reason: String) -> String {
        let supported = [
            "tokens",
            "cost_estimate",
            "web_requests",
            "children",
            "operations",
            "duration",
            "context_capacity",
            "budget_unavailable"
        ]
        return "ask.budget.reason." + (supported.contains(reason) ? reason : "budget_unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("ask.budget.title")).font(.system(size: 12, weight: .semibold))
            Text(L(budget.metering == "client_reported" ? "ask.budget.client" : "ask.budget.estimate"))
                .foregroundStyle(StudioTheme.textSecondary)
            Text(L("ask.budget.tokens", budget.actual.tokens, budget.occupied.tokens, budget.limits.tokens))
            Text(L("ask.budget.web", budget.occupied.webRequests, budget.limits.webRequests))
            if budget.pending > 0 {
                Text(L("ask.budget.pending", budget.pending))
            }
            if let reason = budget
                .stopReason {
                Text(L("ask.budget.stopped", L(Self.reasonKey(reason)))).foregroundStyle(StudioTheme.warning)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 10))
    }
}
