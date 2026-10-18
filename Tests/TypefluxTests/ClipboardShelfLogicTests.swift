import AppKit
@testable import Typeflux
import XCTest

/// The shelf's keys, selection helpers, placement, wheel handling, header colors, card text and
/// the style setting.
final class ClipboardShelfLogicTests: XCTestCase {
    private func shelfCommand(
        _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil,
        queryIsEmpty: Bool = true, selection: Bool = false
    ) -> ClipboardPanelKeyCommand? {
        ClipboardPanelKeyCommand.command(
            keyCode: keyCode, modifiers: modifiers, characters: characters,
            queryIsEmpty: queryIsEmpty, hasTextSelection: selection, style: .shelf
        )
    }

    // MARK: - Keys

    func testShelfArrowsMoveTheSelectionEvenWhileSearching() {
        for query in [true, false] {
            XCTAssertEqual(shelfCommand(123, queryIsEmpty: query), .moveUp)
            XCTAssertEqual(shelfCommand(124, queryIsEmpty: query), .moveDown)
            XCTAssertEqual(shelfCommand(123, .command, queryIsEmpty: query), .moveToFirst)
            XCTAssertEqual(shelfCommand(124, .command, queryIsEmpty: query), .moveToLast)
        }
        XCTAssertEqual(shelfCommand(124, selection: true), .moveDown, "A search selection does not capture arrows")
        XCTAssertNil(shelfCommand(124, .shift), "Shift-arrows still extend the search selection")
        XCTAssertNil(shelfCommand(123, .option))
    }

    func testShelfVerticalArrowsAndSpaceControlThePreview() {
        XCTAssertEqual(shelfCommand(126), .showPreview)
        XCTAssertEqual(shelfCommand(125), .hidePreview)
        XCTAssertEqual(shelfCommand(49, [], " "), .togglePreview)
        XCTAssertNil(shelfCommand(49, [], " ", queryIsEmpty: false), "A space inside a search is typed")
        XCTAssertNil(shelfCommand(49, .shift, " "))
        XCTAssertNil(shelfCommand(126, .command))
    }

    func testShelfKeepsTheSharedShortcuts() {
        XCTAssertEqual(shelfCommand(36), .action(.paste))
        XCTAssertEqual(shelfCommand(36, .command), .action(.pastePlainText))
        XCTAssertEqual(shelfCommand(53), .cancel)
        XCTAssertEqual(shelfCommand(48), .nextCategory)
        XCTAssertEqual(shelfCommand(35, .command, "p"), .action(.togglePin))
        XCTAssertEqual(shelfCommand(51, .command), .action(.delete))
        XCTAssertEqual(shelfCommand(18, .command, "1"), .quickPaste(1))
        XCTAssertEqual(shelfCommand(42, .command, "\\"), .togglePreview)
    }

    func testListStyleKeepsItsArrows() {
        let list = { (keyCode: UInt16, query: Bool) in
            ClipboardPanelKeyCommand.command(keyCode: keyCode, modifiers: [], characters: nil,
                                             queryIsEmpty: query, hasTextSelection: false)
        }
        XCTAssertEqual(list(124, true), .showPreview)
        XCTAssertNil(list(124, false), "The list leaves arrows to a non-empty search")
        XCTAssertEqual(list(125, true), .moveDown)
        XCTAssertNil(ClipboardPanelKeyCommand.command(keyCode: 49, modifiers: [], characters: " ",
                                                       queryIsEmpty: true, hasTextSelection: false))
    }

    // MARK: - Model

