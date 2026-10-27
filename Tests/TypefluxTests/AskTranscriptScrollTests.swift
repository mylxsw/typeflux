import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Transcript user scrolling", .exclusiveUIState)
@MainActor
struct AskTranscriptScrollTests {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    @Test func onlyUserScrollingChangesFollowingIntent() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
        scroll.documentView = document
        let observer = AskTranscriptScrollObserver.ObserverView()
        document.addSubview(observer)
        var changes: [Bool] = []
        observer.onScroll = { changes.append($0) }
        observer.attach()
        observer.attach() // Re-rendering must not register duplicate listeners.
        defer { observer.detach() }
        let center = NotificationCenter.default
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        document.setFrameSize(NSSize(width: 600, height: 1400))
        #expect(changes.isEmpty)
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(changes == [false])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(changes == [false, false])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(changes == [false, false, true])
        observer.detach()
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(changes.count == 3)
        #expect(observer.hitTest(.zero) == nil)
    }

    @Test(arguments: [false, true], [200.0, 1200.0])
    func repeatedGesturesAtBottomNeverStopFollowing(flipped: Bool, height: Double) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let frame = NSRect(x: 0, y: 0, width: 600, height: height)
        let document = flipped ? Document(frame: frame) : NSView(frame: frame)
        scroll.documentView = document
        let observer = AskTranscriptScrollObserver.ObserverView()
        document.addSubview(observer)
        var changes: [Bool] = []
        observer.onScroll = { changes.append($0) }
        observer.attach()
        defer { observer.detach() }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? max(0, height - 400) : 0))

        for _ in 0..<5 {
            for name in [NSScrollView.willStartLiveScrollNotification,
                         NSScrollView.didLiveScrollNotification,
                         NSScrollView.didEndLiveScrollNotification] {
                NotificationCenter.default.post(name: name, object: scroll)
            }
        }
        #expect(changes.count == 15)
        #expect(changes.allSatisfy { $0 })
    }

    @Test func scrollingUpFromBottomStopsFollowingOnlyAfterLeavingBottom() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
        scroll.documentView = document
        let observer = AskTranscriptScrollObserver.ObserverView()
        document.addSubview(observer)
        var changes: [Bool] = []
        observer.onScroll = { changes.append($0) }
        observer.attach()
        defer { observer.detach() }
        let center = NotificationCenter.default
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(changes == [true])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(changes == [true, false])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(changes == [true, false, true])
    }

    @Test func bottomToleranceIncludesFooterButNotHistory() {
        for distance: CGFloat in [-30, 0, 8, 12] {
            #expect(AskTranscriptScrollObserver.ObserverView.isAtBottom(distance: distance))
        }
        #expect(!AskTranscriptScrollObserver.ObserverView.isAtBottom(distance: 13))
        #expect(!AskTranscriptScrollObserver.ObserverView.isAtBottom(distance: 200))
    }

    @Test func bottomButtonRendersInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: AskTranscriptBottomButton(action: {}))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width >= 36)
        }
    }
}
