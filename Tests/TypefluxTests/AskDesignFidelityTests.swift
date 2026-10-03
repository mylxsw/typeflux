import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The design-board details of the Liquid Glass workspace that are decided by
/// pure logic: geometry, labels, ordering and drawing helpers.
@Suite("Ask design fidelity")
struct AskDesignFidelityTests {
    // MARK: - Window and glass

    @Test func windowIsFrostedGlassOverTheDesktop() {
        // The desktop shows through as a soft cast; the window keeps its own tint.
        for dark in [true, false] {
            let tint = AskWindowBackdrop.tintOpacity(dark: dark, reduceTransparency: false)
            #expect(tint > 0.6 && tint < 0.9)
            #expect(AskWindowBackdrop.tintOpacity(dark: dark, reduceTransparency: true) == 1)
        }
        #expect(AskWindowBackdrop.base(dark: true) != AskWindowBackdrop.base(dark: false))
    }

    @Test func designMetricsMatchTheBoard() {
        #expect(AskMetrics.sidebarWidth == 264)
        #expect(AskMetrics.headerCapsuleHeight == 38)
        #expect(AskMetrics.transcriptMaxWidth == 720)
        #expect(AskMetrics.composerMaxWidth == 760)
        #expect(AskMetrics.composerControlHeight == 34)
        #expect(AskSendButton.size == 36)
        #expect(AskMetrics.suggestionsMaxWidth == 680)
        let workspace = AskComposerChrome.workspace
        #expect(workspace.corner == 28)
        #expect(workspace.footerHeight == 48)
        #expect(workspace.fill == AskTheme.glassFill)
    }

    // MARK: - Transcript

    @Test func headingSizesFollowTheBoard() {
        #expect(AskMarkdownText.headingFont(level: 1).pointSize == 20)
        #expect(AskMarkdownText.headingFont(level: 2).pointSize == 17)
        #expect(AskMarkdownText.headingFont(level: 3).pointSize == 15.5)
        #expect(AskMarkdownText.headingFont(level: 4).pointSize == AskMarkdownText.bodySize)
        #expect(AskMarkdownText.headingFont(level: 6).pointSize == AskMarkdownText.bodySize)
    }

    @Test func bodyListsAndCodeUseTheBoardTypography() throws {
        let value = AskMarkdownText.render("Intro\n\n- one\n- two\n\nUse `code` here\n\n```\nlet a = 1\n```")
        let intro = try #require(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(intro.pointSize == AskMarkdownText.bodySize)
        let item = (value.string as NSString).range(of: "one")
        let style = try #require(value.attribute(.paragraphStyle, at: item.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent == AskMarkdownText.listIndent)
        #expect(style.tabStops.first?.location == AskMarkdownText.listIndent)
        #expect(value.string.contains("•\tone"))
        let code = (value.string as NSString).range(of: "code")
        #expect(value.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor == AskMarkdownText.codeFill)
        let block = (value.string as NSString).range(of: "let a = 1")
        let blockStyle = try #require(value.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(blockStyle.textBlocks.first is AskCodeBlock)
        // The last list item keeps the body's paragraph gap before the next paragraph.
        let two = (value.string as NSString).range(of: "two")
        let twoStyle = try #require(value.attribute(.paragraphStyle, at: two.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(twoStyle.paragraphSpacing == AskMarkdownText.paragraphSpacing)
    }

    @Test func twoColumnTablesGiveTheKeyColumnAThird() {
        #expect(AskMarkdownTable.columnWidth(column: 0, count: 2) == 34)
        #expect(AskMarkdownTable.columnWidth(column: 1, count: 2) == 66)
        #expect(AskMarkdownTable.columnWidth(column: 2, count: 4) == 25)
        #expect(AskMarkdownTable.columnWidth(column: 0, count: 0) == 100)
    }

