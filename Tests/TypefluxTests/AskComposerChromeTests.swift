import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer chrome")
struct AskComposerChromeTests {
    @Test func launcherIsAGlassCardAndTheWorkspaceStaysOpaque() {
        let launcher = AskComposerChrome.of(launcher: true)
        let workspace = AskComposerChrome.of(launcher: false)
        #expect(launcher.glass)
        #expect(!workspace.glass)
        // Reduce Transparency falls back to the same opaque surface as the workspace.
        #expect(launcher.fill == workspace.fill)
        #expect(launcher.corner > workspace.corner)
        #expect(launcher.editorFontSize > workspace.editorFontSize)
        #expect(launcher.footerHeight > workspace.footerHeight)
    }

    @Test func launcherCornerIsConcentricWithTheFooterControls() {
        let launcher = AskComposerChrome.launcher
        // The send button sits 10pt from the trailing edge; the corner wraps it at the same centre.
        #expect(launcher.corner == 10 + AskMetrics.composerControlHeight / 2)
        // Controls are vertically centred in the footer with the same 10pt clearance.
        #expect((launcher.footerHeight - AskMetrics.composerControlHeight) / 2 == 10)
        #expect(launcher.footerLeadingInset == 10)
    }

    @Test func launcherEditorTextLinesUpWithTheModelName() {
        let launcher = AskComposerChrome.launcher
        let editorText = launcher.horizontalInset + AskComposerTextView.lineFragmentPadding
        let modelText = launcher.footerLeadingInset + AskMetrics.composerControlPadding
        #expect(editorText == modelText)
    }

    @Test func workspaceChromeUsesTheComposerTokens() {
        let workspace = AskComposerChrome.workspace
        #expect(workspace.fill == AskTheme.composerSurface)
        #expect(workspace.corner == AskMetrics.composerCardCorner)
        #expect(workspace.idleBorder == AskTheme.border)
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
