import Foundation
import Testing
@testable import Typeflux

@Suite("Ask context chips")
struct AskContextChipsTests {
    private func items(screenshot: AskScreenshotState = .off, source: String? = nil, bundle: String? = nil,
                       selection: String? = nil, memory: AskMemory? = nil,
                       pinned: Bool = false) -> [AskContextItem] {
        AskContextChips.items(screenshot: screenshot, source: source, sourceBundleID: bundle,
                              selection: selection, memory: memory, memoryPinned: pinned)
    }

    @Test func sourceSplitsAppFromWindowTitle() {
        let parts = AskContextChips.sourceParts("Google Chrome — Multica — Project Management")
        #expect(parts.app == "Google Chrome")
        #expect(parts.window == "Multica — Project Management")
        #expect(AskContextChips.sourceParts("Finder").app == "Finder")
        #expect(AskContextChips.sourceParts("Finder").window == nil)
        #expect(AskContextChips.sourceParts("Finder — ").window == nil)
    }

    @Test func sourceChipIsTheAppIconWithTheWindowInItsCard() throws {
        let source = try #require(items(source: "Google Chrome — Multica", bundle: "com.google.Chrome")
            .first { $0.kind == .source })
        #expect(source.appBundleID == "com.google.Chrome")
        #expect(source.title == "Google Chrome")
        #expect(source.detail == "Multica")
        #expect(!source.removable)
        #expect(items(source: "").allSatisfy { $0.kind != .source })
    }

    @Test func appIconTileCoversTheWholeChip() {
        let side = AskContextChips.appIconSide(chip: AskContextChips.chipSize)
        #expect(side == 35)
        // The visible tile (824 of 1024) reaches the chip's edges, so no ring of margin remains.
        #expect(side * AskContextChips.appIconTileFraction >= AskContextChips.chipSize)
        #expect(side * AskContextChips.appIconTileFraction < AskContextChips.chipSize + 1)
        #expect(AskContextChips.appIconSide(chip: 0) == 0)
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
        #expect(selection.removable)
        #expect(selection.detail?.contains("line one line two") == true)
        #expect(selection.detail?.hasSuffix("…”") == true)
        #expect(AskContextChips.selectionPreview("short") == "short")
        #expect(AskContextChips.selectionPreview(String(repeating: "a", count: 61)).count == 61)
    }

    @Test func memoryBadgesItsSourceAppAndPinnedMemoryIsReadOnly() throws {
        let appMemory = AskMemory(app: .init(id: "com.google.Chrome", name: "Google Chrome", excerpts: ["x"]))
        let draft = try #require(items(memory: appMemory).first { $0.kind == .memory })
        #expect(draft.badge == .app("com.google.Chrome"))
        #expect(draft.removable && draft.style == .active)
        let global = try #require(items(memory: AskMemory(global: "soul")).first { $0.kind == .memory })
        #expect(global.badge == nil)
        #expect(items(memory: AskMemory()).allSatisfy { $0.kind != .memory })
        let pinned = try #require(items(memory: appMemory, pinned: true).first { $0.kind == .memory })
        #expect(!pinned.removable && pinned.detail == L("ask.memory.pinned"))
    }

    @Test func overflowFoldsSelectionAndMemoryFromTheRight() {
        let all = items(screenshot: .attached, source: "Chrome — Tab", selection: "a",
                        memory: AskMemory(global: "soul"))
        #expect(all.map(\.kind) == [.screenshot, .source, .selection, .memory])
        let layouts = AskContextChips.layouts(all)
        #expect(layouts.count == 3)
        #expect(layouts[0].hidden.isEmpty)
        #expect(layouts[1].shown.map(\.kind) == [.screenshot, .source, .selection])
        #expect(layouts[1].hidden.map(\.kind) == [.memory])
        #expect(layouts[2].shown.map(\.kind) == [.screenshot, .source])
        #expect(layouts[2].hidden.map(\.kind) == [.selection, .memory])
        #expect(AskContextChips.layouts(items()).count == 1)
    }

    @Test func draftsWithoutASourceBundleStillDecode() throws {
        let json = #"{"text":"hi","includeScreenshot":true,"source":"Finder"}"#
        let draft = try JSONDecoder().decode(AskDraft.self, from: Data(json.utf8))
        #expect(draft.source == "Finder")
        #expect(draft.sourceBundleID == nil)
    }

    @Test func everyLocalizationDefinesTheChipCopy() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in ["ask.context.screenshot.attached", "ask.context.screenshot.offHint",
                        "ask.context.previewHint", "ask.context.more"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(value != key, "Missing \(key) for \(language.rawValue)")
            }
        }
    }
}
