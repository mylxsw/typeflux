@testable import Typeflux
import XCTest

final class ClipboardEntryActionTests: XCTestCase {
    func testAvailableActionsFollowTheEntryKind() {
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.voice)),
            [.paste, .pastePlainText, .copy, .retryTranscription, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.link)),
            [.paste, .pastePlainText, .copy, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.image, imagePath: "/i.png")),
            [.paste, .copy, .quickLook, .saveToDownloads, .copyImageText, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.image, filePaths: ["/i.png"])),
            [.paste, .pastePlainText, .copy, .quickLook, .revealInFinder, .copyImageText, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.files, filePaths: ["/a", "/b"])),
            [.paste, .pastePlainText, .copy, .quickLook, .revealInFinder, .togglePin, .delete]
        )
    }

    func testTitlesAreLocalizedAndContextual() {
        let text = ClipboardTestSupport.entry(.text)
        let file = ClipboardTestSupport.entry(.pdf, filePaths: ["/a.pdf"])
        let pinned = ClipboardTestSupport.entry(.text, isPinned: true)
        for action in ClipboardEntryAction.allCases {
            XCTAssertFalse(action.title(for: text).hasPrefix("clipboard."), "\(action)")
        }
        XCTAssertEqual(ClipboardEntryAction.pastePlainText.title(for: text), L("clipboard.action.pastePlainText"))
        XCTAssertEqual(ClipboardEntryAction.pastePlainText.title(for: file), L("clipboard.action.pastePath"))
        XCTAssertEqual(ClipboardEntryAction.togglePin.title(for: text), L("clipboard.action.pin"))
        XCTAssertEqual(ClipboardEntryAction.togglePin.title(for: pinned), L("clipboard.action.unpin"))
    }

    func testShortcutsAndContentRequirements() {
        XCTAssertEqual(ClipboardEntryAction.paste.shortcutLabel, "↩")
        XCTAssertEqual(ClipboardEntryAction.quickLook.shortcutLabel, "⌘Y")
        XCTAssertNil(ClipboardEntryAction.revealInFinder.shortcutLabel)
        XCTAssertTrue(ClipboardEntryAction.copy.requiresContent)
        XCTAssertFalse(ClipboardEntryAction.delete.requiresContent)
        XCTAssertFalse(ClipboardEntryAction.retryTranscription.requiresContent)
    }
}