    func testMoveToFirstAndLastClampToTheVisibleEntries() {
        let model = ClipboardPanelModel()
        model.moveToLast()
        XCTAssertEqual(model.selectedIndex, 0, "No entries: nothing to select")
        model.reset(entries: (0 ..< 4).map { ClipboardTestSupport.entry(.text, text: "item \($0)") })
        model.moveToLast()
        XCTAssertEqual(model.selectedIndex, 3)
        model.moveToFirst()
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testRecentSourceAppsAreUniqueInPanelOrderAndSkipVoiceAndSnippets() {
        var snippet = ClipboardTestSupport.entry(.text, text: "sig", sourceBundleID: "com.snippet", sourceAppName: "Snip")
        snippet.snippet = ClipboardSnippet(name: "Signature", alias: "")
        let model = ClipboardPanelModel()
        model.reset(entries: [
            ClipboardTestSupport.entry(.voice, text: "spoken"),
            snippet,
            ClipboardTestSupport.entry(.text, text: "a", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, text: "b", sourceBundleID: "com.apple.Notes", sourceAppName: "Notes"),
            ClipboardTestSupport.entry(.text, text: "c", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, text: "d", sourceBundleID: "", sourceAppName: "Blank"),
            ClipboardTestSupport.entry(.text, text: "e", sourceBundleID: "com.tinyspeck.slackmacgap")
        ])
        XCTAssertEqual(model.recentSourceApps(limit: 8), [
            ClipboardAppFilter(bundleID: "com.apple.Safari", name: "Safari"),
            ClipboardAppFilter(bundleID: "com.apple.Notes", name: "Notes"),
            ClipboardAppFilter(bundleID: "com.tinyspeck.slackmacgap", name: "com.tinyspeck.slackmacgap")
        ])
        XCTAssertEqual(model.recentSourceApps(limit: 1).map(\.bundleID), ["com.apple.Safari"])
        XCTAssertEqual(model.recentSourceApps(limit: 0), [])
    }

    // MARK: - Placement

    func testShelfSpansTheBottomOfTheUsableScreen() {
        let screen = NSRect(x: -1920, y: 70, width: 1920, height: 1010)
        let frame = ClipboardPanelPlacement.shelfFrame(height: 348, screen: screen)
        XCTAssertEqual(frame, NSRect(x: -1912, y: 78, width: 1904, height: 348))
        let tiny = ClipboardPanelPlacement.shelfFrame(height: 348, screen: NSRect(x: 0, y: 0, width: 10, height: 100))
        XCTAssertEqual(tiny, NSRect(x: 8, y: 8, width: 0, height: 84))
    }

    func testPreviewSitsAboveTheSelectedCardInsideTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let shelf = ClipboardPanelPlacement.shelfFrame(height: 348, screen: screen)
        let size = NSSize(width: 520, height: 380)
        let centred = ClipboardPanelPlacement.shelfPreviewFrame(size: size, shelf: shelf, cardMidX: 700, screen: screen)
        XCTAssertEqual(centred.midX, shelf.minX + 700)
        XCTAssertEqual(centred.minY, shelf.maxY + 8)
        XCTAssertEqual(centred.size, size)
        let left = ClipboardPanelPlacement.shelfPreviewFrame(size: size, shelf: shelf, cardMidX: 20, screen: screen)
        XCTAssertEqual(left.minX, 8)
        let right = ClipboardPanelPlacement.shelfPreviewFrame(size: size, shelf: shelf, cardMidX: 1430, screen: screen)
        XCTAssertEqual(right.maxX, 1432)
        let short = NSRect(x: 0, y: 0, width: 1440, height: 600)
        let clipped = ClipboardPanelPlacement.shelfPreviewFrame(
            size: size, shelf: ClipboardPanelPlacement.shelfFrame(height: 348, screen: short), cardMidX: 700, screen: short
        )
        XCTAssertEqual(clipped.maxY, 592, "A short screen keeps the preview's top edge on screen")
    }

    // MARK: - Wheel

    func testNotchedWheelMovesOneCardPerNotch() {
        XCTAssertEqual(ClipboardShelfScroll.selectionDelta(deltaX: 0, deltaY: -1, isPrecise: false), 1)
        XCTAssertEqual(ClipboardShelfScroll.selectionDelta(deltaX: 0, deltaY: 3, isPrecise: false), -1)
        XCTAssertNil(ClipboardShelfScroll.selectionDelta(deltaX: 0, deltaY: -1, isPrecise: true), "Trackpads scroll")
        XCTAssertNil(ClipboardShelfScroll.selectionDelta(deltaX: 4, deltaY: 1, isPrecise: false))
        XCTAssertNil(ClipboardShelfScroll.selectionDelta(deltaX: 0, deltaY: 0, isPrecise: false))
    }

    // MARK: - Header colors

