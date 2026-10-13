import AppKit
import SwiftUI

/// Keep a full-height native table, with alternating backgrounds confined to its actual row views.
struct TypefluxTableRowBackground: NSViewRepresentable {
    let tableIdentifier: String
    var stylesRowOnly = false

    final class RowBackgroundView: NSView {
        var tableIdentifier = ""
        var stylesRowOnly = false
        private var refreshScheduled = false
        private var rowStylingActive = true
        private weak var styledTable: NSTableView?
        private weak var styledClip: NSClipView?
        private var rowObservers: [NSObjectProtocol] = []
        private var tablePostedFrameChanges = false
        private var clipPostedBoundsChanges = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservingRows()
            scheduleRowBackgrounds()
        }

        override func layout() {
            super.layout()
            scheduleRowBackgrounds()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            scheduleRowBackgrounds()
        }

        func scheduleRowBackgrounds() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                refreshScheduled = false
                guard rowStylingActive, window != nil, let table = contentTable(),
                      let scroll = table.enclosingScrollView else { return }
                if stylesRowOnly {
                    // Cell lifecycle updates also cover rows inserted without changing the table's frame.
                    guard let rowView = enclosingRowView() else { return }
                    let row = table.row(for: rowView)
                    guard row >= 0 else { return }
                    table.effectiveAppearance.performAsCurrentDrawingAppearance {
                        self.applyRowStripe(rowView, row: row)
                    }
                    return
                }
                observeRows(table, clip: scroll.contentView)
                // SwiftUI owns the delegate, selection, sorting and scroll geometry. Change only surfaces.
                if scroll.drawsBackground { scroll.drawsBackground = false }
                if scroll.contentView.drawsBackground { scroll.contentView.drawsBackground = false }
                if table.backgroundColor != .clear { table.backgroundColor = .clear }
                if table.usesAlternatingRowBackgroundColors { table.usesAlternatingRowBackgroundColors = false }
                table.effectiveAppearance.performAsCurrentDrawingAppearance {
                    table.enumerateAvailableRowViews { rowView, row in
                        self.applyRowStripe(rowView, row: row)
                    }
                }
            }
        }

        private func applyRowStripe(_ rowView: NSTableRowView, row: Int) {
            let color: NSColor = row.isMultiple(of: 2) ? .clear
                : NSColor.alternatingContentBackgroundColors.last ?? .clear
            if rowView.backgroundColor != color { rowView.backgroundColor = color }
        }

        private func contentTable() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                if stylesRowOnly {
                    if let table = view as? NSTableView { return table }
                    ancestor = view.superview
                    continue
                }
                let tables = rowDescendants(view).compactMap { $0 as? NSTableView }.filter { table in
                    guard !(table is NSOutlineView), table.window === window,
                          let scroll = table.enclosingScrollView else { return false }
                    return convert(scroll.bounds, from: scroll).contains(NSPoint.zero)
                }
                if let table = tables.first(where: { $0.accessibilityIdentifier() == tableIdentifier }) { return table }
                if tables.count == 1 { return tables[0] }
                ancestor = view.superview
            }
            return nil
        }

        private func enclosingRowView() -> NSTableRowView? {
            var ancestor = superview
            while let view = ancestor {
                if let rowView = view as? NSTableRowView { return rowView }
                ancestor = view.superview
            }
            return nil
        }

        private func observeRows(_ table: NSTableView, clip: NSClipView) {
            guard styledTable !== table || styledClip !== clip else { return }
            stopObservingRows()
            styledTable = table
            styledClip = clip
            tablePostedFrameChanges = table.postsFrameChangedNotifications
            clipPostedBoundsChanges = clip.postsBoundsChangedNotifications
            table.postsFrameChangedNotifications = true
            clip.postsBoundsChangedNotifications = true
            for (name, view) in [(NSView.frameDidChangeNotification, table as NSView),
                                 (NSView.boundsDidChangeNotification, clip as NSView),
                                 (NSTableView.selectionDidChangeNotification, table as NSView)] {
                rowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRowBackgrounds() } })
            }
        }

        func stopObservingRows() {
            rowObservers.forEach(NotificationCenter.default.removeObserver)
            rowObservers.removeAll()
            styledTable?.postsFrameChangedNotifications = tablePostedFrameChanges
            styledClip?.postsBoundsChangedNotifications = clipPostedBoundsChanges
            styledTable = nil
            styledClip = nil
        }

        func deactivateRowStyling() {
            rowStylingActive = false
            stopObservingRows()
        }

        private func rowDescendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(rowDescendants)
        }
    }

    func makeNSView(context _: Context) -> RowBackgroundView { RowBackgroundView() }

    func updateNSView(_ view: RowBackgroundView, context _: Context) {
        view.tableIdentifier = tableIdentifier
        view.stylesRowOnly = stylesRowOnly
        view.scheduleRowBackgrounds()
    }

    static func dismantleNSView(_ view: RowBackgroundView, coordinator _: ()) { view.deactivateRowStyling() }
}
