import SwiftUI

/// Wraps metadata and related word buttons at the available content width.
struct AskWordBookFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var positionY = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var positionX = bounds.minX
            for index in row.indices {
                let size = measured(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: positionX, y: positionY + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                positionX += size.width + spacing
            }
            positionY += row.height + spacing
        }
    }

    private func measured(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, max(0, width)), height: nil))
    }

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = measured(subviews[index], width: maxWidth)
            if !row.indices.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
