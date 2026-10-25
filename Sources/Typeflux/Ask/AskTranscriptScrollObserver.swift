import AppKit
import SwiftUI

/// Only native user scrolling changes reading intent; layout and streamed text do not.
struct AskTranscriptScrollObserver: NSViewRepresentable {
    var onScroll: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
        view.attach()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.detach()
    }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void = { _ in }
        private weak var observedScroll: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let scroll = enclosingScrollView, observedScroll !== scroll else { return }
            detach()
            observedScroll = scroll
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            observedScroll = nil
        }

        @objc private func started() { onScroll(false) }

        @objc private func scrolled() {
            guard let scroll = observedScroll, let document = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            onScroll(Self.isAtBottom(distance: distance))
        }

        static func isAtBottom(distance: CGFloat) -> Bool {
            // Allow the transcript’s eight-point footer, fractional pixels and elastic overscroll.
            distance <= 12
        }
    }
}

struct AskTranscriptBottomButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TFColors.textPrimary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(TFColors.textPrimary.opacity(hovering ? 0.20 : 0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.08), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("ask.quickAsk.bottom"))
        .accessibilityLabel(L("ask.quickAsk.bottom"))
        .accessibilityIdentifier("ask.transcript.scrollToBottom")
    }
}
