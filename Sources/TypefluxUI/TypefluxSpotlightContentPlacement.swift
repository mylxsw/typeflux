import SwiftUI

/// The input occupies the viewport's top edge even while results request a different height.
struct TypefluxSpotlightContentPlacement: Layout {
    var spacing: CGFloat
    var fillsAvailableHeight: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + (sizes.count > 1 ? spacing : 0)
        let height = fillsAvailableHeight ? proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } : nil
        return CGSize(width: width ?? sizes.map(\.width).max() ?? 0, height: height ?? naturalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let input = subviews.first else { return }
        let inputProposal = ProposedViewSize(width: bounds.width, height: nil)
        let inputHeight = input.sizeThatFits(inputProposal).height
        input.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: inputHeight))
        for results in subviews.dropFirst() {
            results.place(at: CGPoint(x: bounds.minX, y: bounds.minY + inputHeight + spacing), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width,
                                                     height: max(0, bounds.height - inputHeight - spacing)))
        }
    }
}
