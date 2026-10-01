import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask redesign presentation")
@MainActor
struct AskPresentationTests {
    @Test func accountNamePrefersProfileNameThenEmailLocalPart() {
        #expect(AskPresentation.accountName(name: " Ada ", email: "ada@example.com") == "Ada")
        #expect(AskPresentation.accountName(name: "  ", email: "ada@example.com") == "ada")
        #expect(AskPresentation.accountName(name: nil, email: "ada@example.com") == "ada")
        #expect(AskPresentation.accountName(name: nil, email: nil) == nil)
        #expect(AskPresentation.accountName(name: nil, email: "@example.com") == nil)
    }

    private func summary(_ title: String) -> AskConversationSummary {
        AskConversationSummary(id: UUID().uuidString, title: title, updatedAt: Date())
    }

    @Test func historySearchMatchesTitlesCaseInsensitively() {
        let items = [summary("Swift concurrency"), summary("会议纪要整理"), summary("Screen error")]
        #expect(AskPresentation.filterHistory(items, query: "  ").count == 3)
        #expect(AskPresentation.filterHistory(items, query: "swift").map(\.title) == ["Swift concurrency"])
        #expect(AskPresentation.filterHistory(items, query: "纪要").map(\.title) == ["会议纪要整理"])
        #expect(AskPresentation.filterHistory(items, query: "nothing").isEmpty)
    }

    @Test func selectionChipCountsVisibleLines() {
        #expect(AskPresentation.lineCount("") == 0)
        #expect(AskPresentation.lineCount("one") == 1)
        #expect(AskPresentation.lineCount("one\ntwo\nthree") == 3)
        // A trailing newline still ends a line the user can see.
        #expect(AskPresentation.lineCount("one\n") == 2)
    }

    @Test func toolStateFollowsTheToolResult() {
        let pending: AskMessage? = nil
        let ok = AskMessage(id: "1", role: "tool", text: "done", isError: false, createdAt: Date())
        let bad = AskMessage(id: "2", role: "tool", text: "boom", isError: true, createdAt: Date())
        #expect(AskPresentation.toolState(result: pending) == .running)
        #expect(AskPresentation.toolState(result: ok) == .done)
        #expect(AskPresentation.toolState(result: bad) == .failed)
        #expect(AskPresentation.toolStatusText(result: pending) == L("ask.tool.running"))
        #expect(AskPresentation.toolStatusText(result: ok) == L("ask.tool.done"))
        #expect(AskPresentation.toolStatusText(result: bad) == L("ask.tool.failed"))
        #expect(AskActivityState.failed.needsAttention)
        #expect(AskActivityState.attention.needsAttention)
        #expect(!AskActivityState.running.needsAttention)
        #expect(!AskActivityState.done.needsAttention)
    }

    @Test func toolSymbolsCoverDesktopBrowserAndMCP() {
        func call(_ name: String) -> AskToolCall {
            AskToolCall(id: name, type: "function", function: .init(name: name, arguments: "{}"))
        }
        #expect(AskPresentation.toolSymbol(call("computer")) == "desktopcomputer")
        #expect(AskPresentation.toolSymbol(call("browser")) == "globe")
        #expect(AskPresentation.toolSymbol(call("search_files")) == "wrench.and.screwdriver")
    }

    @Test func quotingAppendsWithoutLosingAnUnfinishedDraft() {
        let quoted = AskPresentation.quote(existing: "", quoting: "first\nsecond")
        #expect(quoted == "> first\n> second\n\n")
        let appended = AskPresentation.quote(existing: "my question", quoting: "answer")
        #expect(appended.hasPrefix("my question\n\n> answer"))
        let clipped = AskPresentation.quote(existing: "", quoting: (1...10).map(String.init).joined(separator: "\n"), limit: 3)
        #expect(clipped == "> 1\n> 2\n> 3\n> …\n\n")
    }

