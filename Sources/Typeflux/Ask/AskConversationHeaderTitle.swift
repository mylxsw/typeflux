import SwiftUI

/// Cap the title's rendered width while keeping short titles snug and allowing
/// the header to compress further when its other controls need room.
struct AskConversationHeaderTitle: View {
    static let maximumWidth: CGFloat = 320
    let title: String

    var body: some View {
        HeaderTitleLayout {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityIdentifier("ask.workspace.title")
        }
    }

    private struct HeaderTitleLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            guard let text = subviews.first else { return .zero }
            let limit = AskConversationHeaderTitle.maximumWidth
            let width = min(limit, max(0, proposal.width ?? limit))
            return text.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
