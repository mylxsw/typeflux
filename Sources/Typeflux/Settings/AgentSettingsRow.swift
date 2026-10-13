import SwiftUI

struct AgentSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var badge: String?
    var subtitleLineLimit: Int? = 2
    var titleLineLimit: Int? = 1
    @ViewBuilder var trailing: Trailing

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.body).lineLimit(titleLineLimit)
                if let badge {
                    Text(badge).font(.subheadline).foregroundStyle(.secondary)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension AgentSettingsRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, badge: String? = nil, subtitleLineLimit: Int? = 2) {
        self.init(icon: icon, title: title, subtitle: subtitle, badge: badge,
                  subtitleLineLimit: subtitleLineLimit) { EmptyView() }
    }
}
