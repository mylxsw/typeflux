import AppKit
import SwiftUI

/// Fit a native table to real rows so AppKit does not stripe the unused document area.
struct TypefluxTableContentHeight: NSViewRepresentable {
    @Binding var height: CGFloat
    let rowCount: Int
    let identifier: String

    final class MeasurementView: NSView {
        var report: ((CGFloat) -> Void)?
        var rowCount = 0
        var tableIdentifier = ""
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        override func layout() {
            super.layout()
            schedule()
        }

        func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                guard window != nil, let table = table(), table.numberOfRows == rowCount,
                      rowCount > 0, let scroll = table.enclosingScrollView else { return }
                let rowsHeight = table.rect(ofRow: rowCount - 1).maxY
                let chromeHeight = scroll.frame.height - scroll.contentView.frame.height
                let measured = ceil(rowsHeight + chromeHeight + scroll.contentInsets.top + scroll.contentInsets.bottom)
                if measured.isFinite, measured > 0 { report?(measured) }
            }
        }

        private func table() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                if let table = descendants(view).compactMap({ $0 as? NSTableView }).first(where: {
                    $0.accessibilityIdentifier() == tableIdentifier
                }) { return table }
                ancestor = view.superview
            }
            return nil
        }

        private func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
    }

    func makeNSView(context _: Context) -> MeasurementView { MeasurementView() }

    func updateNSView(_ view: MeasurementView, context _: Context) {
        view.rowCount = rowCount
        view.tableIdentifier = identifier
        view.report = { measured in
            if abs(height - measured) > 0.5 { height = measured }
        }
        view.schedule()
    }

    static func dismantleNSView(_ view: MeasurementView, coordinator _: ()) { view.report = nil }
}
