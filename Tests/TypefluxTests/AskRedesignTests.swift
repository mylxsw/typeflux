import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask redesign presentation")
@MainActor
struct AskPresentationTests {
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

    @Test func launcherHeightIsTheTwoLayerCardPlusItsGlowGutter() {
        let resting = AskMetrics.launcherHeight(editor: 32, banners: 0)
        #expect(resting == 114)
        #expect(AskMetrics.launcherHeight(editor: 148, banners: 0) == 230)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1) == resting + 38)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 2) == resting + 76)
    }

    @Test func focusAloneKeepsTheNeutralBorder() {
        #expect(AskVoiceBorder.borderColor(listening: false, active: false) == AskTheme.border)
        #expect(AskVoiceBorder.borderColor(listening: true, active: true) == AskTheme.accent)
        #expect(AskVoiceBorder.borderColor(listening: false, active: true) != AskTheme.border)
        #expect(AskVoiceBorder.borderColor(listening: false, active: true) != AskTheme.accent)
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