    @Test func launcherHeightIsTheComposerCardPlusItsGutter() {
        let resting = AskMetrics.launcherHeight(editor: 32, banners: 0)
        // 32 editor + 14 + 2 insets + 52 footer + 6 gutter on each side.
        #expect(resting == 112)
        #expect(AskMetrics.launcherHeight(editor: 148, banners: 0) == 228)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1) == resting + 38)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 2) == resting + 76)
    }

    @Test func focusAloneKeepsTheNeutralBorder() {
        #expect(AskVoiceBorder.borderColor(listening: false) == AskTheme.border)
        #expect(AskVoiceBorder.borderWidth(listening: false) == 1)
        // Recording is unmistakable: a full-strength accent edge, thicker, plus a halo.
        #expect(AskVoiceBorder.borderColor(listening: true) == AskTheme.accent)
        #expect(AskVoiceBorder.borderWidth(listening: true) > AskVoiceBorder.borderWidth(listening: false))
        #expect(AskVoiceBorder.haloWidth > 0)
    }

    @Test func waveformBarsStayInsideTheMeter() {
        for index in 0..<11 {
            for step in 0..<12 {
                let height = AskWaveform.height(index: index, phase: Double(step) * 0.12)
                #expect(height >= 4)
                #expect(height <= 14)
            }
        }
    }
}

@Suite("Ask redesign layout", .serialized)
@MainActor
struct AskRedesignLayoutTests {
    @Test func launcherPanelReportsTheRedesignedHeight() async throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture()
        var reported: CGFloat = 0
        let size = NSSize(width: AskMetrics.launcherWidth, height: 114)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AskLauncherView(
            model: fixture.model, onDismiss: {}, onHeightChange: { reported = $0 }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reported >= 110)
        #expect(reported <= 120)
        fixture.model.launcherDraft.text = String(repeating: "Line of text\n", count: 30)
        try await Task.sleep(for: .milliseconds(350))
        #expect(reported >= 200)
        #expect(reported <= AskMetrics.launcherHeight(editor: 148, banners: 0))
        fixture.model.resetSession()
    }

    @Test func workspaceKeepsTheWiderSidebarDistinctFromTheTranscript() async throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try await render(AskConversationView(model: fixture.model),
                                          size: NSSize(width: 1100, height: 740), appearance: appearance)
            let sidebar = try pixel(bitmap, x: 240, y: 400)
            let transcript = try pixel(bitmap, x: 300, y: 400)
            #expect(sidebar.alphaComponent > 0.999)
            #expect(transcript.alphaComponent > 0.999)
            let delta = abs(sidebar.redComponent - transcript.redComponent)
                + abs(sidebar.greenComponent - transcript.greenComponent)
                + abs(sidebar.blueComponent - transcript.blueComponent)
            #expect(delta > 0.01)
        }
        fixture.model.resetSession()
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}

@Suite("Ask redesign fidelity helpers")
@MainActor
struct AskRedesignFidelityTests {
    @Test func referenceStripShowsUpToThreeQuotesThenScrolls() {
        let chip = AskReferenceStrip.chipHeight
        let gap = AskReferenceStrip.chipSpacing
        #expect(AskReferenceStrip.stripHeight(count: 0) == 0)
        #expect(AskReferenceStrip.stripHeight(count: 1) == chip)
        #expect(AskReferenceStrip.stripHeight(count: 2) == chip * 2 + gap)
        #expect(AskReferenceStrip.stripHeight(count: 3) == chip * 3 + gap * 2)
        // Past three the strip stops growing and scrolls instead.
        #expect(AskReferenceStrip.stripHeight(count: 8) == AskReferenceStrip.stripHeight(count: 3))
        #expect(AskReferenceStrip.stripHeight(count: -1) == 0)
    }

    @Test func transcriptAndComposerShareOneCentredColumn() {
        #expect(AskMetrics.composerMaxWidth == AskMetrics.columnWidth)
        #expect(AskMetrics.transcriptMaxWidth == AskMetrics.columnWidth - AskMetrics.columnInset * 2)
        #expect(AskMetrics.bubbleMaxWidth < AskMetrics.transcriptMaxWidth)
    }

