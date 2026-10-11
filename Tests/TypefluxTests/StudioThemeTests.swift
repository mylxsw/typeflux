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
            XCTAssertEqual(layout.sidebarInline, width >= 1040)
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

    func testOverviewLayoutUsesStackedArrangementForNarrowContent() {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: 700)

        XCTAssertEqual(layout.arrangement, .stacked)
        XCTAssertEqual(layout.activityWidth, 700)
        XCTAssertEqual(layout.metricsWidth, 700)
        XCTAssertGreaterThan(layout.height, StudioTheme.Layout.overviewPrimaryMinHeight)
    }

    func testOverviewLayoutUsesSideBySideArrangementForWideContent() {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: 1100)

        XCTAssertEqual(layout.arrangement, .sideBySide)
        XCTAssertEqual(layout.height, StudioTheme.Layout.overviewPrimaryMinHeight)
        XCTAssertLessThan(layout.metricsWidth, 1100)
        XCTAssertGreaterThan(layout.activityWidth, layout.metricsWidth)
    }
}
