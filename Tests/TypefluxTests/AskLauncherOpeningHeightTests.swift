import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher opening height")
struct AskLauncherOpeningHeightTests {
    @Test(arguments: InterfaceStyle.allCases)
    func completeModeExpandsACachedCollapsedPanelImmediately(_ style: InterfaceStyle) {
        let collapsed = AskLauncherWindowMode.simpleHeight(for: style)
        let expanded = AskMetrics.launcherHeight(editor: 32, banners: 0, style: style)
        #expect(AskLauncherWindowMode.openingHeight(collapsed: false, cachedHeight: collapsed, style: style)
            == expanded)
        #expect(expanded > collapsed)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func completeModeKeepsATallerCachedViewport(_ style: InterfaceStyle) {
        let height: CGFloat = 440
        #expect(AskLauncherWindowMode.openingHeight(collapsed: false, cachedHeight: height, style: style) == height)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func simpleModeUsesItsCurrentStyleRegardlessOfTheCachedViewport(_ style: InterfaceStyle) {
        for cachedHeight: CGFloat in [0, 68, 440] {
            #expect(AskLauncherWindowMode.openingHeight(collapsed: true, cachedHeight: cachedHeight, style: style)
                == AskLauncherWindowMode.simpleHeight(for: style))
        }
    }
}
