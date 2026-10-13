import SwiftUI

/// The checklist from update_plan.
struct AskPlanList: View {
    let items: [AskPlanItem]

    static func symbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: Self.symbol(item.status)).font(.system(size: 10.5))
                        .foregroundStyle(item.status == "completed" ? TypefluxColor.success.color
                            :
                            (item.status == "in_progress" ? TypefluxColor.accent.color : TypefluxColor.tertiaryLabel
                                .color))
                    Text(item.step)
                        .font(.system(size: 12.5, weight: item.status == "in_progress" ? .semibold : .regular))
                        .foregroundStyle(item.status == "completed" ? TypefluxColor.secondaryLabel.color : TypefluxColor
                            .label.color)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
