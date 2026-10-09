import Foundation
import Testing
@testable import Typeflux

@Suite("Ask captured content inventory", .exclusiveUIState)
@MainActor
struct AskCapturedContentItemsTests {
    @Test func sourceAndSelectionMatchTheirIndependentOutgoingFields() throws {
        var draft = AskDraft(includeScreenshot: false, selection: "First line\nSecond line",
                             source: "Safari — A page title", sourceBundleID: "com.apple.Safari")
        let items = AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off)
        #expect(items.map(\.kind) == [.source, .selection])
        let source = try #require(items.first)
        #expect(source.title == "Safari")
        #expect(source.detail == "A page title")
        #expect(source.appBundleID == "com.apple.Safari")
        #expect(source.removable)
        let selection = items[1]
        #expect(selection.title == "“First line Second line”")
        #expect(selection.badge == .count(2))
        #expect(selection.detail == draft.selection)
        #expect(selection.sourceAppName == "Safari")
        draft.sourceOff = true
        #expect(draft.request(deviceId: "device", tools: []).source == nil)
        let selectionOnly = AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off)
        #expect(selectionOnly.map(\.kind) == [.selection])
        #expect(selectionOnly[0].sourceAppName == "Safari", "Capture provenance survives metadata removal")
        draft.selectionOff = true
        #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off).isEmpty)
        draft.sourceOff = nil
        #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off).map(\.kind) == [.source])
    }

    @Test func missingSourceAndMemoryDoNotCreateAnInventoryEntry() {
        for source in [nil, "", "  \n"] as [String?] {
            let draft = AskDraft(includeScreenshot: false, source: source, memory: AskMemory(global: "A preference"))
            #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off).isEmpty)
        }
        let appOnly = AskAttachmentStrip.contentItems(draft: AskDraft(includeScreenshot: false, source: "Finder"),
                                                      screenshotState: .off)
        #expect(appOnly.first?.title == "Finder")
        #expect(appOnly.first?.detail == nil)
        let selectionOnly = AskAttachmentStrip.contentItems(draft: AskDraft(includeScreenshot: false, selection: "Words"),
                                                            screenshotState: .off)
        #expect(selectionOnly.first?.sourceAppName == nil)
        #expect(selectionOnly.first?.sourceAppBundleID == nil)
    }

    @Test func screenshotAppearsOnlyWhenCapturedOrItsPendingStateIsVisible() throws {
        var draft = AskDraft(includeScreenshot: true)
        #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached).isEmpty)
        let pending = try #require(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached,
                                                                  capturing: true).first)
        #expect(pending.kind == .screenshot)
        #expect(pending.title == L("ask.context.screen.capturing"))
        #expect(pending.style == .neutral)
        #expect(pending.removable)
        draft.screenshot = "data:image/png;base64,screen"
        let ready = try #require(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached).first)
        #expect(ready.title == L("ask.context.screen.full"))
        #expect(ready.detail == L("ask.context.screen.scope"))
        #expect(ready.removable)
        #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .off).isEmpty)
        draft.includeScreenshot = false
        #expect(AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached, capturing: true).isEmpty)
    }

    @Test(arguments: [true, false])
    func captureFailureShowsTheRecoveryActionAtTheMissingScreenshot(_ permission: Bool) throws {
        let draft = AskDraft(includeScreenshot: true, source: "Safari")
        let state = AskScreenshotState.failed(permission: permission, message: "Capture failed")
        let items = AskAttachmentStrip.contentItems(draft: draft, screenshotState: state)
        #expect(items.map(\.kind) == [.source, .screenshot])
        let failure = try #require(items.last)
        #expect(failure.style == .warning)
        #expect(failure.title == L("ask.context.screen.failed"))
        #expect(failure.detail == "Capture failed")
        #expect(failure.hint == L(permission ? "ask.context.screen.grant" : "ask.context.screen.retry"))
        #expect(failure.removable)
        #expect(draft.request(deviceId: "device", tools: []).image == nil)
        let retrying = AskAttachmentStrip.contentItems(draft: draft, screenshotState: state, capturing: true)
        #expect(retrying.last?.title == L("ask.context.screen.capturing"))
        #expect(retrying.last?.hint == nil)
    }

    @Test func unsupportedScreenshotIsClearlyExcludedAndCanBeRemoved() throws {
        let draft = AskDraft(includeScreenshot: true)
        let items = AskAttachmentStrip.contentItems(draft: draft, screenshotState: .unavailable(reason: "Text-only model"))
        let item = try #require(items.first)
        #expect(item.style == .unavailable)
        #expect(item.title == L("ask.context.screen.failed"))
        #expect(item.detail == "Text-only model")
        #expect(item.hint == nil)
        #expect(item.removable)
    }

    @Test func wrappingInventoryKeepsLongItemsInsideNarrowWidths() {
        for width: CGFloat in [200, 406, 456, 656] {
            let rows = AskFlowLayout.rows(sizes: [CGSize(width: 560, height: 30), CGSize(width: 320, height: 30),
                                                  CGSize(width: 160, height: 30), CGSize(width: 200, height: 30)],
                                         maxWidth: width, spacing: 6)
            #expect(rows.flatMap(\.indices) == [0, 1, 2, 3])
            #expect(rows.allSatisfy { $0.width <= width })
            #expect(AskFlowLayout.height(of: rows, spacing: 6) == CGFloat(rows.count * 36 - 6))
        }
    }
}
