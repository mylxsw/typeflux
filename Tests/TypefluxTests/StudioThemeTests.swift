@testable import Typeflux
import XCTest
import Foundation

final class StudioThemeTests: XCTestCase {
    // MARK: - Layout Constants

    func testLayoutConstantsArePositive() {
        XCTAssertGreaterThan(StudioTheme.Layout.sidebarWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.contentMaxWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.settingsWindowWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.overlayWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.contentInset, 0)
    }

    func testSidebarWidth() {
        XCTAssertEqual(StudioTheme.Layout.sidebarWidth, AskMetrics.sidebarWidth)
    }

    func testContentMaxWidth() {
        XCTAssertEqual(StudioTheme.Layout.contentMaxWidth, 1160)
    }

    func testSettingsWindowWidth() {
        XCTAssertEqual(StudioTheme.Layout.settingsWindowWidth, 1100)
    }

    func testSettingsWindowNavigationYieldsToNarrowContent() {
        for width: CGFloat in [720, 900, 1039, 1040, 1100, 1440] {
            let layout = StudioShellLayout(width: width)
            XCTAssertEqual(layout.sidebarWidth, width >= 1040 ? 220 : 0)
            XCTAssertGreaterThanOrEqual(layout.contentWidth, 672)
            XCTAssertLessThanOrEqual(layout.contentWidth + layout.sidebarWidth + layout.horizontalInset * 2, width)
        }
        XCTAssertLessThan(StudioTheme.Layout.settingsWindowMinWidth, StudioTheme.Layout.settingsWindowWidth)
        XCTAssertTrue(SettingsPaneMetrics.isCompact(contentWidth:
            StudioShellLayout(width: StudioTheme.Layout.settingsWindowMinWidth).contentWidth))
    }

    func testOverlayWidth() {
        XCTAssertEqual(StudioTheme.Layout.overlayWidth, 320)
    }

    // MARK: - Top-level Convenience Properties

    func testTopLevelSidebarWidthMatchesLayout() {
        XCTAssertEqual(StudioTheme.sidebarWidth, StudioTheme.Layout.sidebarWidth)
    }

    func testTopLevelContentMaxWidthMatchesLayout() {
        XCTAssertEqual(StudioTheme.contentMaxWidth, StudioTheme.Layout.contentMaxWidth)
    }

    func testTopLevelContentInsetMatchesLayout() {
        XCTAssertEqual(StudioTheme.contentInset, StudioTheme.Layout.contentInset)
    }

    func testModelProviderIconPlateUsesWhiteBackground() {
        XCTAssertEqual(StudioTheme.modelProviderIconPlate, .white)
    }

    func testModelProviderFallbackSymbolUsesDarkForeground() {
        XCTAssertEqual(StudioTheme.modelProviderFallbackSymbol, .black.opacity(0.72))
    }

    // MARK: - Overview Layout

    func testOverviewLayoutKeepsStatisticsBesideActivityAtSupportedWindowSizes() {
        for windowWidth: CGFloat in [720, 900, 1039, 1040, 1100, 1160, 1200, 1440] {
            let width = StudioShellLayout(width: windowWidth).contentWidth
            let layout = StudioOverviewPanelLayoutCalculator.layout(for: width)
            XCTAssertEqual(layout.height, 260)
            XCTAssertEqual(layout.activityWidth + layout.metricsWidth + StudioTheme.Spacing.large, width, accuracy: 0.01)
            XCTAssertGreaterThan(layout.activityWidth, layout.metricsWidth)
            XCTAssertGreaterThanOrEqual(layout.donutSize, 104)
            XCTAssertLessThanOrEqual(layout.donutSize, 154)
        }
    }

    func testOverviewLayoutDoesNotJumpAtFormerBreakpoint() {
        let before = StudioOverviewPanelLayoutCalculator.layout(for: 839)
        let after = StudioOverviewPanelLayoutCalculator.layout(for: 840)
        XCTAssertEqual(before.height, after.height)
        XCTAssertLessThan(abs(before.activityWidth - after.activityWidth), 1)
        XCTAssertLessThan(abs(before.metricsWidth - after.metricsWidth), 1)
        XCTAssertLessThan(abs(before.donutSize - after.donutSize), 1)
    }
}
