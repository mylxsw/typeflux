import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer chrome")
struct AskComposerChromeTests {
    @Test func launcherMatchesTheWorkspaceComposerExceptItsEdge() {
        let launcher = AskComposerChrome.of(launcher: true)
        let workspace = AskComposerChrome.of(launcher: false)
        #expect(launcher.fill == workspace.fill)
        #expect(launcher.corner == workspace.corner)
        #expect(launcher.editorFontSize == workspace.editorFontSize)
        #expect(launcher.horizontalInset == workspace.horizontalInset)
        #expect(launcher.idleBorder != workspace.idleBorder)
        var aligned = launcher
        aligned.idleBorder = workspace.idleBorder
        #expect(aligned == workspace)
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
