import SwiftUI

/// The model's current plan for a multi-step task (`run.plan`).
struct AskPlanCard: View {
    var items: [AskPlanItem]
    @State private var expanded = true

    static func symbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }

    static func summary(_ items: [AskPlanItem]) -> String {
        L("ask.plan.progress", items.filter { $0.status == "completed" }.count, items.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.clipboard").font(.system(size: 11, weight: .medium))
                    Text(L("ask.plan.title")).font(.system(size: 12, weight: .semibold))
                    Text(Self.summary(items)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: Self.symbol(item.status)).font(.system(size: 10.5))
                            .foregroundStyle(item.status == "completed" ? StudioTheme.success : StudioTheme.textSecondary)
                        Text(item.step).font(.system(size: 12, weight: item.status == "in_progress" ? .semibold : .regular))
                            .strikethrough(item.status == "completed", color: StudioTheme.textTertiary)
                            .foregroundStyle(item.status == "completed" ? StudioTheme.textSecondary : StudioTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
