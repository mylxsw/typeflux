import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask captured content sizing")
@MainActor
struct AskCapturedComposerTests {
    @Test func measuredRowsGrowTheLauncherAndDisappearWithTheStrip() {
        let base = AskMetrics.launcherHeight(editor: 32, banners: 1, suggestions: AskLauncherSuggestions.typicalHeight)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1, suggestions: AskLauncherSuggestions.typicalHeight,
                                          attachments: true, attachmentHeight: 30) == base + 40)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1, suggestions: AskLauncherSuggestions.typicalHeight,
                                          attachments: true, attachmentHeight: 66) == base + 76)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1, suggestions: AskLauncherSuggestions.typicalHeight,
                                          attachments: false, attachmentHeight: 66) == base)
        #expect(AskMetrics.launcherHeight(editor: 32, banners: 1, suggestions: AskLauncherSuggestions.typicalHeight,
                                          attachments: true, attachmentHeight: -1) == base + 10)
    }

    @Test func heightPreferenceKeepsTheTallestVisibleStrip() {
        var height = AskCapturedStripHeight.defaultValue
        AskCapturedStripHeight.reduce(value: &height) { 30 }
        AskCapturedStripHeight.reduce(value: &height) { 66 }
        AskCapturedStripHeight.reduce(value: &height) { 30 }
        #expect(height == 66)
    }
}
