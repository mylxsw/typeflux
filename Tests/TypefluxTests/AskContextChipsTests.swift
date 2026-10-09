import Foundation
import Testing
@testable import Typeflux

@Suite("Ask context chips", .exclusiveUIState)
struct AskContextChipsTests {
    private func items(screenshot: AskScreenshotState = .off, source: String? = nil, bundle: String? = nil,
                       selection: String? = nil, selectionOff: Bool = false, memory: AskMemory? = nil,
                       memoryOff: Bool = false, pinned: Bool = false) -> [AskContextItem] {
        AskContextChips.items(screenshot: screenshot, source: source, sourceBundleID: bundle,
                              selection: selection, selectionOff: selectionOff, memory: memory,
                              memoryOff: memoryOff, memoryPinned: pinned)
    }

    @Test func sourceSplitsAppFromWindowTitle() {
        let parts = AskContextChips.sourceParts("Google Chrome — Multica — Project Management")
        #expect(parts.app == "Google Chrome")
        #expect(parts.window == "Multica — Project Management")
        #expect(AskContextChips.sourceParts("Finder").app == "Finder")
        #expect(AskContextChips.sourceParts("Finder").window == nil)
        #expect(AskContextChips.sourceParts("Finder — ").window == nil)
    }

    @Test func sourceIsSelectionProvenanceInsteadOfAStandaloneChip() throws {
        let all = items(source: "Google Chrome — Multica", bundle: "com.google.Chrome", selection: "Selected text")
        #expect(all.allSatisfy { $0.kind != .source })
        let selection = try #require(all.first { $0.kind == .selection })
        #expect(selection.sourceAppName == "Google Chrome")
        #expect(selection.sourceAppBundleID == "com.google.Chrome")
        #expect(selection.badge == .count(1))
        #expect(selection.detail == "“Selected text”")
        #expect(items(source: "Finder", bundle: "com.apple.finder").map(\.kind) == [.screenshot])
    }

