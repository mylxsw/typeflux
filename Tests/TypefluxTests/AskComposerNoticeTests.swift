import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer notices")
@MainActor
struct AskComposerNoticeTests {
    @Test func noticesAreOrderedMostUrgentFirst() {
        let notices = AskComposerNotice.resolve(sendError: "send", voiceError: "voice",
                                                attachment: "file", screenshot: "shot")
        #expect(notices.map(\.kind) == [.sendError, .voice, .attachment, .screenshot])
        #expect(notices.map(\.text) == ["send", "voice", "file", "shot"])
    }

    @Test func emptyAndMissingNoticesAreSkipped() {
        #expect(AskComposerNotice.resolve(sendError: nil, voiceError: nil, attachment: nil, screenshot: nil).isEmpty)
        let notices = AskComposerNotice.resolve(sendError: "  ", voiceError: nil, attachment: "\n", screenshot: "shot")
        #expect(notices.map(\.kind) == [.screenshot])
    }

    @Test func noticeToneAndSymbolFollowTheirKind() {
        let notices = AskComposerNotice.resolve(sendError: "a", voiceError: "b", attachment: "c", screenshot: "d")
        #expect(notices.map(\.tone) == [.warning, .warning, .warning, .info])
        #expect(notices.map(\.systemImage) == [nil, "mic.slash", "paperclip", nil])
        #expect(notices.first?.id == .sendError)
    }

    @Test func onlyOneRowShowsUntilExpanded() {
        #expect(AskComposerNotice.visibleCount(total: 0, expanded: false) == 0)
        #expect(AskComposerNotice.visibleCount(total: 0, expanded: true) == 0)
        #expect(AskComposerNotice.visibleCount(total: 1, expanded: false) == 1)
        #expect(AskComposerNotice.visibleCount(total: 3, expanded: false) == 1)
        #expect(AskComposerNotice.visibleCount(total: 3, expanded: true) == 3)
    }

    @Test func nothingSitsUnderTheComposer() {
        // The keyboard hint row is gone; the card keeps a plain bottom inset.
        #expect(AskMetrics.composerBottomInset == 22)
        #expect(L("ask.notice.more", 2).contains("2"))
        #expect(L("ask.notice.less") != "ask.notice.less")
    }

    @Test func confirmationsDefaultToAShortNote() async throws {
        let fixture = try AskTestFixture()
        fixture.model.confirm("Switched")
        #expect(fixture.model.commandFeedback == "Switched")
        // A newer confirmation replaces the older one, and the older timer leaves it alone.
        fixture.model.confirm("Copied", for: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.model.commandFeedback == "Copied")
        for _ in 0 ..< 100 where fixture.model.commandFeedback != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fixture.model.commandFeedback == nil)
    }

    @Test func noticeViewsRender() async throws {
        _ = NSApplication.shared
        var expanded = false
        var dismissed: [AskComposerNotice.Kind] = []
        let notices = AskComposerNotice.resolve(sendError: nil, voiceError: "Microphone is off",
                                                attachment: "video.mov is not supported", screenshot: nil)
        let view = VStack(spacing: 12) {
            AskComposerNoticeStack(notices: notices, expanded: Binding(get: { expanded }, set: { expanded = $0 }),
                                   dismiss: { kind in { dismissed.append(kind) } })
            AskComposerNoticeStack(notices: notices, expanded: .constant(true), dismiss: { _ in nil })
            AskComposerFootnote(text: "Switched to coding/auto")
            AskSystemLine(text: "Switched to a vision model", systemImage: "eye", actionTitle: "Undo",
                          action: {}, onDismiss: {})
            AskBanner(text: "Notice", more: "+1 more", onMore: {})
        }
        .frame(width: 680)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        #expect(hosting.fittingSize.height > 100)
        #expect(dismissed.isEmpty)
    }
}

@Suite("Ask launcher notices", .serialized)
@MainActor
struct AskLauncherNoticeLayoutTests {
    @Test func confirmationsKeepTheHeightAndNoticesAddOneRow() async throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture()
        var reported: CGFloat = 0
        let size = NSSize(width: AskMetrics.launcherWidth, height: 200)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AskLauncherView(
            model: fixture.model, onDismiss: {}, onHeightChange: { reported = $0 }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }

        func settle(until done: () -> Bool) async throws {
            for _ in 0 ..< 100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        }

        // Typed text hides the suggestions, so only notices change the height.
        fixture.model.launcherDraft.text = "Question"
        let resting = AskMetrics.launcherHeight(editor: 32, banners: 0)
        try await settle { abs(reported - resting) <= 4 }
        #expect(abs(reported - resting) <= 4)

        // A confirmation rides in the footer: the panel keeps its height.
        fixture.model.commandFeedback = "Switched to coding/auto"
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(reported - resting) <= 4)
        fixture.model.commandFeedback = nil

        // A notice adds one row inside the card.
        fixture.model.launcherScreenshotNotice = "Screenshot removed"
        let oneRow = AskMetrics.launcherHeight(editor: 32, banners: 1)
        try await settle { abs(reported - oneRow) <= 4 }
        #expect(abs(reported - oneRow) <= 4)

        // A second notice is counted on the first row instead of stacking.
        fixture.model.launcherAttachmentNotice = "video.mov is not supported"
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(reported - oneRow) <= 4)

        fixture.model.launcherScreenshotNotice = nil
        fixture.model.launcherAttachmentNotice = nil
        try await settle { abs(reported - resting) <= 4 }
        #expect(abs(reported - resting) <= 4)
    }
}
