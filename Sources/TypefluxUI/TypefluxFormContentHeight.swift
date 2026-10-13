import AppKit
import SwiftUI

/// Bounded sheet forms fit their document and use the system's scrollbar policy when they overflow.
struct TypefluxFormContentHeight: NSViewRepresentable {
    @Binding var height: CGFloat?

    final class FormMeasurementView: NSView {
        var documentReport: ((CGFloat) -> Void)?
        private weak var formScrollView: NSScrollView?
        private weak var formDocument: NSView?
        private var formFrameObservers: [NSObjectProtocol] = []
        private var documentPostedFrameChanges = false
        private var scrollPostedFrameChanges = false
        private var measurementScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMeasuringForm()
            scheduleFormMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleFormMeasurement()
        }

        func scheduleFormMeasurement() {
            guard !measurementScheduled else { return }
            measurementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measurementScheduled = false
                guard window != nil, let scroll = enclosingFormScroll(),
                      let document = scroll.documentView else { return }
                observeForm(scroll: scroll, document: document)
                if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
                if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
                let fittingHeight = document.fittingSize.height
                let documentHeight = fittingHeight > 0 ? fittingHeight : document.bounds.height
                let chromeHeight = max(0, scroll.frame.height - scroll.contentView.frame.height)
                let measured = ceil(documentHeight + chromeHeight
                    + max(0, scroll.contentInsets.top) + max(0, scroll.contentInsets.bottom))
                if measured.isFinite, measured > 0 { documentReport?(measured) }
            }
        }

        private func enclosingFormScroll() -> NSScrollView? {
            var ancestor = superview
            while let view = ancestor {
                // Exclude nested TextEditors; their document must never size the whole form.
                let candidates = formDescendants(view).compactMap { $0 as? NSScrollView }.filter { scroll in
                    scroll.window === window && scroll.documentView != nil && !(scroll.documentView is NSTextView)
                        && convert(scroll.bounds, from: scroll).contains(NSPoint.zero)
                }
                // Prefer the outer form over nested lists under the same background's anchor.
                if let scroll = candidates.max(by: {
                    $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
                }) { return scroll }
                ancestor = view.superview
            }
            return nil
        }

        private func observeForm(scroll: NSScrollView, document: NSView) {
            guard formScrollView !== scroll || formDocument !== document else { return }
            stopMeasuringForm()
            formScrollView = scroll
            formDocument = document
            documentPostedFrameChanges = document.postsFrameChangedNotifications
            scrollPostedFrameChanges = scroll.postsFrameChangedNotifications
            document.postsFrameChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            for view in [document, scroll] {
                formFrameObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleFormMeasurement() } })
            }
        }

        func stopMeasuringForm() {
            formFrameObservers.forEach(NotificationCenter.default.removeObserver)
            formFrameObservers.removeAll()
            formDocument?.postsFrameChangedNotifications = documentPostedFrameChanges
            formScrollView?.postsFrameChangedNotifications = scrollPostedFrameChanges
            formDocument = nil
            formScrollView = nil
        }

        private func formDescendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(formDescendants)
        }
    }

    func makeNSView(context _: Context) -> FormMeasurementView { FormMeasurementView() }

    func updateNSView(_ view: FormMeasurementView, context _: Context) {
        view.documentReport = { measured in
            if abs((height ?? 0) - measured) > 0.5 { height = measured }
        }
        view.scheduleFormMeasurement()
    }

    static func dismantleNSView(_ view: FormMeasurementView, coordinator _: ()) {
        view.documentReport = nil
        view.stopMeasuringForm()
    }
}
