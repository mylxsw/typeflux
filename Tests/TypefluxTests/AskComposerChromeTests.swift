import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer chrome")
struct AskComposerChromeTests {
    @Test func workspaceUsesSolidContentWhileTheLauncherUsesGlass() {
        let launcher = AskComposerChrome.of(launcher: true)
        let workspace = AskComposerChrome.of(launcher: false)
        #expect(launcher.glass)
        #expect(!workspace.glass)
        // The workspace retains the composer layout while using the library content tokens.
        #expect(launcher.editorFontSize == 17)
        #expect(workspace.editorFontSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(workspace.editorTopInset == 14)
        #expect(workspace.footerLeadingInset == 10)
        #expect(workspace.corner == TypefluxRadius.form.value(for: .liquidGlass))
        #expect(workspace.horizontalInset == 20)
        #expect(workspace.footerHeight == 48)
        #expect(workspace.fill == TypefluxColor.controlBackground.color)
        #expect(launcher.fill == AskTheme.launcherSurface)
        // Only the floating launcher uses a glass material.
        #expect(launcher.placement == .floating)
        #expect(workspace.placement == .inWindow)
    }

    @Test func launcherKeepsTheMainSizingInBothStyles() {
        for style in InterfaceStyle.allCases {
            let launcher = AskComposerChrome.of(launcher: true, style: style)
            #expect(launcher == .launcher)
            #expect(launcher.corner == AskMetrics.launcherCardCorner)
            #expect(launcher.editorTopInset == 12)
            #expect(launcher.editorBottomInset == 12)
            #expect(launcher.horizontalInset == 12)
            #expect(launcher.footerHeight == 48)
            let layout = AskComposerLayout(launcher: true, compact: false, width: 680, availableHeight: nil)
            #expect(layout.editorTopInset == launcher.editorTopInset)
            #expect(layout.editorBottomInset == launcher.editorBottomInset)
            #expect(AskMetrics.launcherHeaderHeight(editor: 32) == 58)
            #expect(AskMetrics.launcherHeaderHeight(editor: 33) == 58)
            #expect(AskMetrics.launcherHeaderHeight(editor: 60) == 84)
            #expect(AskMetrics.launcherHeight(editor: 32, banners: 0) == 118)
            #expect(AskLauncherWindowMode.simpleHeight == 70)
        }
    }

    @Test func launcherEditorTextLinesUpWithTheModelName() {
        let launcher = AskComposerChrome.launcher
        let editorText = launcher.horizontalInset + AskComposerTextView.lineFragmentPadding
        let modelText = launcher.footerLeadingInset + AskMetrics.composerControlPadding
        #expect(editorText == modelText)
    }

    @Test func opaqueFallbackBordersMatchTheirSurface() {
        #expect(AskComposerChrome.workspace.fill == TypefluxColor.controlBackground.color)
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