    @Test func selectionProvenanceKeepsTheNameWhenTheAppIconIsUnavailable() throws {
        let selection = try #require(items(source: "Uninstalled app — Document", bundle: "test.missing.application",
                                           selection: "text").first { $0.kind == .selection })
        #expect(selection.sourceAppName == "Uninstalled app")
        #expect(selection.sourceAppBundleID == "test.missing.application")
        for source in [nil, "", "  \n"] as [String?] {
            let unknown = try #require(items(source: source, selection: "text").first { $0.kind == .selection })
            #expect(unknown.sourceAppName == nil)
            #expect(unknown.sourceAppBundleID == nil)
        }
        let noBundle = try #require(items(source: "Finder", selection: "text").first { $0.kind == .selection })
        #expect(noBundle.sourceAppName == "Finder")
        #expect(noBundle.sourceAppBundleID == nil)
        let off = try #require(items(source: "Finder", bundle: "com.apple.finder", selection: "text", selectionOff: true)
            .first { $0.kind == .selection })
        #expect(off.style == .neutral)
        #expect(off.sourceAppName == "Finder")
        #expect(off.sourceAppBundleID == "com.apple.finder")
    }

    @Test func appIconTileIsOpticallySmallerThanTheChipWithoutInnerMargin() {
        // Bright, opaque app tiles read larger than tinted chips, so they sit inset.
        #expect(AskContextChips.appTileSize < AskContextChips.chipSize)
        #expect(AskContextChips.appTileSize == 24)
        let side = AskContextChips.appIconSide(tile: AskContextChips.appTileSize)
        #expect(side == 30)
        // The visible tile (824 of 1024) still reaches the clip edge, so no inner gap remains.
        #expect(side * AskContextChips.appIconTileFraction >= AskContextChips.appTileSize)
        #expect(side * AskContextChips.appIconTileFraction < AskContextChips.appTileSize + 1)
        #expect(AskContextChips.appTileCorner < AskContextChips.appTileSize / 2)
        #expect(AskContextChips.appIconSide(tile: 0) == 0)
    }

    @Test func screenshotStatesMapToStylesAndActions() {
        let off = items(screenshot: .off)[0]
        #expect(off.style == .neutral && !off.removable && off.hint == L("ask.context.screenshot.offHint"))
        let attached = items(screenshot: .attached)[0]
        #expect(attached.style == .active && attached.removable && attached.title == L("ask.context.screenshot.attached"))
        let unavailable = items(screenshot: .unavailable(reason: "No vision"))[0]
        #expect(unavailable.style == .unavailable && unavailable.detail == "No vision" && unavailable.hint == nil)
        let permission = items(screenshot: .failed(permission: true, message: "Grant access"))[0]
        #expect(permission.style == .warning && permission.title == L("ask.capture.settings"))
        #expect(items(screenshot: .failed(permission: false, message: "x"))[0].title == L("ask.capture.retry"))
    }

    @Test func selectionShowsLineCountBadgeAndShortPreview() throws {
        let text = "line one\nline two\n" + String(repeating: "x", count: 100)
        let selection = try #require(items(selection: text).first { $0.kind == .selection })
        #expect(selection.badge == .count(3))
        #expect(selection.style == .active)
        #expect(selection.detail?.contains("line one line two") == true)
        #expect(selection.detail?.hasSuffix("…”") == true)
        #expect(AskContextChips.selectionPreview("short") == "short")
        #expect(AskContextChips.selectionPreview(String(repeating: "a", count: 61)).count == 61)
    }

    @Test func selectionIsAToggleThatStaysVisibleWhenOff() throws {
        let on = try #require(items(selection: "a\nb").first { $0.kind == .selection })
        #expect(!on.removable)
        #expect(on.hint == L("ask.context.selection.offHint"))
        let off = try #require(items(selection: "a\nb", selectionOff: true).first { $0.kind == .selection })
        #expect(!off.removable)
        #expect(off.style == .neutral)
        #expect(off.badge == nil)
        #expect(off.hint == L("ask.context.selection.onHint"))
        #expect(off.title == on.title)
    }

    @Test func memoryBadgesItsSourceAppAndPinnedMemoryIsReadOnly() throws {
        let appMemory = AskMemory(app: .init(id: "com.google.Chrome", name: "Google Chrome", excerpts: ["x"]))
        let draft = try #require(items(memory: appMemory).first { $0.kind == .memory })
        #expect(draft.badge == .app("com.google.Chrome"))
        // A toggle, not a removal: switched off it greys out and stays.
        #expect(!draft.removable && draft.style == .active && draft.hint == L("ask.context.memory.offHint"))
        let off = try #require(items(memory: appMemory, memoryOff: true).first { $0.kind == .memory })
        #expect(off.style == .neutral && off.hint == L("ask.context.memory.onHint"))
        #expect(off.badge == draft.badge && off.title == draft.title)
        let global = try #require(items(memory: AskMemory(global: "soul")).first { $0.kind == .memory })
        #expect(global.badge == nil)
        #expect(items(memory: AskMemory()).allSatisfy { $0.kind != .memory })
        let pinned = try #require(items(memory: appMemory, pinned: true).first { $0.kind == .memory })
        #expect(!pinned.removable && pinned.detail == L("ask.memory.pinned"))
        // Pinned memory is a toggle like a new question's: on by default, grey when switched off.
        #expect(pinned.style == .active && pinned.hint == L("ask.context.memory.offHint"))
        let pinnedOff = try #require(items(memory: appMemory, memoryOff: true, pinned: true).first { $0.kind == .memory })
        #expect(pinnedOff.style == .neutral && pinnedOff.hint == L("ask.context.memory.onHint"))
    }

    @Test func overflowFoldsSelectionAndMemoryFromTheRight() {
        let all = items(screenshot: .attached, source: "Chrome — Tab", selection: "a",
                        memory: AskMemory(global: "soul"))
        #expect(all.map(\.kind) == [.screenshot, .selection, .memory])
        let layouts = AskContextChips.layouts(all)
        #expect(layouts.count == 3)
        #expect(layouts[0].hidden.isEmpty)
        #expect(layouts[1].shown.map(\.kind) == [.screenshot, .selection])
        #expect(layouts[1].hidden.map(\.kind) == [.memory])
        #expect(layouts[2].shown.map(\.kind) == [.screenshot])
        #expect(layouts[2].hidden.map(\.kind) == [.selection, .memory])
        #expect(AskContextChips.layouts(items()).count == 1)
    }

    @Test func placeholderUsesTheEditorTextInset() {
        #expect(AskComposerTextView.lineFragmentPadding == 5)
    }

    @Test func draftsWithoutASourceBundleStillDecode() throws {
        let json = #"{"text":"hi","includeScreenshot":true,"source":"Finder"}"#
        let draft = try JSONDecoder().decode(AskDraft.self, from: Data(json.utf8))
        #expect(draft.source == "Finder")
        #expect(draft.sourceBundleID == nil)
        #expect(draft.memoryOff == nil)
    }

    @Test func everyLocalizationDefinesTheChipCopy() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in ["ask.context.screenshot", "ask.context.screenshot.attached", "ask.context.screenshot.offHint",
                        "ask.context.previewHint", "ask.context.more", "ask.context.details",
                        "ask.context.source", "ask.context.source.draft", "ask.context.source.included",
                        "ask.context.source.excluded", "ask.context.source.remove", "ask.context.source.restore",
                        "ask.context.source.none", "ask.context.refresh", "ask.context.refresh.hint",
                        "ask.context.refresh.failed", "ask.context.refresh.externalApp", "ask.context.screen.included", "ask.context.screen.excluded",
                        "ask.context.screen.scope", "ask.context.selection.source", "ask.context.selection.excluded",
                        "ask.context.memory.offHint", "ask.context.memory.onHint",
                        "ask.context.selection.offHint", "ask.context.selection.onHint",
                        "ask.models.isDefault", "ask.models.supportsImages"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(value != key, "Missing \(key) for \(language.rawValue)")
            }
        }
    }
}
