@testable import Typeflux
import XCTest

final class ClipboardEntryActionTests: XCTestCase {
    func testAvailableActionsFollowTheEntryKind() {
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.voice)),
            [.paste, .pastePlainText, .editBeforePaste, .copy, .retryTranscription, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(.link)),
            [.paste, .pastePlainText, .editBeforePaste, .copy, .togglePin, .delete]
        )
        XCTAssertEqual(
            ClipboardEntryAction.available(for: ClipboardTestSupport.entry(
                .text, sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"
            )),
            [.paste, .pastePlainText, .editBeforePaste, .copy, .showOnlyApp, .togglePin, .delete, .deleteAllFromApp]
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
        let safari = ClipboardTestSupport.entry(.text, sourceBundleID: "com.apple.Safari", sourceAppName: "Safari")
        XCTAssertEqual(ClipboardEntryAction.showOnlyApp.title(for: safari), L("clipboard.action.showOnlyApp", "Safari"))
        XCTAssertEqual(
            ClipboardEntryAction.deleteAllFromApp.title(for: safari), L("clipboard.action.deleteAllFromApp", "Safari")
        )
        XCTAssertTrue(ClipboardEntryAction.showOnlyApp.title(for: safari).contains("Safari"))
    }

    func testShortcutsAndContentRequirements() {
        XCTAssertEqual(ClipboardEntryAction.paste.shortcutLabel, "↩")
        XCTAssertEqual(ClipboardEntryAction.quickLook.shortcutLabel, "⌘Y")
        XCTAssertNil(ClipboardEntryAction.revealInFinder.shortcutLabel)
        XCTAssertTrue(ClipboardEntryAction.copy.requiresContent)
        XCTAssertFalse(ClipboardEntryAction.delete.requiresContent)
        XCTAssertFalse(ClipboardEntryAction.retryTranscription.requiresContent)
        XCTAssertEqual(ClipboardEntryAction.editBeforePaste.shortcutLabel, "⌘E")
        for action in [ClipboardEntryAction.editBeforePaste, .showOnlyApp, .deleteAllFromApp] {
            XCTAssertFalse(action.requiresContent)
        }
        XCTAssertNil(ClipboardEntryAction.deleteAllFromApp.shortcutLabel)
        XCTAssertTrue(ClipboardPanelRow.startsMenuGroup(.togglePin, after: .copy))
        XCTAssertTrue(ClipboardPanelRow.startsMenuGroup(.showOnlyApp, after: .copy))
        XCTAssertFalse(ClipboardPanelRow.startsMenuGroup(.showOnlyApp, after: .revealInFinder))
        XCTAssertFalse(ClipboardPanelRow.startsMenuGroup(.deleteAllFromApp, after: .delete))
    }
}