    @Test func bubbleShapeKeepsItsTailCornerTight() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 60)
        let path = AskBubbleShape().path(in: rect)
        #expect(path.boundingRect.insetBy(dx: -0.5, dy: -0.5).contains(rect.insetBy(dx: 0.5, dy: 0.5)))
        // A 16pt corner leaves the top-right point outside the shape; the 5pt
        // tail corner keeps a point 3pt from the bottom-right corner inside.
        #expect(!path.contains(CGPoint(x: 199, y: 1)))
        #expect(path.contains(CGPoint(x: 197, y: 57)))
        let inset = AskBubbleShape().inset(by: 4).path(in: rect)
        #expect(inset.boundingRect.minX >= 3.5)
        #expect(inset.boundingRect.maxX <= 196.5)
        // Radii never exceed half the shortest side.
        let tiny = AskBubbleShape(radius: 40, tail: 50).path(in: CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(!tiny.isEmpty)
    }
}

@Suite("Ask design polish helpers")
@MainActor
struct AskDesignPolishTests {
    @Test func multiplierBadgeUsesTheTimesSignAndATone() {
        #expect(AskMultiplierBadge.text("5") == "5×")
        #expect(AskMultiplierBadge.text("1") == "1×")
        #expect(AskMultiplierBadge.text("0.5") == "0.5×")
        // Anything the pricing label rejects shows no badge at all.
        #expect(AskMultiplierBadge.text("abc") == nil)
        #expect(AskMultiplierBadge.text("0") == nil)
        #expect(AskMultiplierBadge.tone("1") == StudioTheme.success)
        #expect(AskMultiplierBadge.tone("0.5") == StudioTheme.success)
        #expect(AskMultiplierBadge.tone("5") == StudioTheme.warning)
        #expect(AskMultiplierBadge.tone("abc") == StudioTheme.textSecondary)
    }

    @Test func lineGlyphsFollowTheDesignPathsAndScale() {
        #expect(AskLineGlyph.polylines(.usage).count == 4)
        #expect(AskLineGlyph.polylines(.trash).count == 3)
        for kind in [AskLineGlyph.Kind.usage, .trash] {
            let points = AskLineGlyph.polylines(kind).flatMap { $0 }
            #expect(points.allSatisfy { (0...24).contains($0.x) && (0...24).contains($0.y) })
            let path = AskLineGlyph(kind: kind).path(in: CGRect(x: 0, y: 0, width: 48, height: 48))
            #expect(!path.isEmpty)
            // Scaled by two and never outside the frame.
            #expect(path.boundingRect.maxX <= 48 && path.boundingRect.maxY <= 48)
            #expect(path.boundingRect.width >= 30)
        }
        // A non-square frame keeps the glyph square and centred.
        let wide = AskLineGlyph(kind: .usage).path(in: CGRect(x: 0, y: 0, width: 100, height: 24))
        #expect(abs(wide.boundingRect.midX - 50) < 1)
    }

    @Test func modelCaptionUsesCompactCounts() {
        var model = RegisteredModel(id: "m", name: "Model")
        #expect(AskModelChoices.caption(model) == nil)
        model.contextWindowTokens = 204_800
        #expect(AskModelChoices.caption(model) == nil)
        model.maxOutputTokens = 16_384
        let caption = AskModelChoices.caption(model) ?? ""
        #expect(caption.contains(AccountUsageDisplayFormatter.count(204_800)))
        #expect(caption.contains(AccountUsageDisplayFormatter.count(16_384)))
        #expect(!caption.contains("204800"))
    }

    @Test func everyReasoningLevelHasItsOwnCaption() {
        let captions = AskReasoningEffort.allCases.map(\.caption)
        #expect(captions.allSatisfy { !$0.isEmpty && !$0.hasPrefix("ask.") })
        #expect(Set(captions).count == captions.count)
    }

    @Test func designSurfacesAreDistinctFromEachOther() {
        // The composer card must not blend into the popover or panel cards.
        #expect(AskTheme.composerSurface != AskTheme.popoverSurface)
        #expect(AskTheme.panelCard != AskTheme.segmentTrack)
        #expect(AskTheme.primaryAction != AskTheme.accent)
    }
}