    @Test func tableCellsOnlyRoundTheTablesOuterCorners() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 40)
        let corner = AskTableCellBlock.Edges(top: true, bottom: false, left: true, right: false)
        let inner = AskTableCellBlock.Edges(top: false, bottom: false, left: false, right: false)
        let cornerPath = AskTableCellBlock.outline(rect, edges: corner, radius: 12)
        let innerPath = AskTableCellBlock.outline(rect, edges: inner, radius: 12)
        // The rounded top-left corner leaves its very corner outside the outline.
        #expect(!cornerPath.contains(NSPoint(x: 0.5, y: 0.5)))
        #expect(innerPath.contains(NSPoint(x: 0.5, y: 0.5)))
        #expect(cornerPath.contains(NSPoint(x: 99.5, y: 39.5)))
        // An inner cell strokes only the rule under its row.
        let strokes = AskTableCellBlock.strokes(rect, edges: inner, radius: 12)
        #expect(strokes.bounds.height < 1)
        let outer = AskTableCellBlock.strokes(rect, edges: .init(top: true, bottom: true, left: true, right: true), radius: 12)
        #expect(outer.bounds.width >= 99 && outer.bounds.height >= 39)
    }

    @Test func tableEdgesComeFromTheCellsPosition() {
        let table = AskTextTable()
        table.rowCount = 3
        table.numberOfColumns = 2
        let first = AskTableCellBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        let last = AskTableCellBlock(table: table, startingRow: 2, rowSpan: 1, startingColumn: 1, columnSpan: 1)
        #expect(first.edges == .init(top: true, bottom: false, left: true, right: false))
        #expect(last.edges == .init(top: false, bottom: true, left: false, right: true))
    }

    @Test func inlineCodeChipsHugTheirGlyphsOnEachLine() {
        let lines = [NSRect(x: 0, y: 0, width: 400, height: 20), NSRect(x: 0, y: 24, width: 400, height: 20)]
        let glyphs = [NSRect(x: 200, y: 2, width: 180, height: 16), NSRect(x: 0, y: 26, width: 60, height: 16)]
        let chips = AskRoundedBackgroundLayoutManager.chipRects(rects: lines, glyphs: glyphs)
        #expect(chips[0].minX == 197 && chips[0].width == 186)
        #expect(chips[1].minX == -3 && chips[1].width == 66)
        #expect(chips[0].minY == 1 && chips[0].height == 18)
        // With no glyph on a line, the run's own rect is used.
        let fallback = AskRoundedBackgroundLayoutManager.chipRects(rects: [lines[0]], glyphs: [])
        #expect(fallback[0].width == 406)
    }

    // MARK: - Composer, header and sidebar

    @Test func contextRingNeverShowsZeroForAStartedConversation() {
        #expect(AskContextUsageButton.percentText(nil) == "—")
        #expect(AskContextUsageButton.percentText(0) == "0%")
        #expect(AskContextUsageButton.percentText(0.0098) == "1%")
        #expect(AskContextUsageButton.percentText(0.426) == "43%")
        #expect(AskContextUsageButton.percentText(2) == "100%")
    }

    @Test func avatarInitials() {
        #expect(AskAvatar.initials("Demir Von") == "DV")
        #expect(AskAvatar.initials("mylxsw") == "MY")
        #expect(AskAvatar.initials("ana.li") == "AL")
        #expect(AskAvatar.initials("") == "")
    }

    @Test func composerHintNamesTheVoiceKey() {
        #expect(AskComposerHint.text(voiceKey: "Fn").contains("Fn"))
        #expect(L("ask.launcher.hint") != "ask.launcher.hint")
    }

    @Test func pinnedMemoryChipNamesItsApp() {
        let memory = AskMemory(global: "g", app: .init(id: "com.google.Chrome", name: "Chrome", excerpts: ["x"]))
        let items = AskContextChips.items(screenshot: .off, source: nil, sourceBundleID: nil, selection: nil,
                                          memory: nil, memoryPinned: true, pinnedMemory: memory)
        let chip = items.first { $0.kind == .memory }
        #expect(chip?.title == memory.chipTitle)
        #expect(chip?.badge == .app("com.google.Chrome"))
        let plain = AskContextChips.items(screenshot: .off, source: nil, sourceBundleID: nil, selection: nil,
                                          memory: nil, memoryPinned: true)
        #expect(plain.first { $0.kind == .memory }?.title == L("ask.memory"))
    }

    @Test func modelCapabilitiesReadAsWords() {
        let both = RegisteredModel(id: "m", name: "M", vision: true, reasoning: true)
        #expect(AskModelCapabilities.badges(both).map(\.text) == [L("ask.models.badge.vision"), L("ask.models.badge.reasoning")])
        #expect(AskModelCapabilities.badges(RegisteredModel(id: "t", name: "T")).isEmpty)
    }

    // MARK: - Tool cards and approval

    @Test func toolStepsShowTheirToolTagAndDetail() {
        let call = AskToolCall(id: "c", type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        #expect(AskToolStepRow.tag(call) == "browser.read")
        let bare = AskToolCall(id: "b", type: "function", function: .init(name: "web_search", arguments: "{}"))
        #expect(AskToolStepRow.tag(bare) == "web_search")
        let result = AskMessage(id: "r", role: "tool", text: "First line\nsecond", createdAt: Date())
        #expect(AskToolStepRow.detail(call, result: result) == "First line")
        #expect(AskToolStepRow.detail(call, result: nil) == nil)
        let file = AskToolCall(id: "f", type: "function",
                               function: .init(name: "files", arguments: #"{"action":"read","path":"/tmp/a.txt"}"#))
        #expect(AskToolStepRow.detail(file, result: result) == "/tmp/a.txt")
    }

    @Test func approvalHighlightsAllowingForTheConversationExceptForDestructiveSteps() {
        #expect(AskApprovalCard.primaryIsConversation(risk: .write, canAllowForConversation: true))
        #expect(!AskApprovalCard.primaryIsConversation(risk: .write, canAllowForConversation: false))
        #expect(!AskApprovalCard.primaryIsConversation(risk: .destructive, canAllowForConversation: true))
        #expect(AskApprovalCard.panelTint(.destructive) == StudioTheme.danger)
        #expect(AskApprovalCard.panelTint(.read) == AskTheme.accent)
    }

    @Test @MainActor func approvalSitsInTheToolCardThatHoldsItsCall() {
        let call = AskToolCall(id: "click", type: "function", function: .init(name: "browser", arguments: "{}"))
        let message = AskMessage(id: "a", role: "assistant", text: "", toolCalls: [call], createdAt: Date())
        let items = [AskTranscriptItem(kind: .activity(AskActivityGroup(id: "a", messages: [message])))]
        #expect(AskConversationView.groupContains(items, callId: "click"))
        #expect(!AskConversationView.groupContains(items, callId: "other"))
        #expect(!AskConversationView.groupContains([], callId: "click"))
    }

    // MARK: - Launcher

    @Test func launcherSuggestionsWrapAndMatchTheEmptyState() {
        #expect(AskSuggestion.all.map(\.key) == ["ask.suggest.screen", "ask.suggest.selection", "ask.suggest.page"])
        #expect(AskSuggestion.all.filter(\.screenshot).map(\.key) == ["ask.suggest.screen"])
        #expect(AskSuggestion.all.allSatisfy { $0.title != $0.key && $0.caption != $0.key + ".caption" })
        #expect(AskSuggestion.step(0, by: -1) == 2)
        #expect(AskSuggestion.step(2, by: 1) == 0)
        #expect(AskSuggestion.step(1, by: 1) == 2)
        #expect(AskSuggestion.step(0, by: 1, count: 0) == 0)
        #expect(AskLauncherSuggestions.height > 3 * AskLauncherSuggestions.rowHeight)
    }
}
