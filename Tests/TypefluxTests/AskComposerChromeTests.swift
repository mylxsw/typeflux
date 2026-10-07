import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer chrome")
struct AskComposerChromeTests {
    @Test func workspaceSharesTheLaunchersGlassCard() {
        let launcher = AskComposerChrome.of(launcher: true)
        let workspace = AskComposerChrome.of(launcher: false)
        #expect(launcher.glass)
        #expect(workspace.glass)
        // The same controls; the launcher reads as a search field in larger type,
        // and the in-window card takes the design board's larger corner, wider
        // text inset and its own glass tint.
        #expect(launcher.editorFontSize == 17)
        #expect(workspace.editorFontSize == 15)
        #expect(workspace.editorTopInset == 14)
        #expect(workspace.footerLeadingInset == 10)
        #expect(workspace.corner == 28)
        #expect(workspace.horizontalInset == 20)
        #expect(workspace.footerHeight == 48)
        #expect(workspace.fill == AskTheme.glassFill)
        #expect(launcher.fill == AskTheme.launcherSurface)
        // The launcher uses a deeper frost and samples other windows; the
        // workspace samples its own transcript with the in-window tint.
        #expect(launcher.placement == .floating)
        #expect(workspace.placement == .inWindow)
    }

    @Test func launcherUsesCompactCornersWithoutChangingHeaderLayout() {
        let launcher = AskComposerChrome.launcher
        // Compact card corners keep the existing editor and control spacing.
        #expect(launcher.horizontalInset == 12)
        #expect(launcher.editorTopInset == 12)
        #expect(launcher.corner == 16)
        #expect(launcher.corner == AskMetrics.launcherCardCorner)
        // One line of text keeps the header at 58pt, with the buttons centred in it.
        #expect(AskMetrics.launcherHeaderHeight(editor: 32) == 58)
        #expect(AskMetrics.launcherHeaderHeight(editor: 33) == 58)
        #expect(AskMetrics.launcherHeaderHeight(editor: 60) == 84)
        // The bottom bar holds the same 34pt controls with 4pt to spare above and below.
        #expect((launcher.footerHeight - AskMetrics.composerControlHeight) / 2 == 4)
    }

    @Test func launcherEditorTextLinesUpWithTheModelName() {
        let launcher = AskComposerChrome.launcher
        let editorText = launcher.horizontalInset + AskComposerTextView.lineFragmentPadding
        let modelText = launcher.footerLeadingInset + AskMetrics.composerControlPadding
        #expect(editorText == modelText)
    }

    @Test func opaqueFallbackBordersMatchTheirSurface() {
        #expect(AskComposerChrome.workspace.fill == AskTheme.glassFill)
        #expect(AskComposerChrome.workspace.idleBorder == AskTheme.border)
        #expect(AskComposerChrome.launcher.idleBorder == AskTheme.floatingBorder)
    }

    @Test func recordingEdgeIsTheSameOnBothSurfaces() {
        for chrome in [AskComposerChrome.launcher, .workspace] {
            #expect(AskVoiceBorder.borderColor(listening: true, idle: chrome.idleBorder) == AskTheme.accent)
            #expect(AskVoiceBorder.borderColor(listening: false, idle: chrome.idleBorder) == chrome.idleBorder)
        }
    }

    @Test func everyLocalizationNamesTheUnavailableScreenshotChip() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            let value = bundle.localizedString(forKey: "ask.screenshot.unavailable", value: nil, table: nil)
            #expect(value != "ask.screenshot.unavailable", "Missing chip title for \(language.rawValue)")
        }
    }
}
