import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer notices", .exclusiveUIState)
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

@Suite("Ask launcher notices", .serialized, .exclusiveUIState)
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

/// Renders the composer's notices: a failed run and a model switch in the
/// transcript, a notice row and a confirmation in the card. The PNGs land in
/// TYPEFLUX_ASK_SNAPSHOTS when it is set, otherwise in a temporary directory.
@Suite("Ask notice snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskNoticeVisualTests {
    private func snapshot(_ hosting: NSView, to url: URL) throws {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(png.count > 10000)
    }

    @Test func renderNotices() async throws {
        let keep = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"]
        let root = keep.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ask-notices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: root) } }
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let fixture = try await noticeFixture()
            defer { fixture.model.resetSession() }
            let workspace = AskConversationView(model: fixture.model).environment(\.askGlassMaterialOverride, .opaque)
            try await render(workspace, size: NSSize(width: 1100, height: 720), appearance: appearance,
                             to: root.appendingPathComponent("notices-workspace-\(name).png"))

            fixture.model.launcherDraft.text = "这段报错是什么意思？"
            fixture.model.error = "发送失败：Typeflux Cloud 暂时不可用"
            let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.askGlassMaterialOverride, .opaque)
            let panel = NSSize(width: AskMetrics.launcherWidth, height: 220)
            try await render(launcher, size: panel, appearance: appearance,
                             to: root.appendingPathComponent("notices-launcher-\(name).png"))
        }
    }

    /// A conversation whose last run failed, with a model switch, two notices and a confirmation.
    private func noticeFixture() async throws -> AskTestFixture {
        let fixture = try AskTestFixture()
        let now = Date()
        let messages: [AskMessage] = [
            .init(id: "q1", role: "user", text: "讲讲这一屏在做什么", createdAt: now),
            .init(id: "a1", role: "assistant", text: "这是 Typeflux 的「随便问」窗口。左侧是对话列表，中间是对话内容。", createdAt: now),
            .init(id: "q2", role: "user", text: "再帮我把它翻成英文", createdAt: now)
        ]
        let run = AskRun(id: "run", deviceId: "device", status: "failed", error: "回答中断：网络连接已断开",
                         steps: 1, updatedAt: now, tools: [], pending: [])
        let conversation = AskConversation(id: "notices", title: "讲讲这一屏在做什么", revision: 1, updatedAt: now,
                                           messages: messages, run: run)
        await fixture.api.seed(conversation)
        await fixture.model.refreshHistory()
        await fixture.model.select(conversation.id)
        fixture.model.visionSwitch = AskVisionSwitch(draftKey: "notices", from: "local:llama3.2",
                                                     to: "local:qwen2.5-vl")
        fixture.model.screenshotNotice = L("ask.image.detached")
        fixture.model.attachmentNotice = "video.mov 无法添加"
        fixture.model.commandFeedback = L("ask.command.modelChanged", "coding/auto")
        return fixture
    }

    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(800))
        try snapshot(hosting, to: url)
    }
}
