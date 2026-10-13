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
        private weak var measuredTable: NSTableView?
        private var tableFrameObserver: NSObjectProtocol?
        private weak var measuredScroll: NSScrollView?
        private var scrollFrameObserver: NSObjectProtocol?
        private var tablePostedFrameChanges = false
        private var scrollPostedFrameChanges = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMeasuringTable()
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
                guard window != nil, let table = table(), let scroll = table.enclosingScrollView else { return }
                observeTableFrame(table, scroll: scroll)
                guard table.numberOfRows == rowCount, rowCount > 0 else { return }
                let rowsHeight = table.rect(ofRow: rowCount - 1).maxY
                // A floating header can overlap the clip view, so the frame difference alone
                // undercounts it. Legacy horizontal scrollers also reserve height at narrow widths.
                let headerHeight = table.headerView?.frame.height ?? 0
                let scrollerHeight = scroll.scrollerStyle == .legacy && scroll.hasHorizontalScroller
                    ? (scroll.horizontalScroller?.frame.height ?? 0) : 0
                let chromeHeight = max(headerHeight + scrollerHeight,
                                       scroll.frame.height - scroll.contentView.frame.height)
                let measured = ceil(rowsHeight + chromeHeight
                    + max(0, scroll.contentInsets.top) + max(0, scroll.contentInsets.bottom))
                if measured.isFinite, measured > 0 { report?(measured) }
            }
        }

        private func table() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                let tables = descendants(view).compactMap { $0 as? NSTableView }.filter { table in
                    guard !(table is NSOutlineView), table.window === window,
                          let scroll = table.enclosingScrollView else { return false }
                    return convert(scroll.bounds, from: scroll).contains(NSPoint.zero)
                }
                if let table = tables.first(where: {
                    $0.accessibilityIdentifier() == tableIdentifier
                }) { return table }
                // SwiftUI can put the identifier on its hosting view rather than the NSTableView.
                // Only accept an unambiguous table in this background's nearest container.
                if tables.count == 1 { return tables[0] }
                let matchingRows = tables.filter { $0.numberOfRows == rowCount }
                if matchingRows.count == 1 { return matchingRows[0] }
                ancestor = view.superview
            }
            return nil
        }

        private func observeTableFrame(_ table: NSTableView, scroll: NSScrollView) {
            guard measuredTable !== table || measuredScroll !== scroll else { return }
            stopMeasuringTable()
            measuredTable = table
            tablePostedFrameChanges = table.postsFrameChangedNotifications
            table.postsFrameChangedNotifications = true
            tableFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: table, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
            measuredScroll = scroll
            scrollPostedFrameChanges = scroll.postsFrameChangedNotifications
            scroll.postsFrameChangedNotifications = true
            scrollFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
        }

        func stopMeasuringTable() {
            if let tableFrameObserver { NotificationCenter.default.removeObserver(tableFrameObserver) }
            tableFrameObserver = nil
            if let scrollFrameObserver { NotificationCenter.default.removeObserver(scrollFrameObserver) }
            scrollFrameObserver = nil
            measuredTable?.postsFrameChangedNotifications = tablePostedFrameChanges
            measuredScroll?.postsFrameChangedNotifications = scrollPostedFrameChanges
            measuredTable = nil
            measuredScroll = nil
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

    static func dismantleNSView(_ view: MeasurementView, coordinator _: ()) {
        view.report = nil
        view.stopMeasuringTable()
    }
}