    /// A square of `fill`; with `dot`, a grey square with a 2-point dot of `fill` in the middle.
    private func image(_ fill: NSColor, size: Int = 32, dot: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (dot ? NSColor.gray : fill).setFill()
            rect.fill()
            if dot {
                fill.setFill()
                NSRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2).fill()
            }
            return true
        }
    }

    func testDominantColorFollowsTheIconAndStaysReadable() throws {
        let red = try XCTUnwrap(ClipboardAppAccent.dominantColor(of: image(.systemRed)))
        XCTAssertGreaterThan(red.redComponent, red.greenComponent + 0.3)
        XCTAssertLessThanOrEqual(red.brightnessComponent, ClipboardAppAccent.maximumBrightness + 0.001)
        let dark = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1)
        let blue = try XCTUnwrap(ClipboardAppAccent.dominantColor(of: image(dark)))
        XCTAssertEqual(blue.blueComponent, 0.5, accuracy: 0.03, "Dark colors are kept as they are")
        XCTAssertEqual(blue.redComponent, 0.1, accuracy: 0.03)
    }

    func testGreyTransparentOrEmptyIconsHaveNoDominantColor() {
        XCTAssertNil(ClipboardAppAccent.dominantColor(of: image(.gray)))
        XCTAssertNil(ClipboardAppAccent.dominantColor(of: image(.clear)))
        XCTAssertNil(ClipboardAppAccent.dominantColor(of: NSImage(size: .zero)))
        XCTAssertNil(ClipboardAppAccent.dominantColor(of: image(.systemBlue, dot: true)),
                     "A small colored detail does not color the header")
    }

    func testReadableOnlyDarkensBrightColors() {
        let bright = ClipboardAppAccent.readable(NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1))
        XCTAssertEqual(bright.brightnessComponent, ClipboardAppAccent.maximumBrightness, accuracy: 0.001)
        let dark = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.4, alpha: 1)
        XCTAssertEqual(ClipboardAppAccent.readable(dark), dark.usingColorSpace(.sRGB))
    }

    @MainActor
    func testHeaderColorIsCachedPerAppAndFixedForVoiceAndSnippets() {
        let bundleID = "com.example.accent.\(UUID().uuidString)"
        let entry = ClipboardTestSupport.entry(.text, text: "a", sourceBundleID: bundleID)
        let first = ClipboardShelfCardHeader.color(for: entry, icon: image(.systemGreen))
        let again = ClipboardShelfCardHeader.color(for: entry, icon: image(.systemPurple))
        XCTAssertEqual(first, again, "The first icon decides the app's color")
        XCTAssertEqual(ClipboardShelfCardHeader.color(for: entry, icon: nil), ClipboardAppAccent.neutral)
        let grey = ClipboardTestSupport.entry(.text, text: "a", sourceBundleID: bundleID + ".grey")
        XCTAssertEqual(ClipboardShelfCardHeader.color(for: grey, icon: image(.gray)), ClipboardAppAccent.neutral)
        XCTAssertEqual(ClipboardShelfCardHeader.color(for: ClipboardTestSupport.entry(.voice, text: "v"), icon: nil),
                       ClipboardAppAccent.voice)
        var snippet = entry
        snippet.snippet = ClipboardSnippet(name: "Sig", alias: "")
        XCTAssertEqual(ClipboardShelfCardHeader.color(for: snippet, icon: image(.systemGreen)), ClipboardAppAccent.snippet)
    }

    // MARK: - Card text

    func testCardTextNamesTheKindAndOmitsWhatTheHeaderShows() {
        let date = Date().addingTimeInterval(-3600)
        let text = ClipboardTestSupport.entry(.text, date: date, text: "hello", sourceAppName: "Notes")
        XCTAssertEqual(ClipboardShelfCard.footerText(for: text, info: nil), L("clipboard.entry.characters", 5))
        let link = ClipboardTestSupport.entry(.link, text: "https://example.com/a")
        XCTAssertEqual(ClipboardShelfCard.footerText(for: link, info: nil), "example.com")
        let badLink = ClipboardTestSupport.entry(.link, text: "not a url")
        XCTAssertEqual(ClipboardShelfCard.footerText(for: badLink, info: nil), L("clipboard.entry.characters", 9))
        let image = ClipboardTestSupport.entry(.image, date: date, imagePath: "/tmp/a.png",
                                               imagePixelSize: CGSize(width: 40, height: 30), byteSize: 2048,
                                               sourceBundleID: "com.apple.Preview", sourceAppName: "Preview")
        let footer = ClipboardShelfCard.footerText(for: image, info: nil)
        XCTAssertTrue(footer.hasPrefix("PNG · 40×30 · "), footer)
        XCTAssertFalse(footer.contains("Preview"))
        let files = ClipboardTestSupport.entry(.files, date: date, filePaths: ["/a.txt", "/b.txt"])
        XCTAssertEqual(ClipboardShelfCard.footerText(for: files, info: nil), L("clipboard.kind.file"))
        var snippet = ClipboardTestSupport.entry(.text, text: "abc")
        snippet.snippet = ClipboardSnippet(name: "Sig", alias: "sign")
        XCTAssertEqual(ClipboardShelfCard.footerText(for: snippet, info: nil), L("clipboard.entry.characters", 3))
    }

    func testHeaderTitlesAndSubtitles() {
        let expected: [(ClipboardEntryKind, String)] = [
            (.voice, L("clipboard.kind.voice")), (.text, L("clipboard.kind.text")), (.link, L("clipboard.kind.link")),
            (.code, L("clipboard.kind.code")), (.image, L("clipboard.entry.image")), (.images, L("clipboard.kind.image")),
            (.pdf, "PDF"), (.video, L("clipboard.kind.video")), (.audio, L("clipboard.kind.audio")),
            (.files, L("clipboard.kind.file"))
        ]
        for (kind, title) in expected {
            XCTAssertEqual(ClipboardShelfCardHeader.kindTitle(for: ClipboardTestSupport.entry(kind)), title)
        }
        let document = ClipboardTestSupport.entry(.document, filePaths: ["/plan.docx"])
        XCTAssertEqual(ClipboardShelfCardHeader.kindTitle(for: document),
                       ClipboardContentClassifier.badge(forFilePath: "/plan.docx"))

        let now = Date()
        let recent = ClipboardTestSupport.entry(.text, date: now, text: "a")
        XCTAssertEqual(ClipboardShelfCardHeader.subtitle(for: recent, now: now), L("clipboard.time.justNow"))
        var snippet = recent
        snippet.snippet = ClipboardSnippet(name: "Sig", alias: "")
        XCTAssertEqual(ClipboardShelfCardHeader.kindTitle(for: snippet), "Sig")
        XCTAssertEqual(ClipboardShelfCardHeader.subtitle(for: snippet), L("clipboard.snippet.permanent"))
        snippet.snippet = ClipboardSnippet(name: "Sig", alias: "sign")
        XCTAssertEqual(ClipboardShelfCardHeader.subtitle(for: snippet), L("clipboard.snippet.voiceAlias", "sign"))
        XCTAssertEqual(ClipboardShelfCard.accessibilityLabel(for: recent), "\(L("clipboard.kind.text")), a")
    }

    // MARK: - Setting

    func testStyleDefaultsToTheListUntilOnboardingChoosesTheShelf() {
        let suite = "ClipboardShelfLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.clipboardPanelStyle, .list, "People who used the clipboard before keep the list")
        settings.applyNewUserClipboardDefaults()
        XCTAssertEqual(settings.clipboardPanelStyle, .shelf)
        settings.clipboardPanelStyle = .list
        settings.applyNewUserClipboardDefaults()
        XCTAssertEqual(settings.clipboardPanelStyle, .list, "A choice made before onboarding finishes is kept")
        defaults.set("cards", forKey: "clipboard.panelStyle")
        XCTAssertEqual(settings.clipboardPanelStyle, .list)

        let model = ClipboardSettingsModel(store: settings)
        model.setPanelStyle(.shelf)
        XCTAssertEqual(model.panelStyle, .shelf)
        XCTAssertEqual(settings.clipboardPanelStyle, .shelf)
        XCTAssertEqual(ClipboardSettingsModel(store: settings).panelStyle, .shelf)
        XCTAssertEqual(Set(ClipboardPanelStyle.allCases.map(\.title)).count, 2)
        XCTAssertEqual(ClipboardPanelStyle.shelf.id, "shelf")
    }
}
