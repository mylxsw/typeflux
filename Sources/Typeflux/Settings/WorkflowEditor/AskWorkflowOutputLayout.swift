import SwiftUI

/// Keeps the output form inside the editor's insets, stacking the preview when
/// the form's minimum width and the preview no longer fit side by side.
struct AskWorkflowOutputLayout: Layout {
    private let previewWidth: CGFloat = 330
    private let spacing: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? (previewWidth * 2 + spacing)
        let columns = sizes(width: width, subviews: subviews)
        return CGSize(width: max(width, columns.form.width),
                      height: columns.horizontal ? max(columns.form.height, columns.preview.height)
                          : columns.form.height + spacing + columns.preview.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let columns = sizes(width: bounds.width, subviews: subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(columns.form))
        let previewOrigin = columns.horizontal
            ? CGPoint(x: bounds.minX + bounds.width - previewWidth, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + columns.form.height + spacing)
        subviews[1].place(at: previewOrigin, proposal: ProposedViewSize(columns.preview))
    }

    private struct Columns {
        var form: CGSize
        var preview: CGSize
        var horizontal: Bool
    }

    private func sizes(width: CGFloat, subviews: Subviews) -> Columns {
        let formWidth = max(0, width - previewWidth - spacing)
        let form = subviews[0].sizeThatFits(ProposedViewSize(width: formWidth, height: nil))
        if form.width <= formWidth {
            return Columns(form: form,
                           preview: subviews[1].sizeThatFits(ProposedViewSize(width: previewWidth, height: nil)),
                           horizontal: true)
        }
        let stacked = ProposedViewSize(width: width, height: nil)
        return Columns(form: subviews[0].sizeThatFits(stacked), preview: subviews[1].sizeThatFits(stacked),
                       horizontal: false)
    }
}
